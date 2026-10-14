#!/usr/bin/env python3
"""Use upstream's detector for cache identity and record the engine actually run."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("blutter"))
    parser.add_argument("--lib-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    sys.path.insert(0, str(root))
    from blutter import find_lib_files, get_dart_lib_info
    app, flutter = find_lib_files(str(args.lib_dir))
    info = get_dart_lib_info(app, flutter)
    sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    record = {"repository": "https://github.com/worawit/blutter", "commit": sha,
              "dart_version": info.version, "os": info.os_name, "arch": info.arch,
              "compressed_pointers": info.has_compressed_ptrs, "snapshot_hash": info.snapshot_hash}
    key = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write("cache_key=" + key + "\n")


if __name__ == "__main__":
    main()
