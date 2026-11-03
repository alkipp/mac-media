#!/usr/bin/env bash
#
# download-models.sh — Bild-/Audio-Modelle für das photo-Backend laden.
#
# Sequenziell, eine Verbindung, Standard 5,6 MB/s. Kleine Konfigurationsdateien
# kommen über hf, die Gewichte über aria2 (Resume, 50 Versuche).
#
# Aufruf:
#   ./download-models.sh              # fehlende Modelle laden
#   RATE=4M ./download-models.sh      # andere Obergrenze
#   ./download-models.sh --check      # nur Größen und Hashes prüfen
#
set -euo pipefail

DIR="${PHOTO_MODELS_DIR:-$HOME/models/photo}"
LIST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/models.txt"
RATE="${RATE:-5630K}"
BASE="https://huggingface.co"
MODE="download"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE="check" ;;
    --help|-h) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$LIST" ] || { echo "Liste fehlt: $LIST" >&2; exit 1; }
mkdir -p "$DIR"

check() {
  local file="$1" subdir="$2" size="$3" sha="$4"
  local target="$DIR/$subdir/$file"
  [ -f "$target" ] || { echo "✖ fehlt: $subdir/$file"; return 1; }
  [ "$(stat -f%z "$target")" = "$size" ] || { echo "✖ Größe: $subdir/$file"; return 1; }
  [ "$(shasum -a 256 "$target" | awk '{print $1}')" = "$sha" ] || { echo "✖ SHA: $subdir/$file"; return 1; }
  echo "✔ $subdir/$file"
}

if [ "$MODE" = "check" ]; then
  failures=0
  while IFS='|' read -r repo file subdir size sha license; do
    case "$repo" in \#*|"") continue ;; esac
    check "$file" "$subdir" "$size" "$sha" || failures=$((failures + 1))
  done < "$LIST"
  [ "$failures" = "0" ] || { echo "$failures Datei(en) fehlerhaft" >&2; exit 1; }
  exit 0
fi

echo "=== photo-Modelle $(date '+%Y-%m-%d %H:%M:%S') · $RATE · $DIR ==="
while IFS='|' read -r repo file subdir size sha license; do
  case "$repo" in \#*|"") continue ;; esac
  target="$DIR/$subdir/$file"
  if [ -f "$target" ] && [ "$(stat -f%z "$target")" = "$size" ]; then
    echo "✔ vorhanden: $subdir/$file"
    continue
  fi
  mkdir -p "$DIR/$subdir"
  # Kleine Begleitdateien (config.json, processor_config.json, …) über hf.
  # Fehlt das CLI, laden die Gewichte trotzdem – nur die Begleitdateien nicht.
  if command -v hf >/dev/null 2>&1; then
    hf download "$repo" \
      --exclude "*.safetensors" --exclude "*.bin" --exclude "*.pth" --exclude "*.pt" \
      --local-dir "$DIR/$subdir" >/dev/null
  else
    echo "ℹ hf fehlt – Begleitdateien für $repo werden übersprungen"
  fi
  echo "▶ $(date '+%H:%M:%S') $subdir/$file ($((size / 1024 / 1024)) MB, $license)"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c --continue=true --max-connection-per-server=1 --split=1 \
      --min-split-size=1M --max-download-limit="$RATE" --max-tries=50 \
      --retry-wait=10 --connect-timeout=30 --timeout=60 --file-allocation=none \
      --auto-file-renaming=false --allow-overwrite=true --summary-interval=120 \
      --console-log-level=warn --dir="$DIR/$subdir" --out="$file" \
      "$BASE/$repo/resolve/main/$file?download=true"
  else
    # Ohne aria2: kein Resume, dafür keine zusätzliche Installation nötig.
    echo "ℹ aria2c fehlt – lade mit curl"
    curl -fL --retry 5 --retry-delay 5 -o "$DIR/$subdir/$file" \
      "$BASE/$repo/resolve/main/$file?download=true"
  fi
  check "$file" "$subdir" "$size" "$sha"
done < "$LIST"
echo "=== Fertig $(date '+%Y-%m-%d %H:%M:%S') ==="
du -sh "$DIR"
