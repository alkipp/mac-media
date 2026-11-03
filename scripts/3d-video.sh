#!/usr/bin/env bash
#
# 3d-video.sh — Abnahme für Schritt 16 (3D-Szene).
#
# Rendert die Beispielszene mit Kamera, Licht und drei Objekten als 1080p30-MP4
# und prüft Dauer, Auflösung, Framezahl und Hardware-Pfad.
#
# Aufruf:
#   scripts/3d-video.sh            # Standard
#   scripts/3d-video.sh --keep     # Zwischenstände behalten
#
set -euo pipefail

BIN_DIR="${MAC_COMPUTE_BIN:-$HOME/Library/Application Support/mac-compute/bin}"
VIDEO="$BIN_DIR/video-mcp"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENE="$REPO_DIR/config/scenes/3d-golden.json"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }

[ -x "$VIDEO" ] || fail "video-mcp nicht gefunden: $VIDEO"
[ -f "$SCENE" ] || fail "Szene fehlt: $SCENE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/3d-video.XXXXXX")"
cleanup() {
  [ "$KEEP" = "1" ] && { printf 'Reste: %s\n' "$WORK"; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT

step "3D-Szene rendern"
SECONDS=0
"$VIDEO" --render3d "$SCENE" "$WORK/3d.mp4" >"$WORK/render.txt"
elapsed=$SECONDS

grep -q 'scene: 3d' "$WORK/render.txt" || fail "3D-Modus nicht gemeldet"
grep -q 'objects: 3' "$WORK/render.txt" || fail "Objektzahl ist nicht 3"
grep -q 'resolution: 1920x1080@30' "$WORK/render.txt" || fail "Auflösung/Framerate falsch"
grep -q 'frames: 90' "$WORK/render.txt" || fail "Framezahl ist nicht 90"
grep -q 'hardware: true' "$WORK/render.txt" || fail "Hardware-Encoder nicht aktiv"

"$VIDEO" --probe "$WORK/3d.mp4" | tee "$WORK/probe.txt" >/dev/null
grep -q '1920x1080' "$WORK/probe.txt" || fail "Probe: Auflösung falsch"
grep -q 'duration: 3.0 s' "$WORK/probe.txt" || fail "Probe: Dauer ist nicht 3,0 s"

ok "3D: 90 Frames in ${elapsed}s, hardware"
printf '\n✔ 3D-Abnahme bestanden\n'
