#!/usr/bin/env bash
#
# Qualitäts-Gate für mac-compute-mcp.
#
# Prüft Formatierung, Lints, Tests, Abhängigkeiten und Shell-Skripte.
# Aufruf aus jedem Verzeichnis: scripts/check.sh
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Homebrew liegt bei nicht-interaktiven Aufrufen (launchd, ssh) oft nicht im
# PATH; sonst fehlt shellcheck und das Gate prüft still weniger.
for prefix in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) [ -d "$prefix" ] && PATH="$prefix:$PATH" ;;
  esac
done
export PATH

fail() { printf '✖ %s\n' "$*" >&2; exit 1; }
step() { printf '\n▶ %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 fehlt – Installation siehe README"
}

require cargo
require cargo-fmt
require cargo-clippy
require cargo-deny
require cargo-audit
require swift
require cmake

step "cargo fmt --all --check"
cargo fmt --all --check

step "cargo clippy --workspace --all-targets"
cargo clippy --workspace --all-targets -- -D warnings

step "Tests"
if command -v cargo-nextest >/dev/null 2>&1; then
  cargo nextest run --workspace
  cargo test --workspace --doc
else
  cargo test --workspace
fi

step "swift build"
swift build -c release --package-path swift

step "swift test"
# `swift test` endet auch dann mit 0, wenn keine XCTest-Suite läuft: die
# swift-testing-Zeile meldet dann „0 tests in 0 suites … passed“. Am 2026-11-07
# war genau das im Gate-Log zu sehen, während 17 Tests liefen — und im
# umgekehrten Fall wäre das Gate still grün. Deshalb wird gezählt.
swift_log="$(mktemp)"
trap 'rm -f "$swift_log"' EXIT
swift test --package-path swift 2>&1 | tee "$swift_log"
executed="$(grep -oE 'Executed [0-9]+ tests?' "$swift_log" | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
[ "${executed:-0}" -gt 0 ] || fail "swift test führte 0 Tests aus"
printf '✔ %s Swift-Tests ausgeführt\n' "$executed"

step "cargo deny check"
cargo deny check

step "cargo audit"
cargo audit

step "Shell-Skripte"
shopt -s nullglob
scripts=(scripts/*.sh backends/*/*.sh)
[ "${#scripts[@]}" -gt 0 ] || fail "keine Skripte unter scripts/ oder backends/"
for script in "${scripts[@]}"; do
  bash -n "$script"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "${scripts[@]}"
else
  printf 'ℹ shellcheck fehlt – Syntaxprüfung mit bash -n durchgeführt\n'
fi

step "Python-Skripte"
pyscripts=(scripts/*.py)
if [ "${#pyscripts[@]}" -gt 0 ]; then
  for script in "${pyscripts[@]}"; do
    python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' "$script"
  done
  # Ein Skript, das nur syntaktisch prüfbar ist, kann trotzdem beim Start
  # scheitern; --help beweist, dass es ohne Nebenwirkung läuft.
  [ -f scripts/gateway-call.py ] \
    && { python3 scripts/gateway-call.py --help >/dev/null || fail "gateway-call.py startet nicht"; }
  if command -v ruff >/dev/null 2>&1; then
    ruff format --check "${pyscripts[@]}"
    ruff check "${pyscripts[@]}"
  else
    printf 'ℹ ruff fehlt – nur Syntaxprüfung mit ast.parse\n'
  fi
fi

step "Version und Tag"
version="$(tr -d '[:space:]' < VERSION)"
latest="$(git describe --tags --abbrev=0 2>/dev/null || true)"
latest="${latest#v}"
if [ -n "$latest" ]; then
  newest="$(printf '%s\n%s\n' "$version" "$latest" | sort -V | tail -1)"
  [ "$version" = "$newest" ] && [ "$version" != "$latest" ] \
    || fail "VERSION $version ist nicht größer als der letzte Tag v$latest"
  printf 'VERSION %s ist neuer als v%s\n' "$version" "$latest"
else
  printf 'ℹ noch kein Tag vorhanden\n'
fi

step "Medien-Benchmark (Schwellen)"
if [ "$(uname -s)" = "Darwin" ] && [ -x "$HOME/Library/Application Support/mac-compute/bin/video-mcp" ]; then
  scripts/bench-media.sh --gate
else
  printf 'ℹ kein macOS oder keine installierten Binaries – Benchmark übersprungen\n'
fi

step "3D-Abnahme"
if [ "$(uname -s)" = "Darwin" ] && [ -x "$HOME/Library/Application Support/mac-compute/bin/video-mcp" ]; then
  scripts/3d-video.sh
else
  printf 'ℹ kein macOS oder keine installierten Binaries – 3D-Abnahme übersprungen\n'
fi

step "Thumbnail-Regression"
if [ "$(uname -s)" = "Darwin" ] && [ -f "$HOME/Library/Application Support/mac-compute/inbox/sample.mp4" ]; then
  scripts/media-thumbnail-check.sh
else
  printf 'ℹ kein Beispielvideo in inbox/ – Thumbnail-Test übersprungen\n'
fi

step "Python-Backends"
# Lints laufen im Wegwerf-venv mit Homebrew-Python (3.14). Die Protokolltests
# brauchen torch und bleiben deshalb in der photo-venv.
tools_venv="${PYTOOLS_VENV:-/tmp/opencode/hc-venv}"
backend_python="$HOME/Library/Application Support/mac-compute/venvs/photo/bin/python"
if [ ! -x "$tools_venv/bin/ruff" ] && command -v uv >/dev/null 2>&1; then
  uv venv --python 3.14 "$tools_venv" >/dev/null 2>&1 || true
  uv pip install --python "$tools_venv/bin/python" ruff mypy bandit >/dev/null 2>&1 || true
fi
if [ -x "$tools_venv/bin/ruff" ]; then
  "$tools_venv/bin/ruff" format --check backends/*/server.py
  "$tools_venv/bin/ruff" check backends/*/server.py
  # Je Backend getrennt: beide heißen `server.py`, mypy lehnt das in einem Lauf ab.
  for backend in backends/*/server.py; do
    "$tools_venv/bin/mypy" --ignore-missing-imports "$backend"
  done
  "$tools_venv/bin/bandit" -q backends/*/server.py
else
  printf 'ℹ Werkzeug-venv fehlt (uv, %s) – Lints übersprungen\n' "$tools_venv"
fi
if [ -x "$backend_python" ]; then
  ( cd backends/photo && "$backend_python" test/test_protocol.py >/dev/null )
  ( cd backends/gen && "$backend_python" test/test_protocol.py >/dev/null )
else
  printf 'ℹ photo-venv fehlt – Protokolltests übersprungen\n'
fi

printf '\n✔ Alle Prüfungen bestanden\n'
