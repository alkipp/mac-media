#!/usr/bin/env python3
"""gen-mcp — generative Bild- und OCR-Helfer als MCP-Backend für mac-compute.

FLUX.2 Klein 4B und Z-Image-Turbo laufen als mflux-CLI in einem Subprozess
(MLX, 4- bzw. 6-bit). PaddleOCR-VL läuft als eigener Worker in einer zweiten
venv (transformers 4.x), weil mflux transformers 5.x verlangt. Vor jedem Job
wird das Textmodell in llama-swap entladen; nach jedem Job ist kein Modell
mehr resident.

Tools:
  models     — Pfade und Zustand
  unload     — Hinweis (OCR läuft als Subprozess)
  txt2img    — Text zu Bild (FLUX.2 Klein 4B)
  zimage     — Text zu Bild (Z-Image-Turbo, 9 Schritte)
  sdxl       — Text zu Bild mit eigenem SDXL-Checkpoint (stable-diffusion.cpp)
  edit       — Bildbearbeitung mit Prompt (FLUX.2 Klein 4B)
  ocr        — Texterkennung (PaddleOCR-VL), task ocr/table/formula/chart
"""

from __future__ import annotations

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

HOME = Path.home()
APP_SUPPORT = HOME / "Library/Application Support/mac-compute"
INBOX = APP_SUPPORT / "inbox"
ARTIFACTS = APP_SUPPORT / "artifacts"
MODELS = HOME / "models/gen"
FLUX_DIR = MODELS / "flux2-klein-4b-mflux-q4"
ZIMAGE_DIR = MODELS / "z-image-turbo-mflux-q6"
SDXL_DIR = MODELS / "sdxl-local"
SDXL_MODEL = SDXL_DIR / "model.safetensors"
# diffusers-Ordner mit denselben Gewichten (Hardlinks): stabiler Pfad, offline.
SDXL_DIFFUSERS = SDXL_DIR / "diffusers"
SDXL_PYTHON = APP_SUPPORT / "venvs/sdxl/bin/python"
SDXL_WORKER = Path(__file__).resolve().parent / "sdxl_worker.py"
OCR_DIR = MODELS / "paddleocr-vl"
VIDEO_DIR = HOME / "models/video"
MESH_PYTHON = APP_SUPPORT / "venvs/mesh/bin/python"
MESH_RUN = HOME / "models/3d/TripoSR/run.py"
MESH_MODEL = HOME / "models/3d/triposr"
SD_CLI = APP_SUPPORT / "bin/sd-cli"
OCR_PYTHON = APP_SUPPORT / "venvs/ocr/bin/python"
WORKER = Path(__file__).resolve().parent / "ocr_worker.py"
COMPAT = Path(__file__).resolve().parent / "compat"
LLAMA_SWAP_KEY = HOME / ".config/llama-swap/api-key"
LLAMA_SWAP_URL = "http://127.0.0.1:8080"
# Zielordner für die Direktablage (`dest`). Im Container ist derselbe Ordner
# unter /workspace/ausgabe/bilder sichtbar.
EXPORT_DIR = Path(
    os.environ.get("MAC_COMPUTE_EXPORT_DIR", str(HOME / "workspace/ausgabe/bilder"))
)
# Kantenlänge der Prüf-Vorschau; klein genug für den Chat, groß genug für die
# Beurteilung von Schärfe, Dampf und Details.
PREVIEW_EDGE = 512
# Signatur einer PNG-Datei; nur echte Bilder bekommen eine Vorschau.
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
VERSION = "0.5.0"

FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
MFLUX = shutil.which("mflux-generate-flux2") or str(
    Path(sys.executable).parent / "mflux-generate-flux2"
)
MFLUX_ZIMAGE = shutil.which("mflux-generate-z-image-turbo") or str(
    Path(sys.executable).parent / "mflux-generate-z-image-turbo"
)
TASKS = {"ocr", "table", "formula", "chart"}
# Sampler, die für den SDXL-Checkpoint geprüft sind. Die Liste ist eng
# gehalten: ein falscher Name bricht in sd-cli erst nach dem Laden ab.
SDXL_SAMPLERS = {"euler", "euler_a", "dpm2", "dpm++2m", "dpm++2s_a", "lms"}
# Gewichtstyp beim Laden. Der Checkpoint liegt als f16 vor; q8_0 halbiert den
# Speicherbedarf, ohne eine zweite Datei auf Platte zu brauchen.
SDXL_TYPES = {"f16", "q8_0", "q5_1", "q4_1"}
# diffusers ist der Standard: der Metal-Pfad von sd.cpp liefert für SDXL auf
# diesem Mac nur weiße Bilder. sd-cli bleibt als Engine verfügbar (CPU-Device).
SDXL_ENGINES = {"diffusers", "sd-cli"}
SDXL_DEVICES = {"metal", "cpu"}
# Text für das `dest`-Feld in allen Bild-Tools.
DEST_DESCRIPTION = (
    "Dateiname im Exportordner (Vorgabe ~/workspace/ausgabe/bilder); "
    "nur flacher Name auf .png, kein Pfad"
)


def log(message: str) -> None:
    print(f"gen-mcp: {message}", file=sys.stderr, flush=True)


def unload_text_model() -> None:
    try:
        key = LLAMA_SWAP_KEY.read_text(encoding="utf-8").strip()
        request = urllib.request.Request(
            f"{LLAMA_SWAP_URL}/api/models/unload",
            method="POST",
            headers={"Authorization": f"Bearer {key}"},
        )
        with urllib.request.urlopen(request, timeout=15):  # nosec B310
            pass
    except Exception as error:  # noqa: BLE001 - Vorstufe, kein harter Fehler
        log(f"llama-swap nicht entladen: {error}")


def resolve_input(value: str) -> Path:
    raw = Path(value)
    if str(value).startswith("/inbox/"):
        raw = Path(str(value)[len("/inbox/") :])
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


def preview_path(target: Path) -> Path:
    """Pfad der Vorschau neben dem Vollbild."""
    return target.with_name(f"{target.stem}-preview.png")


