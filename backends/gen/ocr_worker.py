#!/usr/bin/env python3
"""ocr_worker — PaddleOCR-VL in einer eigenen venv (transformers 4.57).

Wird vom gen-Backend als Subprozess aufgerufen, damit mflux (transformers 5.x)
und PaddleOCR-VL (transformers 4.x) sich nicht beeinflussen. Gibt JSON auf
stdout aus, Fehler auf stderr mit Exitcode 1.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

import torch
import transformers.masking_utils as masking


def _patch_masking() -> None:
    """Transformers 4.57 nennt den Parameter input_embeds, das Modell inputs_embeds."""
    original = masking.create_causal_mask

    def compatible(*args, **kwargs):  # type: ignore[no-untyped-def]
        if "inputs_embeds" in kwargs:
            kwargs["input_embeds"] = kwargs.pop("inputs_embeds")
        return original(*args, **kwargs)

    masking.create_causal_mask = compatible  # type: ignore[assignment]


PROMPTS = {
    "ocr": "OCR:",
    "table": "Table Recognition:",
    "formula": "Formula Recognition:",
    "chart": "Chart Recognition:",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--task", default="ocr", choices=sorted(PROMPTS))
    parser.add_argument("--max-tokens", type=int, default=1024)
    args = parser.parse_args()

    _patch_masking()
    from PIL import Image
    from transformers import AutoModelForCausalLM, AutoProcessor

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    started = time.time()
    processor = AutoProcessor.from_pretrained(
        args.model_dir, trust_remote_code=True, local_files_only=True
    )
    loaded: Any = AutoModelForCausalLM.from_pretrained(
        args.model_dir,
        trust_remote_code=True,
        local_files_only=True,
        torch_dtype=torch.float16,
    )
    model = loaded.to(device).eval()
    image = Image.open(args.path).convert("RGB")
    messages = [
        {
            "role": "user",
            "content": [
                {"type": "image", "image": image},
                {"type": "text", "text": PROMPTS[args.task]},
            ],
        }
    ]
    inputs = processor.apply_chat_template(
        messages,
        tokenize=True,
        add_generation_prompt=True,
        return_dict=True,
        return_tensors="pt",
    ).to(device)
    prompt_length = inputs["input_ids"].shape[1]
    with torch.inference_mode():
        outputs = model.generate(
            **inputs,
            max_new_tokens=max(32, min(args.max_tokens, 4096)),
            do_sample=False,
        )
    text = processor.batch_decode(outputs[:, prompt_length:], skip_special_tokens=True)[
        0
    ].strip()
    print(
        json.dumps(
            {
                "text": text,
                "task": args.task,
                "device": device,
                "ms": round((time.time() - started) * 1000),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - Fehler an das Backend geben
        print(f"ocr_worker: {error}", file=sys.stderr)
        sys.exit(1)
