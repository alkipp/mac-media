#!/usr/bin/env python3
"""photo-mcp — Bild- und Audio-Helfer als MCP-Backend für mac-compute.

Läuft auf dem Mac in einer eigenen venv (torch + transformers + spandrel).
Je Aufruf ist höchstens ein Modell geladen; vor dem Laden wird das Textmodell
in llama-swap entladen. Ein- und Ausgaben laufen über den inbox/artifacts-
Vertrag des Gateways.

Tools:
  models       — geladenes Modell und Pfade
  unload       — Modelle freigeben
  depth        — Tiefenkarte (Depth Anything V2 Large)
  upscale      — 2x/4x (Real-ESRGAN x4plus)
  matte        — Freistellen mit Alpha (BiRefNet)
  segment      — Maske aus Punkt oder Box (SAM 2.1 large)
  transcribe   — Untertitel/Text (Whisper large-v3-turbo, whisper.cpp)

Kein RIFE: Frame-Interpolation folgt separat (MLX).
"""

from __future__ import annotations

import gc
import json
import os
import shutil
import subprocess  # nosec B404 - feste Binärpfade, keine Shell
import sys
import time
import urllib.request
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any, cast

import numpy as np
import torch
from PIL import Image

HOME = Path.home()
APP_SUPPORT = HOME / "Library/Application Support/mac-compute"
INBOX = APP_SUPPORT / "inbox"
ARTIFACTS = APP_SUPPORT / "artifacts"
MODELS = HOME / "models/photo"
LLAMA_SWAP_KEY = HOME / ".config/llama-swap/api-key"
LLAMA_SWAP_URL = "http://127.0.0.1:8080"

DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
VERSION = "0.2.0"
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
WHISPER_CLI = shutil.which("whisper-cli") or "/opt/homebrew/bin/whisper-cli"

# Halbe Genauigkeit auf der GPU: auf dem M2 Pro rund 1,5–2× schneller und
# halber Speicher, bei Bildmodellen ohne sichtbaren Unterschied. `PHOTO_FP16=0`
# schaltet zurück, falls ein Modell damit Artefakte zeigt.
FP16 = os.environ.get("PHOTO_FP16", "1") != "0" and DEVICE == "mps"

MODEL_PATHS = {
    "depth": MODELS / "depth-anything-v2-large",
    "sam": MODELS / "sam2.1-hiera-large",
    "matte": MODELS / "birefnet",
    "esrgan": MODELS / "real-esrgan/RealESRGAN_x4plus.pth",
    "esrgan2": MODELS / "real-esrgan/RealESRGAN_x2.pth",
    "whisper": MODELS / "whisper/ggml-large-v3-turbo.bin",
}

# Real-ESRGAN heißt im HF-Repo RealESRGAN_x4.pth.
if not MODEL_PATHS["esrgan"].exists():
    MODEL_PATHS["esrgan"] = MODELS / "real-esrgan/RealESRGAN_x4.pth"


def log(message: str) -> None:
    print(f"photo-mcp: {message}", file=sys.stderr, flush=True)


def unload_text_model() -> None:
    """Entlädt das Chat-Modell, damit die Pipeline den Speicher bekommt."""
    try:
        key = LLAMA_SWAP_KEY.read_text(encoding="utf-8").strip()
        request = urllib.request.Request(
            f"{LLAMA_SWAP_URL}/api/models/unload",
            method="POST",
            headers={"Authorization": f"Bearer {key}"},
        )
        with urllib.request.urlopen(request, timeout=15):  # nosec B310 - feste Adresse 127.0.0.1:8080
            pass
    except Exception as error:  # noqa: BLE001 - Entladen ist eine Vorstufe
        log(f"llama-swap nicht entladen: {error}")


