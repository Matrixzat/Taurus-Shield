/**
 * Taurus Shield — libmatrix-hook.so
 *
 * Strategy:
 *   - IL2CPP patches : manual mprotect + memcpy + __builtin___clear_cache
 *   - eglSwapBuffers : xhook GOT-patch in libunity.so  → ImGui GLES2 overlay
 *   - AInputQueue_getEvent : xhook GOT-patch → touch feeds ImGui
 *
 * Both hooks are installed from a background thread (polling) because
 * libunity.so loads AFTER our constructor (it is dlopen'd by libmain_orig.so).
 */

#include <android/log.h>
#include <android/input.h>
#include <dlfcn.h>
#include <elf.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <EGL/egl.h>
#define GL_GLEXT_PROTOTYPES
#include <GLES2/gl2.h>

extern "C" {
#include "xhook.h"
}

#define IMGUI_IMPL_OPENGL_ES2
#include "imgui.h"
#include "imgui_impl_opengl3.h"

// ──────────────────────────────────────────────────────────────────────────────
//  Logging
// ──────────────────────────────────────────────────────────────────────────────
#define TAG  "matrix-hook"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ──────────────────────────────────────────────────────────────────────────────
//  IL2CPP patch table  (Subway Surfers 3.62.1, arm64)
//  Each entry: name, offset-from-libil2cpp-base, patch bytes, original bytes
// ──────────────────────────────────────────────────────────────────────────────
struct Patch {
    const char* name;
    uintptr_t   offset;
    const uint8_t patch[4];
    const uint8_t orig[4];
    bool        enabled;
    bool        applied;
};

static Patch g_patches[] = {
    { "No Ads",          0x3B24C0C, {0x00,0x00,0x80,0xD2}, {0,0,0,0}, false, false },
    { "High Score",      0x3B1A070, {0x00,0x00,0x80,0xD2}, {0,0,0,0}, false, false },
    { "Unlimited Coins", 0x3B2F444, {0x00,0x00,0x80,0xD2}, {0,0,0,0}, false, false },
    { "Unlimited Keys",  0x3B2F8AC, {0x00,0x00,0x80,0xD2}, {0,0,0,0}, false, false },
    { "Speed Hack x2",   0x3B1C8E4, {0x40,0x1F,0x80,0x52}, {0,0,0,0}, false, false },
};
static const int kPatchCount = sizeof(g_patches) / sizeof(g_patches[0]);

static uintptr_t g_il2cpp_base = 0;

// ──────────────────────────────────────────────────────────────────────────────
//  Manual code patch (replaces DobbyCodePatch)
// ──────────────────────────────────────────────────────────────────────────────
static bool patch_code(uintptr_t addr, const uint8_t* bytes, size_t len) {
    uintptr_t page_start = addr & ~(uintptr_t)(getpagesize() - 1);
    size_t    page_len   = (addr + len - page_start + getpagesize() - 1)
                           & ~(uintptr_t)(getpagesize() - 1);
    if (mprotect((void*)page_start, page_len, PROT_READ | PROT_WRITE | PROT_EXEC) != 0)
        return false;
    memcpy((void*)addr, bytes, len);
    __builtin___clear_cache((char*)addr, (char*)(addr + len));
    mprotect((void*)page_start, page_len, PROT_READ | PROT_EXEC);
    return true;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Patch apply / revert
// ──────────────────────────────────────────────────────────────────────────────
static void apply_patch(Patch& p) {
    if (!g_il2cpp_base || p.applied) return;
    uintptr_t addr = g_il2cpp_base + p.offset;
    memcpy((void*)p.orig, (void*)addr, 4);       // save original bytes
    if (patch_code(addr, p.patch, 4)) {
        p.applied = true;
        LOGI("Patch ON  : %s @ 0x%lX", p.name, addr);
    }
}

static void revert_patch(Patch& p) {
    if (!g_il2cpp_base || !p.applied) return;
    uintptr_t addr = g_il2cpp_base + p.offset;
    if (patch_code(addr, p.orig, 4)) {
        p.applied = false;
        LOGI("Patch OFF : %s @ 0x%lX", p.name, addr);
    }
}

// ──────────────────────────────────────────────────────────────────────────────
//  ImGui state
// ──────────────────────────────────────────────────────────────────────────────
static bool  g_imgui_init = false;
static float g_display_w  = 1080;
static float g_display_h  = 1920;
static bool  g_menu_open  = true;

// Touch state forwarded to ImGui
static pthread_mutex_t g_touch_mutex = PTHREAD_MUTEX_INITIALIZER;
struct TouchEvent { float x, y; int action; };
static TouchEvent g_touch = {0, 0, -1};

// ──────────────────────────────────────────────────────────────────────────────
//  eglSwapBuffers hook — render ImGui overlay
// ──────────────────────────────────────────────────────────────────────────────
typedef EGLBoolean (*PFN_eglSwapBuffers)(EGLDisplay, EGLSurface);
static PFN_eglSwapBuffers orig_eglSwapBuffers = nullptr;

static EGLBoolean hook_eglSwapBuffers(EGLDisplay display, EGLSurface surface) {
    // Initialise ImGui once on first call
    if (!g_imgui_init) {
        EGLint w = 0, h = 0;
        eglQuerySurface(display, surface, EGL_WIDTH,  &w);
        eglQuerySurface(display, surface, EGL_HEIGHT, &h);
        if (w > 0) g_display_w = (float)w;
        if (h > 0) g_display_h = (float)h;

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io = ImGui::GetIO();
        io.DisplaySize       = ImVec2(g_display_w, g_display_h);
        io.IniFilename       = nullptr;
        io.LogFilename       = nullptr;
        ImGui::StyleColorsDark();
        ImGui_ImplOpenGL3_Init("#version 100");   // GLES2 shader
        g_imgui_init = true;
        LOGI("ImGui initialized (%dx%d)", w, h);
    }

    // Feed touch events into ImGui
    {
        pthread_mutex_lock(&g_touch_mutex);
        TouchEvent te = g_touch;
        g_touch.action = -1;
        pthread_mutex_unlock(&g_touch_mutex);

        if (te.action >= 0) {
            ImGuiIO& io = ImGui::GetIO();
            io.MousePos     = ImVec2(te.x, te.y);
            io.MouseDown[0] = (te.action == AMOTION_EVENT_ACTION_DOWN ||
                               te.action == AMOTION_EVENT_ACTION_MOVE);
        }
    }

    // Render mod menu
    ImGui_ImplOpenGL3_NewFrame();
    ImGui::NewFrame();

    if (g_menu_open) {
        ImGui::SetNextWindowSize(ImVec2(340, 60 + kPatchCount * 28), ImGuiCond_Once);
        ImGui::SetNextWindowPos(ImVec2(20, 120), ImGuiCond_Once);
        ImGui::Begin("Taurus Shield", &g_menu_open,
                     ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoCollapse);

        for (int i = 0; i < kPatchCount; i++) {
            Patch& p = g_patches[i];
            if (ImGui::Checkbox(p.name, &p.enabled)) {
                if (p.enabled) apply_patch(p);
                else           revert_patch(p);
            }
        }
        ImGui::End();
    }

    ImGui::Render();
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());

    return orig_eglSwapBuffers(display, surface);
}

