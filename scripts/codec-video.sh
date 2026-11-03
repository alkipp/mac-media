#!/usr/bin/env bash
#
# codec-video.sh — Abnahme für die Schritte 12 und 14 (Audio, HEVC, ProRes).
#
# Prüft für eine kurze Szene:
#   - H.264, HEVC und ProRes 422 rendern und melden den richtigen Codec
#   - HEVC nutzt den Hardware-Pfad, ProRes nicht
#   - Audio-Muxing liefert eine AAC-Spur mit A/V-Sync <= 1 Frame
#
# Aufruf:
#   scripts/codec-video.sh            # Standard (3-s-Szene)
#   scripts/codec-video.sh --keep     # Zwischenstände behalten
#
# Binaries: $MAC_COMPUTE_BIN (Default ~/Library/Application Support/mac-compute/bin)
#
set -euo pipefail

BIN_DIR="${MAC_COMPUTE_BIN:-$HOME/Library/Application Support/mac-compute/bin}"
VIDEO="$BIN_DIR/video-mcp"
RENDER="$BIN_DIR/render-mcp"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }

[ -x "$VIDEO" ] || fail "video-mcp nicht gefunden: $VIDEO"
[ -x "$RENDER" ] || fail "render-mcp nicht gefunden: $RENDER"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/codec-video.XXXXXX")"
cleanup() {
  [ "$KEEP" = "1" ] && { printf 'Reste: %s\n' "$WORK"; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT

# Kurze Szene (3 s, 30 fps) mit Bewegung
cat >"$WORK/scene.json" <<'JSON'
{
  "version": 1,
  "width": 1280,
  "height": 720,
  "fps": 30,
  "duration": 3.0,
  "background": "#101218",
  "layers": [
    {"type": "rect", "x": 60, "y": 60, "width": 240, "height": 140, "radius": 16,
     "color": "#5B8DEF", "motion": {"dx": 700, "dy": 0, "easing": "ease-in-out"}},
    {"type": "circle", "x": 640, "y": 520, "radius": 80, "color": "#4FA37A",
     "motion": {"keyframes": [{"t": 0, "y": 520}, {"t": 1.5, "y": 260}, {"t": 3, "y": 520}]}}
  ]
}
JSON

check_codec() { # check_codec <codec> <endung> <hardware-erwartung>
  local codec="$1" ext="$2" expect_hw="$3"
  local out="$WORK/$codec.$ext"
  step "$codec"
  "$VIDEO" --render "$WORK/scene.json" "$out" --codec "$codec" >"$WORK/$codec.txt"
  grep -q "codec: $codec" "$WORK/$codec.txt" || fail "$codec: Codec nicht gemeldet"
  grep -q "hardware: $expect_hw" "$WORK/$codec.txt" || fail "$codec: Hardware-Erwartung $expect_hw verfehlt"
  [ -s "$out" ] || fail "$codec: Datei fehlt"
  "$VIDEO" --probe "$out" >"$WORK/$codec.probe"
  grep -q "codec: $codec" "$WORK/$codec.probe" || fail "$codec: Probe erkennt Codec nicht"
  ok "$codec ($ext), hardware: $expect_hw"
}

check_codec h264 mp4 true
check_codec hevc mp4 true
check_codec prores422 mov false

step "Audio (AAC)"
AUDIO_SRC="/System/Library/Sounds/Glass.aiff"
[ -f "$AUDIO_SRC" ] || fail "Testaudio fehlt: $AUDIO_SRC"
"$VIDEO" --render "$WORK/scene.json" "$WORK/av.mp4" --audio "$AUDIO_SRC" >"$WORK/av.txt"
grep -q 'audio: ' "$WORK/av.txt" || fail "Audio wurde nicht gemeldet"
grep -Eq 'av_sync: [0-9.]+ ms' "$WORK/av.txt" || fail "av_sync fehlt"
"$VIDEO" --probe "$WORK/av.mp4" >"$WORK/av.probe"
grep -q 'audio: ja' "$WORK/av.probe" || fail "Probe findet keine Audiospur"
ok "Audio gemuxt, Sync geprüft"

printf '\n✔ Codec- und Audio-Abnahme bestanden\n'
