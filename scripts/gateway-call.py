#!/usr/bin/env python3
"""Ruft ein Werkzeug des laufenden mac-media-Gateways auf.

Ersetzt den Ad-hoc-Client, der in einer Sitzung fünfmal neu geschrieben wurde
(Bash mit curl, dann zweimal Python). Ein Aufruf, keine Vorgeschichte:

    ./scripts/gateway-call.py --list
    ./scripts/gateway-call.py ml_analyze '{"path":"foto.heic"}'
    ./scripts/gateway-call.py ml_analyze --file auftrag.json
    ./scripts/gateway-call.py --json ml_info

Der Gateway spricht Streamable HTTP (MCP) und antwortet als SSE; die Sitzungs-
kennung steht im Kopf der Antwort auf `initialize`. Das Token liest das Skript
aus `~/.config/mac-compute/token` (Datei 0600); es wird nie ausgegeben.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import sys
from pathlib import Path
from typing import Any

DEFAULT_URL = "http://127.0.0.1:8787"
DEFAULT_TOKEN_FILE = "~/.config/mac-compute/token"


class GatewayError(RuntimeError):
    """Fehler, den der Aufrufer als Meldung sieht."""


class Gateway:
    """Minimaler MCP-Client für den lokalen Gateway."""

    def __init__(self, base_url: str, token_file: str, timeout: float) -> None:
        self.host, self.port, self.scheme = _split_url(base_url)
        self.token = Path(token_file).expanduser().read_text(encoding="utf-8").strip()
        self.timeout = timeout
        self.session: str | None = None

    def _post(self, body: dict[str, Any]) -> tuple[str, str | None]:
        if self.scheme == "https":
            conn: http.client.HTTPConnection = http.client.HTTPSConnection(
                self.host, self.port, timeout=self.timeout
            )
        else:
            conn = http.client.HTTPConnection(
                self.host, self.port, timeout=self.timeout
            )
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session:
            headers["mcp-session-id"] = self.session
        try:
            conn.request("POST", "/mcp", body=json.dumps(body), headers=headers)
            response = conn.getresponse()
            text = response.read().decode("utf-8", "replace")
            session = response.getheader("mcp-session-id")
        except OSError as error:
            raise GatewayError(f"Gateway nicht erreichbar: {error}") from error
        finally:
            conn.close()
        return text, session

    def open(self) -> None:
        """Handschlag; die Sitzungskennung kommt im Antwortkopf."""
        text, session = self._post(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "gateway-call", "version": "1"},
                },
            }
        )
        if session is None:
            raise GatewayError(f"keine Sitzungskennung erhalten: {_first_line(text)}")
        self.session = session
        self._post(
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}
        )

    def call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        text, _ = self._post(
            {"jsonrpc": "2.0", "id": 2, "method": method, "params": params}
        )
        payload = _last_payload(text)
        if payload is None:
            raise GatewayError(f"keine JSON-Antwort: {_first_line(text)}")
        if "error" in payload:
            error = payload["error"]
            raise GatewayError(f"{error.get('code')}: {error.get('message')}")
        result = payload.get("result")
        if not isinstance(result, dict):
            raise GatewayError(f"unerwartete Antwort: {payload}")
        return result


def _split_url(base_url: str) -> tuple[str, int, str]:
    parsed = base_url.split("://", 1)
    if len(parsed) != 2:
        raise GatewayError(f"URL ohne Schema: {base_url}")
    scheme, rest = parsed
    host, _, port = rest.partition(":")
    default_port = 443 if scheme == "https" else 80
    return host, int(port) if port else default_port, scheme


def _last_payload(text: str) -> dict[str, Any] | None:
    """Liest den letzten JSON-Rumpf aus einer SSE-Antwort."""
    found: dict[str, Any] | None = None
    for line in text.splitlines():
        if not line.startswith("data: "):
            continue
        try:
            candidate = json.loads(line[6:])
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict):
            found = candidate
    return found


def _first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return "leere Antwort"


def _content_text(result: dict[str, Any]) -> str:
    blocks = result.get("content") or []
    texts = [block.get("text", "") for block in blocks if block.get("type") == "text"]
    return "\n".join(texts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Werkzeug im laufenden mac-media-Gateway aufrufen.",
        epilog='Beispiel: gateway-call.py ml_analyze \'{"path":"foto.heic"}\'',
    )
    parser.add_argument("tool", nargs="?", help="Werkzeugname, z. B. ml_analyze")
    parser.add_argument("arguments", nargs="?", default="{}", help="Argumente als JSON")
    parser.add_argument("--file", help="Argumente aus einer JSON-Datei lesen")
    parser.add_argument(
        "--list", action="store_true", help="Werkzeuge auflisten und beenden"
    )
    parser.add_argument(
        "--json", action="store_true", help="Rohantwort als JSON ausgeben"
    )
    parser.add_argument("--url", default=os.environ.get("MAC_COMPUTE_URL", DEFAULT_URL))
    parser.add_argument(
        "--token-file",
        default=os.environ.get("MAC_COMPUTE_TOKEN_FILE", DEFAULT_TOKEN_FILE),
    )
    parser.add_argument(
        "--timeout", type=float, default=600.0, help="Sekunden (Standard 600)"
    )
    options = parser.parse_args(argv)

    if not options.list and not options.tool:
        parser.error("Werkzeugnamen angeben oder --list verwenden")

    try:
        gateway = Gateway(options.url, options.token_file, options.timeout)
        gateway.open()
        if options.list:
            result = gateway.call("tools/list", {})
            for tool in result.get("tools", []):
                print(tool.get("name", "?"))
            return 0

        if options.file:
            arguments = json.loads(
                Path(options.file).expanduser().read_text(encoding="utf-8")
            )
        else:
            arguments = json.loads(options.arguments)
        result = gateway.call(
            "tools/call", {"name": options.tool, "arguments": arguments}
        )
    except GatewayError as error:
        print(f"✖ {error}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as error:
        print(f"✖ Argumente sind kein JSON: {error}", file=sys.stderr)
        return 1

    if options.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        text = _content_text(result)
        print(text if text else json.dumps(result, indent=2, ensure_ascii=False))
    if result.get("isError"):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
