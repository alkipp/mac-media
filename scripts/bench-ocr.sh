#!/usr/bin/env bash
#
# scripts/bench-ocr.sh — Laufzeit der Vision-Texterkennung (`ml_ocr`) messen.
#
# Aufruf: scripts/bench-ocr.sh <datei-unter-inbox> [seitenbereich]
# Beispiel: scripts/bench-ocr.sh scan.pdf 1-17
#
# Gemessen wird je Erkennungsstufe die Zeit, die ein MCP-Client bis zur Antwort
# wartet, und die Dauer, die das Tool selbst für die Seiten meldet. Die Datei
# bleibt im inbox des Macs; das Skript schreibt nichts außer seiner Ausgabe.
#
set -euo pipefail

binary="${ML_OCR_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/swift/.build/release/ml-mcp}"
file="${1:?Aufruf: $0 <datei-unter-inbox> [seitenbereich]}"
pages="${2:-1-}"

[ -x "$binary" ] || {
  printf '✖ %s fehlt – vorher: swift build -c release --package-path swift\n' "$binary" >&2
  exit 1
}
command -v python3 >/dev/null || {
  printf '✖ python3 fehlt (xcode-select --install)\n' >&2
  exit 1
}

export ML_OCR_BIN="$binary" ML_OCR_FILE="$file" ML_OCR_PAGES="$pages"

python3 - <<'PY'
import json
import os
import signal
import subprocess
import sys
import time

binary = os.environ["ML_OCR_BIN"]
name = os.environ["ML_OCR_FILE"]
pages = os.environ["ML_OCR_PAGES"]

process = subprocess.Popen(
    [binary, "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
    text=True,
    bufsize=1,
)


def send(payload):
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()


def wait(identifier, timeout=600):
    def abort(signum, frame):
        raise TimeoutError(f"keine Antwort nach {timeout} s")

    signal.signal(signal.SIGALRM, abort)
    signal.alarm(timeout)
    try:
        while True:
            line = process.stdout.readline()
            if not line:
                return None
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if message.get("id") == identifier:
                return message
    finally:
        signal.alarm(0)


send(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "bench-ocr", "version": "1"},
        },
    }
)
wait(1, 30)
send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

print(f"Datei: {name}, Seiten: {pages}")
print(f"{'Stufe':10} {'Client':>9}  Tool")
for index, level in enumerate(("accurate", "fast"), start=2):
    started = time.time()
    send(
        {
            "jsonrpc": "2.0",
            "id": index,
            "method": "tools/call",
            "params": {
                "name": "ocr",
                "arguments": {
                    "path": name,
                    "pages": pages,
                    "level": level,
                    "write": True,
                },
            },
        }
    )
    try:
        message = wait(index)
    except TimeoutError as error:
        print(f"{level:10} {error}")
        process.kill()
        sys.exit(1)
    elapsed = (time.time() - started) * 1000

    if message is None:
        print(f"{level:10} keine Antwort")
        process.kill()
        sys.exit(1)
    result = message.get("result", {})
    if result.get("isError"):
        print(f"{level:10} Fehler: {result.get('content')}")
        process.kill()
        sys.exit(1)

    text = "".join(part.get("text", "") for part in result.get("content", []))
    details = [
        line.strip()
        for line in text.splitlines()
        if line.startswith(("Dauer:", "Erkennung:", "Seiten:"))
    ]
    print(f"{level:10} {elapsed:7.0f} ms  {' | '.join(details)}")

process.kill()
PY
