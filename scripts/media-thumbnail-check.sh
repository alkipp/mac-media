#!/usr/bin/env bash
#
# media-thumbnail-check.sh — Regressionstest für media_thumbnail.
#
# Der Fehler vom 2026-11-02: `at_seconds` kam als Ganzzahl im JSON an, der
# Backend las nur `doubleValue` und nahm stillschweigend 0 — jedes Vorschaubild
# war der schwarze erste Frame. Der Test schickt den Wert bewusst als Ganzzahl
# und prüft, dass der Frame wirklich an dieser Stelle liegt und Bildinhalt hat.
#
# Aufruf:
#   scripts/media-thumbnail-check.sh                      # inbox/sample.mp4
#   scripts/media-thumbnail-check.sh --video <datei>      # andere Quelle
#   scripts/media-thumbnail-check.sh --seconds 12
#
set -euo pipefail

BIN_DIR="${MAC_COMPUTE_BIN:-$HOME/Library/Application Support/mac-compute/bin}"
MEDIA="$BIN_DIR/media-mcp"
VIDEO="$HOME/Library/Application Support/mac-compute/inbox/sample.mp4"
SECONDS_AT=8

while [ "$#" -gt 0 ]; do
  case "$1" in
    --video)
      VIDEO="${2:-}"
      shift 2
      ;;
    --seconds)
      SECONDS_AT="${2:-}"
      shift 2
      ;;
    --help | -h)
      sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf '✖ unbekannte Option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }

[ -x "$MEDIA" ] || fail "media-mcp fehlt: $MEDIA"
[ -f "$VIDEO" ] || fail "Video fehlt: $VIDEO"

# Ganzzahl, nicht 8.0: genau dieser Typ hat den Fehler ausgelöst.
request=$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"thumbnail","arguments":{"path":"%s","at_seconds":%s,"width":320}}}' "$VIDEO" "$SECONDS_AT")
response=$(
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}'
    sleep 1
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
    sleep 1
    printf '%s\n' "$request"
    sleep 6
  } | "$MEDIA" --stdio 2>/dev/null
)

pts=$(printf '%s' "$response" | grep -o 'pts: [0-9.]*' | tail -1 | awk '{print $2}')
luma=$(printf '%s' "$response" | grep -o 'luma: [0-9.-]*' | tail -1 | awk '{print $2}')

[ -n "$pts" ] || fail "keine Antwort mit pts/luma (läuft media-mcp?)"
awk -v a="$pts" -v b="$SECONDS_AT" 'BEGIN {exit !((a - b) < 0.5 && (b - a) < 0.5)}' \
  || fail "Frame liegt bei ${pts}s statt bei ${SECONDS_AT}s – Argument wird ignoriert"
awk -v l="$luma" 'BEGIN {exit !(l > 1)}' \
  || fail "Vorschaubild ist schwarz (luma ${luma})"

printf '✔ thumbnail bei %ss: luma %s, pts %s\n' "$SECONDS_AT" "$luma" "$pts"
