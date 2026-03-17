#!/usr/bin/env bash
set -euo pipefail

DART_VERSION="${1:?Usage: build_blutter.sh <dart_version> <blutter_dir>}"
BLUTTER_DIR="${2:-blutter}"

echo "=========================================================="
echo "  Building blutter for Dart ${DART_VERSION} (Android ARM64)"
echo "  Host arch: $(uname -m)"
echo "=========================================================="

# ── Locate Android NDK ────────────────────────────────────────────────────────
NDK_HOME="${ANDROID_NDK_HOME:-}"
if [ -z "$NDK_HOME" ] || [ ! -d "$NDK_HOME" ]; then
    NDK_HOME=$(find /usr/local/lib/android/sdk/ndk \
        -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
fi
if [ -z "$NDK_HOME" ] || [ ! -d "$NDK_HOME" ]; then
    echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME."
    exit 1
fi
echo "NDK: $NDK_HOME"

TOOLCHAIN="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
CC="$TOOLCHAIN/bin/aarch64-linux-android26-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android26-clang++"
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
STRIP_BIN="$TOOLCHAIN/bin/llvm-strip"
NDK_TOOLCHAIN_FILE="$NDK_HOME/build/cmake/android.toolchain.cmake"

ANDROID_COMMON_CMAKE=(
    -DCMAKE_TOOLCHAIN_FILE="$NDK_TOOLCHAIN_FILE"
    -DANDROID_ABI=arm64-v8a
    -DANDROID_PLATFORM=android-26
    -DANDROID_STL=c++_static
    -DCMAKE_BUILD_TYPE=Release
    -GNinja
)

ANDROID_LIBS="/tmp/android_arm64_libs"
mkdir -p "$ANDROID_LIBS"

# ── Build capstone 4.0.2 for Android ARM64 (static) ──────────────────────────
echo ""
echo "[prep 1/3] Building capstone 4.0.2 for Android ARM64..."
git clone --depth=1 --branch 4.0.2 \
    https://github.com/capstone-engine/capstone.git /tmp/capstone_src 2>/dev/null \
    || echo "capstone already cloned"

cmake -B /tmp/capstone_build /tmp/capstone_src \
    "${ANDROID_COMMON_CMAKE[@]}" \
    -DCMAKE_INSTALL_PREFIX="$ANDROID_LIBS" \
    -DCAPSTONE_BUILD_STATIC=ON \
    -DCAPSTONE_BUILD_STATIC_RUNTIME=ON \
    -DCAPSTONE_BUILD_SHARED=OFF \
    -DCAPSTONE_BUILD_TESTS=OFF \
    -DCAPSTONE_BUILD_CSTOOL=OFF \
    -DCAPSTONE_ARCHITECTURE_DEFAULT=ON

ninja -C /tmp/capstone_build install
echo "capstone built: $(ls $ANDROID_LIBS/lib/libcapstone.a 2>/dev/null)"

# ── Build fmt for Android ARM64 (static) ─────────────────────────────────────
echo ""
echo "[prep 2/3] Building fmt for Android ARM64..."
git clone --depth=1 --branch 10.2.1 \
    https://github.com/fmtlib/fmt.git /tmp/fmt_src 2>/dev/null \
    || echo "fmt already cloned"

cmake -B /tmp/fmt_build /tmp/fmt_src \
    "${ANDROID_COMMON_CMAKE[@]}" \
    -DCMAKE_INSTALL_PREFIX="$ANDROID_LIBS" \
    -DFMT_TEST=OFF \
    -DFMT_DOC=OFF \
    -DFMT_INSTALL=ON \
    -DBUILD_SHARED_LIBS=OFF

ninja -C /tmp/fmt_build install
echo "fmt built: $(ls $ANDROID_LIBS/lib/libfmt.a 2>/dev/null)"

# ── FindICU override: point to NDK sysroot ICU ───────────────────────────────
echo ""
echo "[prep 3/3] Setting up ICU for Android NDK..."
NDK_SYSROOT="$TOOLCHAIN/sysroot"
mkdir -p /tmp/android_cmake_modules

# Symlink host ICU headers into the NDK sysroot so they are found automatically
# during cross-compilation without any extra cmake flags.
# ICU headers are architecture-independent — safe to reuse from the host.
NDK_SYSROOT_INCLUDE="$TOOLCHAIN/sysroot/usr/include"
if [ ! -e "$NDK_SYSROOT_INCLUDE/unicode" ]; then
    ln -sf /usr/include/unicode "$NDK_SYSROOT_INCLUDE/unicode"
    echo "Linked ICU headers into NDK sysroot"
fi

cat > /tmp/android_cmake_modules/FindICU.cmake << ICUCMAKE
# Android NDK FindICU override
# Headers: via NDK sysroot symlink to host libicu-dev headers
# Runtime: Android system libicuuc.so / libicui18n.so (API 26+)
set(ICU_FOUND TRUE)
set(ICU_VERSION "70.1")
set(ICU_INCLUDE_DIRS "${NDK_SYSROOT_INCLUDE}")
set(ICU_LIBRARIES "-licuuc -licui18n")

if(NOT TARGET ICU::uc)
  add_library(ICU::uc INTERFACE IMPORTED)
  set_target_properties(ICU::uc PROPERTIES
    INTERFACE_LINK_LIBRARIES "-licuuc")
endif()
if(NOT TARGET ICU::i18n)
  add_library(ICU::i18n INTERFACE IMPORTED)
  set_target_properties(ICU::i18n PROPERTIES
    INTERFACE_LINK_LIBRARIES "-licui18n")
endif()
if(NOT TARGET ICU::data)
  add_library(ICU::data INTERFACE IMPORTED)
  set_target_properties(ICU::data PROPERTIES
    INTERFACE_LINK_LIBRARIES "-licudata")
endif()
ICUCMAKE

# ── cmake wrapper: injects NDK toolchain + our static libs into blutter.py ───
mkdir -p /tmp/cmake_wrapper
cat > /tmp/cmake_wrapper/cmake << CMAKEWRAP
#!/bin/bash
exec /usr/bin/cmake \\
    -DCMAKE_TOOLCHAIN_FILE="${NDK_TOOLCHAIN_FILE}" \\
    -DANDROID_ABI=arm64-v8a \\
    -DANDROID_PLATFORM=android-26 \\
    -DANDROID_STL=c++_static \\
    -DCMAKE_PREFIX_PATH="${ANDROID_LIBS}" \\
    -DCMAKE_MODULE_PATH="/tmp/android_cmake_modules" \\
    -DCMAKE_EXE_LINKER_FLAGS="-rdynamic" \\
    "\$@"
CMAKEWRAP
chmod +x /tmp/cmake_wrapper/cmake
export PATH="/tmp/cmake_wrapper:$PATH"

# ── blutter build ─────────────────────────────────────────────────────────────
cd "${BLUTTER_DIR}"

echo ""
echo "[1/3] Building dartvm package for ${DART_VERSION}_android_arm64 ..."
python3 dartvm_fetch_build.py "${DART_VERSION}" android arm64

echo ""
echo "[2/3] Building blutter binary (Android ARM64 via NDK)..."
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

python3 blutter.py --dart-version "${DART_VERSION}_android_arm64" \
    --rebuild "${DUMMY_SO}" /tmp/blutter_out 2>&1 || true
rm -f "${DUMMY_SO}"

echo ""
echo "[3/3] Checking output ..."
BIN_NAME="blutter_dartvm${DART_VERSION}_android_arm64"
BIN_PATH="bin/${BIN_NAME}"

if [ -f "${BIN_PATH}" ]; then
    echo "SUCCESS: ${BIN_PATH}"
    file "${BIN_PATH}"
    ls -lh "${BIN_PATH}"

    # Strip debug info only — preserves dynamic symbol table for dlsym
    "$STRIP_BIN" --strip-debug "${BIN_PATH}" 2>/dev/null \
        || strip --strip-debug "${BIN_PATH}" 2>/dev/null || true

    echo "Final size:"
    ls -lh "${BIN_PATH}"

    echo "Dynamic dependencies (should only be Android system libs):"
    "$TOOLCHAIN/bin/llvm-readelf" -d "${BIN_PATH}" 2>/dev/null \
        | grep NEEDED || readelf -d "${BIN_PATH}" | grep NEEDED || true

    echo "Checking main symbol:"
    "$TOOLCHAIN/bin/llvm-nm" -D "${BIN_PATH}" 2>/dev/null \
        | grep " main" || nm -D "${BIN_PATH}" 2>/dev/null | grep " main" \
        || echo "(main symbol check skipped)"
else
    echo "ERROR: Binary not found at ${BIN_PATH}"
    ls -la bin/ 2>/dev/null || echo "(bin/ empty)"
    find . -name "blutter_*" -type f 2>/dev/null | head -10
    exit 1
fi

echo ""
echo "=========================================================="
echo "  Build complete: ${BIN_PATH}"
echo "=========================================================="
