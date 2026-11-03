"""Protokolltests für das gen-Backend — ohne Modellgewichte."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import server


class ProtocolTest(unittest.TestCase):
    def test_initialize(self) -> None:
        response = server.dispatch(
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        )
        assert response is not None
        self.assertEqual(response["result"]["serverInfo"]["name"], "gen")
        self.assertIn("tools", response["result"]["capabilities"])

    def test_tools_list(self) -> None:
        response = server.dispatch({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert response is not None
        names = [tool["name"] for tool in response["result"]["tools"]]
        self.assertEqual(
            names,
            [
                "models",
                "unload",
                "txt2img",
                "zimage",
                "sdxl",
                "edit",
                "video",
                "mesh",
                "ocr",
            ],
        )

    def test_zimage_schema(self) -> None:
        response = server.dispatch({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert response is not None
        tools = {tool["name"]: tool for tool in response["result"]["tools"]}
        schema = tools["zimage"]["inputSchema"]
        self.assertEqual(schema["properties"]["steps"]["default"], 9)
        self.assertEqual(schema["required"], ["prompt"])

    def test_zimage_rejects_empty_prompt(self) -> None:
        with self.assertRaises(ValueError):
            server.tool_zimage({"prompt": "   "})

    def test_sdxl_schema(self) -> None:
        response = server.dispatch({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        assert response is not None
        tools = {tool["name"]: tool for tool in response["result"]["tools"]}
        schema = tools["sdxl"]["inputSchema"]
        self.assertEqual(schema["required"], ["prompt"])
        self.assertEqual(schema["properties"]["steps"]["default"], 25)
        self.assertEqual(schema["properties"]["engine"]["default"], "diffusers")
        self.assertIn("dpm++2m", schema["properties"]["sampling_method"]["enum"])

    def test_sdxl_rejects_empty_prompt(self) -> None:
        with self.assertRaises(ValueError):
            server.tool_sdxl({"prompt": "  "})

    def test_sdxl_rejects_unknown_sampler(self) -> None:
        with self.assertRaises(ValueError):
            server.tool_sdxl({"prompt": "Haus", "sampling_method": "nope"})

    def test_sdxl_rejects_unknown_engine(self) -> None:
        with self.assertRaises(ValueError):
            server.tool_sdxl({"prompt": "Haus", "engine": "cuda"})

    def test_sdxl_rejects_unknown_device(self) -> None:
        with self.assertRaises(ValueError):
            server.tool_sdxl({"prompt": "Haus", "engine": "sd-cli", "device": "ane"})

    def test_sdxl_rejects_unknown_weight_type(self) -> None:
        with self.assertRaises(ValueError):
            server.tool_sdxl({"prompt": "Haus", "engine": "sd-cli", "type": "q2_K"})

    def test_sdxl_reports_missing_weights(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "nichts"
            with (
                mock.patch.object(server, "SDXL_MODEL", missing / "model.safetensors"),
                mock.patch.object(server, "SDXL_DIFFUSERS", missing / "diffusers"),
                self.assertRaises(ValueError),
            ):
                server.tool_sdxl({"prompt": "Haus"})

    def test_sdxl_uses_diffusers_worker_by_default(self) -> None:
        """Default ist der MPS-Worker; sd.cpp-Metal liefert auf diesem Mac Weiß."""
        seen: list[str] = []

        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            seen.extend(command)
            Path(command[command.index("--output") + 1]).write_bytes(b"png")
            return mock.Mock(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as tmp:
            weights = Path(tmp) / "diffusers"
            weights.mkdir()
            with (
                mock.patch.object(server, "ARTIFACTS", Path(tmp)),
                mock.patch.object(server, "SDXL_DIFFUSERS", weights),
                mock.patch.object(server, "unload_text_model", lambda: None),
                mock.patch.object(server.subprocess, "run", fake_run),
            ):
                info = server.tool_sdxl({"prompt": "Haus", "seed": 7})
        self.assertIn("sdxl_worker.py", seen[1])
        self.assertEqual(seen[seen.index("--prompt") + 1], "Haus")
        self.assertEqual(seen[seen.index("--steps") + 1], "25")
        self.assertEqual(seen[seen.index("--sampler") + 1], "dpm++2m")
        self.assertEqual(seen[seen.index("--diffusers-dir") + 1], str(weights))
        self.assertEqual(info["engine"], "diffusers")
        self.assertEqual(info["seed"], 7)

    def test_sdxl_sd_cli_engine_keeps_vae_off_gpu(self) -> None:
        seen: list[str] = []

        def fake_run(command: list[str], **kwargs: object) -> mock.Mock:
            seen.extend(command)
            Path(command[command.index("-o") + 1]).write_bytes(b"png")
            return mock.Mock(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as tmp:
            weights = Path(tmp) / "model.safetensors"
            weights.write_bytes(b"x")
            with (
                mock.patch.object(server, "ARTIFACTS", Path(tmp)),
                mock.patch.object(server, "SDXL_MODEL", weights),
                mock.patch.object(server, "unload_text_model", lambda: None),
                mock.patch.object(server.subprocess, "run", fake_run),
            ):
                info = server.tool_sdxl({"prompt": "Haus", "engine": "sd-cli"})
        self.assertEqual(seen[seen.index("-M") + 1], "img_gen")
        self.assertEqual(seen[seen.index("--type") + 1], "q8_0")
        self.assertEqual(seen[seen.index("--backend") + 1], "vae=cpu")
        self.assertIn("--vae-tiling", seen)
        self.assertEqual(info["engine"], "sd-cli")
        self.assertEqual(info["type"], "q8_0")

    def test_mflux_environment_prepends_compat(self) -> None:
        previous = os.environ.get("PYTHONPATH")
        os.environ["PYTHONPATH"] = "/tmp/other"
        try:
            entries = server.mflux_environment()["PYTHONPATH"].split(os.pathsep)
        finally:
            if previous is None:
                del os.environ["PYTHONPATH"]
            else:
                os.environ["PYTHONPATH"] = previous
        self.assertEqual(entries[0], str(server.COMPAT))
        self.assertEqual(entries[1], "/tmp/other")

    def test_mflux_environment_without_pythonpath(self) -> None:
        previous = os.environ.pop("PYTHONPATH", None)
        try:
            self.assertEqual(
                server.mflux_environment()["PYTHONPATH"], str(server.COMPAT)
            )
        finally:
            if previous is not None:
                os.environ["PYTHONPATH"] = previous

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

    def test_dimension_clamp(self) -> None:
        self.assertEqual(server.clamp_dimension(100, 1024), 256)
        self.assertEqual(server.clamp_dimension(5000, 1024), 1536)
        self.assertEqual(server.clamp_dimension(1000, 1024), 992)

    def test_safe_dest_akzeptiert_flachen_namen(self) -> None:
        self.assertEqual(
            server.safe_dest("teetasse-japanisch-50mm.png"),
            "teetasse-japanisch-50mm.png",
        )
        self.assertIsNone(server.safe_dest(None))
        self.assertIsNone(server.safe_dest("   "))

    def test_safe_dest_lehnt_pfade_ab(self) -> None:
        for value in (
            "../../etc/passwd.png",
            "unter/ordner.png",
            "/absolut/bild.png",
            "..",
            ".versteckt.png",
            "bild.jpg",
        ):
            with self.assertRaises(ValueError, msg=value):
                server.safe_dest(value)

    def test_export_image_schreibt_in_exportordner(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "artifacts" / "image.png"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"png")
            with mock.patch.object(server, "EXPORT_DIR", root / "ausgabe"):
                destination = server.export_image(source, "probe.png")
                assert destination is not None
                self.assertEqual(Path(destination), root / "ausgabe" / "probe.png")
                self.assertEqual(Path(destination).read_bytes(), b"png")
                self.assertIsNone(server.export_image(source, None))

    def test_preview_ist_kleiner_und_liegt_neben_dem_bild(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "image.png"
            source.write_bytes(server.PNG_MAGIC + b"rest")
            with mock.patch.object(server, "ARTIFACTS", root):
                preview = server.preview_path(source)
                self.assertEqual(preview.name, "image-preview.png")
                with mock.patch.object(server.shutil, "which", return_value=None):
                    self.assertIsNone(server.make_preview(source))
            # Kein PNG (Testdoubles schreiben nur b"png") → keine Vorschau.
            source.write_bytes(b"png")
            with mock.patch.object(
                server.shutil, "which", return_value="/usr/bin/sips"
            ):
                self.assertIsNone(server.make_preview(source))

    def test_finish_image_meldet_vorschau_und_export(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "artifacts" / "image.png"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"png")
            info = {"path": str(source)}
            with (
                mock.patch.object(server, "ARTIFACTS", root / "artifacts"),
                mock.patch.object(server, "EXPORT_DIR", root / "ausgabe"),
                mock.patch.object(
                    server,
                    "make_preview",
                    return_value={"path": "preview.png", "bytes": 3},
                ),
            ):
                result = server.finish_image(source, info, "probe.png")
            self.assertEqual(result["preview"]["path"], "preview.png")
            self.assertEqual(result["export"], str(root / "ausgabe" / "probe.png"))


if __name__ == "__main__":
    unittest.main()
