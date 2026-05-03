// Taurus Shield – Mod Engine template
// This file is compiled by the mod-build.yml workflow, NOT by the Taurus Shield app itself.
// The workflow generates a custom version with game-specific hooks filled in.

#include <jni.h>
#include <string>
#include <android/log.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include "dobby.h"

#define TAG  "ModEngine"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ─────────────────────────────────────────────────────────────────────────────
// Base address finder
// Reads /proc/self/maps to locate libil2cpp.so at runtime.
// libil2cpp.so is loaded at a random address each launch (ASLR), so we
// always find it dynamically then add our pre-dumped offsets to it.
// ─────────────────────────────────────────────────────────────────────────────
static uintptr_t findLibBase(const char* libName) {
    FILE* maps = fopen("/proc/self/maps", "r");
    if (!maps) {
        LOGE("Cannot open /proc/self/maps");
        return 0;
    }
    char line[512];
    uintptr_t base = 0;
    while (fgets(line, sizeof(line), maps)) {
        if (strstr(line, libName) && strstr(line, "r-xp")) {
            base = (uintptr_t)strtoull(line, nullptr, 16);
            LOGI("Found %s base: 0x%lx", libName, (unsigned long)base);
            break;
        }
    }
    fclose(maps);
    if (base == 0) {
        LOGE("Library not found in /proc/self/maps: %s", libName);
    }
    return base;
}

// ─────────────────────────────────────────────────────────────────────────────
// ===HOOKS_START===
// The mod-build.yml workflow replaces everything between these markers
// with game-specific hook functions and installs them in installHooks().
//
// Example of what gets generated for a "GetCoins" hook:
//
//   typedef int (*feat_0_GetCoins_fn)(void*);
//   static feat_0_GetCoins_fn orig_feat_0_GetCoins = nullptr;
//   static int val_feat_0_GetCoins = 0;
//   static bool enabled_feat_0_GetCoins = false;
//   static int hook_feat_0_GetCoins(void* thiz) {
//       if (enabled_feat_0_GetCoins) return val_feat_0_GetCoins;
//       return orig_feat_0_GetCoins ? orig_feat_0_GetCoins(thiz) : 0;
//   }
//
// And installHooks() does:
//   uintptr_t base = findLibBase("libil2cpp.so");
//   DobbyHook((void*)(base + 0x2A4F8C), (void*)hook_feat_0_GetCoins,
//             (void**)&orig_feat_0_GetCoins);
// ===HOOKS_END===
//
// Template stub (no features — replace with generated version per game):

static void installHooks() {
    uintptr_t base = findLibBase("libil2cpp.so");
    if (base == 0) {
        LOGE("Cannot install hooks — libil2cpp.so base not found");
        return;
    }
    LOGI("Hook install base: 0x%lx (no features in template)", (unsigned long)base);
    // Generated hooks go here
}

// ─────────────────────────────────────────────────────────────────────────────
// JNI: called when the .so is first loaded into the game process.
// Dobby hooks are installed here — they are active for the entire game session.
// ─────────────────────────────────────────────────────────────────────────────
extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
    LOGI("ModEngine loading...");
    installHooks();
    LOGI("ModEngine ready");
    return JNI_VERSION_1_6;
}

// ─────────────────────────────────────────────────────────────────────────────
// JNI: called from the mod menu overlay (if included) to toggle features.
// featNum  = feature index (matches the features_json array order)
// intVal   = integer value (e.g. speed multiplier × 10, or custom amount)
// longVal  = long value (e.g. coin amount)
// boolVal  = on/off toggle
// ─────────────────────────────────────────────────────────────────────────────
extern "C" JNIEXPORT void JNICALL
Java_com_taurus_shield_ModEngineLoader_applyFeature(
        JNIEnv*, jclass,
        jint featNum, jint intVal, jlong longVal, jboolean boolVal) {
    LOGI("applyFeature(%d, int=%d, long=%lld, bool=%d)",
         (int)featNum, (int)intVal, (long long)longVal, (int)boolVal);
    // Generated switch cases go here (one per feature)
}
