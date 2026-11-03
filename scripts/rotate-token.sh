#!/usr/bin/env bash
#
# rotate-token.sh – wechselt den Bearer-Token des mac-compute-Gateways.
#
# Ablauf:
#   1. bisherigen Token als token.previous sichern (startet die Frist)
#   2. neuen Token erzeugen (32 Byte, hex, Rechte 0600)
#   3. LaunchAgent abmelden und neu registrieren
#   4. neuen und alten Token gegen /health prüfen
#
# Der Gateway akzeptiert den alten Token ab dem Änderungsdatum von
# token.previous für --token-grace-hours (Vorgabe 168 h). Danach ist
# token.previous zu löschen.
#
# Aufruf:
#   scripts/rotate-token.sh [--dry-run] [--no-restart] [--force]
#
# Der Token selbst wird nie ausgegeben; curl liest den Authorization-Header
# aus stdin, damit der Wert nicht in der Prozessliste steht.

set -euo pipefail

LABEL="de.kippar.mac-compute-gateway"
CONFIG_DIR="${MAC_COMPUTE_CONFIG_DIR:-$HOME/.config/mac-compute}"
TOKEN_FILE="$CONFIG_DIR/token"
PREVIOUS_FILE="$CONFIG_DIR/token.previous"
PLIST="${MAC_COMPUTE_PLIST:-$HOME/Library/LaunchAgents/$LABEL.plist}"
HEALTH_URL="${MAC_COMPUTE_HEALTH_URL:-http://127.0.0.1:8787/health}"
GRACE_HOURS="${MAC_COMPUTE_TOKEN_GRACE_HOURS:-168}"

DRY_RUN=0
RESTART=1
FORCE=0

usage() {
  cat <<'EOF'
Wechselt den Bearer-Token des mac-compute-Gateways und prüft beide Token.

  --dry-run, -n   nur zeigen, was passieren würde
  --no-restart    Token-Dateien schreiben, Gateway nicht neu laden
  --force         vorhandenes token.previous überschreiben
  --help, -h      diese Hilfe
EOF
}

die() { printf '✖ %s\n' "$*" >&2; exit 1; }
warn() { printf '! %s\n' "$*" >&2; }
step() { printf '\n▶ %s\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run | -n) DRY_RUN=1 ;;
    --no-restart) RESTART=0 ;;
    --force) FORCE=1 ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unbekannte Option '$1'"
      ;;
  esac
  shift
done

[ -r "$TOKEN_FILE" ] || die "Token-Datei '$TOKEN_FILE' fehlt oder ist nicht lesbar"
[ -f "$PLIST" ] || die "LaunchAgent-Plist '$PLIST' fehlt"
command -v openssl >/dev/null 2>&1 || die "openssl fehlt"
command -v curl >/dev/null 2>&1 || die "curl fehlt"
if [ "$RESTART" -eq 1 ] && ! command -v launchctl >/dev/null 2>&1; then
  die "launchctl fehlt – dieses Skript läuft auf macOS"
fi

if [ -e "$PREVIOUS_FILE" ] && [ "$FORCE" -ne 1 ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "token.previous existiert bereits – ein echter Lauf würde hier abbrechen (--force überschreibt)"
  else
    warn "token.previous existiert bereits; der abgelöste Token bleibt bis zum Ablauf gültig."
    die "Erst nach Ablauf löschen oder mit --force überschreiben"
  fi
elif [ -e "$PREVIOUS_FILE" ]; then
  warn "--force: der bisherige Übergangstoken in $PREVIOUS_FILE wird ersetzt; wer ihn noch hält, verliert den Zugang"
fi

step "Bisherigen Token als token.previous sichern"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  würde %s nach %s kopieren (0600)\n' "$TOKEN_FILE" "$PREVIOUS_FILE"
else
  umask 077
  cp "$TOKEN_FILE" "$PREVIOUS_FILE"
  chmod 600 "$PREVIOUS_FILE"
  printf '  gesichert: %s\n' "$PREVIOUS_FILE"
fi

step "Neuen Token erzeugen"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  würde 32 Byte Zufall als Hex nach %s schreiben (0600)\n' "$TOKEN_FILE"
  printf '\nTrockenlauf: nichts geändert.\n'
  exit 0
fi
umask 077
openssl rand -hex 32 >"$TOKEN_FILE.tmp"
chmod 600 "$TOKEN_FILE.tmp"
mv -f "$TOKEN_FILE.tmp" "$TOKEN_FILE"
printf '  geschrieben: %s\n' "$TOKEN_FILE"

if [ "$RESTART" -eq 0 ]; then
  printf '\nToken gewechselt; das laufende Gateway behält den bisherigen Wert.\n'
  printf 'Beim nächsten Neustart liest es den neuen Token aus %s.\n' "$TOKEN_FILE"
  exit 0
fi

step "Gateway neu laden"
# Nach einem Binary-Tausch scheitert `kickstart -k` an der Code-Signatur;
# abmelden und neu registrieren ist der verlässliche Weg.
launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
printf '  LaunchAgent neu registriert\n'

# Liest den Authorization-Header aus stdin, damit der Token nicht in der
# Prozessliste auftaucht.
health_code() {
  printf 'Authorization: Bearer %s\n' "$1" |
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H @- "$HEALTH_URL" || true
}

step "Neuen Token prüfen"
NEW_TOKEN="$(cat "$TOKEN_FILE")"
CODE=""
for _ in $(seq 1 30); do
  CODE="$(health_code "$NEW_TOKEN")"
  if [ "$CODE" = "200" ]; then
    break
  fi
  sleep 0.5
done
if [ "$CODE" != "200" ]; then
  die "Gateway antwortet nicht mit dem neuen Token (HTTP ${CODE:-000}); Log: ~/Library/Logs/mac-compute/gateway.err.log"
fi
printf '  neuer Token: HTTP %s\n' "$CODE"

step "Abgelösten Token prüfen"
OLD_CODE="$(health_code "$(cat "$PREVIOUS_FILE")")"
case "$OLD_CODE" in
  200) printf '  alter Token: HTTP 200, Übergangsfrist läuft\n' ;;
  401) warn "alter Token wird abgelehnt – ist --token-grace-hours 0 gesetzt?" ;;
  *) warn "alter Token: HTTP ${OLD_CODE:-000} (unerwartet)" ;;
esac

if EXPIRY="$(date -v+"${GRACE_HOURS}"H '+%Y-%m-%d %H:%M' 2>/dev/null)"; then
  printf '\nFrist endet voraussichtlich: %s (token.previous + %s h)\n' "$EXPIRY" "$GRACE_HOURS"
fi
cat <<EOF

Nächste Schritte:
  - Sandbox/Container neu starten, damit sie den neuen Token aus ~/.zshenv liest
  - nach Ablauf aufräumen: rm "$PREVIOUS_FILE"
EOF
