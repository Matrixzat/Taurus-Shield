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
echo "capstone headers: $(find $ANDROID_LIBS/include -name capstone.h 2>/dev/null | head -3)"

# Write capstone.pc (capstone 4.x cmake does not generate one)
mkdir -p "$ANDROID_LIBS/lib/pkgconfig"
cat > "$ANDROID_LIBS/lib/pkgconfig/capstone.pc" << 'CAPSTONE_PC'
prefix=/tmp/android_arm64_libs
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: capstone
Description: Capstone disassembly engine
Version: 4.0.2
Libs: -L${libdir} -lcapstone
Cflags: -I${includedir}/capstone
CAPSTONE_PC
echo "capstone.pc written to $ANDROID_LIBS/lib/pkgconfig/"

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

# ── Create stub .so files for Android system libs (ICU, pthread) ─────────────
# libicuuc/libicui18n/libpthread are Android system libs — they exist at
# runtime on device but the NDK cross-compile sysroot has no stub .so for them.
# We create minimal valid ELF stubs so the linker (-licuuc etc.) is satisfied.
# --allow-shlib-undefined (added to CMAKE_EXE_LINKER_FLAGS below) then permits
# the ICU symbols themselves to be resolved at runtime from Android's system.
SYSROOT_LIBDIR="${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android"
echo "NDK ICU stubs: $(ls ${SYSROOT_LIBDIR}/libicu*.* 2>/dev/null || echo 'none')"
echo "NDK pthread:   $(ls ${SYSROOT_LIBDIR}/libpthread.* 2>/dev/null || echo 'none')"
# ICU: link STATICALLY with no-op stubs so the binary has zero DT_NEEDED
# for libicuuc/libicui18n/libicudata.  The Android APEX namespace isolation
# (clns-4 vs apex/com.android.i18n) prevents dlopen from resolving DT_NEEDED
# ICU at runtime.  Static stubs return 0 for every ICU call; blutter's
# analysis path does not execute Dart code so the regexp/unicode engine is
# never actually invoked.
cat > /tmp/icu_stubs.c << 'ICU_STUBS_EOF'
#include <stdint.h>
#include <string.h>

/* Non-null sentinel object returned by all ICU factory/getInstance functions.
   The Dart VM asserts the return value is non-null (ASSERT(nfc_normalizer_ != nullptr))
   and uses __builtin_trap() for assertion failures — that's the SIGTRAP we saw.
   Any subsequent calls that USE these objects hit the no-op S() stubs below,
   which is fine: blutter does not need real unicode processing, just no crashes. */
static char g_icu_obj[128];

/* S = no-op stub, returns 0/NULL (safe for void/int/bool returns and close() funcs) */
#define S(n) __attribute__((visibility("hidden"))) void* n() { return 0; }
/* P = non-null stub, returns sentinel (required for factory/getInstance functions) */
#define P(n) __attribute__((visibility("hidden"))) void* n() { return g_icu_obj; }
/* STR = string stub, returns a valid constant string */
#define STR(n,v) __attribute__((visibility("hidden"))) const char* n() { return (v); }

/* ── uset.h ──────────────────────────────────────────────────────────────── */
/* open/create → must be non-null (callers do ASSERT(set != nullptr)) */
P(uset_openEmpty) P(uset_open) P(uset_openPattern) P(uset_openPatternOptions)
P(uset_clone) P(uset_cloneAsThawed)
/* everything else → no-op */
S(uset_close) S(uset_isFrozen) S(uset_freeze)
S(uset_set) S(uset_applyPattern) S(uset_applyIntPropertyValue) S(uset_applyPropertyAlias)
S(uset_resemblesPattern) S(uset_toPattern)
S(uset_add) S(uset_addAll) S(uset_addRange) S(uset_addString) S(uset_addAllCodePoints)
S(uset_remove) S(uset_removeRange) S(uset_removeString) S(uset_removeAll)
S(uset_retain) S(uset_retainAll) S(uset_retainString) S(uset_compact)
S(uset_complement) S(uset_complementAll) S(uset_complementRange) S(uset_complementString)
S(uset_clear) S(uset_closeOver) S(uset_removeAllStrings)
S(uset_isEmpty) S(uset_contains) S(uset_containsRange) S(uset_containsString)
S(uset_indexOf) S(uset_charAt) S(uset_size) S(uset_getItemCount) S(uset_getItem)
S(uset_containsAll) S(uset_containsAllCodePoints) S(uset_containsNone) S(uset_containsSome)
S(uset_span) S(uset_spanBack) S(uset_spanUTF8) S(uset_spanBackUTF8)
S(uset_equals) S(uset_serialize) S(uset_getSerializedSet) S(uset_setSerializedToOne)
S(uset_serializedContains) S(uset_getSerializedRangeCount) S(uset_getSerializedRange)
S(uset_getString) S(uset_getStringCount)
S(uset_getRangeCount) S(uset_getRangeStart) S(uset_getRangeEnd)

