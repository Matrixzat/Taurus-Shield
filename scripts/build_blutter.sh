#!/usr/bin/env bash
set -euo pipefail

DART_VERSION="${1:?Usage: build_blutter.sh <dart_version> <blutter_dir>}"
BLUTTER_DIR="${2:-blutter}"

echo "=========================================================="
echo "  Building blutter for Dart ${DART_VERSION} (android arm64)"
echo "  Host arch: $(uname -m)"
echo "=========================================================="

cd "${BLUTTER_DIR}"

echo ""
echo "[1/3] Building dartvm package for ${DART_VERSION}_android_arm64 ..."
python3 dartvm_fetch_build.py "${DART_VERSION}" android arm64

echo ""
echo "[2/3] Building blutter binary ..."

# Export main + all global symbols so dlopen/dlsym can find them
# (Android app loads via dlopen from code_cache, not execve)
export LDFLAGS="-rdynamic"
export CMAKE_EXE_LINKER_FLAGS_INIT="-rdynamic"

# Patch any CMakeLists.txt that defines the blutter target
for f in CMakeLists.txt blutter/CMakeLists.txt; do
    if [ -f "$f" ]; then
        if ! grep -q "rdynamic" "$f"; then
            printf '\n# Export symbols for dlopen/dlsym\nadd_link_options(-rdynamic)\n' >> "$f"
            echo "Patched $f with -rdynamic"
        fi
    fi
done

DUMMY_SO="$(mktemp /tmp/dummy_XXXXXX.so)"
python3 -c "
import struct
elf = bytearray(4096)
elf[0:4] = b'\x7fELF'
elf[4] = 2
elf[5] = 1
elf[6] = 1
elf[16:18] = struct.pack('<H', 3)
elf[18:20] = struct.pack('<H', 183)
elf[20:24] = struct.pack('<I', 1)
with open('${DUMMY_SO}', 'wb') as f:
    f.write(bytes(elf))
"

python3 blutter.py --dart-version "${DART_VERSION}_android_arm64" --rebuild "${DUMMY_SO}" /tmp/blutter_out 2>&1 || true
rm -f "${DUMMY_SO}"

echo ""
echo "[3/3] Checking output ..."

BIN_NAME="blutter_dartvm${DART_VERSION}_android_arm64"
BIN_PATH="bin/${BIN_NAME}"

if [ -f "${BIN_PATH}" ]; then
    echo "SUCCESS: ${BIN_PATH}"
    file "${BIN_PATH}"
    ls -lh "${BIN_PATH}"
    # Use --strip-debug only: preserves the dynamic symbol table needed for dlsym
    strip --strip-debug "${BIN_PATH}" 2>/dev/null || true
    echo "Stripped (debug only) size:"
    ls -lh "${BIN_PATH}"
    # Verify main is in dynamic symbol table
    echo "Checking dynamic symbols:"
    nm -D "${BIN_PATH}" 2>/dev/null | grep " main" || echo "(main symbol check skipped)"
else
    echo "ERROR: Binary not found at ${BIN_PATH}"
    echo "Contents of bin/:"
    ls -la bin/ 2>/dev/null || echo "(bin/ empty)"
    echo "All blutter_* files:"
    find . -name "blutter_*" -type f 2>/dev/null | head -10
    exit 1
fi

echo ""
echo "=========================================================="
echo "  Build complete: ${BIN_PATH}"
echo "=========================================================="
