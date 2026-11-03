#!/usr/bin/env bash
#
# model-fetch.sh — Gewichte eines Hugging-Face-Repos laden und gegen die API prüfen.
#
# Aufruf:
#   ./scripts/model-fetch.sh <repo> <zielverzeichnis> [Optionen]
#
# Optionen:
#   --check            nur prüfen, nichts laden
#   --limit <rate>     Downloadrate, Standard 5630K (5,6 MB/s, LAN-schonend)
#   --pattern <glob>   nur passende Pfade, Standard "*"
#   --help             diese Hilfe
#
# Geprüft wird gegen die Quelle, nicht gegen eine gepflegte Liste: die Größe
# jeder Datei und die SHA-256 aller LFS-Dateien (Gewichte) stammen aus
# `https://huggingface.co/api/models/<repo>/tree/main?recursive=true`. Kleine
# Konfigurationsdateien liegen nicht in LFS und haben dort nur eine
# Git-Blob-ID (SHA-1); für sie zählt allein die Größe.
#
# Token: gated Repos brauchen eine Anmeldung. Der Token kommt aus `HF_TOKEN`
# oder `~/.cache/huggingface/token` (`hf auth login`) und wird als
# Header-Datei an curl übergeben – nie auf der Kommandozeile, damit er nicht in
# `ps` oder der Shell-History steht, und nie ausgegeben.
#
# Rückgabewert: 0 = alles vorhanden und geprüft, 1 = Datei fehlt oder ist
# beschädigt, 2 = Aufruffehler.
#
# Beispiele:
#   ./scripts/model-fetch.sh mflux-community/z-image-turbo-mflux-q6 \
#     ~/models/gen/z-image-turbo-mflux-q6
#   ./scripts/model-fetch.sh meta-llama/Llama-3.2-1B ~/models/llm/llama-3.2-1b \
#     --pattern "*.safetensors"
#
set -euo pipefail

# Homebrew liegt bei nicht-interaktiven Aufrufen (ssh, launchd) nicht im PATH;
# sonst fehlen Werkzeuge, und das Skript bricht früh ab.
for prefix in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) [ -d "$prefix" ] && PATH="$prefix:$PATH" ;;
  esac
done
export PATH

die() { printf '✖ %s\n' "$*" >&2; exit 1; }
ok() { printf '✔ %s\n' "$*"; }
note() { printf '▶ %s\n' "$*"; }
warn() { printf '▲ %s\n' "$*" >&2; }

usage() {
  sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'
}

[ "$(uname -s)" = "Darwin" ] || die "Dieses Skript ist für macOS gedacht."

REPO=""
DEST=""
CHECK=0
LIMIT="5630K"
PATTERN="*"
API_BASE="https://huggingface.co"
RESOLVE_BASE="https://huggingface.co"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --limit)
      [ "$#" -ge 2 ] || die "--limit braucht einen Wert"
      LIMIT="$2"
      shift
      ;;
    --pattern)
      [ "$#" -ge 2 ] || die "--pattern braucht einen Wert"
      PATTERN="$2"
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
      if [ -z "$REPO" ]; then
        REPO="$1"
      elif [ -z "$DEST" ]; then
        DEST="$1"
      else
        die "zu viele Argumente: $1"
      fi
      ;;
  esac
  shift
done

[ -n "$REPO" ] && [ -n "$DEST" ] || {
  usage >&2
  exit 2
}

command -v python3 >/dev/null 2>&1 || die "python3 fehlt (xcode-select --install)"
command -v curl >/dev/null 2>&1 || die "curl fehlt"

# --- Token ---------------------------------------------------------------
# Reihenfolge: HF_TOKEN aus der Umgebung, sonst die Datei von `hf auth login`.
# Der Wert wird nie ausgegeben, nur die Quelle.
TOKEN=""
TOKEN_SOURCE=""
TOKEN_FILE="${HF_TOKEN_FILE:-$HOME/.cache/huggingface/token}"

if [ -n "${HF_TOKEN:-}" ]; then
  TOKEN="$(printf '%s' "$HF_TOKEN" | tr -d '[:space:]')"
  TOKEN_SOURCE="Umgebungsvariable HF_TOKEN"
elif [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '[:space:]' <"$TOKEN_FILE")"
  [ -n "$TOKEN" ] && TOKEN_SOURCE="$TOKEN_FILE"
fi

HEADER_FILE="$(mktemp -t hf-header)"
chmod 600 "$HEADER_FILE"
TREE="$(mktemp -t model-tree)"
LIST="$(mktemp -t model-list)"
trap 'rm -f "$TREE" "$LIST" "$HEADER_FILE"' EXIT

if [ -n "$TOKEN" ]; then
  printf 'Authorization: Bearer %s\n' "$TOKEN" >"$HEADER_FILE"
  note "Token: $TOKEN_SOURCE"
else
  note "Token: keiner – nur öffentliche Repos"
fi
unset TOKEN

curl_auth() { curl -H "@$HEADER_FILE" "$@"; }