/* ── unorm2.h ────────────────────────────────────────────────────────────── */
/* getNFC/NFD/NFKC/etc. → must be non-null (stored in global and ASSERT'd) */
P(unorm2_getNFCInstance) P(unorm2_getNFDInstance)
P(unorm2_getNFKCInstance) P(unorm2_getNFKDInstance) P(unorm2_getNFKCCasefoldInstance)
P(unorm2_getInstance) P(unorm2_openFiltered)
S(unorm2_close)
S(unorm2_normalize) S(unorm2_normalizeSecondAndAppend) S(unorm2_append)
S(unorm2_isNormalized) S(unorm2_quickCheck) S(unorm2_spanQuickCheckYes)
S(unorm2_hasBoundaryBefore) S(unorm2_hasBoundaryAfter) S(unorm2_isInert)
S(unorm2_getDecomposition) S(unorm2_getRawDecomposition)
S(unorm2_composePair) S(unorm2_getCombiningClass)

/* ── u_* general + uchar.h ───────────────────────────────────────────────── */
STR(u_errorName,      "")
STR(u_getDataDirectory, "")
P(u_getBinaryPropertySet)
S(u_setDataDirectory) S(u_init) S(u_cleanup)
S(u_versionToString) S(u_getVersion)
S(u_charType) S(u_getCombiningClass) S(u_charDigitValue) S(ublock_getCode)
S(u_charName) S(u_charFromName) S(u_enumCharNames) S(u_charNameAlias) S(u_enumCharTypes)
S(u_getIntPropertyValue) S(u_getIntPropertyMinValue) S(u_getIntPropertyMaxValue)
S(u_getNumericValue) S(u_isUAlphabetic) S(u_isULowercase) S(u_isUUppercase) S(u_isUWhiteSpace)
S(u_hasBinaryProperty)
S(u_isalpha) S(u_isalnum) S(u_isdigit) S(u_isxdigit) S(u_ispunct) S(u_isgraph)
S(u_isblank) S(u_isdefined) S(u_isspace) S(u_isJavaSpaceChar) S(u_isWhitespace)
S(u_iscntrl) S(u_isISOControl) S(u_isprint) S(u_isbase)
S(u_charDirection) S(u_isMirrored) S(u_charMirror) S(u_getBidiPairedBracket)
S(u_toupper) S(u_tolower) S(u_totitle) S(u_foldCase)
S(u_digit) S(u_forDigit) S(u_charAge) S(u_getUnicodeVersion) S(u_getFC_NFKC_Closure)
/* uprops.h */
S(u_getPropertyEnum) S(u_getPropertyName)
S(u_getPropertyValueEnum) S(u_getPropertyValueName) S(u_getPropertyValueEnumNoSpaces)

/* ── ustring.h ───────────────────────────────────────────────────────────── */
S(u_strlen) S(u_strcat) S(u_strncat) S(u_strcmp) S(u_strcasecmp)
S(u_strncmp) S(u_strncasecmp) S(u_strncmpCodePointOrder)
S(u_strcpy) S(u_strncpy) S(u_uastrcpy) S(u_uastrncpy) S(u_austrcpy) S(u_austrncpy)
S(u_strToUTF8) S(u_strFromUTF8) S(u_strToUTF8WithSub) S(u_strFromUTF8WithSub) S(u_strFromUTF8Lenient)
S(u_strToUTF32) S(u_strFromUTF32) S(u_strToUTF32WithSub) S(u_strFromUTF32WithSub)
S(u_countChar32) S(u_strHasMoreChar32Than)
S(u_memcpy) S(u_memmove) S(u_memset) S(u_memcmp) S(u_memcmpCodePointOrder)
S(u_memchr) S(u_memchr32) S(u_memrchr) S(u_memrchr32) S(u_unescape) S(u_unescapeAt)
S(u_strToLower) S(u_strToUpper) S(u_strToTitle) S(u_strFoldCase)
S(u_strCompare) S(u_strCompareIter) S(u_strCaseCompare)
S(u_strchr) S(u_strchr32) S(u_strrstr) S(u_strstr) S(u_strFindFirst) S(u_strFindLast)
S(u_strcspn) S(u_strspn) S(u_strpbrk) S(u_strrchr) S(u_strrchr32) S(u_strtok_r)

