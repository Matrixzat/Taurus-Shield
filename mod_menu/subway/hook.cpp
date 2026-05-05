/**
 * Taurus Shield — matrix-hook
 * libmatrix-hook.so — Subway Surfers 3.62.1 Runtime Hook
 *
 * Loaded by the libmain.so stub via dlopen.
 * libil2cpp.so is already fully mapped by the time our constructor fires.
 */

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define TAG  "matrix-hook"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Find base address of a loaded .so ────────────────────────────────────────
static uintptr_t getLibBase(const char* name) {
    char line[512];
    FILE* fp = fopen("/proc/self/maps", "r");
    if (!fp) return 0;
    while (fgets(line, sizeof(line), fp)) {
        if (strstr(line, name) && strstr(line, "r-xp")) {
            uintptr_t base = (uintptr_t)strtoull(line, nullptr, 16);
            fclose(fp);
            return base;
        }
    }
    fclose(fp);
    return 0;
}

// ── Make memory writable, write ARM64 instructions, restore ──────────────────
static void writeAt(uintptr_t addr, const uint32_t* insns, size_t count) {
    size_t    len     = count * 4;
    long      pgsz    = getpagesize();
    uintptr_t page    = addr & ~(uintptr_t)(pgsz - 1);
    size_t    pageLen = len + (addr - page);
    mprotect((void*)page, pageLen, PROT_READ | PROT_WRITE | PROT_EXEC);
    memcpy((void*)addr, insns, len);
    mprotect((void*)page, pageLen, PROT_READ | PROT_EXEC);
    __builtin___clear_cache((char*)addr, (char*)(addr + len));
}

// ── ARM64 patch helpers ───────────────────────────────────────────────────────

static void patchBool(uintptr_t base, uintptr_t off, bool val) {
    uint32_t i[] = { val ? 0x52800020u : 0x52800000u, 0xD65F03C0u };
    writeAt(base + off, i, 2);
    LOGI("  bool  @0x%lX = %s", (unsigned long)off, val ? "true" : "false");
}

static void patchInt16(uintptr_t base, uintptr_t off, uint16_t val) {
    uint32_t i[] = { (uint32_t)(0x52800000u | ((uint32_t)val << 5)), 0xD65F03C0u };
    writeAt(base + off, i, 2);
    LOGI("  int   @0x%lX = %u", (unsigned long)off, (unsigned)val);
}

static void patchInt32(uintptr_t base, uintptr_t off, uint32_t val) {
    uint16_t lo = (uint16_t)(val & 0xFFFF);
    uint16_t hi = (uint16_t)(val >> 16);
    uint32_t i[] = {
        (uint32_t)(0x52800000u | ((uint32_t)lo << 5)),
        (uint32_t)(0x72A00000u | ((uint32_t)hi << 5)),
        0xD65F03C0u
    };
    writeAt(base + off, i, 3);
    LOGI("  int32 @0x%lX = %u", (unsigned long)off, val);
}

static void patchFloat(uintptr_t base, uintptr_t off, float val) {
    uint32_t bits;
    memcpy(&bits, &val, 4);
    uint16_t lo = (uint16_t)(bits & 0xFFFF);
    uint16_t hi = (uint16_t)(bits >> 16);
    uint32_t i[] = {
        (uint32_t)(0x52800000u | ((uint32_t)lo << 5)),
        (uint32_t)(0x72A00000u | ((uint32_t)hi << 5)),
        0x1E270000u,
        0xD65F03C0u
    };
    writeAt(base + off, i, 4);
    LOGI("  float @0x%lX = %.3f", (unsigned long)off, (double)val);
}

static void patchVoid(uintptr_t base, uintptr_t off) {
    uint32_t i[] = { 0xD65F03C0u };
    writeAt(base + off, i, 1);
    LOGI("  void  @0x%lX silenced", (unsigned long)off);
}

// ── All Subway Surfers 3.62.1 patches ────────────────────────────────────────
static void applyPatches(uintptr_t base) {
    LOGI("=== matrix-hook — Subway Surfers 3.62.1 ===");
    LOGI("libil2cpp base: 0x%lX", (unsigned long)base);

    // Ad Removal
    patchVoid (base, 0x1043C64);
    patchVoid (base, 0x1150264);
    patchBool (base, 0x3247894, false);
    // IAP / Unlock
    patchBool (base, 0x32477FC, true);
    // Currency — 999999
    patchInt32(base, 0x158EF98, 999999u);
    patchInt32(base, 0x32B4820, 999999u);
    // Jump
    patchInt16(base, 0xF9EFD4, 100);
    patchFloat(base, 0xF9EFF4, 3.0f);
    // Speed
    patchFloat(base, 0xF9F454, 5.0f);
    patchFloat(base, 0xF9F624, 5.0f);
    patchBool (base, 0xF9F3C8, true);
    patchFloat(base, 0xF9F48C, 0.5f);
    patchFloat(base, 0xF9F674, 0.5f);
    // Score Booster
    patchBool (base, 0x13918C4, true);
    patchBool (base, 0x13919DC, true);
    patchInt16(base, 0x1392030, 5);
    patchBool (base, 0x1021B20, true);
    // Powerups always active
    patchBool (base, 0xFC2538, true);
    patchBool (base, 0xFC2548, true);
    patchBool (base, 0xFC2578, true);
    // Revive
    patchBool (base, 0x13D570C, true);

    LOGI("=== 21 patches applied ===");
}

// ── Constructor — fires when matrix-hook.so is dlopen'd ──────────────────────
__attribute__((constructor))
static void onLoad() {
    LOGI("matrix-hook loaded");
    uintptr_t base = 0;
    for (int i = 0; i < 40 && !base; i++) {
        base = getLibBase("libil2cpp.so");
        if (!base) usleep(50000);
    }
    if (!base) { LOGE("libil2cpp.so not found — patches skipped"); return; }
    applyPatches(base);
}
