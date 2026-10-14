#!/usr/bin/env python3
"""Resolve the current upstream dpt-shell release and fetch a verified executable.

No pinned release numbers. `resolve` must run on every protect job before cache
lookup. Cache keys use immutable release + asset IDs, not just a mutable tag.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import urllib.request
import zipfile

API = "https://api.github.com/repos/luoyesiqiu/dpt-shell/releases/latest"
REPO_URL = "https://github.com/luoyesiqiu/dpt-shell"


def request(url: str):
    if not url.startswith(("https://api.github.com/", "https://github.com/", "https://release-assets.githubusercontent.com/")):
        raise ValueError("Refusing unexpected DPT download host")
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "taurus-dpt-updater"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token and url.startswith("https://api.github.com/"):
        headers["Authorization"] = "Bearer " + token
    return urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=45)


def resolve(release: dict) -> dict:
    if release.get("draft") or release.get("prerelease"):
        raise ValueError("Latest release must be public and stable")
    tag = release.get("tag_name")
    asset = next((a for a in release.get("assets", []) if a.get("name") == "executable.zip"), None)
    if not tag or not asset or not asset.get("id"):
        raise ValueError("Upstream stable release has no executable.zip asset")
    url = asset.get("browser_download_url", "")
    if not url.startswith(REPO_URL + "/releases/download/"):
        raise ValueError("Unexpected executable.zip URL")
    digest = asset.get("digest") or ""
    if digest and (not digest.startswith("sha256:") or len(digest) != 71 or
                   any(c not in '0123456789abcdef' for c in digest[7:].lower())):
        raise ValueError("Unsupported GitHub asset digest: " + digest)
    return {
        "repository": REPO_URL, "release_id": release.get("id"),
        "tag": tag, "asset_id": asset["id"], "asset_url": url,
        "asset_sha256": digest.split(":", 1)[1] if digest else "",
        "asset_size": asset.get("size"),
    }


def find_binary(root: Path) -> Path:
    jars = sorted(p for p in root.rglob('dpt.jar') if p.is_file())
    if len(jars) != 1:
        raise ValueError(f"Expected exactly one dpt.jar, found {len(jars)}")
    jar = jars[0]
    if not (jar.parent / "shell-files").is_dir():
        raise ValueError("Latest executable.zip has no shell-files beside dpt.jar")
    with zipfile.ZipFile(jar) as archive:
        if archive.testzip():
            raise ValueError("Corrupt dpt.jar")
    return jar


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as f:
        for data in iter(lambda: f.read(1024*1024), b''):
            digest.update(data)
    return digest.hexdigest()


def fetch(meta: dict, dest: Path):
    # Check the exact upstream metadata resolved earlier; don't silently pick
    # another release if upstream changes between resolution and download.
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dpt-stage-", dir=str(dest.parent)) as tmp:
        stage = Path(tmp)
        bundle = stage / 'executable.zip'
        with request(meta['asset_url']) as res, bundle.open('wb') as out:
            shutil.copyfileobj(res, out)
        if meta.get('asset_size') and bundle.stat().st_size != meta['asset_size']:
            raise ValueError("Downloaded DPT asset size disagrees with latest release metadata")
        actual = sha256(bundle)
        if meta.get('asset_sha256') and actual != meta['asset_sha256'].lower():
            raise ValueError("Downloaded DPT asset SHA-256 disagrees with GitHub")
        with zipfile.ZipFile(bundle) as z:
            if z.testzip():
                raise ValueError("Upstream executable.zip has an invalid entry checksum")
            for entry in z.infolist():
                # Prevent traversal and symlink extraction from any archive.
                name = entry.filename.replace('\\', '/')
                pieces = Path(name).parts
                if name.startswith('/') or '..' in pieces or not pieces:
                    raise ValueError("Unsafe ZIP entry: " + name)
                if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError("Refusing ZIP symlinks")
            z.extractall(stage / 'release')
        jar = find_binary(stage / 'release')
        meta['verified_download_sha256'] = actual
        meta['jar_sha256'] = sha256(jar)
        (stage / 'release' / 'upstream-release.json').write_text(json.dumps(meta, indent=2) + '\n')
        if dest.exists():
            shutil.rmtree(dest)
        shutil.move(str(stage / 'release'), str(dest))


def verify(meta: dict, dest: Path):
    file = dest / 'upstream-release.json'
    saved = json.loads(file.read_text())
    for key in ['release_id', 'tag', 'asset_id', 'asset_sha256']:
        if str(saved.get(key, '')) != str(meta.get(key, '')):
            raise ValueError(f"DPT cache mismatch for {key}")
    jar = find_binary(dest)
    if sha256(jar) != saved.get('jar_sha256'):
        raise ValueError("Cached dpt.jar has changed unexpectedly")
    return jar


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument('action', choices=['resolve', 'fetch', 'verify'])
    cli.add_argument('--metadata', default='dpt-release.json')
    cli.add_argument('--dest', default='dpt-shell-release')
    cli.add_argument('--github-output', default='')
    args = cli.parse_args()
    metadata = Path(args.metadata)
    if args.action == 'resolve':
        with request(API) as response:
            release = json.load(response)
        meta = resolve(release)
        metadata.write_text(json.dumps(meta, indent=2) + '\n')
        print(f"Latest DPT Shell: {meta['tag']} (asset {meta['asset_id']})")
        if args.github_output:
            with open(args.github_output, 'a') as stream:
                for key in ('tag', 'release_id', 'asset_id'):
                    stream.write(f"{key}={meta[key]}\n")
                stream.write("digest=" + (meta['asset_sha256'] or 'no-digest') + '\n')
    else:
        meta = json.loads(metadata.read_text())
        if args.action == 'fetch':
            fetch(meta, Path(args.dest))
        jar = verify(meta, Path(args.dest))
        print(f"Validated DPT {meta['tag']}: {jar}, SHA-256={sha256(jar)}")


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f"DPT release verification failed: {exc}", file=sys.stderr)
        sys.exit(1)
