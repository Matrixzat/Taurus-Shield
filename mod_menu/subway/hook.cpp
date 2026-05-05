/**
 * Taurus Shield — Subway Surfers 3.62.1 Runtime Hook
 *
 * Injected as libmain.so replacement (proxy pattern).
 * Original libmain.so → renamed to libmain_orig.so inside APK.
 *
 * Load order inside Unity:
 *   libil2cpp.so  ← already mapped by the time JNI_OnLoad fires
 *   libmain.so    ← this library (our hook)
 *
 * __attribute__((constructor)) fires at dlopen time, before JNI_OnLoad.
 * By then libil2cpp.so is fully mapped — safe to patch.
 */

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define TAG  "TaurusHook"
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

// ── Make memory writable, write bytes, restore ────────────────────────────────
static void writeAt(uintptr_t addr, const uint32_t* insns, size_t count) {
    size_t len  = count * 4;
    long   pgsz = getpagesize();
    uintptr_t page    = addr & ~(uintptr_t)(pgsz - 1);
    size_t    pageLen = len + (addr - page);

    mprotect((void*)page, pageLen, PROT_READ | PROT_WRITE | PROT_EXEC);
    memcpy((void*)addr, insns, len);
    mprotect((void*)page, pageLen, PROT_READ | PROT_EXEC);
    __builtin___clear_cache((char*)addr, (char*)(addr + len));
}

// ── ARM64 patch helpers ───────────────────────────────────────────────────────

// bool getter → MOV W0, #0/#1  /  RET
static void patchBool(uintptr_t base, uintptr_t off, bool val) {
    uint32_t i[] = {
        val ? 0x52800020u : 0x52800000u,   // MOVZ W0, #1 or #0
        0xD65F03C0u                         // RET
    };
    writeAt(base + off, i, 2);
    LOGI("  bool  @0x%lX = %s", off, val ? "true" : "false");
}

// int getter ≤ 65535 → MOVZ W0, #val  /  RET
static void patchInt16(uintptr_t base, uintptr_t off, uint16_t val) {
    uint32_t i[] = {
        (uint32_t)(0x52800000u | ((uint32_t)val << 5)),
        0xD65F03C0u
    };
    writeAt(base + off, i, 2);
    LOGI("  int   @0x%lX = %u", off, (unsigned)val);
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
    LOGI("  int32 @0x%lX = %u", off, val);
}

// float getter → MOVZ W0, lo16  /  MOVK W0, hi16, LSL#16  /  FMOV S0,W0  /  RET
static void patchFloat(uintptr_t base, uintptr_t off, float val) {
    uint32_t bits;
    memcpy(&bits, &val, 4);
    uint16_t lo = (uint16_t)(bits & 0xFFFF);
    uint16_t hi = (uint16_t)(bits >> 16);
    uint32_t i[] = {
        (uint32_t)(0x52800000u | ((uint32_t)lo << 5)),   // MOVZ W0, lo
        (uint32_t)(0x72A00000u | ((uint32_t)hi << 5)),   // MOVK W0, hi, LSL#16
        0x1E270000u,                                       // FMOV S0, W0
        0xD65F03C0u                                        // RET
    };
    writeAt(base + off, i, 4);
    LOGI("  float @0x%lX = %.3f", off, (double)val);
}

// void method → RET  (silences the function entirely)
static void patchVoid(uintptr_t base, uintptr_t off) {
    uint32_t i[] = { 0xD65F03C0u };   // RET
    writeAt(base + off, i, 1);
    LOGI("  void  @0x%lX silenced", off);
}

// ── All Subway Surfers 3.62.1 patches (from Taurus Shield patch file) ─────────
static void applyPatches(uintptr_t base) {
    LOGI("=== Taurus Shield — Subway Surfers 3.62.1 ===");
    LOGI("libil2cpp base: 0x%lX", base);

    // Ad Removal
    LOGI("[Ads]");
    patchVoid (base, 0x1043C64);              // TryShowInterstitial
    patchVoid (base, 0x1150264);              // AttemptShowInterstitial
    patchBool (base, 0x3247894, false);       // get_IsAdCost → false

    // IAP / Unlock
    LOGI("[IAP]");
    patchBool (base, 0x32477FC, true);        // get_IsIAP → true (all items owned)

    // Currency — 999999 = 0x000F423F
    LOGI("[Currency]");
    patchInt32(base, 0x158EF98, 999999u);     // GetCurrency (OnlineInventoryManager)
    patchInt32(base, 0x32B4820, 999999u);     // GetCurrency (base manager)

    // Jump
    LOGI("[Jump]");
    patchInt16(base, 0xF9EFD4, 100);          // get_JumpLimit  → 100 jumps
    patchFloat(base, 0xF9EFF4, 3.0f);         // get_JumpHeight → 3x

    // Speed
    LOGI("[Speed]");
    patchFloat(base, 0xF9F454, 5.0f);         // get_SpeedMultiplier (MovementAbility)
    patchFloat(base, 0xF9F624, 5.0f);         // get_SpeedMultiplier (Instance)
    patchBool (base, 0xF9F3C8, true);         // get_SpeedMultiplierOn → forced on
    patchFloat(base, 0xF9F48C, 0.5f);         // get_GravityMultiplier (low gravity)
    patchFloat(base, 0xF9F674, 0.5f);         // get_GravityMultiplier (Instance)

    // Score Booster
    LOGI("[Score]");
    patchBool (base, 0x13918C4, true);        // get_ScoreBoosterActive
    patchBool (base, 0x13919DC, true);        // get_ScoreBoosterMaxed
    patchInt16(base, 0x1392030, 5);           // get_ScoreBoosterIndex → max tier
    patchBool (base, 0x1021B20, true);        // get_DoubleScorePowerupActive

    // Powerups — always active
    LOGI("[Powerups]");
    patchBool (base, 0xFC2538, true);         // get_MagnetActive
    patchBool (base, 0xFC2548, true);         // get_SuperSneakersActive
    patchBool (base, 0xFC2578, true);         // get_HoverboardActive

    // Revive
    LOGI("[Revive]");
    patchBool (base, 0x13D570C, true);        // get_CanRevive → unlimited

    LOGI("=== All %d patches applied ===", 21);
}

// ── Constructor — runs when our .so is loaded ─────────────────────────────────
__attribute__((constructor))
static void onLoad() {
    LOGI("Taurus Shield hook loaded");

    uintptr_t base = 0;
    // libil2cpp.so is loaded before libmain.so in Unity — should be instant
    for (int i = 0; i < 30 && !base; i++) {
        base = getLibBase("libil2cpp.so");
        if (!base) usleep(50000);   // 50 ms
    }

    if (!base) {
        LOGE("libil2cpp.so base not found — patches skipped");
        return;
    }

    applyPatches(base);
}

// ── JNI_OnLoad proxy — forwards to original libmain.so ───────────────────────
extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    // Load original libmain (renamed to libmain_orig.so during injection)
    void* orig = dlopen("libmain_orig.so", RTLD_NOW | RTLD_GLOBAL);
    if (!orig) {
        LOGE("dlopen libmain_orig.so failed: %s", dlerror());
        return JNI_VERSION_1_6;
    }

    typedef jint (*JNI_OnLoad_t)(JavaVM*, void*);
    auto origOnLoad = (JNI_OnLoad_t)dlsym(orig, "JNI_OnLoad");
    if (!origOnLoad) {
        LOGE("JNI_OnLoad not found in libmain_orig.so");
        return JNI_VERSION_1_6;
    }

    LOGI("Forwarding JNI_OnLoad to original libmain");
    return origOnLoad(vm, reserved);
}