def resolve_input(value: str) -> Path:
    """Pfad aus der Sandbox (/inbox/...) oder absolut unterhalb von INBOX."""
    raw = Path(value)
    if str(value).startswith("/inbox/"):
        raw = Path(str(value)[len("/inbox/") :])
    elif str(value).startswith("/artifacts/"):
        raise ValueError("Eingaben liegen unter /inbox, nicht unter /artifacts")
    candidate = (INBOX / raw).resolve() if not raw.is_absolute() else raw.resolve()
    if INBOX.resolve() not in candidate.parents and candidate != INBOX.resolve():
        raise ValueError(f"Pfad liegt nicht unter {INBOX}: {value}")
    if not candidate.is_file():
        raise ValueError(f"Datei fehlt: {candidate}")
    return candidate


def output_dir() -> Path:
    target = ARTIFACTS / str(uuid.uuid4())
    target.mkdir(parents=True, exist_ok=True)
    return target


def describe(path: Path) -> dict[str, Any]:
    relative = path.relative_to(ARTIFACTS)
    return {
        "path": str(path),
        "sandbox_path": f"/artifacts/{relative}",
        "bytes": path.stat().st_size,
    }


def load_image(path: Path) -> Image.Image:
    image = Image.open(path)
    return image.convert("RGB")


class Models:
    """Hält genau ein Modell; ein Wechsel gibt das vorige frei."""

    def __init__(self) -> None:
        self.current: str | None = None
        self.payload: Any = None

    def require(self, name: str, path: Path) -> None:
        if not path.exists():
            raise ValueError(f"Modell fehlt: {path}")
        if self.current == name:
            return
        self.unload()
        unload_text_model()
        log(f"lade {name} von {path} auf {DEVICE}")
        self.current = name
        self.payload = self._load(name, path)

    def _load(self, name: str, path: Path) -> Any:
        from transformers import (
            AutoImageProcessor,
            AutoModelForDepthEstimation,
            AutoModelForImageSegmentation,
            Sam2Model,
            Sam2Processor,
        )

        if name == "depth":
            processor = AutoImageProcessor.from_pretrained(  # nosec B615 - local_files_only
                path, local_files_only=True
            )
            model = (
                AutoModelForDepthEstimation.from_pretrained(  # nosec B615 - local_files_only
                    path, local_files_only=True
                )
                .to(DEVICE)
                .eval()
            )
            if FP16:
                model = model.half()
            return processor, model
        if name == "matte":
            model = (
                AutoModelForImageSegmentation.from_pretrained(  # nosec B615 - local_files_only
                    path, trust_remote_code=True, local_files_only=True
                )
                .to(DEVICE)
                .eval()
            )
            if FP16:
                model = model.half()
            return model
        if name == "sam":
            processor = Sam2Processor.from_pretrained(  # nosec B615 - local_files_only
                path, local_files_only=True
            )
            loaded: Any = Sam2Model.from_pretrained(  # nosec B615 - local_files_only
                path, local_files_only=True
            )
            model = loaded.to(DEVICE).eval()
            return processor, model
        if name in ("esrgan", "esrgan2"):
            from spandrel import ModelLoader

            descriptor = ModelLoader().load_from_file(str(path))
            model = descriptor.model.to(DEVICE).eval()
            if FP16:
                model = model.half()
            return model
        raise ValueError(f"unbekanntes Modell: {name}")

    def unload(self) -> None:
        if self.payload is None:
            return
        self.payload = None
        self.current = None
        gc.collect()
        if DEVICE == "mps":
            torch.mps.empty_cache()


MODELS_CACHE = Models()