/* ── uloc.h ──────────────────────────────────────────────────────────────── */
STR(uloc_getDefault, "en_US")
S(uloc_setDefault) S(uloc_getLanguage) S(uloc_getScript)
S(uloc_getCountry) S(uloc_getVariant) S(uloc_getName) S(uloc_canonicalize)
S(uloc_getISO3Language) S(uloc_getISO3Country) S(uloc_getLCID)
S(uloc_getDisplayName) S(uloc_getDisplayLanguage) S(uloc_getDisplayScript)
S(uloc_getDisplayCountry) S(uloc_getDisplayVariant) S(uloc_getDisplayKeyword)
S(uloc_getDisplayKeywordValue) S(uloc_getAvailable) S(uloc_countAvailable)

/* ── udata.h ─────────────────────────────────────────────────────────────── */
P(udata_open) P(udata_openChoice)
S(udata_close) S(udata_getMemory) S(udata_getInfo)
S(udata_setCommonData) S(udata_setAppData) S(udata_setFileAccess)

/* ── misc ────────────────────────────────────────────────────────────────── */
P(usprep_open) P(usprep_openByType)
S(usprep_close) S(usprep_prepare)
P(uidna_openUTS46)
S(uidna_close) S(uidna_nameToASCII) S(uidna_nameToUnicode)
S(uidna_labelToASCII) S(uidna_labelToUnicode)
S(uidna_nameToASCII_UTF8) S(uidna_nameToUnicodeUTF8)
S(uidna_labelToASCII_UTF8) S(uidna_labelToUnicodeUTF8)
P(ucasemap_open)
S(ucasemap_close) S(ucasemap_getLocale) S(ucasemap_getOptions)
S(ucasemap_setLocale) S(ucasemap_setOptions) S(ucasemap_getNFKCCasefold)
S(ucasemap_setNFKCCasefold) S(ucasemap_utf8ToLower) S(ucasemap_utf8ToUpper)
S(ucasemap_utf8ToTitle) S(ucasemap_utf8FoldCase)
ICU_STUBS_EOF

"${CC}" --target=aarch64-linux-android31 --sysroot="${TOOLCHAIN}/sysroot" \
    -c /tmp/icu_stubs.c -o /tmp/icu_stubs.o
for ICU_LIB in libicuuc libicui18n libicudata; do
    "${AR}" rcs "${ANDROID_LIBS}/lib/${ICU_LIB}.a" /tmp/icu_stubs.o
    echo "static ICU stub: ${ANDROID_LIBS}/lib/${ICU_LIB}.a"
done
# pthread: Android's libc.so contains all pthread symbols — there is NO
# libpthread.so on Android. A .so stub would add DT_NEEDED libpthread.so
# which the Android linker cannot find at runtime (exit code 126).
# Use an empty static archive instead: satisfies -lpthread at link time,
# adds no DT_NEEDED entry, and pthread symbols resolve from libc at runtime.
printf 'void __pthread_stub(void) {}\n' > /tmp/pthread_stub.c
"${CC}" --target=aarch64-linux-android31 \
    --sysroot="${TOOLCHAIN}/sysroot" \
    -c /tmp/pthread_stub.c -o /tmp/pthread_stub.o
"${AR}" rcs "${ANDROID_LIBS}/lib/libpthread.a" /tmp/pthread_stub.o
echo "pthread static stub: ${ANDROID_LIBS}/lib/libpthread.a"

# ── custom toolchain: chains NDK + adds capstone include_directories ─────────
# Capstone 4.x installs to include/capstone/. include_directories() in the
# toolchain file guarantees the path reaches ALL targets even when cmake's
# cross-compile pkg-config path filtering would strip it from Cflags.
printf 'include("%s")\ninclude_directories("%s/include/capstone")\n' \
    "${NDK_TOOLCHAIN_FILE}" "${ANDROID_LIBS}" \
    > /tmp/android_blutter_toolchain.cmake
