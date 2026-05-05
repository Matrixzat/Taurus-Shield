/**
 * Taurus Shield — libmain.so loader stub
 *
 * Uses dladdr to find own absolute path, derives the lib directory,
 * then dlopen's libmatrix-hook.so from the same directory.
 * This is required because Android's linker namespace isolation blocks
 * short-name dlopen for non-system libraries.
 */

#include <android/log.h>
#include <dlfcn.h>
#include <jni.h>
#include <stdio.h>
#include <string.h>

#define TAG "matrix-stub"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

__attribute__((constructor))
static void loadHook(void) {
    /* Step 1: find our own absolute path via dladdr on this function */
    Dl_info selfInfo;
    if (!dladdr((void*)loadHook, &selfInfo) || !selfInfo.dli_fname) {
        LOGE("dladdr failed — cannot locate lib directory");
        return;
    }

    /* Step 2: copy path and strip filename to get directory */
    char dir[512];
    snprintf(dir, sizeof(dir), "%s", selfInfo.dli_fname);
    char* slash = strrchr(dir, '/');
    if (!slash) {
        LOGE("Unexpected path format: %s", dir);
        return;
    }
    *slash = '\0';   /* dir now = "/data/app/.../lib/arm64" */

    /* Step 3: build absolute path to libmatrix-hook.so */
    char hook_path[600];
    snprintf(hook_path, sizeof(hook_path), "%s/libmatrix-hook.so", dir);
    LOGI("Loading: %s", hook_path);

    void* h = dlopen(hook_path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        LOGE("dlopen(%s) failed: %s", hook_path, dlerror());
    } else {
        LOGI("libmatrix-hook.so loaded OK");
    }
}

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    /* Forward to the original libmain.so */
    Dl_info selfInfo;
    char orig_path[600] = {0};
    if (dladdr((void*)loadHook, &selfInfo) && selfInfo.dli_fname) {
        char dir[512];
        snprintf(dir, sizeof(dir), "%s", selfInfo.dli_fname);
        char* slash = strrchr(dir, '/');
        if (slash) {
            *slash = '\0';
            snprintf(orig_path, sizeof(orig_path), "%s/libmain_orig.so", dir);
        }
    }

    const char* path = orig_path[0] ? orig_path : "libmain_orig.so";
    LOGI("Forwarding JNI_OnLoad -> %s", path);

    void* orig = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!orig) {
        LOGE("dlopen(%s) failed: %s", path, dlerror());
        return JNI_VERSION_1_6;
    }

    typedef jint (*fn_t)(JavaVM*, void*);
    fn_t fn = (fn_t)dlsym(orig, "JNI_OnLoad");
    if (!fn) {
        LOGE("JNI_OnLoad symbol not found in %s", path);
        return JNI_VERSION_1_6;
    }

    return fn(vm, reserved);
}
