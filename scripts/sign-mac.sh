#!/usr/bin/env bash
#
# sign-mac.sh — Gateway und Backends signieren und notarisieren (Schritt 22).
#
# Ohne Developer-ID läuft das Skript nur bis zur Prüfung und ändert nichts.
#
# Voraussetzungen:
#   - Apple Developer ID Application im Schlüsselbund
#   - für die Notarisierung ein notarytool-Profil (xcrun notarytool store-credentials)
#
# Aufruf:
#   scripts/sign-mac.sh --check
#   scripts/sign-mac.sh --identity "Developer ID Application: … (TEAMID)"
#   scripts/sign-mac.sh --identity … --notarize --profile opencode-mac-compute
#
# Optionen:
#   --check              nur prüfen, ob Identität und Werkzeuge vorhanden sind
#   --identity <name>    Signaturidentität (Default: SIGN_IDENTITY)
#   --notarize           ZIP bauen und bei Apple einreichen
#   --profile <name>     notarytool-Profil (Default: NOTARY_PROFILE)
#   --dry-run            Befehle nur anzeigen
#
set -euo pipefail

BIN_DIR="${MAC_COMPUTE_BIN:-$HOME/Library/Application Support/mac-compute/bin}"
BINARIES=(mac-compute-gateway render-mcp llm-mcp ml-mcp media-mcp video-mcp)
IDENTITY="${SIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"
CHECK=0
NOTARIZE=0
DRY_RUN=0
WORK=""

log()  { printf '%s: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
step() { printf '\n▶ %s\n' "$*" >&2; }
ok()   { printf '✔ %s\n' "$*" >&2; }
die()  { printf '✖ %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [trocken] %s\n' "$*" >&2
    return 0
  fi
  "$@"
}

cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check)     CHECK=1 ;;
    --identity)  IDENTITY="${2:?--identity braucht einen Wert}"; shift ;;
    --notarize)  NOTARIZE=1 ;;
    --profile)   PROFILE="${2:?--profile braucht einen Wert}"; shift ;;
    --dry-run)   DRY_RUN=1 ;;
    --help|-h)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unbekannte Option: $1 (--help)" ;;
  esac
  shift
done

step "Voraussetzungen"
[ "$(uname -s)" = "Darwin" ] || die "nur auf macOS"
command -v codesign >/dev/null || die "codesign fehlt"
command -v xcrun >/dev/null || die "xcrun fehlt (Xcode Command Line Tools)"
[ -d "$BIN_DIR" ] || die "Binary-Verzeichnis fehlt: $BIN_DIR"

if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1 || true)"
fi
[ -n "$IDENTITY" ] || die "keine Developer-ID gefunden (security find-identity -p codesigning)"
ok "Identität: $IDENTITY"

for name in "${BINARIES[@]}"; do
  [ -x "$BIN_DIR/$name" ] || die "Binary fehlt: $BIN_DIR/$name"
done
ok "${#BINARIES[@]} Binaries vorhanden"

if [ "$CHECK" = "1" ]; then
  printf '\n✔ Prüfung bestanden – nichts geändert.\n' >&2
  exit 0
fi

step "Signieren"
for name in "${BINARIES[@]}"; do
  run codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$IDENTITY" \
    "$BIN_DIR/$name"
  run codesign --verify --strict --verbose=2 "$BIN_DIR/$name"
  ok "$name"
done

if [ "$NOTARIZE" != "1" ]; then
  printf '\n✔ Signiert. Notarisierung mit --notarize und --profile <name>.\n' >&2
  exit 0
fi

[ -n "$PROFILE" ] || die "--notarize braucht --profile oder NOTARY_PROFILE"
command -v ditto >/dev/null || die "ditto fehlt"

step "Notarisieren"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sign-mac.XXXXXX")"
ZIP="$WORK/mac-compute.zip"
run ditto -c -k --keepParent "$BIN_DIR" "$ZIP"
run xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
ok "Notarisierung eingereicht (Ergebnis siehe Ausgabe)"

printf '\nHinweis: Einzelne Executables lassen sich nicht stappeln; Gatekeeper\n' >&2
printf 'prüft sie beim ersten Start. Für stabile Verteilung ein signiertes\n' >&2
printf 'Installer-Paket bauen (pkgbuild/productbuild) und dieses stappeln.\n' >&2