echo "custom toolchain: $(cat /tmp/android_blutter_toolchain.cmake)"

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
    -DCMAKE_TOOLCHAIN_FILE="/tmp/android_blutter_toolchain.cmake" \\
    -DANDROID_ABI=arm64-v8a \\
    -DANDROID_PLATFORM=android-31 \\
    -DANDROID_STL=c++_static \\
    -DCMAKE_PREFIX_PATH="${ANDROID_LIBS};${BLUTTER_DIR}/packages" \\
    -DCMAKE_FIND_ROOT_PATH="${BLUTTER_DIR}/packages;${ANDROID_LIBS}" \\
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \\
    -DCMAKE_MODULE_PATH="/tmp/android_cmake_modules" \\
    -DCMAKE_EXE_LINKER_FLAGS="-rdynamic -Wl,--unresolved-symbols=ignore-all -L${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android -L${TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/31 -llog -ldl -lm -lz" \\
    -DPKG_CONFIG_USE_CMAKE_PREFIX_PATH=TRUE \\
    "\$@"
CMAKEWRAP
chmod +x /tmp/cmake_wrapper/cmake
export PATH="/tmp/cmake_wrapper:$PATH"

# ── blutter build ─────────────────────────────────────────────────────────────
cd "${BLUTTER_DIR}"

echo ""
echo "[1/3] Building dartvm package for ${DART_VERSION}_android_arm64 ..."
python3 dartvm_fetch_build.py "${DART_VERSION}" android arm64

# ── auto-detect ALL undefined ICU symbols from downloaded dartvm archives ─────
# Scan every .a in packages/ so no ICU symbol is ever missed regardless of
# which Dart VM version or ICU API subset it uses.  Stubs are compiled into
# the static libicuuc/libicui18n/libicudata archives BEFORE cmake runs, so
# the linker always resolves them statically (zero DT_NEEDED for ICU).
echo "Scanning dartvm archives for undefined ICU symbols..."
# Debug: show what's in packages/ and dartsdk/ so we know where .a lives
echo "  packages/ contents (lib/):"
ls -lh "${BLUTTER_DIR}/packages/lib/" 2>/dev/null | head -10 || echo "    (packages/lib/ not found)"
echo "  dartsdk/ contents:"
ls "${BLUTTER_DIR}/dartsdk/" 2>/dev/null | head -5 || echo "    (dartsdk/ not found)"

# Search packages/, dartsdk/ and any build output dirs for dartvm .a archives
DARTVM_ARCHIVES_LIST=()
while IFS= read -r _f; do
    [ -f "$_f" ] && DARTVM_ARCHIVES_LIST+=("$_f")
done < <(find "${BLUTTER_DIR}" \( -name "*.a" -o -name "libdart*.a" \) \
    -not -path "*/capstone/*" -not -path "*/android_arm64_libs/*" 2>/dev/null)

