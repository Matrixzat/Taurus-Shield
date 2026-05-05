/**
 * Taurus Shield — libmain.so loader stub
 *
 * Replaces the original libmain.so in the APK.
 * Responsibilities:
 *   1. dlopen libmatrix-hook.so  (our hook — runs patches via constructor)
 *   2. JNI_OnLoad → forwarded to libmain_orig.so (original Unity init)
 */

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>

#define TAG "matrix-stub"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

__attribute__((constructor))
static void loadHook(void) {
    LOGI("Loading libmatrix-hook.so...");
    void* h = dlopen("libmatrix-hook.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) LOGE("dlopen libmatrix-hook.so failed: %s", dlerror());
    else     LOGI("libmatrix-hook.so loaded OK");
}

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    void* orig = dlopen("libmain_orig.so", RTLD_NOW | RTLD_GLOBAL);
    if (!orig) {
        LOGE("dlopen libmain_orig.so failed: %s", dlerror());
        return JNI_VERSION_1_6;
    }
    typedef jint (*fn_t)(JavaVM*, void*);
    fn_t fn = (fn_t)dlsym(orig, "JNI_OnLoad");
    if (!fn) {
        LOGE("JNI_OnLoad not found in libmain_orig.so");
        return JNI_VERSION_1_6;
    }
    LOGI("Forwarding JNI_OnLoad → libmain_orig.so");
    return fn(vm, reserved);
}