def tool_depth(args: dict[str, Any]) -> dict[str, Any]:
    from PIL import Image as PILImage

    source = resolve_input(str(args.get("path", "")))
    image = load_image(source)
    MODELS_CACHE.require("depth", MODEL_PATHS["depth"])
    processor, model = MODELS_CACHE.payload

    started = time.time()
    inputs = processor(images=image, return_tensors="pt")
    if FP16:
        inputs = {
            key: value.half() if value.is_floating_point() else value
            for key, value in inputs.items()
        }
    inputs = {key: value.to(DEVICE) for key, value in inputs.items()}
    with torch.no_grad():
        prediction = model(**inputs).predicted_depth
    prediction = prediction.float()
    prediction = torch.nn.functional.interpolate(
        prediction.unsqueeze(1),
        size=image.size[::-1],
        mode="bicubic",
        align_corners=False,
    ).squeeze()
    values = prediction.detach().cpu().numpy().astype(np.float32)
    values = values - values.min()
    peak = float(values.max())
    if peak > 0:
        values = values / peak
    target = output_dir() / "depth.png"
    PILImage.fromarray((values * 255).round().astype(np.uint8)).save(target)
    np.save(target.with_suffix(".npy"), values)
    result = describe(target)
    result.update(
        {
            "width": image.width,
            "height": image.height,
            "ms": round((time.time() - started) * 1000),
        }
    )
    return result


def _run_esrgan(model: Any, image: Image.Image, factor: int = 4) -> Image.Image:
    array = np.asarray(image).astype(np.float32) / 255.0
    dtype = next(model.parameters()).dtype
    tensor = torch.from_numpy(array).permute(2, 0, 1).unsqueeze(0).to(DEVICE, dtype)
    # Auf ein Vielfaches von 8 auffüllen, damit die Pixel-Shuffle-Schichten passen.
    height, width = tensor.shape[-2:]
    pad_h = (8 - height % 8) % 8
    pad_w = (8 - width % 8) % 8
    if pad_h or pad_w:
        tensor = torch.nn.functional.pad(tensor, (0, pad_w, 0, pad_h), mode="reflect")
    with torch.no_grad():
        output = model(tensor)
    output = output.float().clamp(0, 1).squeeze(0).permute(1, 2, 0).cpu().numpy()
    output = (output * 255).round().astype(np.uint8)
    result = Image.fromarray(output)
    return result.crop((0, 0, width * factor, height * factor))


def tool_upscale(args: dict[str, Any]) -> dict[str, Any]:
    source = resolve_input(str(args.get("path", "")))
    scale = int(args.get("scale", 4))
    if scale not in (2, 4):
        raise ValueError("scale muss 2 oder 4 sein")
    image = load_image(source)
    if max(image.size) > 1536:
        raise ValueError("Bild ist größer als 1536 px; vorher verkleinern")
    # Für 2× gibt es ein eigenes x2-Modell: halb so viele Ausgabepixel wie beim
    # x4-Modell und ohne Lanczos-Verkleinerung. Fehlt es, bleibt der alte Weg.
    if scale == 2 and MODEL_PATHS["esrgan2"].exists():
        MODELS_CACHE.require("esrgan2", MODEL_PATHS["esrgan2"])
        factor = 2
    else:
        MODELS_CACHE.require("esrgan", MODEL_PATHS["esrgan"])
        factor = 4
    started = time.time()
    result = _run_esrgan(MODELS_CACHE.payload, image, factor=factor)
    if scale == 2 and factor == 4:
        result = result.resize(
            (image.width * 2, image.height * 2),
            Image.Resampling.LANCZOS,  # type: ignore[attr-defined]
        )
    target = output_dir() / "upscaled.png"
    result.save(target)
    info = describe(target)
    info.update(
        {
            "width": result.width,
            "height": result.height,
            "ms": round((time.time() - started) * 1000),
        }
    )
    return info


def tool_matte(args: dict[str, Any]) -> dict[str, Any]:
    from PIL import Image as PILImage
    from torchvision import transforms

    source = resolve_input(str(args.get("path", "")))
    image = load_image(source)
    MODELS_CACHE.require("matte", MODEL_PATHS["matte"])
    model = MODELS_CACHE.payload

    started = time.time()
    preprocess = transforms.Compose(
        [
            transforms.Resize((1024, 1024)),
            transforms.ToTensor(),
            transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
        ]
    )
    tensor = preprocess(image).unsqueeze(0).to(DEVICE)
    if next(model.parameters()).dtype == torch.float16:
        tensor = tensor.half()
    with torch.no_grad():
        output = model(tensor)
    logits = output[-1] if isinstance(output, (list, tuple)) else output
    if hasattr(logits, "logits"):
        logits = logits.logits
    mask = torch.sigmoid(logits.float()).squeeze().detach().cpu().numpy()
    alpha = PILImage.fromarray((mask * 255).round().astype(np.uint8)).resize(
        image.size,
        Image.Resampling.LANCZOS,  # type: ignore[attr-defined]
    )
    rgba = image.convert("RGBA")
    rgba.putalpha(alpha)
    target = output_dir() / "matte.png"
    rgba.save(target)
    info = describe(target)
    info.update(
        {
            "width": image.width,
            "height": image.height,
            "ms": round((time.time() - started) * 1000),
        }
    )
    return info


