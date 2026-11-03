#!/usr/bin/env bash
#
# install-mac.sh — mac-compute-Gateway auf dem Mac installieren/aktualisieren.
#
# Richtet Binaries, Manifeste, Token, LaunchAgent und Logs ein und prüft
# anschließend /health. Idempotent: vorhandene Dateien bleiben erhalten,
# solange kein --force/--build gesetzt ist.
#
# Aufruf:
#   ./scripts/install-mac.sh              # fehlende Teile ergänzen
#   ./scripts/install-mac.sh --build      # Binaries neu bauen
#   ./scripts/install-mac.sh --dry-run    # nur zeigen, was passieren würde
#   ./scripts/install-mac.sh --no-restart # LaunchAgent nicht neu laden
#
# Optionen:
#   --build             Rust- und Swift-Binaries neu bauen
#   --update-manifests  Manifeste aus config/servers.d/ überschreiben
#   --dry-run           nichts ändern
#   --no-restart        LaunchAgent nicht neu laden
#   --force             vorhandenes token.previous ignorieren
#   --help              diese Hilfe
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/mac-compute"
BIN_DIR="$APP_SUPPORT/bin"
SERVERS_DIR="$APP_SUPPORT/servers.d"
STATE_DIR="$APP_SUPPORT/state"
TOKEN_DIR="$HOME/.config/mac-compute"
TOKEN_FILE="$TOKEN_DIR/token"
PREVIOUS_FILE="$TOKEN_DIR/token.previous"
LOG_DIR="$HOME/Library/Logs/mac-compute"
LABEL="de.kippar.mac-compute-gateway"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
HEALTH_URL="${MAC_COMPUTE_HEALTH_URL:-http://127.0.0.1:8787/health}"

DRY_RUN=0
BUILD=0
UPDATE_MANIFESTS=0
NO_RESTART=0
FORCE=0

log()  { printf '%s: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
step() { printf '\n▶ %s\n' "$*" >&2; }
ok()   { printf '✔ %s\n' "$*" >&2; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die()  { printf '✖ %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [trocken] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

usage() {
  cat <<'EOF'
install-mac.sh — mac-compute-Gateway installieren/aktualisieren

Optionen:
  --build             Rust- und Swift-Binaries neu bauen
  --update-manifests  Manifeste aus config/servers.d/ überschreiben
  --dry-run           nichts ändern
  --no-restart        LaunchAgent nicht neu laden
  --force             vorhandenes token.previous ignorieren
  --help              diese Hilfe
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --build)            BUILD=1 ;;
    --update-manifests) UPDATE_MANIFESTS=1 ;;
    --dry-run)          DRY_RUN=1 ;;
    --no-restart)       NO_RESTART=1 ;;
    --force)            FORCE=1 ;;
    --help|-h)          usage; exit 0 ;;
    *)                  die "Unbekannte Option: $1 (--help)" ;;
  esac
  shift
done

[ "$(uname -s)" = "Darwin" ] || die "Dieses Skript ist für macOS gedacht."
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"

render() { # render <vorlage> <ziel>
  python3 - "$1" "$2" "$HOME" <<'PY'
import sys

src, dst, home = sys.argv[1:4]
with open(src, encoding="utf-8") as handle:
    text = handle.read()
text = text.replace("@HOME@", home).replace("@APP_SUPPORT@", home + "/Library/Application Support/mac-compute")
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
}

# --- Bestand ---------------------------------------------------------------

RUST_BINS=(mac-compute-gateway render-mcp llm-mcp)
SWIFT_BINS=(ml-mcp media-mcp video-mcp)
missing=()
for name in "${RUST_BINS[@]}" "${SWIFT_BINS[@]}"; do
  [ -x "$BIN_DIR/$name" ] || missing+=("$name")
done

step "Voraussetzungen"
command -v python3 >/dev/null || die "python3 fehlt (xcode-select --install)"
command -v plutil  >/dev/null || die "plutil fehlt"
if [ "${#missing[@]}" -gt 0 ] || [ "$BUILD" = "1" ]; then
  command -v cargo >/dev/null || die "cargo fehlt (brew install rust)"
  command -v swift >/dev/null || die "swift fehlt (xcode-select --install)"
fi
ok "macOS $(sw_vers -productVersion), $(uname -m)"

if [ "$DRY_RUN" = "1" ]; then
  log "Trockenlauf: es werden keine Dateien geändert"
fi

# --- Binaries --------------------------------------------------------------

step "Binaries"
# Ein vorhandenes Release-Binary wird ohne --build übernommen. Ist der Quellcode
# neuer als das Binary, wäre das ein stiller Altstand (am 2026-10-27: Gateway
# meldete weiter 0.1.0, obwohl die Quelle die Repo-Version las). Deshalb wird
# gebaut, sobald cargo vorhanden ist – inkrementell kostet das unter einer
# Sekunde, ein mtime-Vergleich je Binary meldet dagegen Fehlalarme, weil cargo
# unveränderte Pakete nicht neu linkt.
if [ "$BUILD" != "1" ] && [ "$DRY_RUN" != "1" ] && command -v cargo >/dev/null; then
  log "cargo vorhanden – baue inkrementell (kein Altstand)"
  BUILD=1
fi
if [ "$BUILD" = "1" ] || [ "${#missing[@]}" -gt 0 ]; then
  if [ "${#missing[@]}" -gt 0 ] && [ "$BUILD" != "1" ]; then
    log "fehlen: ${missing[*]} – baue nach"
  fi
  run cargo build --quiet --release --manifest-path "$REPO_DIR/Cargo.toml" \
    -p mac-compute-gateway -p render-mcp -p llm-mcp
  [ -d "$REPO_DIR/swift" ] && run swift build --quiet -c release --package-path "$REPO_DIR/swift"
