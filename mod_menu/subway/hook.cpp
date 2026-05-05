/**
 * Taurus Shield — matrix-hook
 * libmatrix-hook.so — Subway Surfers 3.62.1 Runtime Hook
 *
 * Uses dl_iterate_phdr to find libil2cpp.so base address reliably.
 * Works whether libs are extracted to disk or loaded directly from APK.
 */

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define TAG  "matrix-hook"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Find base address using dl_iterate_phdr (handles extracted + APK-loaded) ─
struct FindLib { const char* target; uintptr_t base; };

static int findLibCb(struct dl_phdr_info* info, size_t /*size*/, void* data) {
    FindLib* fl = (FindLib*)data;
    if (info->dlpi_name && strstr(info->dlpi_name, fl->target)) {
        fl->base = (uintptr_t)info->dlpi_addr;
        return 1;
    }
    return 0;
}

static uintptr_t getLibBase(const char* name) {
    FindLib fl = { name, 0 };
    dl_iterate_phdr(findLibCb, &fl);
    return fl.base;
}

// ── Make a memory page writable, write ARM64 instructions, restore ────────────
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

// bool getter → MOVZ W0, #1/#0  /  RET
static void patchBool(uintptr_t base, uintptr_t off, bool val) {
    uint32_t i[] = { val ? 0x52800020u : 0x52800000u, 0xD65F03C0u };
    writeAt(base + off, i, 2);
    LOGI("  bool  @0x%lX = %s", (unsigned long)off, val ? "true" : "false");
}

// int getter ≤ 65535 → MOVZ W0, #val  /  RET
static void patchInt16(uintptr_t base, uintptr_t off, uint16_t val) {
    uint32_t i[] = { (uint32_t)(0x52800000u | ((uint32_t)val << 5)), 0xD65F03C0u };
    writeAt(base + off, i, 2);
    LOGI("  int   @0x%lX = %u", (unsigned long)off, (unsigned)val);
}

// int getter > 65535 → MOVZ W0, lo16  /  MOVK W0, hi16, LSL#16  /  RET
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

// float getter → encode IEEE-754 bits into W0 via MOVZ+MOVK, FMOV S0,W0  /  RET
static void patchFloat(uintptr_t base, uintptr_t off, float val) {
    uint32_t bits;
    memcpy(&bits, &val, 4);
    uint16_t lo = (uint16_t)(bits & 0xFFFF);
    uint16_t hi = (uint16_t)(bits >> 16);
    uint32_t i[] = {
        (uint32_t)(0x52800000u | ((uint32_t)lo << 5)),
        (uint32_t)(0x72A00000u | ((uint32_t)hi << 5)),
        0x1E270000u,   // FMOV S0, W0
        0xD65F03C0u    // RET
    };
    writeAt(base + off, i, 4);
    LOGI("  float @0x%lX = %.3f", (unsigned long)off, (double)val);
}

// void method → RET  (silences the function)
static void patchVoid(uintptr_t base, uintptr_t off) {
    uint32_t i[] = { 0xD65F03C0u };
    writeAt(base + off, i, 1);
    LOGI("  void  @0x%lX silenced", (unsigned long)off);
}

// ── Subway Surfers 3.62.1 patch table ────────────────────────────────────────
static void applyPatches(uintptr_t base) {
    LOGI("=== matrix-hook — Subway Surfers 3.62.1 ===");
    LOGI("libil2cpp base: 0x%lX", (unsigned long)base);

    // Ad Removal
    patchVoid (base, 0x1043C64);              // TryShowInterstitial
    patchVoid (base, 0x1150264);              // AttemptShowInterstitial
    patchBool (base, 0x3247894, false);       // get_IsAdCost → false

    // IAP / Unlock everything
    patchBool (base, 0x32477FC, true);        // get_IsIAP → true

    // Currency — 999999 = 0x000F_423F
    patchInt32(base, 0x158EF98, 999999u);     // GetCurrency (OnlineInventoryManager)
    patchInt32(base, 0x32B4820, 999999u);     // GetCurrency (base manager)

    // Jump — 100 air jumps, 3× height
    patchInt16(base, 0xF9EFD4, 100);          // get_JumpLimit
    patchFloat(base, 0xF9EFF4, 3.0f);         // get_JumpHeight

    // Speed — 5× run speed, forced on, low gravity
    patchFloat(base, 0xF9F454, 5.0f);         // get_SpeedMultiplier (MovementAbility)
    patchFloat(base, 0xF9F624, 5.0f);         // get_SpeedMultiplier (Instance)
    patchBool (base, 0xF9F3C8, true);         // get_SpeedMultiplierOn
    patchFloat(base, 0xF9F48C, 0.5f);         // get_GravityMultiplier (MovementAbility)
    patchFloat(base, 0xF9F674, 0.5f);         // get_GravityMultiplier (Instance)

    // Score Booster — always maxed
    patchBool (base, 0x13918C4, true);        // get_ScoreBoosterActive
    patchBool (base, 0x13919DC, true);        // get_ScoreBoosterMaxed
    patchInt16(base, 0x1392030, 5);           // get_ScoreBoosterIndex → tier 5
    patchBool (base, 0x1021B20, true);        // get_DoubleScorePowerupActive

    // Powerups always active
    patchBool (base, 0xFC2538, true);         // get_MagnetActive
    patchBool (base, 0xFC2548, true);         // get_SuperSneakersActive
    patchBool (base, 0xFC2578, true);         // get_HoverboardActive

    // Revive — unlimited
    patchBool (base, 0x13D570C, true);        // get_CanRevive

    LOGI("=== 21 patches applied ===");
}

// ── Constructor: runs when dlopen completes ───────────────────────────────────
__attribute__((constructor))
static void onLoad() {
    LOGI("matrix-hook constructor fired");

    // Wait up to 3 seconds for libil2cpp.so to appear
    uintptr_t base = 0;
    for (int i = 0; i < 60 && !base; i++) {
        base = getLibBase("libil2cpp.so");
        if (!base) usleep(50000);   // 50 ms × 60 = 3 s max
    }

    if (!base) {
        LOGE("libil2cpp.so base not found after 3s — patches skipped");
        return;
    }

    applyPatches(base);
}
