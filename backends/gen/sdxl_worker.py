#!/usr/bin/env python3
"""sdxl_worker — SDXL über diffusers auf MPS (eigene venv).

Wird vom gen-Backend als Subprozess aufgerufen. Grund: der Metal-Pfad von
stable-diffusion.cpp liefert auf diesem Mac für SDXL nur weiße Bilder
(getestet mit baf45b4 und be48649, f16/f32, mit und ohne Flash-Attention,
VAE und Textencoder auf CPU) — auf der CPU rechnet sd.cpp korrekt, aber mit
~36 s pro Schritt bei 1024 px zu langsam. diffusers auf MPS liefert dagegen
brauchbare Bilder.

Gibt JSON auf stdout aus, Fehler auf stderr mit Exitcode 1.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Safetensors-Checkpoint")
    parser.add_argument("--diffusers-dir", default="", help="Alternativer Ordner")
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--negative-prompt", default="")
    parser.add_argument("--output", required=True)
    parser.add_argument("--width", type=int, default=1024)
    parser.add_argument("--height", type=int, default=1024)
    parser.add_argument("--steps", type=int, default=25)
    parser.add_argument("--cfg-scale", type=float, default=7.0)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--sampler", default="dpm++2m")
    args = parser.parse_args()

    import torch
    from diffusers import (
        DPMSolverMultistepScheduler,
        EulerAncestralDiscreteScheduler,
        EulerDiscreteScheduler,
        StableDiffusionXLPipeline,
    )

    if not torch.backends.mps.is_available():
        print("MPS nicht verfügbar", file=sys.stderr)
        return 1
    device = "mps"
    torch_dtype = torch.float16
    started = time.time()

    source = args.model
    diffusers_dir = Path(args.diffusers_dir) if args.diffusers_dir else None
    if diffusers_dir and diffusers_dir.is_dir():
        pipe = StableDiffusionXLPipeline.from_pretrained(
            str(diffusers_dir),
            torch_dtype=torch_dtype,
            use_safetensors=True,
            local_files_only=True,
        )
    else:
        pipe = StableDiffusionXLPipeline.from_single_file(
            source, torch_dtype=torch_dtype, use_safetensors=True
        )

    samplers = {
        "euler": EulerDiscreteScheduler,
        "euler_a": EulerAncestralDiscreteScheduler,
        "dpm++2m": DPMSolverMultistepScheduler,
    }
    scheduler = samplers[args.sampler].from_config(pipe.scheduler.config)
    pipe.scheduler = scheduler
    pipe.set_progress_bar_config(disable=True)
    # 16 GB: Aufmerksamkeit und VAE in Slices, sonst kippt 1024 px in den Swap.
    # Die Methoden wandern zwischen diffusers-Versionen; deshalb defensiv.
    for method in ("enable_attention_slicing", "enable_vae_slicing"):
        call = getattr(pipe, method, None)
        if callable(call):
            call()
    vae = getattr(pipe, "vae", None)
    if vae is not None:
        for method in ("enable_slicing", "enable_tiling"):
            call = getattr(vae, method, None)
            if callable(call):
                call()
    pipe.to(device)

    generator = torch.Generator(device="cpu").manual_seed(args.seed)
    image = pipe(
        prompt=args.prompt,
        negative_prompt=args.negative_prompt or None,
        width=args.width,
        height=args.height,
        num_inference_steps=args.steps,
        guidance_scale=args.cfg_scale,
        generator=generator,
    ).images[0]

    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    image.save(target)
    print(
        json.dumps(
            {
                "path": str(target),
                "bytes": target.stat().st_size,
                "ms": round((time.time() - started) * 1000),
                "device": device,
                "sampler": args.sampler,
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