def tool_segment(args: dict[str, Any]) -> dict[str, Any]:
    from PIL import Image as PILImage

    source = resolve_input(str(args.get("path", "")))
    image = load_image(source)
    points = args.get("points")
    box = args.get("box")
    if not points and not box:
        raise ValueError("points oder box angeben")
    MODELS_CACHE.require("sam", MODEL_PATHS["sam"])
    processor, model = MODELS_CACHE.payload

    kwargs: dict[str, Any] = {"images": image, "return_tensors": "pt"}
    if points:
        kwargs["input_points"] = [[[[float(p[0]), float(p[1])] for p in points]]]
        labels = args.get("labels")
        if labels:
            kwargs["input_labels"] = [[[int(value) for value in labels]]]
    if box:
        kwargs["input_boxes"] = [[[float(value) for value in box]]]

    started = time.time()
    inputs = processor(**kwargs).to(DEVICE)
    with torch.no_grad():
        output = model(**inputs, multimask_output=False)
    masks = processor.post_process_masks(
        output.pred_masks.cpu(),
        inputs["original_sizes"].cpu(),
        binarize=True,
    )
    mask = masks[0][0, 0].numpy().astype(np.uint8) * 255
    target = output_dir() / "mask.png"
    PILImage.fromarray(mask).save(target)
    info = describe(target)
    info.update(
        {
            "width": image.width,
            "height": image.height,
            "ms": round((time.time() - started) * 1000),
        }
    )
    return info


def tool_transcribe(args: dict[str, Any]) -> dict[str, Any]:
    source = resolve_input(str(args.get("path", "")))
    model = MODEL_PATHS["whisper"]
    if not model.exists():
        raise ValueError(f"Whisper-Modell fehlt: {model}")
    target = output_dir()
    audio = target / "audio.wav"
    unload_text_model()
    started = time.time()
    subprocess.run(  # nosec B603 - ffmpeg als fester Pfad, Argumente als Liste
        [
            FFMPEG,
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(source),
            "-ar",
            "16000",
            "-ac",
            "1",
            "-c:a",
            "pcm_s16le",
            str(audio),
        ],
        check=True,
        timeout=600,
    )
    prefix = target / "transcript"
    language = str(args.get("language", "auto"))
    command = [
        WHISPER_CLI,
        "-m",
        str(model),
        "-f",
        str(audio),
        "-osrt",
        "-otxt",
        "-of",
        str(prefix),
    ]
    if language and language != "auto":
        command += ["-l", language]
    subprocess.run(command, check=True, timeout=1800)  # nosec B603 - whisper-cli, Liste
    srt = prefix.with_suffix(".srt")
    txt = prefix.with_suffix(".txt")
    audio.unlink(missing_ok=True)
    text = txt.read_text(encoding="utf-8").strip() if txt.exists() else ""
    result: dict[str, Any] = {
        "text": text[:4000],
        "ms": round((time.time() - started) * 1000),
        "srt": describe(srt) if srt.exists() else None,
        "txt": describe(txt) if txt.exists() else None,
    }
    return result


