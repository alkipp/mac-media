#!/usr/bin/env bash
#
# bench-media.sh — Messwerte für den Frame-Transport von video-mcp.
#
# Vergleicht den PNG-Weg (Dateien, wie bis 0.1.x) mit dem Ring-Puffer (rohe
# BGRA-Frames) bei 1080p, 4K und 4K mit Effekten. Gibt Sekunden und Millisekunden
# je Frame aus und prüft, dass der Lauf wirklich den angeforderten Transport
# benutzt hat (kein stiller Rückfall auf PNG).
#
# Aufruf:
#   scripts/bench-media.sh                 # Standard: je ein Lauf
#   scripts/bench-media.sh --repeat 3      # Mittelwert aus drei Läufen
#   scripts/bench-media.sh --gate          # nur Schwellen prüfen (für check.sh)
#   scripts/bench-media.sh --keep          # Zwischenstände behalten
#
# Schwellen für --gate: BENCH_MAX_1080P (Default 3,0 s), BENCH_MAX_4K (5,0 s).
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${MAC_COMPUTE_BIN:-$HOME/Library/Application Support/mac-compute/bin}"
VIDEO="$BIN_DIR/video-mcp"
REPEAT=1
KEEP=0
GATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repeat)
      REPEAT="${2:-1}"
      shift 2
      ;;
    --gate)
      GATE=1
      shift
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --help | -h)
      sed -n '2,16p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      printf '✖ unbekannte Option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
step() { printf '\n▶ %s\n' "$*"; }