// ──────────────────────────────────────────────────────────────────────────────
//  AInputQueue_getEvent hook — capture touch for ImGui
// ──────────────────────────────────────────────────────────────────────────────
typedef int (*PFN_AInputQueue_getEvent)(AInputQueue*, AInputEvent**);
static PFN_AInputQueue_getEvent orig_AInputQueue_getEvent = nullptr;

static int hook_AInputQueue_getEvent(AInputQueue* queue, AInputEvent** event) {
    int result = orig_AInputQueue_getEvent(queue, event);
    if (result >= 0 && *event &&
        AInputEvent_getType(*event) == AINPUT_EVENT_TYPE_MOTION) {
        int action = AMotionEvent_getAction(*event) & AMOTION_EVENT_ACTION_MASK;
        float x    = AMotionEvent_getX(*event, 0);
        float y    = AMotionEvent_getY(*event, 0);
        pthread_mutex_lock(&g_touch_mutex);
        g_touch = {x, y, action};
        pthread_mutex_unlock(&g_touch_mutex);
    }
    return result;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Read libil2cpp.so base from /proc/self/maps
// ──────────────────────────────────────────────────────────────────────────────
static uintptr_t find_lib_base(const char* libname) {
    char line[512];
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) return 0;
    uintptr_t base = 0;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, libname) && strstr(line, "r-xp")) {
            base = (uintptr_t)strtoull(line, nullptr, 16);
            break;
        }
    }
    fclose(f);
    return base;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Background setup thread
//  • polls until libil2cpp.so appears → applies any already-enabled patches
//  • polls until libunity.so appears  → installs xhook on eglSwapBuffers
// ──────────────────────────────────────────────────────────────────────────────
static void* setup_thread(void*) {
    // ── Wait for libil2cpp.so ────────────────────────────────────────────────
    for (int i = 0; i < 400 && !g_il2cpp_base; i++) {
        g_il2cpp_base = find_lib_base("libil2cpp.so");
        if (!g_il2cpp_base) usleep(50000);
    }
    if (g_il2cpp_base)
        LOGI("libil2cpp.so base: 0x%lX", g_il2cpp_base);
    else
        LOGE("libil2cpp.so base NOT found after 20 s");

    // ── Wait for libunity.so then install xhook ──────────────────────────────
    bool hooks_installed = false;
    for (int i = 0; i < 400 && !hooks_installed; i++) {
        uintptr_t unity_base = find_lib_base("libunity.so");
        if (unity_base) {
            xhook_enable_sigsegv_protection(1);

            // Hook eglSwapBuffers in every library that imports it
            xhook_register(".*\\.so$", "eglSwapBuffers",
                           (void*)hook_eglSwapBuffers,
                           (void**)&orig_eglSwapBuffers);

            // Hook AInputQueue_getEvent likewise
            xhook_register(".*\\.so$", "AInputQueue_getEvent",
                           (void*)hook_AInputQueue_getEvent,
                           (void**)&orig_AInputQueue_getEvent);

            if (xhook_refresh(0) == 0 && orig_eglSwapBuffers) {
                hooks_installed = true;
                LOGI("xhook installed — eglSwapBuffers=%p  AInputQueue=%p",
                     (void*)orig_eglSwapBuffers,
                     (void*)orig_AInputQueue_getEvent);
            } else {
                // clear and retry
                xhook_clear();
                LOGI("xhook retry %d (unity_base=0x%lX)", i, unity_base);
            }
        }
        if (!hooks_installed) usleep(50000);
    }
    if (!hooks_installed)
        LOGE("eglSwapBuffers hook NOT installed after 20 s");

    return nullptr;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Constructor — kick off background thread immediately
// ──────────────────────────────────────────────────────────────────────────────
__attribute__((constructor))
static void onLoad() {
    LOGI("libmatrix-hook.so loaded — starting setup thread");
    pthread_t t;
    if (pthread_create(&t, nullptr, setup_thread, nullptr) == 0)
        pthread_detach(t);
}
