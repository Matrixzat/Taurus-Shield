#!/usr/bin/env python3
"""Check the upstream detector contract using synthetic ELF metadata, not an app.

Usage: python3 scripts/test_blutter_target.py /path/to/worawit-blutter
Requires gcc, requests and pyelftools. Does not compile or run Blutter's engine.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def shared_library(path, symbol, data):
    source = path.with_suffix(".c")
    source.write_text("const unsigned char " + symbol + "[] = {" +
                      ",".join(str(x) for x in data) + "};\n")
    subprocess.run(["gcc", "-shared", "-fPIC", str(source), "-o", str(path)], check=True)
    # The detector reads ELF metadata only. Set EM_AARCH64 for this fixture;
    # there are no functions and no instructions are executed from this ELF.
    raw = bytearray(path.read_bytes())
    raw[18:20] = (183).to_bytes(2, "little")
    path.write_bytes(raw)


def main():
    upstream = Path(sys.argv[1]).resolve()
    helper = Path(__file__).with_name("blutter_target.py")
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        snapshot = b"\0" * 20 + b"f" * 32 + b"product compressed-pointers\0" + b"\0" * 256
        shared_library(root / "libapp.so", "_kDartVmSnapshotData", snapshot)
        engine = b"\0" + b"a" * 40 + b"\0" + b"b" * 40 + b"\0" + b"3.99.7 (stable)\0"
        shared_library(root / "libflutter.so", "synthetic_engine_info", engine)
        out = root / "engine-version.json"
        subprocess.run([sys.executable, str(helper), "--root", str(upstream),
                        "--lib-dir", str(root), "--output", str(out)], check=True)
        data = json.loads(out.read_text())
        assert data["dart_version"] == "3.99.7"
        assert data["arch"] == "arm64"
        assert data["snapshot_hash"] == "f" * 32
        assert data["compressed_pointers"] is True
        assert len(data["commit"]) == 40
        print("Blutter detector contract/provenance: passed (synthetic ELF metadata)")


if __name__ == "__main__":
    main()
