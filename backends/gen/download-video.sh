#!/usr/bin/env bash
#
# download-video.sh — stable-diffusion.cpp und Wan2.2 TI2V 5B laden.
#
# Sequenziell, eine Verbindung, Standard 5,6 MB/s. Die Binärdatei kommt aus
# dem macOS-arm64-Release, die Gewichte als GGUF/Safetensors.
#
set -euo pipefail

D="${VIDEO_MODELS_DIR:-$HOME/models/video}"
BIN_DIR="$HOME/Library/Application Support/mac-compute/bin"
LIMIT="${RATE:-5630K}"
mkdir -p "$D" "$BIN_DIR"

fetch() {
  local url="$1" dest="$2" file="$3" size="$4" sha="$5"
  mkdir -p "$dest"
  if [ -f "$dest/$file" ] && [ "$(stat -f%z "$dest/$file")" = "$size" ]; then
    echo "✔ vorhanden: $file"
    return
  fi
  echo "▶ $(date '+%H:%M:%S') $file ($((size / 1024 / 1024)) MB)"
  aria2c --continue=true --max-connection-per-server=1 --split=1 \
    --min-split-size=1M --max-download-limit="$LIMIT" --max-tries=50 \
    --retry-wait=10 --connect-timeout=30 --timeout=60 --file-allocation=none \
    --auto-file-renaming=false --allow-overwrite=true --summary-interval=120 \
    --console-log-level=warn --dir="$dest" --out="$file" "$url"
  [ "$(stat -f%z "$dest/$file")" = "$size" ] || { echo "✖ Größe: $file" >&2; exit 1; }
  if [ -n "$sha" ]; then
    [ "$(shasum -a 256 "$dest/$file" | awk '{print $1}')" = "$sha" ] || {
      echo "✖ SHA: $file" >&2
      exit 1
    }
  fi
  echo "✔ fertig: $file"
}

echo "=== Video-Modelle $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ ! -x "$BIN_DIR/sd-cli" ] || [ ! -f "$BIN_DIR/libstable-diffusion.dylib" ]; then
  ZIP="$BIN_DIR/sd-cli.zip"
  fetch "https://github.com/leejet/stable-diffusion.cpp/releases/download/master-996-baf45b4/sd-master-baf45b4-bin-Darwin-macOS-26.6.2-arm64.zip" \
    "$BIN_DIR" "sd-cli.zip" 36884506 ""
  rm -rf "$BIN_DIR/sd-cli.tmp"
  mkdir -p "$BIN_DIR/sd-cli.tmp"
  unzip -q -o "$ZIP" -d "$BIN_DIR/sd-cli.tmp"
  install -m 755 "$BIN_DIR/sd-cli.tmp/sd-cli" "$BIN_DIR/sd-cli"
  install -m 644 "$BIN_DIR/sd-cli.tmp/libstable-diffusion.dylib" "$BIN_DIR/libstable-diffusion.dylib"
  rm -rf "$BIN_DIR/sd-cli.tmp" "$ZIP"
  echo "✔ sd-cli und dylib installiert"
fi

fetch "https://huggingface.co/QuantStack/Wan2.2-TI2V-5B-GGUF/resolve/main/Wan2.2-TI2V-5B-Q4_K_M.gguf?download=true" \
  "$D" "Wan2.2-TI2V-5B-Q4_K_M.gguf" 3433116000 \
  95b19697b7f98e65b0a543640e9ca7b4dfec32e2a6e3731e8e10708be52655e2
fetch "https://huggingface.co/city96/umt5-xxl-encoder-gguf/resolve/main/umt5-xxl-encoder-Q4_K_M.gguf?download=true" \
  "$D" "umt5-xxl-encoder-Q4_K_M.gguf" 3655145312 \
  17cf97a5bbbc60a646d6105b832b6f657ce904a8a1ad970e4b59df0c67584a40
fetch "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors?download=true" \
  "$D" "wan2.2_vae.safetensors" 1409400960 \
  e40321bd36b9709991dae2530eb4ac303dd168276980d3e9bc4b6e2b75fed156

echo "=== Fertig $(date '+%Y-%m-%d %H:%M:%S') ==="
du -sh "$D"