def make_preview(target: Path, max_edge: int = PREVIEW_EDGE) -> dict[str, Any] | None:
    """Schreibt eine verkleinerte Vorschau neben das Bild.

    Die Vorschau dient der Sichtprüfung im Chat: sie ist klein genug, um sie
    ohne Kontextlast zu lesen, und ersetzt das Vollbild nur beim Prüfen, nicht
    bei der Auslieferung. Ohne `sips` (nicht-macOS) oder ohne echtes PNG
    entfällt sie still.
    """
    sips = shutil.which("sips")
    if sips is None:
        return None
    try:
        with target.open("rb") as handle:
            if handle.read(8) != PNG_MAGIC:
                return None
    except OSError as error:
        log(f"Vorschau übersprungen: {error}")
        return None
    preview = preview_path(target)
    result = subprocess.run(  # nosec B603
        [sips, "-Z", str(max_edge), str(target), "--out", str(preview)],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0 or not preview.exists():
        log(f"Vorschau fehlgeschlagen: {(result.stderr or '').strip()[:200]}")
        return None
    return describe(preview)


def safe_dest(value: Any) -> str | None:
    """Prüft einen Zieldateinamen für die Direktablage.

    Nur ein flacher Dateiname mit `.png` ist erlaubt: kein Verzeichnis, kein
    `..`, kein absoluter Pfad. So kann ein Aufruf nicht aus dem Exportordner
    ausbrechen.
    """
    if value is None:
        return None
    name = str(value).strip()
    if not name:
        return None
    if name.endswith(".png") is False:
        raise ValueError(f"dest muss auf .png enden: {name}")
    if "/" in name or "\\" in name or name in {".", ".."} or name.startswith("."):
        raise ValueError(f"dest ist kein flacher Dateiname: {name}")
    if len(name) > 120:
        raise ValueError("dest ist länger als 120 Zeichen")
    return name


def export_image(target: Path, dest: str | None) -> str | None:
    """Kopiert das Ergebnis in den Exportordner (`dest` als Dateiname)."""
    if dest is None:
        return None
    EXPORT_DIR.mkdir(parents=True, exist_ok=True)
    destination = EXPORT_DIR / dest
    shutil.copyfile(target, destination)
    return str(destination)


def clamp_dimension(value: int, default: int) -> int:
    size = int(value or default)
    size = max(256, min(size, 1536))
    return size - (size % 16)


def mflux_environment() -> dict[str, str]:
    """Umgebung für mflux-Subprozesse: Compat-Shim immer zuerst im PYTHONPATH."""
    environment = os.environ.copy()
    environment["PYTHONPATH"] = (
        f"{COMPAT}{os.pathsep}{environment['PYTHONPATH']}"
        if environment.get("PYTHONPATH")
        else str(COMPAT)
    )
    return environment


def finish_image(
    target: Path, info: dict[str, Any], dest: str | None
) -> dict[str, Any]:
    """Ergänzt Vorschau und Direktablage zu einem fertigen Bild-Ergebnis."""
    preview = make_preview(target)
    if preview is not None:
        info["preview"] = preview
    export = export_image(target, dest)
    if export is not None:
        info["export"] = export
    return info


def run_mflux(
    command: list[str], target: Path, meta: dict[str, Any], dest: str | None = None
) -> dict[str, Any]:
    started = time.time()
    result = subprocess.run(  # nosec B603
        command,
        capture_output=True,
        text=True,
        timeout=1800,
        check=False,
        env=mflux_environment(),
    )
    if result.returncode != 0 or not target.exists():
        detail = (result.stderr or result.stdout or "").strip().splitlines()[-6:]
        raise RuntimeError("mflux fehlgeschlagen: " + " | ".join(detail))
    info = describe(target)
    info.update(meta)
    info["ms"] = round((time.time() - started) * 1000)
    return finish_image(target, info, dest)


def tool_txt2img(args: dict[str, Any]) -> dict[str, Any]:
    prompt = str(args.get("prompt", "")).strip()
    if not prompt:
        raise ValueError("prompt ist leer")
    width = clamp_dimension(args.get("width", 1024), 1024)
    height = clamp_dimension(args.get("height", 1024), 1024)
    steps = max(1, min(int(args.get("steps", 4)), 50))
    seed = int(args.get("seed", 42))
    target = output_dir() / "image.png"
    unload_text_model()
    command = [
        MFLUX,
        "--model",
        str(FLUX_DIR),
        "--base-model",
        "flux2-klein-4b",
        "--low-ram",
        "--vae-tiling",
        "--prompt",
        prompt,
        "--steps",
        str(steps),
        "--seed",
        str(seed),
        "--width",
        str(width),
        "--height",
        str(height),
        "--output",
        str(target),
    ]
    return run_mflux(
        command,
        target,
        {
            "prompt": prompt,
            "width": width,
            "height": height,
            "steps": steps,
            "seed": seed,
        },
        safe_dest(args.get("dest")),
    )


def tool_zimage(args: dict[str, Any]) -> dict[str, Any]:
    prompt = str(args.get("prompt", "")).strip()
    if not prompt:
        raise ValueError("prompt ist leer")
    width = clamp_dimension(args.get("width", 1024), 1024)
    height = clamp_dimension(args.get("height", 1024), 1024)
    steps = max(1, min(int(args.get("steps", 9)), 50))
    seed = int(args.get("seed", 42))
    guidance = (
        max(0.0, min(float(args["guidance"]), 20.0))
        if args.get("guidance") is not None
        else None
    )
    target = output_dir() / "image.png"
    unload_text_model()
    command = [
        MFLUX_ZIMAGE,
        "--model",
        str(ZIMAGE_DIR),
        "--base-model",
        "z-image-turbo",
        "--low-ram",
        "--mlx-cache-limit-gb",
        "8",
        "--vae-tiling",
        "--prompt",
        prompt,
        "--steps",
        str(steps),
        "--seed",
        str(seed),
        "--width",
        str(width),
        "--height",
        str(height),
        "--output",
        str(target),
    ]
    if guidance is not None:
        command.extend(["--guidance", f"{guidance:g}"])
    meta = {
        "model": "z-image-turbo",
        "prompt": prompt,
        "width": width,
        "height": height,
        "steps": steps,
        "seed": seed,
    }
    if guidance is not None:
        meta["guidance"] = guidance
    return run_mflux(command, target, meta, safe_dest(args.get("dest")))


def sdxl_diffusers(
    prompt: str,
    negative: str,
    target: Path,
    width: int,
    height: int,
    steps: int,
    cfg_scale: float,
    seed: int,
    sampler: str,
) -> dict[str, Any]:
    """SDXL über diffusers auf MPS. Metall in sd.cpp liefert hier weiße Bilder."""
    if not SDXL_PYTHON.exists():
        raise ValueError(
            f"venv für SDXL fehlt: {SDXL_PYTHON} – Einrichtung siehe backends/gen/README.md"
        )
    if not SDXL_WORKER.exists():
        raise ValueError(f"Worker fehlt: {SDXL_WORKER}")
    if not (SDXL_DIFFUSERS.is_dir() or SDXL_MODEL.exists()):
        raise ValueError(f"SDXL-Gewichte fehlen: {SDXL_DIR}")
    command = [
        str(SDXL_PYTHON),
        str(SDXL_WORKER),
        "--model",
        str(SDXL_MODEL),
        "--diffusers-dir",
        str(SDXL_DIFFUSERS),
        "--prompt",
        prompt,
        "--negative-prompt",
        negative,
        "--output",
        str(target),
        "--width",
        str(width),
        "--height",
        str(height),
        "--steps",
        str(steps),
        "--cfg-scale",
        f"{cfg_scale:g}",
        "--seed",
        str(seed),
        "--sampler",
        sampler,
    ]
    result = subprocess.run(  # nosec B603
        command,
        capture_output=True,
        text=True,
        timeout=1800,
        check=False,
    )
    if result.returncode != 0 or not target.exists():
        detail = (result.stderr or result.stdout or "").strip().splitlines()[-8:]
        raise RuntimeError("sdxl_worker fehlgeschlagen: " + " | ".join(detail))
    return {"engine": "diffusers", "device": "mps"}


def sdxl_sd_cli(
    prompt: str,
    negative: str,
    target: Path,
    width: int,
    height: int,
    steps: int,
    cfg_scale: float,
    seed: int,
    sampler: str,
    weight_type: str,
    device: str,
) -> dict[str, Any]:
    """SDXL über stable-diffusion.cpp.

    Der Metal-Pfad dieses Builds liefert auf dem M2 Pro nur weiße Bilder
    (geprüft mit baf45b4 und be48649, f16/f32, Flash-Attention aus, Textencoder
    auf CPU). Mit device=cpu rechnet es korrekt, aber langsam.
    """
    if not SD_CLI.exists():
        raise ValueError(f"sd-cli fehlt: {SD_CLI}")
    if not SDXL_MODEL.exists():
        raise ValueError(f"SDXL-Checkpoint fehlt: {SDXL_MODEL}")
    command = [
        str(SD_CLI),
        "-M",
        "img_gen",
        "-m",
        str(SDXL_MODEL),
        "-p",
        prompt,
        "-n",
        negative,
        "-W",
        str(width),
        "-H",
        str(height),
        "--steps",
        str(steps),
        "--cfg-scale",
        f"{cfg_scale:g}",
        "--sampling-method",
        sampler,
        "--seed",
        str(seed),
        "--type",
        weight_type,
        # 16 GB: VAE in Kacheln und auf der CPU, das UNet bleibt auf Metal.
        "--vae-tiling",
        "--backend",
        "vae=cpu" if device == "metal" else "cpu",
        "-o",
        str(target),
    ]
    result = subprocess.run(  # nosec B603
        command,
        capture_output=True,
        text=True,
        timeout=3600,
        check=False,
    )
    if result.returncode != 0 or not target.exists():
        detail = (result.stderr or result.stdout or "").strip().splitlines()[-8:]
        raise RuntimeError("sd-cli fehlgeschlagen: " + " | ".join(detail))
    return {"engine": "sd-cli", "device": device}


def tool_sdxl(args: dict[str, Any]) -> dict[str, Any]:
    prompt = str(args.get("prompt", "")).strip()
    if not prompt:
        raise ValueError("prompt ist leer")
    width = clamp_dimension(args.get("width", 1024), 1024)
    height = clamp_dimension(args.get("height", 1024), 1024)
    steps = max(1, min(int(args.get("steps", 25)), 60))
    seed = int(args.get("seed", 42))
    cfg_scale = max(1.0, min(float(args.get("cfg_scale", 7.0)), 20.0))
    sampler = str(args.get("sampling_method", "dpm++2m"))
    if sampler not in SDXL_SAMPLERS:
        raise ValueError(
            f"sampling_method unbekannt: {sampler} (erlaubt: {sorted(SDXL_SAMPLERS)})"
        )
    engine = str(args.get("engine", "diffusers"))
    if engine not in SDXL_ENGINES:
        raise ValueError(
            f"engine unbekannt: {engine} (erlaubt: {sorted(SDXL_ENGINES)})"
        )
    device = str(args.get("device", "metal"))
    if device not in SDXL_DEVICES:
        raise ValueError(
            f"device unbekannt: {device} (erlaubt: {sorted(SDXL_DEVICES)})"
        )
    weight_type = str(args.get("type", "q8_0"))
    if weight_type not in SDXL_TYPES:
        raise ValueError(
            f"type unbekannt: {weight_type} (erlaubt: {sorted(SDXL_TYPES)})"
        )
    negative = str(args.get("negative_prompt", "blurry, low quality, watermark, text"))
    target = output_dir() / "image.png"
    unload_text_model()
    started = time.time()
    if engine == "diffusers":
        info = sdxl_diffusers(
            prompt, negative, target, width, height, steps, cfg_scale, seed, sampler
        )
    else:
        info = sdxl_sd_cli(
            prompt,
            negative,
            target,
            width,
            height,
            steps,
            cfg_scale,
            seed,
            sampler,
            weight_type,
            device,
        )
    info.update(
        {
            "model": "sdxl-local",
            "prompt": prompt,
            "negative_prompt": negative,
            "width": width,
            "height": height,
            "steps": steps,
            "cfg_scale": cfg_scale,
            "sampling_method": sampler,
            "seed": seed,
            "ms": round((time.time() - started) * 1000),
        }
    )
    if engine == "sd-cli":
        info["type"] = weight_type
    info.update(describe(target))
    return finish_image(target, info, safe_dest(args.get("dest")))


def tool_edit(args: dict[str, Any]) -> dict[str, Any]:
    prompt = str(args.get("prompt", "")).strip()
    images = args.get("images") or []
    if not prompt:
        raise ValueError("prompt ist leer")
    if not isinstance(images, list) or not images:
        raise ValueError("images ist leer")
    source = resolve_input(str(images[0]))
    strength = float(args.get("strength", 0.6))
    steps = max(1, min(int(args.get("steps", 4)), 50))
    seed = int(args.get("seed", 42))
    target = output_dir() / "edited.png"
    unload_text_model()
    command = [
        MFLUX,
        "--model",
        str(FLUX_DIR),
        "--base-model",
        "flux2-klein-4b",
        "--low-ram",
        "--vae-tiling",
        "--prompt",
        prompt,
        "--image-path",
        str(source),
        "--image-strength",
        str(max(0.0, min(strength, 1.0))),
        "--steps",
        str(steps),
        "--seed",
        str(seed),
        "--output",
        str(target),
    ]
    return run_mflux(
        command,
        target,
        {"prompt": prompt, "strength": strength, "steps": steps, "seed": seed},
        safe_dest(args.get("dest")),
    )


def tool_ocr(args: dict[str, Any]) -> dict[str, Any]:
    source = resolve_input(str(args.get("path", "")))
    task = str(args.get("task", "ocr"))
    if task not in TASKS:
        raise ValueError(f"task muss einer von {sorted(TASKS)} sein")
    if not OCR_PYTHON.exists():
        raise ValueError(f"OCR-venv fehlt: {OCR_PYTHON}")
    if not WORKER.exists():
        raise ValueError(f"OCR-Worker fehlt: {WORKER}")
    max_tokens = max(32, min(int(args.get("max_tokens", 1024)), 4096))
    unload_text_model()
    result = subprocess.run(  # nosec B603
        [
            str(OCR_PYTHON),
            str(WORKER),
            "--path",
            str(source),
            "--model-dir",
            str(OCR_DIR),
            "--task",
            task,
            "--max-tokens",
            str(max_tokens),
        ],
        capture_output=True,
        text=True,
        timeout=1800,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip().splitlines()[-6:]
        raise RuntimeError("PaddleOCR-VL fehlgeschlagen: " + " | ".join(detail))
    try:
        payload = json.loads(result.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError) as error:
        raise RuntimeError(f"OCR-Antwort unlesbar: {result.stdout[:300]}") from error
    payload["source"] = str(source)
    return payload


def tool_video(args: dict[str, Any]) -> dict[str, Any]:
    prompt = str(args.get("prompt", "")).strip()
    if not prompt:
        raise ValueError("prompt ist leer")
    width = clamp_dimension(args.get("width", 512), 512)
    height = clamp_dimension(args.get("height", 288), 288)
    frames = max(5, min(int(args.get("frames", 29)), 121))
    steps = max(1, min(int(args.get("steps", 20)), 60))
    seed = int(args.get("seed", 42))
    cfg = float(args.get("cfg_scale", 6.0))
    negative = str(
        args.get("negative_prompt", "blurry, low quality, static, watermark, text")
    )
    if not SD_CLI.exists():
        raise ValueError(f"sd-cli fehlt: {SD_CLI}")
    if not (VIDEO_DIR / "Wan2.2-TI2V-5B-Q4_K_M.gguf").exists():
        raise ValueError(f"Wan2.2-Modell fehlt unter {VIDEO_DIR}")
    target = output_dir()
    webm = target / "video.webm"
    mp4 = target / "video.mp4"
    unload_text_model()
    started = time.time()
    command = [
        str(SD_CLI),
        "-M",
        "vid_gen",
        "--diffusion-model",
        str(VIDEO_DIR / "Wan2.2-TI2V-5B-Q4_K_M.gguf"),
        "--t5xxl",
        str(VIDEO_DIR / "umt5-xxl-encoder-Q4_K_M.gguf"),
        "--vae",
        str(VIDEO_DIR / "wan2.2_vae.safetensors"),
        "--vae-format",
        "wan",
        "--backend",
        "vae=cpu",
        "-p",
        prompt,
        "-n",
        negative,
        "-W",
        str(width),
        "-H",
        str(height),
        "--video-frames",
        str(frames),
        "--steps",
        str(steps),
        "--cfg-scale",
        str(cfg),
        "--sampling-method",
        "euler",
        "--flow-shift",
        "3.0",
        "--seed",
        str(seed),
        "-o",
        str(webm),
    ]
    result = subprocess.run(  # nosec B603
        command,
        capture_output=True,
        text=True,
        timeout=3600,
        check=False,
    )
    if result.returncode != 0 or not webm.exists():
        detail = (result.stderr or result.stdout or "").strip().splitlines()[-8:]
        raise RuntimeError("sd-cli fehlgeschlagen: " + " | ".join(detail))
    transcode = subprocess.run(  # nosec B603
        [
            FFMPEG,
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(webm),
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(mp4),
        ],
        capture_output=True,
        text=True,
        timeout=600,
        check=False,
    )
    if transcode.returncode != 0 or not mp4.exists():
        raise RuntimeError(
            "ffmpeg-Transcode fehlgeschlagen: " + transcode.stderr.strip()
        )
    webm.unlink(missing_ok=True)
    info = describe(mp4)
    info.update(
        {
            "prompt": prompt,
            "width": width,
            "height": height,
            "frames": frames,
            "steps": steps,
            "seed": seed,
            "cfg_scale": cfg,
            "ms": round((time.time() - started) * 1000),
        }
    )
    return info


def tool_mesh(args: dict[str, Any]) -> dict[str, Any]:
    source = resolve_input(str(args.get("path", "")))
    if not MESH_PYTHON.exists():
        raise ValueError(f"Mesh-venv fehlt: {MESH_PYTHON}")
    if not MESH_RUN.exists():
        raise ValueError(f"TripoSR fehlt: {MESH_RUN}")
    target = output_dir()
    work = target / "work"
    (work / "0").mkdir(parents=True, exist_ok=True)
    command = [
        str(MESH_PYTHON),
        str(MESH_RUN),
        str(source),
        "--device",
        "mps",
        "--pretrained-model-name-or-path",
        str(MESH_MODEL),
        "--output-dir",
        str(work),
    ]
    if not bool(args.get("remove_bg", True)):
        command.append("--no-remove-bg")
    if bool(args.get("bake_texture", False)):
        command.append("--bake-texture")
    unload_text_model()
    started = time.time()
    result = subprocess.run(  # nosec B603
        command,
        capture_output=True,
        text=True,
        timeout=1800,
        check=False,
    )
    produced = work / "0"
    mesh = produced / "mesh.obj"
    if result.returncode != 0 or not mesh.exists():
        detail = (result.stderr or result.stdout or "").strip().splitlines()[-8:]
        raise RuntimeError("TripoSR fehlgeschlagen: " + " | ".join(detail))
    for item in produced.iterdir():
        shutil.move(str(item), str(target / item.name))
    shutil.rmtree(work, ignore_errors=True)
    info = describe(target / "mesh.obj")
    info.update(
        {
            "source": str(source),
            "bake_texture": bool(args.get("bake_texture", False)),
            "ms": round((time.time() - started) * 1000),
        }
    )
    return info


TOOLS = {
    "models": {
        "description": "Zeigt Pfade und den Zustand der generativen Modelle.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "handler": lambda args: {
            "flux": str(FLUX_DIR),
            "zimage": str(ZIMAGE_DIR),
            "sdxl": str(SDXL_MODEL),
            "mflux": MFLUX,
            "mflux_zimage": MFLUX_ZIMAGE,
            "ocr": str(OCR_DIR),
            "ocr_python": str(OCR_PYTHON),
            "worker": str(WORKER),
            "sd_cli": str(SD_CLI),
            "video": str(VIDEO_DIR),
            "mesh_python": str(MESH_PYTHON),
            "mesh_run": str(MESH_RUN),
            "mesh_model": str(MESH_MODEL),
        },
    },
    "unload": {
        "description": "Hinweis: FLUX und OCR laufen als Subprozesse ohne Dauerspeicher.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "additionalProperties": False,
        },
        "handler": lambda args: {
            "unloaded": False,
            "note": "FLUX und OCR laufen als Subprozesse und geben den Speicher selbst frei.",
        },
    },
    "txt2img": {
        "description": (
            "Erzeugt ein Bild aus einem Text (FLUX.2 Klein 4B, 4 Schritte). "
            "Liefert eine 512-px-Vorschau; `dest` legt das Vollbild im Exportordner ab."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "width": {"type": "integer", "default": 1024},
                "height": {"type": "integer", "default": 1024},
                "steps": {"type": "integer", "default": 4},
                "seed": {"type": "integer", "default": 42},
                "dest": {"type": "string", "description": DEST_DESCRIPTION},
            },
            "required": ["prompt"],
            "additionalProperties": False,
        },
        "handler": tool_txt2img,
    },
    "zimage": {
        "description": (
            "Erzeugt ein Bild aus einem Text (Z-Image-Turbo, 6-bit, 9 Schritte). "
            "Liefert eine 512-px-Vorschau; `dest` legt das Vollbild im Exportordner ab."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "width": {"type": "integer", "default": 1024},
                "height": {"type": "integer", "default": 1024},
                "steps": {"type": "integer", "default": 9},
                "seed": {"type": "integer", "default": 42},
                "guidance": {"type": "number", "minimum": 0, "maximum": 20},
                "dest": {"type": "string", "description": DEST_DESCRIPTION},
            },
            "required": ["prompt"],
            "additionalProperties": False,
        },
        "handler": tool_zimage,
    },
    "sdxl": {
        "description": (
            "Erzeugt ein Bild aus einem Text mit dem lokalen SDXL-Checkpoint "
            "Local SDXL checkpoint (diffusers on MPS, 1024 px)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "negative_prompt": {"type": "string"},
                "width": {"type": "integer", "default": 1024},
                "height": {"type": "integer", "default": 1024},
                "steps": {"type": "integer", "default": 25},
                "cfg_scale": {"type": "number", "default": 7.0},
                "seed": {"type": "integer", "default": 42},
                "sampling_method": {
                    "type": "string",
                    "enum": sorted(SDXL_SAMPLERS),
                    "default": "dpm++2m",
                },
                "engine": {
                    "type": "string",
                    "enum": sorted(SDXL_ENGINES),
                    "default": "diffusers",
                },
                "device": {
                    "type": "string",
                    "enum": sorted(SDXL_DEVICES),
                    "default": "metal",
                },
                "type": {
                    "type": "string",
                    "enum": sorted(SDXL_TYPES),
                    "default": "q8_0",
                },
                "dest": {"type": "string", "description": DEST_DESCRIPTION},
            },
            "required": ["prompt"],
            "additionalProperties": False,
        },
        "handler": tool_sdxl,
    },
    "edit": {
        "description": (
            "Bearbeitet ein Bild mit einem Prompt (FLUX.2 Klein 4B). "
            "Liefert eine 512-px-Vorschau; `dest` legt das Vollbild im Exportordner ab."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "images": {"type": "array", "items": {"type": "string"}, "minItems": 1},
                "strength": {"type": "number", "default": 0.6},
                "steps": {"type": "integer", "default": 4},
                "seed": {"type": "integer", "default": 42},
                "dest": {"type": "string", "description": DEST_DESCRIPTION},
            },
            "required": ["prompt", "images"],
            "additionalProperties": False,
        },
        "handler": tool_edit,
    },
    "video": {
        "description": "Erzeugt einen kurzen Clip aus Text (Wan2.2 TI2V 5B, 480p).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string"},
                "width": {"type": "integer", "default": 512},
                "height": {"type": "integer", "default": 288},
                "frames": {"type": "integer", "default": 29},
                "steps": {"type": "integer", "default": 20},
                "seed": {"type": "integer", "default": 42},
                "cfg_scale": {"type": "number", "default": 6.0},
                "negative_prompt": {"type": "string"},
            },
            "required": ["prompt"],
            "additionalProperties": False,
        },
        "handler": tool_video,
    },
    "mesh": {
        "description": "Erzeugt aus einem Bild ein 3D-Mesh (TripoSR, CPU).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "remove_bg": {"type": "boolean", "default": True},
                "bake_texture": {"type": "boolean", "default": False},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": tool_mesh,
    },
    "ocr": {
        "description": "Erkennt Text, Tabellen, Formeln oder Diagramme (PaddleOCR-VL).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "task": {
                    "type": "string",
                    "enum": sorted(TASKS),
                    "default": "ocr",
                },
                "max_tokens": {"type": "integer", "default": 1024},
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": tool_ocr,
    },
}


def text_response(value: Any, error: bool = False) -> dict[str, Any]:
    body = (
        value
        if isinstance(value, str)
        else json.dumps(value, ensure_ascii=False, indent=2)
    )
    return {"content": [{"type": "text", "text": body}], "isError": error}


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
                "serverInfo": {"name": "gen", "version": VERSION},
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
    log(f"bereit, mflux {MFLUX}")
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


if __name__ == "__main__":
    main()
