#!/usr/bin/env bash
# B3a-Modelle: FLUX.2 Klein 4B (mflux q4) und PaddleOCR-VL.
# Sequenziell, eine Verbindung, 5,6 MB/s, SHA-256 je Gewicht.
set -euo pipefail

D="$HOME/models/gen"
LIMIT="${LIMIT:-5630K}"
BASE="https://huggingface.co"
FLUX="$D/flux2-klein-4b-mflux-q4"
OCR="$D/paddleocr-vl"
mkdir -p "$FLUX" "$OCR"

fetch() {
  local repo="$1" file="$2" dest="$3" size="$4" sha="$5"
  mkdir -p "$dest/$(dirname "$file")"
  if [ -f "$dest/$file" ] && [ "$(stat -f%z "$dest/$file")" = "$size" ]; then
    echo "✔ vorhanden: $file"
    return
  fi
  echo "▶ $(date '+%H:%M:%S') $file ($((size / 1024 / 1024)) MB)"
  aria2c --continue=true --max-connection-per-server=1 --split=1 \
    --min-split-size=1M --max-download-limit="$LIMIT" --max-tries=50 \
    --retry-wait=10 --connect-timeout=30 --timeout=60 --file-allocation=none \
    --auto-file-renaming=false --allow-overwrite=true --summary-interval=120 \
    --console-log-level=warn --dir="$dest/$(dirname "$file")" --out="$(basename "$file")" \
    "$BASE/$repo/resolve/main/$file?download=true"
  [ "$(stat -f%z "$dest/$file")" = "$size" ] || { echo "✖ Größe: $file" >&2; exit 1; }
  [ "$(shasum -a 256 "$dest/$file" | awk '{print $1}')" = "$sha" ] || { echo "✖ SHA: $file" >&2; exit 1; }
  echo "✔ fertig: $file"
}

echo "=== B3a Start $(date '+%Y-%m-%d %H:%M:%S') ==="

hf download mflux-community/flux2-klein-4b-mflux-q4 \
  --exclude "*.safetensors" --local-dir "$FLUX" >/dev/null
fetch mflux-community/flux2-klein-4b-mflux-q4 text_encoder/0.safetensors "$FLUX" 2135435237 e59ed2b6825cb8ae3d0ba1e8a43575a565d465ce4518b7d79d28020b19b639cd
fetch mflux-community/flux2-klein-4b-mflux-q4 text_encoder/1.safetensors "$FLUX" 127582075 edbdea3187bc4a0ad0e1ecb7152da8e6b344669413d9e45be5e7a2244f398ee3
fetch mflux-community/flux2-klein-4b-mflux-q4 transformer/0.safetensors "$FLUX" 2145323769 36796395e3946496f3e118f26fe22594b1d7d871342a59dd7824349d91c08266
fetch mflux-community/flux2-klein-4b-mflux-q4 transformer/1.safetensors "$FLUX" 34727728 9730ae148ca4f5ffc62860748b849a70987f0b7301588248bd98a2af9bc15070
fetch mflux-community/flux2-klein-4b-mflux-q4 vae/0.safetensors "$FLUX" 165107888 688ae0c3d2e93573ce8a6d3561d793cf6de5a4207b2e128cad6cd0d71e43b10f

hf download PaddlePaddle/PaddleOCR-VL \
  --exclude "*.safetensors" --local-dir "$OCR" >/dev/null
fetch PaddlePaddle/PaddleOCR-VL model.safetensors "$OCR" 1917255968 3085f1042e184f68f8a412aa0f64f2c4b8562989598bbfba326aaa11fc685de8

echo "=== B3a Fertig $(date '+%Y-%m-%d %H:%M:%S') ==="
du -sh "$D"
