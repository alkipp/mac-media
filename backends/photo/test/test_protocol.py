"""Protokolltests für das photo-Backend — ohne Modellgewichte."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import server


class ProtocolTest(unittest.TestCase):
    def test_initialize(self) -> None:
        response = server.dispatch(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        )
        assert response is not None
        self.assertEqual(response["result"]["serverInfo"]["name"], "photo")
        self.assertIn("tools", response["result"]["capabilities"])

    def test_tools_list(self) -> None:
        response = server.dispatch({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert response is not None
        names = [tool["name"] for tool in response["result"]["tools"]]
        self.assertEqual(
            names,
            ["models", "unload", "depth", "upscale", "matte", "segment", "transcribe"],
        )
        self.assertTrue(
            all("inputSchema" in tool for tool in response["result"]["tools"])
        )

    def test_unknown_tool(self) -> None:
        response = server.dispatch(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "nope"},
            }
        )
        assert response is not None
        self.assertEqual(response["error"]["code"], -32602)

    def test_path_escape_rejected(self) -> None:
        with self.assertRaises(ValueError):
            server.resolve_input("../../etc/passwd")

    def test_missing_file(self) -> None:
        with self.assertRaises(ValueError):
            server.resolve_input("gibt-es-nicht.png")


if __name__ == "__main__":
    unittest.main()
