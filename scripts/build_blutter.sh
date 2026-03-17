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
CC="$TOOLCHAIN/bin/aarch64-linux-android31-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android31-clang++"
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
STRIP_BIN="$TOOLCHAIN/bin/llvm-strip"
NDK_TOOLCHAIN_FILE="$NDK_HOME/build/cmake/android.toolchain.cmake"

ANDROID_COMMON_CMAKE=(
    -DCMAKE_TOOLCHAIN_FILE="$NDK_TOOLCHAIN_FILE"
    -DANDROID_ABI=arm64-v8a
    -DANDROID_PLATFORM=android-31
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

# ── ICU shim + compiler launcher ─────────────────────────────────────────────
echo ""
echo "[prep 3/3] Setting up ICU shim for Android NDK..."
mkdir -p /tmp/android_cmake_modules
mkdir -p /tmp/icu_shim/unicode

# The NDK ships ICU C API headers but NOT C++ headers (like uniset.h).
# The host libicu-dev headers break when compiled with __ANDROID__ defined
# because ICU's platform.h activates Android-specific code paths.
# Solution: provide a minimal icu::UnicodeSet shim that wraps the NDK C API (USet*).
cat > /tmp/icu_shim/unicode/uniset.h << 'UNISET_SHIM'
// Minimal icu::UnicodeSet shim for Android NDK cross-compilation.
// NDK r27 has unicode/uchar.h and unicode/utypes.h (for UChar32/UProperty/UErrorCode)
// but does NOT have unicode/uset.h. We include the NDK type headers and
// forward-declare USet + the uset_* C API ourselves. The functions resolve
// from Android's system libicuuc.so at link time.
#pragma once
#ifdef __cplusplus
// unicode/uchar.h and unicode/utypes.h ARE in NDK r27 sysroot and define
// UChar32, UProperty, UErrorCode as their proper enum/typedef types.
// We include them here so our declarations are consistent even if this
// shim is included before those headers.
#include <unicode/uchar.h>
#include <unicode/utypes.h>

#ifndef USET_CASE_INSENSITIVE
#define USET_CASE_INSENSITIVE 2
#endif

// Opaque USet type — NDK does NOT expose uset.h, so we forward-declare.
struct USet;

// ICU C API — resolved from Android system libicuuc.so at link time
extern "C" {
    USet* uset_openEmpty();
    USet* uset_open(UChar32 start, UChar32 end);
    void  uset_close(USet* set);
    void  uset_add(USet* set, UChar32 c);
    void  uset_addRange(USet* set, UChar32 start, UChar32 end);
    void  uset_addAll(USet* set, const USet* additionalSet);
    void  uset_closeOver(USet* set, int32_t attributes);
    void  uset_removeAllStrings(USet* set);
    void  uset_complement(USet* set);
    void  uset_applyIntPropertyValue(USet* set, UProperty prop, int32_t value, UErrorCode* ec);
    int32_t uset_size(const USet* set);
    int32_t uset_isEmpty(const USet* set);
    int32_t uset_contains(const USet* set, UChar32 c);
    int32_t uset_getRangeCount(const USet* set);
    UChar32 uset_getRangeStart(const USet* set, int32_t rangeIndex);
    UChar32 uset_getRangeEnd(const USet* set, int32_t rangeIndex);
}

namespace icu {

class UnicodeSet {
    USet* _set;
public:
    UnicodeSet() : _set(uset_openEmpty()) {}
    UnicodeSet(UChar32 start, UChar32 end) : _set(uset_open(start, end)) {}
    ~UnicodeSet() { if (_set) uset_close(_set); }

    UnicodeSet& add(UChar32 c) { uset_add(_set, c); return *this; }
    UnicodeSet& add(UChar32 start, UChar32 end) {
        uset_addRange(_set, start, end); return *this;
    }
    UnicodeSet& addAll(const UnicodeSet& other) {
        uset_addAll(_set, other._set); return *this;
    }
    UnicodeSet& closeOver(int32_t attribute) {
        uset_closeOver(_set, attribute); return *this;
    }
    UnicodeSet& removeAllStrings() {
        uset_removeAllStrings(_set); return *this;
    }
    UnicodeSet& complement() {
        uset_complement(_set); return *this;
    }
    UnicodeSet& applyIntPropertyValue(UProperty prop, int32_t value, UErrorCode& ec) {
        uset_applyIntPropertyValue(_set, prop, value, &ec); return *this;
    }
    int32_t size() const { return uset_size(_set); }
    bool isEmpty() const { return uset_isEmpty(_set) != 0; }
    bool contains(UChar32 c) const { return uset_contains(_set, c) != 0; }
    int32_t getRangeCount() const { return uset_getRangeCount(_set); }
    UChar32 getRangeStart(int32_t index) const {
        return uset_getRangeStart(_set, index);
    }
    UChar32 getRangeEnd(int32_t index) const {
        return uset_getRangeEnd(_set, index);
    }
};

} // namespace icu
#endif // __cplusplus
UNISET_SHIM

echo "ICU shim created at /tmp/icu_shim/unicode/uniset.h"

# Compiler launcher: prepends -I/tmp/icu_shim to every CXX invocation.
# This is the only reliable way to inject include paths before cmake's own flags,
# because dartvm_fetch_build.py's CMakeLists.txt overrides CMAKE_CXX_FLAGS.
# The launcher is called as: <launcher> <compiler> [args...]
cat > /tmp/cxx_launcher.sh << 'LAUNCHER'
#!/bin/bash
compiler="$1"
shift
exec "$compiler" -I/tmp/icu_shim "$@"
LAUNCHER
chmod +x /tmp/cxx_launcher.sh

cat > /tmp/android_cmake_modules/FindICU.cmake << 'ICUCMAKE'
# Android NDK FindICU override.
# ICU_INCLUDE_DIRS="/tmp/icu_shim" causes blutter's cmake to add
# -I/tmp/icu_shim to every CXX compilation, so that
# #include "unicode/uniset.h" resolves to our shim.
set(ICU_FOUND TRUE)
set(ICU_VERSION "70.1")
set(ICU_INCLUDE_DIRS "/tmp/icu_shim")
set(ICU_LIBRARIES "-licuuc -licui18n")

if(NOT TARGET ICU::uc)
  add_library(ICU::uc INTERFACE IMPORTED)
  set_target_properties(ICU::uc PROPERTIES
    INTERFACE_LINK_LIBRARIES "-licuuc"
    INTERFACE_INCLUDE_DIRECTORIES "/tmp/icu_shim")
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

# ── cmake wrapper: injects NDK toolchain + static libs ───────────────────────
mkdir -p /tmp/cmake_wrapper
cat > /tmp/cmake_wrapper/cmake << CMAKEWRAP
#!/bin/bash
# --install: pass through unchanged so dartvm installs to its configured
# CMAKE_INSTALL_PREFIX (blutter/packages/), where blutter.py expects it.
# --build/--open/etc: pass through unchanged (no NDK configure flags).
for arg in "\$@"; do
    case "\$arg" in
        --install|--build|--open|--workflow|--find-package)
            exec /usr/bin/cmake "\$@"
            ;;
    esac
done
exec /usr/bin/cmake \\
    -DCMAKE_TOOLCHAIN_FILE="${NDK_TOOLCHAIN_FILE}" \\
    -DANDROID_ABI=arm64-v8a \\
    -DANDROID_PLATFORM=android-31 \\
    -DANDROID_STL=c++_static \\
    -DCMAKE_PREFIX_PATH="${ANDROID_LIBS};${BLUTTER_DIR}/packages" \\
    -DCMAKE_FIND_ROOT_PATH="${BLUTTER_DIR}/packages;${ANDROID_LIBS}" \\
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \\
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
