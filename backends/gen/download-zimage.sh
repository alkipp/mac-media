#!/usr/bin/env bash
# Z-Image-Turbo (mflux, 6-bit): 8,45 GB. Sequenziell, eine Verbindung,
# 5,6 MB/s, SHA-256 je Gewicht.
#
# Q6 statt FP8: FP8 rechnet Metal nicht, und bf16 (rund 31 GB) passt nicht in
# die 16 GB des Mac. Q6 belegt beim Laufen rund 9 GB (Encoder wird mit
# --low-ram vor dem Decode freigegeben).
set -euo pipefail

# Homebrew liegt bei nicht-interaktiven Aufrufen (ssh, launchd) nicht im PATH;
# sonst fehlen `hf` und `aria2c` und das Skript bricht nach der ersten Zeile ab.
for prefix in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) [ -d "$prefix" ] && PATH="$prefix:$PATH" ;;
  esac
done
export PATH

D="$HOME/models/gen"
LIMIT="${LIMIT:-5630K}"
BASE="https://huggingface.co"
REPO="mflux-community/z-image-turbo-mflux-q6"
ZIMAGE="$D/z-image-turbo-mflux-q6"
mkdir -p "$ZIMAGE"

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

echo "=== Z-Image-Turbo Start $(date '+%Y-%m-%d %H:%M:%S') ==="

hf download "$REPO" --exclude "*.safetensors" --local-dir "$ZIMAGE" >/dev/null
fetch "$REPO" text_encoder/0.safetensors "$ZIMAGE" 2141676614 8c3645149d0184828f00997af271c3f8ead17d5bb36db742430152e57680a9ae
fetch "$REPO" text_encoder/1.safetensors "$ZIMAGE" 1126908653 c0f6546d2dd5b8b1cd64ffbb3d9546b38bb7b6493d401d39cabf2e492636e522
fetch "$REPO" transformer/0.safetensors "$ZIMAGE" 2141499805 a06660f3066df50a1bc003c274a5230df19aeeb84b306ad4e81a8b317e8fe71a
fetch "$REPO" transformer/1.safetensors "$ZIMAGE" 2137553315 cc2814ebbb30d1f68ee1e0a722030ff6b1a19c8ffbce6c5cc3818982085946b4
fetch "$REPO" transformer/2.safetensors "$ZIMAGE" 723167574 e6ccd8afcc941a763813a0d060cc467323b96cf4d53ba53d6ce10008988c58f0
fetch "$REPO" vae/0.safetensors "$ZIMAGE" 165178465 140cd03f6f46691faa4ba045c28fbba7d99019f8719aa8f8e9a4e6d1b73f4000

echo "=== Z-Image-Turbo Fertig $(date '+%Y-%m-%d %H:%M:%S') ==="
du -sh "$ZIMAGE"
