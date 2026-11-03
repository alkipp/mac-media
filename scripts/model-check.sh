#!/usr/bin/env bash
#
# model-check.sh — Ein neues Modell von der Platte bis in die Sandbox prüfen.
#
# Aufruf:
#   ./scripts/model-check.sh <backend> <tool> <modellverzeichnis> [Optionen]
#
# Optionen:
#   --repo <hf-repo>      Dateien gegen Hugging Face prüfen (model-fetch.sh --check)
#   --capability <name>   Capability, die im Manifest stehen muss
#   --gateway <url>       MCP-Endpunkt, Standard http://127.0.0.1:8787/mcp
#   --help                diese Hilfe
#
# Geprüft werden vier Stufen: Dateien (optional), Manifest, Werkzeugliste des
# Gateways und die Ausgabe von `<backend>_models`. Genau diese Kette ist beim
# Einbau von Z-Image gerissen: der Server lieferte `gen_zimage`, das Gateway
# listete es, aber die laufende Sitzung sah es nicht (fehlende Capability
# `tools.listChanged`). Ein Aufruf hier hätte das sofort gezeigt.
#
# Rückgabewert: 0 = alle Stufen grün, 1 = mindestens eine Stufe rot,
# 2 = Aufruffehler.
#
# Beispiel:
#   ./scripts/model-check.sh gen zimage ~/models/gen/z-image-turbo-mflux-q6 \
#     --repo mflux-community/z-image-turbo-mflux-q6 --capability z-image
#
set -euo pipefail

for prefix in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) [ -d "$prefix" ] && PATH="$prefix:$PATH" ;;
  esac
done
export PATH

die() { printf '✖ %s\n' "$*" >&2; exit 1; }
ok() { printf '✔ %s\n' "$*"; }
bad() {
  printf '✖ %s\n' "$*" >&2
  FAILED=$((FAILED + 1))
}
step() { printf '\n▶ %s\n' "$*"; }

usage() {
  sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'
}

[ "$(uname -s)" = "Darwin" ] || die "Dieses Skript ist für macOS gedacht."

BACKEND=""
TOOL=""
MODEL_DIR=""
HF_REPO=""
CAPABILITY=""
GATEWAY="http://127.0.0.1:8787/mcp"
TOKEN_FILE="$HOME/.config/mac-compute/token"
APP_SUPPORT="$HOME/Library/Application Support/mac-compute"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || die "--repo braucht einen Wert"
      HF_REPO="$2"
      shift
      ;;
    --capability)
      [ "$#" -ge 2 ] || die "--capability braucht einen Wert"
      CAPABILITY="$2"
      shift
      ;;
    --gateway)
      [ "$#" -ge 2 ] || die "--gateway braucht einen Wert"
      GATEWAY="$2"
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    -*)
      printf '✖ unbekannte Option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [ -z "$BACKEND" ]; then
        BACKEND="$1"
      elif [ -z "$TOOL" ]; then
        TOOL="$1"
      elif [ -z "$MODEL_DIR" ]; then
        MODEL_DIR="$1"
      else
        die "zu viele Argumente: $1"
      fi
      ;;
  esac
  shift
done

[ -n "$BACKEND" ] && [ -n "$TOOL" ] && [ -n "$MODEL_DIR" ] || {
  usage >&2
  exit 2
}

step "Dateien"
if [ ! -d "$MODEL_DIR" ]; then
  bad "Verzeichnis fehlt: $MODEL_DIR"
elif [ -n "$HF_REPO" ]; then
  if "$SCRIPT_DIR/model-fetch.sh" "$HF_REPO" "$MODEL_DIR" --check; then
    ok "Gewichte stimmen mit huggingface.co/$HF_REPO"
  else
    bad "Gewichte weichen von huggingface.co/$HF_REPO ab"
  fi
else
  count="$(find "$MODEL_DIR" -type f | wc -l | tr -d ' ')"
  if [ "$count" -gt 0 ]; then
    ok "$count Dateien unter $MODEL_DIR"
  else
    bad "keine Dateien unter $MODEL_DIR"
  fi
fi

step "Manifest"
MANIFEST="$APP_SUPPORT/servers.d/$BACKEND.json"
if [ ! -f "$MANIFEST" ]; then
  bad "Manifest fehlt: $MANIFEST"
else
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST" 2>/dev/null; then
    version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version","?"))' "$MANIFEST")"
    ok "gültiges JSON, Version $version"
  else
    bad "Manifest ist kein gültiges JSON: $MANIFEST"
  fi
  if [ -n "$CAPABILITY" ]; then
    if grep -Fq "\"$CAPABILITY\"" "$MANIFEST"; then
      ok "Capability $CAPABILITY im Manifest"
    else
      bad "Capability $CAPABILITY fehlt in $MANIFEST"
    fi
  fi
fi

step "Gateway"
if [ ! -f "$TOKEN_FILE" ]; then
  bad "Token fehlt: $TOKEN_FILE"
else
  TOKEN="$(cat "$TOKEN_FILE")"
  HEADERS=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream")
  HEADER_FILE="$(mktemp -t model-check-h)"
  BODY_FILE="$(mktemp -t model-check-b)"
  trap 'rm -f "$HEADER_FILE" "$BODY_FILE"' EXIT
  curl -s -m 10 -D "$HEADER_FILE" -o "$BODY_FILE" "${HEADERS[@]}" -X POST "$GATEWAY" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"model-check","version":"0"}}}' ||
    true
  SID="$(awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}' "$HEADER_FILE" | tr -d '\r')"
  if [ -z "$SID" ]; then
    bad "Gateway antwortet nicht auf initialize: $GATEWAY"
  else
    # Die Capability steht in der initialize-Antwort, nicht in tools/list.
    if grep -Fq '"listChanged":true' "$BODY_FILE"; then
      ok "Capability tools.listChanged angekündigt"
    else
      bad "Capability tools.listChanged fehlt – Clients ignorieren neue Werkzeuge"
    fi

    curl -s -m 5 -o /dev/null "${HEADERS[@]}" -H "mcp-session-id: $SID" -X POST "$GATEWAY" \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

    tools="$(curl -s -m 10 "${HEADERS[@]}" -H "mcp-session-id: $SID" -X POST "$GATEWAY" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')"
    if printf '%s' "$tools" | grep -Fq "\"name\":\"${BACKEND}_${TOOL}\""; then
      ok "Werkzeug ${BACKEND}_${TOOL} in tools/list"
    else
      bad "Werkzeug ${BACKEND}_${TOOL} fehlt in tools/list"
    fi

    models="$(curl -s -m 30 "${HEADERS[@]}" -H "mcp-session-id: $SID" -X POST "$GATEWAY" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"${BACKEND}_models\",\"arguments\":{}}}")"
    if printf '%s' "$models" | grep -Fq "$MODEL_DIR"; then
      ok "${BACKEND}_models nennt $MODEL_DIR"
    else
      bad "${BACKEND}_models nennt den Pfad nicht – Modell im Backend eintragen"
    fi
  fi
fi

printf '\n'
if [ "$FAILED" -gt 0 ]; then
  die "$FAILED Prüfung(en) fehlgeschlagen"
fi
ok "Modell $TOOL ist installiert, eingetragen und über MCP sichtbar"