[ -x "$VIDEO" ] || fail "video-mcp nicht gefunden: $VIDEO"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bench-media.XXXXXX")"
cleanup() {
  if [ "$KEEP" = "1" ]; then
    printf 'Reste: %s\n' "$WORK"
    return
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Ein Lauf, gibt "<sekunden> <frames> <transport>" zurück.
measure() {
  local scene=$1 expect=$2 transport=$3
  shift 3
  local stem output log seconds frames got
  stem="$(basename "$scene" .json)"
  output="$WORK/$stem-$expect-$transport.mp4"
  log="$WORK/$stem-$expect-$transport.log"
  if [ "$transport" = "png" ]; then
    VIDEO_FRAME_TRANSPORT=png /usr/bin/time -p \
      "$VIDEO" --render "$scene" "$output" "$@" >"$log" 2>&1 || {
      tail -5 "$log" >&2
      fail "Lauf fehlgeschlagen: $scene ($expect/$transport)"
    }
  else
    VIDEO_FRAME_TRANSPORT=shm /usr/bin/time -p \
      "$VIDEO" --render "$scene" "$output" "$@" >"$log" 2>&1 || {
      tail -5 "$log" >&2
      fail "Lauf fehlgeschlagen: $scene ($expect/$transport)"
    }
  fi
  seconds=$(awk '/^real/ {print $2}' "$log")
  frames=$(awk '/^frames:/ {print $2}' "$log")
  got=$(awk '/^transport:/ {print $2}' "$log")
  [ -n "$seconds" ] || fail "keine Zeitmessung: $log"
  [ -n "$frames" ] || fail "keine Framezahl: $log"
  [ "$got" = "$transport" ] || fail "Transport $got statt $transport: $log"
  printf '%s %s %s\n' "$seconds" "$frames" "$got"
}

# Mittelwert über REPEAT Läufe, Ausgabe: "<sekunden> <ms/frame> <transport>".
average() {
  local scene=$1 expect=$2 transport=$3
  shift 3
  local sum=0 frames=0 got="" n=0 result="" seconds=""
  while [ "$n" -lt "$REPEAT" ]; do
    n=$((n + 1))
    result=$(measure "$scene" "$expect" "$transport" "$@")
    seconds=$(printf '%s' "$result" | awk '{print $1}')
    frames=$(printf '%s' "$result" | awk '{print $2}')
    got=$(printf '%s' "$result" | awk '{print $3}')
    sum=$(awk -v a="$sum" -v b="$seconds" 'BEGIN {print a + b}')
    printf '  Lauf %s: %ss (%s Frames)\n' "$n" "$seconds" "$frames" >&2
  done
  awk -v s="$sum" -v n="$REPEAT" -v f="$frames" -v t="$got" \
    'BEGIN {avg = s / n; printf "%.2f %.1f %s\n", avg, avg * 1000 / f, t}'
}

printf 'video-mcp: %s\n' "$VIDEO"
printf 'Wiederholungen: %s\n' "$REPEAT"
printf '\n%-22s %-9s %8s %10s\n' "Szene" "Transport" "Sekunden" "ms/Frame"
printf '%-22s %-9s %8s %10s\n' "----------------------" "---------" "--------" "--------"

benchmark() {
  local label=$1 scene=$2 transport=$3
  shift 3
  local result seconds ms
  result=$(average "$scene" "$label" "$transport" "$@")
  seconds=$(printf '%s' "$result" | awk '{print $1}')
  ms=$(printf '%s' "$result" | awk '{print $2}')
  printf '%-22s %-9s %8s %10s\n' "$label" "$transport" "$seconds" "$ms"
}

GOLDEN="$REPO_DIR/config/scenes/golden.json"
FOURK="$REPO_DIR/config/scenes/4k.json"
[ -f "$GOLDEN" ] || fail "Szene fehlt: $GOLDEN"
[ -f "$FOURK" ] || fail "Szene fehlt: $FOURK"

# Schwellen für --gate; über Umgebung anpassbar, wenn ein langsamerer Mac läuft.
# Sie sind eine Regressionsbremse, kein Benchmark: der PNG-Weg liegt bei 4,5 s
# (1080p) und 6,9 s (4K), ein Rückfall fällt damit sicher auf. Der beste von
# drei Läufen zählt, weil ein beschäftigter Mac einzelne Läufe ausbremst.
MAX_1080P="${BENCH_MAX_1080P:-3.0}"
MAX_4K="${BENCH_MAX_4K:-5.0}"

# Prüft einen Lauf gegen eine Obergrenze in Sekunden.
gate() {
  local label=$1 scene=$2 limit=$3 result seconds best="" run=0
  local runs=3
  while [ "$run" -lt "$runs" ]; do
    run=$((run + 1))
    result=$(measure "$scene" "$label" "shm")
    seconds=$(printf '%s' "$result" | awk '{print $1}')
    best=$(awk -v a="$best" -v b="$seconds" 'BEGIN {if (a == "" || b < a) print b; else print a}')
  done
  printf '%-12s %5s s aus %s Läufen (Grenze %s s)\n' "$label" "$best" "$runs" "$limit"
  if awk -v s="$best" -v l="$limit" 'BEGIN {exit !(s > l)}'; then
    fail "$label über der Grenze: $best s > $limit s"
  fi
  printf '✔ %s innerhalb der Grenze\n' "$label"
}

if [ "$GATE" = "1" ]; then
  step "Schwellen (Ring-Transport, bester von drei Läufen)"
  gate "1080p" "$GOLDEN" "$MAX_1080P"
  gate "4K" "$FOURK" "$MAX_4K"
  printf '\n✔ Schwellen eingehalten\n'
  exit 0
fi

step "1080p, 300 Frames"
benchmark "1080p" "$GOLDEN" png
benchmark "1080p" "$GOLDEN" shm

step "4K, 150 Frames"
benchmark "4K" "$FOURK" png
benchmark "4K" "$FOURK" shm

step "4K mit Effekten (bloom, vignette, color)"
benchmark "4K-Effekte" "$FOURK" png --bloom 0.2 --vignette 0.3 --saturation 1.05
benchmark "4K-Effekte" "$FOURK" shm --bloom 0.2 --vignette 0.3 --saturation 1.05

printf '\n✔ Messung abgeschlossen – Transport jeweils wie angefordert\n'
