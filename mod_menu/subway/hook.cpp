/**
 * Taurus Shield — libmatrix-hook.so
 * Subway Surfers 3.62.1  |  ARM64  |  Runtime Hook + Mod Menu
 *
 * Strategy:
 *  1. dl_iterate_phdr → find libil2cpp.so base (works for extracted + APK-loaded libs)
 *  2. mprotect + memcpy → apply/revert ARM64 patches with orig byte backup
 *  3. JNI_GetCreatedJavaVMs → get the running VM, find Unity activity
 *  4. Copy modmenu.dex from APK assets to cache dir, load with DexClassLoader
 *  5. Register native methods, call ModMenu.show(activity)
 */

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <link.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define TAG  "matrix-hook"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── VM / JNI globals ──────────────────────────────────────────────────────────
static JavaVM* gVM = nullptr;

static JNIEnv* getEnv() {
    if (!gVM) return nullptr;
    JNIEnv* env = nullptr;
    jint r = gVM->GetEnv((void**)&env, JNI_VERSION_1_6);
    if (r == JNI_EDETACHED) {
        gVM->AttachCurrentThread(&env, nullptr);
    }
    return env;
}

// ── Library base ──────────────────────────────────────────────────────────────
static uintptr_t gBase = 0;

struct FindLib { const char* target; uintptr_t base; };
static int findLibCb(struct dl_phdr_info* info, size_t, void* data) {
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

// ── Memory patch helpers ──────────────────────────────────────────────────────
static void writeInsns(uintptr_t addr, const uint32_t* insns, int n) {
    size_t    len  = (size_t)n * 4;
    long      pgsz = getpagesize();
    uintptr_t page = addr & ~(uintptr_t)(pgsz - 1);
    size_t    plen = len + (addr - page);
    mprotect((void*)page, plen, PROT_READ | PROT_WRITE | PROT_EXEC);
    memcpy((void*)addr, insns, len);
    mprotect((void*)page, plen, PROT_READ | PROT_EXEC);
    __builtin___clear_cache((char*)addr, (char*)(addr + len));
}

// ── Patch descriptor ──────────────────────────────────────────────────────────
struct SubPatch {
    uintptr_t offset;
    uint32_t  newInsns[4];
    int       nNew;
    uint32_t  origInsns[4];
    bool      origSaved;
};

struct Feature {
    const char* name;
    bool        enabled;      // user's current toggle state
    int         nSub;
    SubPatch    subs[5];
};

// ARM64 encoding helpers
static inline uint32_t movz_w0(uint16_t v)  { return 0x52800000u | ((uint32_t)v << 5); }
static inline uint32_t movk_w0_lsl16(uint16_t v) { return 0x72A00000u | ((uint32_t)v << 5); }
static constexpr uint32_t RET  = 0xD65F03C0u;
static constexpr uint32_t FMOV = 0x1E270000u; // FMOV S0, W0

static uint32_t floatInsns(float val, uint32_t out[4]) {
    uint32_t bits; memcpy(&bits, &val, 4);
    out[0] = movz_w0((uint16_t)(bits & 0xFFFF));
    out[1] = movk_w0_lsl16((uint16_t)(bits >> 16));
    out[2] = FMOV;
    out[3] = RET;
    return 4;
}
static uint32_t int32Insns(uint32_t val, uint32_t out[4]) {
    out[0] = movz_w0((uint16_t)(val & 0xFFFF));
    out[1] = movk_w0_lsl16((uint16_t)(val >> 16));
    out[2] = RET;
    return 3;
}
static uint32_t boolInsns(bool v, uint32_t out[4]) {
    out[0] = v ? movz_w0(1) : movz_w0(0);
    out[1] = RET;
    return 2;
}
static uint32_t voidInsns(uint32_t out[4]) {
    out[0] = RET;
    return 1;
}

// ── Feature table (8 features) ────────────────────────────────────────────────
// Filled at runtime with proper instruction encodings.
static Feature gFeatures[8];

static void initFeatures() {
    uint32_t tmp[4];

    // 0 — No Ads
    gFeatures[0].name    = "No Ads";
    gFeatures[0].enabled = true;
    gFeatures[0].nSub    = 3;
    gFeatures[0].subs[0] = { 0x1043C64, {}, (int)voidInsns(tmp), {}, false };
    memcpy(gFeatures[0].subs[0].newInsns, tmp, 4*voidInsns(tmp));
    voidInsns(tmp); gFeatures[0].subs[0].nNew = (int)voidInsns(tmp);
    // redo cleanly:
    { auto& s = gFeatures[0].subs[0]; s.offset=0x1043C64; s.nNew=(int)voidInsns(tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[0].subs[1]; s.offset=0x1150264; s.nNew=(int)voidInsns(tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[0].subs[2]; s.offset=0x3247894; s.nNew=(int)boolInsns(false,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }

    // 1 — Coins x999999
    gFeatures[1].name    = "Coins x999,999";
    gFeatures[1].enabled = true;
    gFeatures[1].nSub    = 2;
    { auto& s = gFeatures[1].subs[0]; s.offset=0x158EF98; s.nNew=(int)int32Insns(999999,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[1].subs[1]; s.offset=0x32B4820; s.nNew=(int)int32Insns(999999,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }

    // 2 — Jump x100 / 3x height
    gFeatures[2].name    = "Jump x100 / 3x Height";
    gFeatures[2].enabled = true;
    gFeatures[2].nSub    = 2;
    { auto& s = gFeatures[2].subs[0]; s.offset=0xF9EFD4; s.nNew=(int)int32Insns(100,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[2].subs[1]; s.offset=0xF9EFF4; s.nNew=(int)floatInsns(3.0f,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }

    // 3 — Speed x5
    gFeatures[3].name    = "Speed x5";
    gFeatures[3].enabled = true;
    gFeatures[3].nSub    = 3;
    { auto& s = gFeatures[3].subs[0]; s.offset=0xF9F454; s.nNew=(int)floatInsns(5.0f,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[3].subs[1]; s.offset=0xF9F624; s.nNew=(int)floatInsns(5.0f,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[3].subs[2]; s.offset=0xF9F3C8; s.nNew=(int)boolInsns(true,tmp);  memcpy(s.newInsns,tmp,4*s.nNew); }

    // 4 — Low Gravity
    gFeatures[4].name    = "Low Gravity";
    gFeatures[4].enabled = true;
    gFeatures[4].nSub    = 2;
    { auto& s = gFeatures[4].subs[0]; s.offset=0xF9F48C; s.nNew=(int)floatInsns(0.5f,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[4].subs[1]; s.offset=0xF9F674; s.nNew=(int)floatInsns(0.5f,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }

    // 5 — Powerups always on
    gFeatures[5].name    = "Powerups Always On";
    gFeatures[5].enabled = true;
    gFeatures[5].nSub    = 3;
    { auto& s = gFeatures[5].subs[0]; s.offset=0xFC2538; s.nNew=(int)boolInsns(true,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[5].subs[1]; s.offset=0xFC2548; s.nNew=(int)boolInsns(true,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[5].subs[2]; s.offset=0xFC2578; s.nNew=(int)boolInsns(true,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }

    // 6 — Score booster max
    gFeatures[6].name    = "Score Booster Max";
    gFeatures[6].enabled = true;
    gFeatures[6].nSub    = 4;
    { auto& s = gFeatures[6].subs[0]; s.offset=0x13918C4; s.nNew=(int)boolInsns(true,tmp);  memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[6].subs[1]; s.offset=0x13919DC; s.nNew=(int)boolInsns(true,tmp);  memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[6].subs[2]; s.offset=0x1392030; s.nNew=(int)int32Insns(5,tmp);    memcpy(s.newInsns,tmp,4*s.nNew); }
    { auto& s = gFeatures[6].subs[3]; s.offset=0x1021B20; s.nNew=(int)boolInsns(true,tmp);  memcpy(s.newInsns,tmp,4*s.nNew); }

    // 7 — Unlimited revive
    gFeatures[7].name    = "Unlimited Revive";
    gFeatures[7].enabled = true;
    gFeatures[7].nSub    = 1;
    { auto& s = gFeatures[7].subs[0]; s.offset=0x13D570C; s.nNew=(int)boolInsns(true,tmp); memcpy(s.newInsns,tmp,4*s.nNew); }
}

// ── Apply / Revert ────────────────────────────────────────────────────────────
static void applyFeature(int idx) {
    if (!gBase) return;
    Feature& f = gFeatures[idx];
    for (int s = 0; s < f.nSub; s++) {
        SubPatch& sp = f.subs[s];
        uintptr_t addr = gBase + sp.offset;
        if (!sp.origSaved) {
            memcpy(sp.origInsns, (void*)addr, (size_t)sp.nNew * 4);
            sp.origSaved = true;
        }
        writeInsns(addr, sp.newInsns, sp.nNew);
    }
    LOGI("Feature[%d] '%s' ENABLED", idx, f.name);
}

static void revertFeature(int idx) {
    if (!gBase) return;
    Feature& f = gFeatures[idx];
    for (int s = 0; s < f.nSub; s++) {
        SubPatch& sp = f.subs[s];
        if (sp.origSaved) {
            writeInsns(gBase + sp.offset, sp.origInsns, sp.nNew);
        }
    }
    LOGI("Feature[%d] '%s' DISABLED (reverted)", idx, f.name);
}

static void applyAllEnabled() {
    for (int i = 0; i < 8; i++) {
        if (gFeatures[i].enabled) applyFeature(i);
    }
}

// ── JNI native methods exposed to ModMenu.java ────────────────────────────────
extern "C" JNIEXPORT void JNICALL
Java_com_taurus_matrix_ModMenu_nativeToggle(JNIEnv*, jclass, jint id, jboolean on) {
    if (id < 0 || id >= 8) return;
    gFeatures[id].enabled = (bool)on;
    if (on) applyFeature(id);
    else     revertFeature(id);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_taurus_matrix_ModMenu_nativeGetState(JNIEnv*, jclass, jint id) {
    if (id < 0 || id >= 8) return JNI_TRUE;
    return gFeatures[id].enabled ? JNI_TRUE : JNI_FALSE;
}

// ── JNI helpers ───────────────────────────────────────────────────────────────
static jstring jstr(JNIEnv* e, const char* s) { return e->NewStringUTF(s); }

static jobject callObjMethod(JNIEnv* e, jobject obj, const char* cls,
                             const char* name, const char* sig, ...) {
    jclass c = e->FindClass(cls);
    if (!c) { LOGE("Class not found: %s", cls); return nullptr; }
    jmethodID m = e->GetMethodID(c, name, sig);
    if (!m) { LOGE("Method not found: %s.%s%s", cls, name, sig); return nullptr; }
    va_list ap; va_start(ap, sig);
    jobject r = e->CallObjectMethodV(obj, m, ap);
    va_end(ap);
    e->DeleteLocalRef(c);
    return r;
}

// ── Menu thread ───────────────────────────────────────────────────────────────
static void* menuThread(void*) {
    JNIEnv* env = nullptr;
    gVM->AttachCurrentThread(&env, nullptr);

    // Wait for UnityPlayer.currentActivity to be non-null (up to 10 s)
    jclass upClass = nullptr;
    jobject activity = nullptr;
    for (int i = 0; i < 200; i++) {
        upClass = env->FindClass("com/unity3d/player/UnityPlayer");
        if (upClass) {
            jfieldID fid = env->GetStaticFieldID(upClass, "currentActivity",
                                                  "Landroid/app/Activity;");
            if (fid) {
                activity = env->GetStaticObjectField(upClass, fid);
                if (activity) break;
            }
        }
        env->ExceptionClear();
        usleep(50000); // 50 ms
    }

    if (!activity) {
        LOGE("Could not find Unity currentActivity — menu skipped");
        gVM->DetachCurrentThread();
        return nullptr;
    }
    LOGI("Got Unity activity");

    // ── Copy modmenu.dex from assets to cache dir ─────────────────────────────
    jobject assetMgr = callObjMethod(env, activity,
        "android/app/Activity", "getAssets", "()Landroid/content/res/AssetManager;");
    jobject cacheFile = callObjMethod(env, activity,
        "android/app/Activity", "getCacheDir", "()Ljava/io/File;");
    jclass fileClass = env->FindClass("java/io/File");
    jmethodID getPath = env->GetMethodID(fileClass, "getAbsolutePath", "()Ljava/lang/String;");
    jstring cacheDirJs = (jstring)env->CallObjectMethod(cacheFile, getPath);
    const char* cacheDirStr = env->GetStringUTFChars(cacheDirJs, nullptr);
    char dexDst[512];
    snprintf(dexDst, sizeof(dexDst), "%s/modmenu.dex", cacheDirStr);
    env->ReleaseStringUTFChars(cacheDirJs, cacheDirStr);
    LOGI("Dex cache path: %s", dexDst);

    // Open asset stream
    jclass amClass = env->FindClass("android/content/res/AssetManager");
    jmethodID openMethod = env->GetMethodID(amClass, "open",
        "(Ljava/lang/String;)Ljava/io/InputStream;");
    jobject inputStream = env->CallObjectMethod(assetMgr, openMethod,
        jstr(env, "modmenu.dex"));
    if (!inputStream || env->ExceptionCheck()) {
        env->ExceptionClear();
        LOGE("Could not open assets/modmenu.dex — did the workflow add it?");
        gVM->DetachCurrentThread();
        return nullptr;
    }

    // Write to cache file via FileOutputStream
    jclass fosClass = env->FindClass("java/io/FileOutputStream");
    jmethodID fosCtor = env->GetMethodID(fosClass, "<init>", "(Ljava/lang/String;)V");
    jobject fos = env->NewObject(fosClass, fosCtor, jstr(env, dexDst));
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        LOGE("FileOutputStream(%s) failed", dexDst);
        gVM->DetachCurrentThread();
        return nullptr;
    }

    jclass isClass = env->FindClass("java/io/InputStream");
    jmethodID readMethod = env->GetMethodID(isClass, "read", "([B)I");
    jmethodID fosWrite = env->GetMethodID(fosClass, "write", "([BII)V");
    jmethodID fosClose = env->GetMethodID(fosClass, "close", "()V");
    jmethodID isClose  = env->GetMethodID(isClass,  "close", "()V");

    jbyteArray buf = env->NewByteArray(8192);
    jint n;
    while ((n = env->CallIntMethod(inputStream, readMethod, buf)) > 0) {
        env->CallVoidMethod(fos, fosWrite, buf, 0, n);
    }
    env->CallVoidMethod(fos, fosClose);
    env->CallVoidMethod(inputStream, isClose);
    env->DeleteLocalRef(buf);
    LOGI("modmenu.dex written to cache");

    // ── Load dex with DexClassLoader ──────────────────────────────────────────
    // Get parent class loader from activity
    jclass ctxClass = env->FindClass("android/content/Context");
    jmethodID getClsLoader = env->GetMethodID(ctxClass, "getClassLoader",
                                               "()Ljava/lang/ClassLoader;");
    jobject parentLoader = env->CallObjectMethod(activity, getClsLoader);

    jclass dexLoaderClass = env->FindClass("dalvik/system/DexClassLoader");
    jmethodID dexLoaderCtor = env->GetMethodID(dexLoaderClass, "<init>",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V");

    char dexOptDir[512];
    snprintf(dexOptDir, sizeof(dexOptDir), "%s", dexDst);
    // Use cache dir as opt dir too
    char* lastSlash = strrchr(dexOptDir, '/');
    if (lastSlash) *lastSlash = '\0';

    jobject dexLoader = env->NewObject(dexLoaderClass, dexLoaderCtor,
        jstr(env, dexDst),
        jstr(env, dexOptDir),
        (jobject)nullptr,
        parentLoader);
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe(); env->ExceptionClear();
        LOGE("DexClassLoader construction failed");
        gVM->DetachCurrentThread();
        return nullptr;
    }
    LOGI("DexClassLoader ready");

    // ── Load ModMenu class ────────────────────────────────────────────────────
    jmethodID loadClass = env->GetMethodID(
        env->FindClass("java/lang/ClassLoader"),
        "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    jclass menuClass = (jclass)env->CallObjectMethod(
        dexLoader, loadClass, jstr(env, "com.taurus.matrix.ModMenu"));
    if (env->ExceptionCheck() || !menuClass) {
        env->ExceptionDescribe(); env->ExceptionClear();
        LOGE("ModMenu class not found in dex");
        gVM->DetachCurrentThread();
        return nullptr;
    }
    LOGI("ModMenu class loaded");

    // ── Register native methods on the loaded class ───────────────────────────
    JNINativeMethod nativeMethods[] = {
        { "nativeToggle",   "(IZ)V",  (void*)Java_com_taurus_matrix_ModMenu_nativeToggle   },
        { "nativeGetState", "(I)Z",   (void*)Java_com_taurus_matrix_ModMenu_nativeGetState },
    };
    jint regResult = env->RegisterNatives(menuClass, nativeMethods, 2);
    if (regResult != JNI_OK) {
        LOGE("RegisterNatives failed: %d", (int)regResult);
        gVM->DetachCurrentThread();
        return nullptr;
    }
    LOGI("Native methods registered");

    // ── Call ModMenu.show(activity) ───────────────────────────────────────────
    jmethodID showMethod = env->GetStaticMethodID(menuClass, "show",
                                                   "(Landroid/app/Activity;)V");
    if (!showMethod) {
        LOGE("ModMenu.show not found");
        gVM->DetachCurrentThread();
        return nullptr;
    }
    env->CallStaticVoidMethod(menuClass, showMethod, activity);
    if (env->ExceptionCheck()) {
        env->ExceptionDescribe(); env->ExceptionClear();
        LOGE("ModMenu.show() threw an exception");
    } else {
        LOGI("ModMenu.show() called — overlay should be visible");
    }

    gVM->DetachCurrentThread();
    return nullptr;
}

// ── Constructor — runs when dlopen completes ──────────────────────────────────
__attribute__((constructor))
static void onLoad() {
    LOGI("matrix-hook constructor fired");

    // 1) Init patch table
    initFeatures();

    // 2) Get JavaVM (already running since JNI started the app)
    typedef jint (*GetVMs_t)(JavaVM**, jsize, jsize*);
    GetVMs_t getVMs = (GetVMs_t)dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs");
    if (!getVMs) {
        // Fallback: try libart.so explicitly
        void* libart = dlopen("libart.so", RTLD_NOLOAD | RTLD_NOW);
        if (libart) getVMs = (GetVMs_t)dlsym(libart, "JNI_GetCreatedJavaVMs");
    }
    if (getVMs) {
        jsize n = 0;
        getVMs(&gVM, 1, &n);
        if (n > 0) LOGI("Got JavaVM: %p", (void*)gVM);
        else        LOGE("JNI_GetCreatedJavaVMs returned 0 VMs");
    } else {
        LOGE("JNI_GetCreatedJavaVMs not found");
    }

    // 3) Find libil2cpp.so — wait up to 4 s
    for (int i = 0; i < 80 && !gBase; i++) {
        gBase = getLibBase("libil2cpp.so");
        if (!gBase) usleep(50000);
    }
    if (!gBase) {
        LOGE("libil2cpp.so base not found — patches skipped");
    } else {
        LOGI("libil2cpp base: 0x%lX", (unsigned long)gBase);
        applyAllEnabled();
    }

    // 4) Launch menu thread (async — don't block the game startup)
    if (gVM) {
        pthread_t t;
        pthread_create(&t, nullptr, menuThread, nullptr);
        pthread_detach(t);
    }
}
