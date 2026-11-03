#!/usr/bin/env bash
#
# setup-mesh.sh — TripoSR für das gen-Backend einrichten (Bild → Mesh).
#
# Eigene Python-3.11-venv, weil TripoSR alte Abhängigkeiten pinnt
# (transformers 4.35). Modell und Checkpoint liegen unter ~/models/3d/.
#
set -euo pipefail

V="$HOME/Library/Application Support/mac-compute/venvs/mesh"
T="$HOME/models/3d/TripoSR"
M="$HOME/models/3d"
RATE="${RATE:-5630K}"

command -v uv >/dev/null || { echo "uv fehlt: brew install uv" >&2; exit 1; }
mkdir -p "$M"

if [ ! -x "$V/bin/python" ]; then
  uv venv --python 3.11 "$V"
fi
uv pip install --python "$V/bin/python" torch torchvision scikit-build-core ninja cmake pybind11

if [ ! -d "$T/.git" ] && [ ! -f "$T/run.py" ]; then
  git clone --depth 1 https://github.com/VAST-AI-Research/TripoSR "$T"
fi

grep -v torchmcubes "$T/requirements.txt" > /tmp/tripo-req.txt
uv pip install --python "$V/bin/python" -r /tmp/tripo-req.txt
uv pip install --python "$V/bin/python" "transformers==4.35.0" trimesh omegaconf \
  einops "rembg[cpu]" imageio huggingface-hub moderngl "xatlas>=0.0.9"

# torchmcubes braucht das installierte torch und einen nicht-isolierten Build.
PATH="$V/bin:$PATH" CMAKE_PREFIX_PATH="$("$V/bin/python" -c 'import torch,os;print(os.path.dirname(torch.__file__))')" \
  uv pip install --python "$V/bin/python" --no-build-isolation \
  "git+https://github.com/tatsy/torchmcubes.git"

mkdir -p "$M/triposr"
if [ ! -s "$M/model.ckpt" ]; then
  aria2c --continue=true --max-connection-per-server=1 --split=1 \
    --min-split-size=1M --max-download-limit="$RATE" --max-tries=50 \
    --retry-wait=10 --connect-timeout=30 --timeout=60 --file-allocation=none \
    --auto-file-renaming=false --allow-overwrite=true \
    --dir="$M" --out="model.ckpt" \
    "https://huggingface.co/stabilityai/TripoSR/resolve/main/model.ckpt?download=true"
fi
if [ ! -f "$M/triposr/config.yaml" ]; then
  curl -fsSL "https://huggingface.co/stabilityai/TripoSR/raw/main/config.yaml" \
    -o "$M/triposr/config.yaml"
fi
ln -sf "$M/model.ckpt" "$M/triposr/model.ckpt"

echo "✔ TripoSR bereit: $T"
echo "  Test: $V/bin/python $T/run.py $T/examples/chair.png --device mps \\"
echo "        --pretrained-model-name-or-path $M/triposr --output-dir /tmp/tripo --no-remove-bg"
