#!/usr/bin/env bash
#
# 4k-video.sh — Abnahme für Schritt 15 (4K30).
#
# Rendert eine 5-s-Szene in 3840×2160 bei 30 fps (150 Frames), encodiert sie
# als H.264 und prüft Auflösung, Framezahl, Hardware-Pfad und den Spitzen-RSS.
#
# Aufruf:
#   scripts/4k-video.sh            # Standard
#   scripts/4k-video.sh --keep     # Zwischenstände behalten
#
set -euo pipefail

BIN_DIR="${MAC_COMPUTE_BIN:-$HOME/Library/Application Support/mac-compute/bin}"
VIDEO="$BIN_DIR/video-mcp"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
step() { printf '\n▶ %s\n' "$*"; }
ok()   { printf '✔ %s\n' "$*"; }

[ -x "$VIDEO" ] || fail "video-mcp nicht gefunden: $VIDEO"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/4k-video.XXXXXX")"
cleanup() {
  [ "$KEEP" = "1" ] && { printf 'Reste: %s\n' "$WORK"; return; }
  rm -rf "$WORK"
}
trap cleanup EXIT

cat >"$WORK/scene.json" <<'JSON'
{
  "version": 1,
  "width": 3840,
  "height": 2160,
  "fps": 30,
  "duration": 5.0,
  "background": "#101218",
  "layers": [
    {"type": "rect", "x": 240, "y": 320, "width": 840, "height": 480, "radius": 48,
     "color": "#5B8DEF",
     "motion": {"keyframes": [{"t": 0, "x": 240}, {"t": 2.5, "x": 2700}, {"t": 5, "x": 240}],
                "easing": "ease-in-out"}},
    {"type": "circle", "x": 1920, "y": 1400, "radius": 280, "color": "#4FA37A",
     "motion": {"keyframes": [{"t": 0, "y": 1400, "opacity": 0.3},
                              {"t": 2.5, "y": 700, "opacity": 1},
                              {"t": 5, "y": 1400, "opacity": 0.3}],
                "easing": "ease-out"}}
  ]
}
JSON

step "4K30 rendern und encodieren"
SECONDS=0
/usr/bin/time -l "$VIDEO" --render "$WORK/scene.json" "$WORK/4k.mp4" \
  >"$WORK/render.txt" 2>"$WORK/time.txt"
elapsed=$SECONDS
grep -q 'resolution: 3840x2160@30' "$WORK/render.txt" || fail "Auflösung/Framerate falsch"
grep -q 'frames: 150' "$WORK/render.txt" || fail "Framezahl ist nicht 150"
grep -q 'hardware: true' "$WORK/render.txt" || fail "Hardware-Encoder nicht aktiv"
grep -q 'duration: 5.0' "$WORK/render.txt" || fail "Dauer ist nicht 5,0 s"

peak_bytes="$(awk '/maximum resident set size/ {print $1}' "$WORK/time.txt" | head -1)"
peak_mb=$(( ${peak_bytes:-0} / 1048576 ))
[ "${peak_bytes:-0}" -gt 0 ] || fail "Spitzen-RSS nicht messbar"

"$VIDEO" --probe "$WORK/4k.mp4" | tee "$WORK/probe.txt" >/dev/null
grep -q '3840x2160' "$WORK/probe.txt" || fail "Probe: Auflösung falsch"

ok "4K30: 150 Frames, ${elapsed}s, Spitzen-RSS ${peak_mb} MiB, hardware"
printf '\n✔ 4K-Abnahme bestanden\n'
