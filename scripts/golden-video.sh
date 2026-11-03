#!/usr/bin/env bash
#
# golden-video.sh — Abnahme für die Schritte 8–10 des Vollausbaus.
#
# Prüft:
#   1. Frame-Provider liefert exakt 300 Frames für die 10-s-Szene bei 30 fps
#   2. identische Szene erzeugt identische PNG-Bytes (Determinismus)
#   3. video-mcp rendert ein H.264-MP4 und meldet Dauer/Auflösung
#
# Aufruf:
#   scripts/golden-video.sh            # vollständiger Lauf
#   scripts/golden-video.sh --keep     # Zwischenstände behalten
#
# Binaries: $MAC_COMPUTE_BIN (Default ~/Library/Application Support/mac-compute/bin)
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENE="$REPO_DIR/config/scenes/golden.json"
BIN_DIR="${MAC_COMPUTE_BIN:-$HOME/Library/Application Support/mac-compute/bin}"
RENDER="$BIN_DIR/render-mcp"
VIDEO="$BIN_DIR/video-mcp"
KEEP=0

[ "${1:-}" = "--keep" ] && KEEP=1

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }

[ -x "$RENDER" ] || fail "render-mcp nicht gefunden: $RENDER"
[ -x "$VIDEO" ] || fail "video-mcp nicht gefunden: $VIDEO"
[ -f "$SCENE" ] || fail "Szene fehlt: $SCENE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/golden-video.XXXXXX")"
cleanup() {
  [ "$KEEP" = "1" ] || rm -rf "$WORK"
  [ "$KEEP" = "1" ] && printf 'Reste: %s\n' "$WORK"
  return 0
}
trap cleanup EXIT

step "Frames rendern (10 s, 30 fps)"
"$RENDER" --scene "$SCENE" --frames-dir "$WORK/frames" >"$WORK/render.json"
frames="$(find "$WORK/frames" -name 'frame-*.png' | wc -l | tr -d ' ')"
[ "$frames" = "300" ] || fail "erwartet 300 Frames, bekommen: $frames"
ok "300 Frames"

step "Determinismus (3 Frames, zwei Läufe)"
"$RENDER" --scene "$SCENE" --frames 3 --frames-dir "$WORK/a" >/dev/null
"$RENDER" --scene "$SCENE" --frames 3 --frames-dir "$WORK/b" >/dev/null
( cd "$WORK/a" && shasum -a 256 frame-*.png ) >"$WORK/a.sum"
( cd "$WORK/b" && shasum -a 256 frame-*.png ) >"$WORK/b.sum"
cmp -s "$WORK/a.sum" "$WORK/b.sum" || fail "Frames sind nicht deterministisch"
ok "identische Bytes"

step "Video rendern und prüfen"
"$VIDEO" --render "$SCENE" "$WORK/golden.mp4" | tee "$WORK/video.txt"
[ -s "$WORK/golden.mp4" ] || fail "MP4 fehlt"
"$VIDEO" --probe "$WORK/golden.mp4" | tee "$WORK/probe.txt"

grep -q 'duration: 10\.0' "$WORK/probe.txt" || fail "Dauer ist nicht 10,0 s"
grep -q '1920x1080' "$WORK/probe.txt" || fail "Auflösung ist nicht 1920x1080"
grep -q 'frames: 300' "$WORK/probe.txt" || fail "Framezahl ist nicht 300"
ok "Golden Video bestanden"
