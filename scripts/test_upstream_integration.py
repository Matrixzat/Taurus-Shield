#!/usr/bin/env python3
"""Regression checks for automatic version resolution and bridge failures."""
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Taurus-Shield/android/app/src/main/python"))
sys.path.insert(0, str(ROOT / "scripts"))
import api_bridge
import blutter_versions


class UpstreamTests(unittest.TestCase):
    def test_auto_versions_and_override(self):
        with patch("urllib.request.urlopen", return_value=io.BytesIO(b'{"version":"3.99.7"}')):
            self.assertEqual(blutter_versions.resolve_versions("3.4.4,auto,3.4.4"), ["3.4.4", "3.99.7"])

    def test_invalid_version_is_rejected(self):
        for value in ("bad", "3.1.0;echo", "../../foo", "3.1.0-dev"):
            with self.assertRaises(ValueError):
                blutter_versions.resolve_versions(value)

    def test_network_failure_is_not_hidden(self):
        with patch("urllib.request.urlopen", side_effect=OSError("offline")):
            with self.assertRaises(OSError):
                blutter_versions.resolve_versions()

    def test_missing_hbc_cannot_report_stub_success(self):
        real_import = __import__

        def fail_hbc(name, *args, **kwargs):
            if name.startswith("hbctool"):
                raise ImportError("simulated missing engine")
            return real_import(name, *args, **kwargs)

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "input.hbc"
            source.write_bytes(b'12345678')
            assembly = root / "hasm"
            assembly.mkdir()
            for name in ("instruction.hasm", "metadata.json", "string.json"):
                (assembly / name).write_text("")
            with patch("builtins.__import__", side_effect=fail_hbc):
                result = api_bridge.do_disassemble(str(source), str(root / "disasm"))
                self.assertEqual(result["status"], "error")
                self.assertFalse((root / "disasm/output.hasm").exists())
                result = api_bridge.do_assemble(str(assembly), str(root / "asm"))
                self.assertEqual(result["status"], "error")
                self.assertFalse((root / "asm/index.android.bundle").exists())


if __name__ == "__main__":
    unittest.main()