# --- Dateiliste aus der API ---------------------------------------------
note "Quelle: huggingface.co/$REPO"
status="$(
  curl_auth -sS -o "$TREE" -w '%{http_code}' --retry 3 \
    --connect-timeout 20 -m 60 \
    "$API_BASE/api/models/$REPO/tree/main?recursive=true"
)" || die "Hugging-Face-API nicht erreichbar"

case "$status" in
  200) ;;
  401)
    die "HTTP 401 – Token fehlt oder ist ungültig (auf dem Mac: hf auth login)"
    ;;
  403)
    die "HTTP 403 – kein Zugriff auf $REPO; auf der Modellseite die Lizenz bestätigen und den Token prüfen"
    ;;
  404)
    die "HTTP 404 – Repo nicht gefunden: $REPO"
    ;;
  *)
    die "Hugging-Face-API antwortet mit HTTP $status für $REPO"
    ;;
esac

python3 - "$TREE" "$PATTERN" >"$LIST" <<'PY'
import fnmatch
import json
import sys

tree, pattern = sys.argv[1], sys.argv[2]
with open(tree, encoding="utf-8") as handle:
    entries = json.load(handle)
if not isinstance(entries, list):
    raise SystemExit("unerwartete API-Antwort")
for entry in entries:
    if entry.get("type") != "file":
        continue
    path = entry["path"]
    if not fnmatch.fnmatch(path, pattern):
        continue
    lfs = entry.get("lfs") or {}
    print(entry["size"], lfs.get("oid", "-"), path, sep="\t")
PY

[ -s "$LIST" ] || die "keine Datei passt auf --pattern $PATTERN"

# --- Download ------------------------------------------------------------
# curl statt aria2: der Token geht als Header-Datei mit, nicht als Argument.
# `-C -` setzt abgebrochene Läufe fort, `--limit-rate` hält das LAN frei.
download() { # <url> <zielpfad>
  local url="$1" target="$2"
  mkdir -p "$(dirname "$target")"
  curl_auth -sS -fL --retry 5 --retry-delay 10 --connect-timeout 30 -C - \
    --limit-rate "$LIMIT" -o "$target" "$url"
}

# curl gab nach fünf Versuchen bei „Connection reset by peer“ auf, obwohl nur
# 219 MB fehlten (2026-10-28, 3,9 GB GGUF). aria2c setzt fort und versucht je
# Segment neu; es bekommt die Restbytes. Nur bei Netzfehlern (curl 7, 18, 28,
# 52, 56) – ein HTTP-Fehler (22 = 401/403) wird nicht wiederholt.
download_resilient() { # <url> <zielpfad>
  local url="$1" target="$2" status=0
  download "$url" "$target" || status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  case "$status" in
    7 | 18 | 28 | 52 | 56)
      if command -v aria2c >/dev/null 2>&1; then
        warn "curl brach mit Exit $status ab – setze mit aria2c fort"
        aria2c -c -x2 -s2 -k1M --max-tries=30 --retry-wait=5 \
          --console-log-level=warn --summary-interval=0 \
          --limit-rate="$LIMIT" -d "$(dirname "$target")" \
          -o "$(basename "$target")" "$url" || return $?
        return 0
      fi
      ;;
  esac
  return "$status"
}

sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

size_of() { wc -c <"$1" | tr -d ' '; }

total=0
present=0
fetched=0
broken=0

while IFS=$'\t' read -r size sha path; do
  [ -n "$path" ] || continue
  target="$DEST/$path"
  total=$((total + size))

  if [ -f "$target" ] && [ "$(size_of "$target")" = "$size" ]; then
    if [ "$sha" != "-" ] && [ "$(sha256 "$target")" != "$sha" ]; then
      printf '✖ SHA-256 falsch: %s\n' "$path" >&2
      broken=$((broken + 1))
      continue
    fi
    present=$((present + 1))
    ok "vorhanden: $path"
    continue
  fi

  if [ "$CHECK" = "1" ]; then
    printf '✖ fehlt oder unvollständig: %s\n' "$path" >&2
    broken=$((broken + 1))
    continue
  fi

  note "$path ($((size / 1024 / 1024)) MB)"
  if ! download_resilient "$RESOLVE_BASE/$REPO/resolve/main/$path?download=true" "$target"; then
    die "Download fehlgeschlagen: $path (Netzabbruch; bei HTTP 401 fehlt der Token, 403 heißt: Lizenz auf der Modellseite bestätigen)"
  fi

  if [ "$(size_of "$target")" != "$size" ]; then
    printf '✖ Größe falsch: %s\n' "$path" >&2
    broken=$((broken + 1))
    continue
  fi
  if [ "$sha" != "-" ] && [ "$(sha256 "$target")" != "$sha" ]; then
    printf '✖ SHA-256 falsch: %s\n' "$path" >&2
    broken=$((broken + 1))
    continue
  fi
  fetched=$((fetched + 1))
  ok "geladen: $path"
done <"$LIST"

if [ "$broken" -gt 0 ]; then
  die "$broken Datei(en) fehlen oder sind beschädigt ($DEST)"
fi

ok "$present vorhanden, $fetched geladen, $((total / 1024 / 1024)) MB gesamt"
if [ "$CHECK" = "1" ]; then
  ok "Prüfung gegen die API vollständig"
fi
exit 0