fi
# Gebaute Binaries werden immer übernommen – auch ohne --build. So wirkt ein
# vorheriger Build sofort, ohne die Toolchain erneut zu bemühen.
run install -d -m 755 "$BIN_DIR"
installed=0
for name in "${RUST_BINS[@]}"; do
  [ -x "$REPO_DIR/target/release/$name" ] || { [ "$BUILD" = "1" ] && warn "Build fehlt: $name"; continue; }
  run install -m 755 "$REPO_DIR/target/release/$name" "$BIN_DIR/$name"
  installed=$((installed + 1))
done
for name in "${SWIFT_BINS[@]}"; do
  [ -x "$REPO_DIR/swift/.build/release/$name" ] || { [ "$BUILD" = "1" ] && warn "Build fehlt: $name"; continue; }
  run install -m 755 "$REPO_DIR/swift/.build/release/$name" "$BIN_DIR/$name"
  installed=$((installed + 1))
done
ok "Binaries installiert in $BIN_DIR ($installed)"

# --- Python-Backends -------------------------------------------------------

step "Backends"
BACKENDS_DIR="$APP_SUPPORT/backends"
run install -d -m 755 "$BACKENDS_DIR"
for backend in "$REPO_DIR"/backends/*; do
  [ -d "$backend" ] || continue
  name="$(basename "$backend")"
  run rm -rf "$BACKENDS_DIR/$name"
  run cp -R "$backend" "$BACKENDS_DIR/$name"
  ok "Backend: $name"
done
if [ ! -x "$APP_SUPPORT/venvs/photo/bin/python" ]; then
  warn "venv für photo fehlt: python3.14 -m venv \"$APP_SUPPORT/venvs/photo\""
  warn "danach: \"$APP_SUPPORT/venvs/photo/bin/pip\" install -r \"$BACKENDS_DIR/photo/requirements.txt\""
fi

# --- Manifeste -------------------------------------------------------------

step "Manifeste"
run install -d -m 700 "$APP_SUPPORT" "$SERVERS_DIR" "$STATE_DIR" "$TOKEN_DIR"
for file in "$REPO_DIR"/config/servers.d/*.json; do
  [ -f "$file" ] || continue
  target="$SERVERS_DIR/$(basename "$file")"
  if [ -f "$target" ] && [ "$UPDATE_MANIFESTS" != "1" ]; then
    continue
  fi
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [trocken] Manifest %s\n' "$target" >&2
    continue
  fi
  python3 - "$file" "$target" <<'PY'
import json
import os
import sys

src, dst = sys.argv[1:3]
home = os.path.expanduser("~")
with open(src, encoding="utf-8") as handle:
    data = handle.read()
data = data.replace(
    "@APP_SUPPORT@", home + "/Library/Application Support/mac-compute"
).replace("@HOME@", home)
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(data)
os.chmod(dst, 0o600)
json.loads(data)
PY
done
ok "Manifeste in $SERVERS_DIR"

# --- Token -----------------------------------------------------------------

step "Token"
if [ -f "$TOKEN_FILE" ]; then
  length="$(wc -c < "$TOKEN_FILE" | tr -d ' ')"
  [ "$length" -ge 32 ] || warn "Token ist kürzer als 32 Zeichen – Gateway startet nicht"
  ok "Token vorhanden"
else
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [trocken] Token in %s erzeugen\n' "$TOKEN_FILE" >&2
  else
    install -d -m 700 "$TOKEN_DIR"
    (umask 077 && openssl rand -hex 32 > "$TOKEN_FILE")
    ok "Token erzeugt ($TOKEN_FILE, 0600)"
  fi
fi
if [ -f "$PREVIOUS_FILE" ] && [ "$FORCE" != "1" ]; then
  warn "token.previous existiert – Übergangsfrist läuft noch, kein neuer Token"
fi

# --- LaunchAgent -----------------------------------------------------------

step "LaunchAgent"
run install -d -m 755 "$HOME/Library/LaunchAgents" "$LOG_DIR"
if [ "$DRY_RUN" = "1" ]; then
  printf '   [trocken] %s aus Vorlage schreiben\n' "$PLIST" >&2
else
  render "$REPO_DIR/launchd/$LABEL.plist.in" "$PLIST"
  plutil -lint "$PLIST" >/dev/null || die "ungültige Plist: $PLIST"
fi

if [ "$NO_RESTART" = "1" ]; then
  warn "LaunchAgent nicht neu geladen (--no-restart)"
elif [ "$DRY_RUN" = "1" ]; then
  printf '   [trocken] launchctl bootout/bootstrap %s\n' "$LABEL" >&2
else
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  ok "LaunchAgent geladen"
fi

# --- Prüfung ---------------------------------------------------------------

step "Prüfung"
if [ "$DRY_RUN" = "1" ]; then
  ok "Trockenlauf beendet – nichts geändert."
  exit 0
fi

sleep 2
if [ -r "$TOKEN_FILE" ]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H "Authorization: Bearer $(cat "$TOKEN_FILE")" "$HEALTH_URL" || true)"
  case "$code" in
    200) ok "/health = 200" ;;
    401) warn "/health = 401 – Token passt nicht zum laufenden Gateway" ;;
    *)   warn "/health = ${code:-keine Antwort}" ;;
  esac
else
  warn "kein Token – Prüfung übersprungen"
fi

printf '\n✔ Gateway installiert. Logs: %s\n' "$LOG_DIR" >&2
printf '  Token: %s (0600) – Wechsel: ./scripts/rotate-token.sh\n' "$TOKEN_FILE" >&2