TOOLS = {
    "models": {
        "description": "Zeigt das geladene Modell und die erwarteten Pfade.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "handler": lambda args: {
            "loaded": MODELS_CACHE.current,
            "device": DEVICE,
            "paths": {name: str(path) for name, path in MODEL_PATHS.items()},
        },
    },
    "unload": {
        "description": "Gibt das geladene Bildmodell frei.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "handler": lambda args: _unload(),
    },
    "depth": {
        "description": "Erzeugt eine Tiefenkarte (Depth Anything V2 Large).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Pfad unter /inbox"}
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": tool_depth,
    },
    "upscale": {
        "description": "Skaliert ein Bild 2x oder 4x hoch (Real-ESRGAN).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "scale": {"type": "integer", "enum": [2, 4], "default": 4},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": tool_upscale,
    },
    "matte": {
        "description": "Stellt ein Motiv frei und liefert RGBA (BiRefNet).",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": tool_matte,
    },
    "segment": {
        "description": "Erzeugt eine Maske aus Punkten oder einer Box (SAM 2.1 large).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "points": {
                    "type": "array",
                    "items": {"type": "array", "items": {"type": "number"}},
                },
                "labels": {"type": "array", "items": {"type": "integer"}},
                "box": {"type": "array", "items": {"type": "number"}},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": tool_segment,
    },
    "transcribe": {
        "description": "Transkribiert Audio/Video und liefert SRT und Text (Whisper).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "language": {"type": "string", "default": "auto"},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": tool_transcribe,
    },
}


def text_response(value: Any, error: bool = False) -> dict[str, Any]:
    body = (
        value
        if isinstance(value, str)
        else json.dumps(value, ensure_ascii=False, indent=2)
    )
    return {"content": [{"type": "text", "text": body}], "isError": error}


def _unload() -> dict[str, Any]:
    previous = MODELS_CACHE.current
    MODELS_CACHE.unload()
    return {"unloaded": True, "previous": previous}


def dispatch(message: dict[str, Any]) -> dict[str, Any] | None:
    method = message.get("method")
    identifier = message.get("id")
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": identifier,
            "result": {
                "protocolVersion": message.get("params", {}).get(
                    "protocolVersion", "2025-06-18"
                ),
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": {"name": "photo", "version": VERSION},
            },
        }
    if method == "ping":
        return {"jsonrpc": "2.0", "id": identifier, "result": {}}
    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": identifier,
            "result": {
                "tools": [
                    {
                        "name": name,
                        "description": tool["description"],
                        "inputSchema": tool["inputSchema"],
                    }
                    for name, tool in TOOLS.items()
                ]
            },
        }
    if method == "tools/call":
        name = message.get("params", {}).get("name")
        tool = TOOLS.get(name)
        if tool is None:
            return {
                "jsonrpc": "2.0",
                "id": identifier,
                "error": {"code": -32602, "message": f"unbekanntes Tool: {name}"},
            }
        try:
            handler = cast(Callable[[dict[str, Any]], Any], tool["handler"])
            result = handler(message.get("params", {}).get("arguments", {}))
            return {"jsonrpc": "2.0", "id": identifier, "result": text_response(result)}
        except Exception as error:  # noqa: BLE001 - als MCP-Fehler zurückgeben
            log(f"{name}: {error}")
            return {
                "jsonrpc": "2.0",
                "id": identifier,
                "result": text_response(str(error), error=True),
            }
        finally:
            # Kein Modell zwischen zwei Jobs halten: so ist auch bei parallelen
            # Backends (photo/gen) höchstens eine Pipeline resident.
            if name not in ("models", "unload"):
                MODELS_CACHE.unload()
    if isinstance(method, str) and method.startswith("notifications/"):
        return None
    if identifier is None:
        return None
    return {
        "jsonrpc": "2.0",
        "id": identifier,
        "error": {"code": -32601, "message": f"unbekannte Methode: {method}"},
    }


def main() -> None:
    log(f"bereit, Gerät {DEVICE}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError as error:
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": None,
                        "error": {"code": -32700, "message": str(error)},
                    }
                ),
                flush=True,
            )
            continue
        response = dispatch(message)
        if response is not None:
            print(json.dumps(response, ensure_ascii=False), flush=True)
    MODELS_CACHE.unload()


if __name__ == "__main__":
    main()