echo "  found ${#DARTVM_ARCHIVES_LIST[@]} dartvm archive(s)"
[ ${#DARTVM_ARCHIVES_LIST[@]} -gt 0 ] && echo "    ${DARTVM_ARCHIVES_LIST[*]}"

if [ ${#DARTVM_ARCHIVES_LIST[@]} -gt 0 ]; then
    # grep exits 1 on no match — use || true so set -e doesn't kill us
    ICU_EXTRA=$(
        "${TOOLCHAIN}/bin/llvm-nm" --undefined-only "${DARTVM_ARCHIVES_LIST[@]}" 2>/dev/null \
        | awk '{print $NF}' \
        | grep -E '^(uset_|unorm2?_|ucol_|uidna_|usprep_|ucasemap_|uloc_|udata_|ublock_|urex|uregex|utext_|uscript_|ubidi_|u_[a-zA-Z])' \
        | sort -u || true
    )
    if [ -n "${ICU_EXTRA}" ]; then
        echo "Auto-adding ICU stubs for:"
        echo "${ICU_EXTRA}"
        printf '#define S(n) __attribute__((visibility("hidden"))) void* n() { return 0; }\n' \
            > /tmp/icu_extra.c
        for SYM in ${ICU_EXTRA}; do
            printf 'S(%s)\n' "${SYM}" >> /tmp/icu_extra.c
        done
        "${CC}" --target=aarch64-linux-android31 --sysroot="${TOOLCHAIN}/sysroot" \
            -c /tmp/icu_extra.c -o /tmp/icu_extra.o
        for ICU_LIB in libicuuc libicui18n libicudata; do
            "${AR}" rcs "${ANDROID_LIBS}/lib/${ICU_LIB}.a" /tmp/icu_stubs.o /tmp/icu_extra.o
            echo "  updated: ${ANDROID_LIBS}/lib/${ICU_LIB}.a (base + auto-detected)"
        done
    else
        echo "No extra ICU symbols found — base stubs sufficient."
    fi
else
    echo "Warning: no dartvm .a archives found in packages/, using base ICU stubs only"
fi

echo ""
echo "[2/3] Building blutter binary (Android ARM64 via NDK)..."
# Expose our capstone.pc so cmake's FindPkgConfig can find it even in
# cross-compilation mode (PKG_CONFIG_PATH is appended to PKG_CONFIG_LIBDIR).
export PKG_CONFIG_PATH="${ANDROID_LIBS}/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# Belt-and-suspenders: cmake reads CXXFLAGS to init CMAKE_CXX_FLAGS, ensuring
# the capstone subdir is always in the include path even if cmake's cross-compile
# pkg-config path filtering strips it.
export CXXFLAGS="-I${ANDROID_LIBS}/include/capstone${CXXFLAGS:+ $CXXFLAGS}"
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

# ── PASS 2: scan built binary for any remaining undefined ICU symbols ──────────
# With --unresolved-symbols=ignore-all, missing stubs become UNDEF entries in
# .dynsym, causing "cannot locate symbol" at dlopen time.  Detect them all
# here, generate stubs, and re-link so the final binary has zero UNDEF ICU.
# After "cd ${BLUTTER_DIR}" above, cwd IS blutter/ — use relative paths
BINARY_P2="bin/blutter_dartvm${DART_VERSION}_android_arm64"
BUILD_DIR_P2="build/blutter_dartvm${DART_VERSION}_android_arm64"
if [ -f "${BINARY_P2}" ] && [ -d "${BUILD_DIR_P2}" ]; then
    echo "PASS 2: scanning ${BINARY_P2} for undefined ICU symbols..."
    # llvm-readelf prints UNDEF entries; sed strips @VERSION suffixes
    ICU_UNDEF_P2=$(
        "${TOOLCHAIN}/bin/llvm-readelf" --dyn-syms "${BINARY_P2}" 2>/dev/null \
        | awk '/UNDEF/ && !/LOCAL/ {print $NF}' \
        | sed 's/@.*//' \
        | grep -E '^(uset_|unorm2?_|u_[a-zA-Z]|ucasemap_|uloc_|udata_|ublock_|ubidi_|uscript_|utext_|uidna_|ucol_|usprep_)' \
        | sort -u || true
    )
    if [ -n "${ICU_UNDEF_P2}" ]; then
        echo "  PASS 2 found undefined ICU symbols — adding stubs and re-linking:"
        echo "${ICU_UNDEF_P2}"
        printf '#define S(n) __attribute__((visibility("hidden"))) void* n() { return 0; }\n' \
            > /tmp/icu_pass2.c
        for SYM in ${ICU_UNDEF_P2}; do
            printf 'S(%s)\n' "${SYM}" >> /tmp/icu_pass2.c
        done
        "${CC}" --target=aarch64-linux-android31 --sysroot="${TOOLCHAIN}/sysroot" \
            -c /tmp/icu_pass2.c -o /tmp/icu_pass2.o
        for ICU_LIB in libicuuc libicui18n libicudata; do
            "${AR}" rcs "${ANDROID_LIBS}/lib/${ICU_LIB}.a" \
                /tmp/icu_stubs.o /tmp/icu_pass2.o
        done
        # Touch the archive so cmake detects it is newer than the binary
        touch "${ANDROID_LIBS}/lib/libicuuc.a"
        # Re-link (cmake detects newer .a → re-runs link step)
        /usr/bin/cmake --build "${BUILD_DIR_P2}" -- -j$(nproc) 2>&1
        /usr/bin/cmake --install "${BUILD_DIR_P2}" 2>&1
        echo "  PASS 2 re-link complete."
    else
        echo "  PASS 2: no undefined ICU symbols — binary is clean."
    fi
else
    echo "  PASS 2: binary or build dir not found, skipping."
fi

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
