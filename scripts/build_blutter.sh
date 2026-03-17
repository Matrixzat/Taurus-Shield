#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build_blutter.sh  <dart_version>  <blutter_repo_dir>
# Builds blutter_dartvm<version> for native ARM64 Linux (arm64-v8a compatible)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DART_VERSION="${1:?dart_version required}"
BLUTTER_DIR="${2:-blutter}"

echo "=========================================================="
echo "  Building blutter for Dart ${DART_VERSION}"
echo "  Blutter dir: ${BLUTTER_DIR}"
echo "  Host arch: $(uname -m)"
echo "=========================================================="

cd "${BLUTTER_DIR}"

# ── Step 1: Let blutter.py download the dartvm package ──────────────────────
# blutter.py can fetch pre-built dartvm packages from worawit/blutter releases.
# We give it a minimal fake libapp.so that contains the version string so it
# can detect which package to fetch.  If no pre-built package exists for this
# arch/version, it will attempt to build from Dart SDK source.

echo ""
echo "[1/4] Preparing version probe ..."

PROBE_DIR="$(mktemp -d)"
FAKE_SO="${PROBE_DIR}/libapp.so"

# Create a minimal valid ELF64 + embed the Dart version string blutter looks for.
# blutter reads the snapshot version from .rodata. We embed the marker bytes.
python3 - <<PYEOF
import struct, sys

# Minimal ELF64 LE ARM64 shared library header
e_ident   = b'\x7fELF\x02\x01\x01\x00' + b'\x00' * 8
e_type    = struct.pack('<H', 3)       # ET_DYN
e_machine = struct.pack('<H', 183)     # EM_AARCH64
e_version = struct.pack('<I', 1)
e_rest    = b'\x00' * (64 - 24)
elf_hdr   = e_ident + e_type + e_machine + e_version + e_rest

# Embed the Dart snapshot version string that blutter searches for
dart_ver  = b'${DART_VERSION}\x00'
payload   = dart_ver * 4 + b'\x00' * 256

with open('${FAKE_SO}', 'wb') as f:
    f.write(elf_hdr + payload)
print("Fake libapp.so created")
PYEOF

echo "[1/4] Probe SO ready at ${FAKE_SO}"

# ── Step 2: Run blutter.py to fetch/build the dartvm package ────────────────
echo ""
echo "[2/4] Fetching dartvm package for ${DART_VERSION} ..."

OUT_DIR="${PROBE_DIR}/out"
mkdir -p "${OUT_DIR}"

# Run blutter.py in package-download/build-only mode.
# blutter.py accepts the libapp path and output dir.
# The build step is automatic — it downloads or builds the dartvm package.
python3 blutter.py "${FAKE_SO}" "${OUT_DIR}" --no-run 2>&1 || {
    echo "Note: blutter.py --no-run failed, trying full mode with fake SO ..."
    # Some versions of blutter don't have --no-run; let it fail on analysis
    python3 blutter.py "${FAKE_SO}" "${OUT_DIR}" 2>&1 | grep -v "^Traceback\|^  File\|RuntimeError" || true
}

# ── Step 3: Build with cmake directly if binary not yet produced ─────────────
echo ""
echo "[3/4] Checking / running cmake build ..."

DARTLIB="dartvm${DART_VERSION}"
PKG_DIR="packages/${DARTLIB}"

if [ ! -d "${PKG_DIR}" ]; then
    echo "Package not found at ${PKG_DIR}, building from Dart SDK source ..."
    python3 scripts/build_dart_sdk.py "${DART_VERSION}" 2>&1 || {
        echo "build_dart_sdk.py not found, trying gen_snapshot approach ..."
        # Fallback: download Dart SDK for linux-arm64 and extract dartvm lib
        DART_SDK_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-arm64-release.zip"
        curl -Lo dart-sdk.zip "${DART_SDK_URL}" --silent --show-error
        unzip -q dart-sdk.zip
        # Copy needed files to packages dir
        mkdir -p "${PKG_DIR}/lib" "${PKG_DIR}/include"
        cp dart-sdk/lib/*.dart "${PKG_DIR}/" 2>/dev/null || true
        echo "Dart SDK extracted as fallback"
    }
fi

# Run cmake if package is available
if [ -d "${PKG_DIR}" ]; then
    BUILD_DIR="cmake_build_${DART_VERSION}"
    cmake -B "${BUILD_DIR}" -S blutter \
        -DDARTLIB="${DARTLIB}" \
        -DCMAKE_BUILD_TYPE=Release \
        -G Ninja 2>&1

    cmake --build "${BUILD_DIR}" \
        --config Release \
        --parallel "$(nproc)" 2>&1

    # Install to bin/
    cmake --install "${BUILD_DIR}" 2>&1 || {
        # Manual copy if install step fails
        find "${BUILD_DIR}" -name "blutter_${DARTLIB}" -exec cp {} bin/ \; 2>/dev/null || true
    }
fi

# ── Step 4: Verify ───────────────────────────────────────────────────────────
echo ""
echo "[4/4] Verifying output ..."

BIN="bin/blutter_${DARTLIB}"
if [ -f "${BIN}" ]; then
    echo "SUCCESS: ${BIN}"
    file "${BIN}"
    ls -lh "${BIN}"
    # Strip debug symbols to reduce size
    strip --strip-unneeded "${BIN}" 2>/dev/null || true
    ls -lh "${BIN}"
else
    echo "WARN: ${BIN} not found"
    echo "Contents of bin/:"
    ls -la bin/ 2>/dev/null || echo "(bin/ empty or missing)"
    find . -name "blutter_*" 2>/dev/null | head -10
    exit 1
fi

echo ""
echo "=========================================================="
echo "  Build complete: ${BIN}"
echo "=========================================================="
