#!/usr/bin/env python3
"""Discover Dart stable for optional Android prebuilds; jobs detect their target."""
import argparse
import json
import os
import re
import urllib.request

VERSION_URL = "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION"


def resolve_versions(value="auto"):
    result = []
    for version in value.split(","):
        version = version.strip()
        if version in ("", "auto", "latest"):
            with urllib.request.urlopen(VERSION_URL, timeout=30) as response:
                version = json.load(response)["version"]
        if not re.fullmatch(r"\d+\.\d+\.\d+", version):
            raise ValueError("Expected stable Dart version, got %r" % version)
        if version not in result:
            result.append(version)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--versions", default="auto")
    versions = resolve_versions(parser.parse_args().versions)
    matrix = json.dumps({"dart_version": versions}, separators=(",", ":"))
    print(matrix)
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as out:
            out.write("matrix=" + matrix + "\n")
