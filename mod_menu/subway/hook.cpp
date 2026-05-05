/**
 * Taurus Shield — libmatrix-hook.so
 *
 * IL2CPP patches : manual mprotect + memcpy + __builtin___clear_cache
 * eglSwapBuffers : xhook GOT-patch → ImGui GLES2 overlay
 * AInputQueue_getEvent : xhook GOT-patch → touch feeds ImGui
 *
 * Background thread polls until libunity.so is loaded (it arrives after ours
 * because loader_stub.c opens libmain_orig.so from JNI_OnLoad).
 */

#include <android/log.h>
#include <android/input.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <EGL/egl.h>
#define GL_GLEXT_PROTOTYPES
#include <GLES2/gl2.h>

extern "C" {
#include "xhook.h"
}

#include "imgui.h"
#include "imgui_impl_opengl3.h"

#define TAG  "matrix-hook"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ──────────────────────────────────────────────────────────────────────────────
//  IL2CPP patch table  (Subway Surfers 3.62.1, arm64)
// ──────────────────────────────────────────────────────────────────────────────
struct Patch {
    const char* name;
    uintptr_t   offset;
    uint8_t     patch[4];
    uint8_t     orig[4];
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
static const int kPatchCount = (int)(sizeof(g_patches) / sizeof(g_patches[0]));

static uintptr_t g_il2cpp_base = 0;

// ──────────────────────────────────────────────────────────────────────────────
//  Manual code patch (replaces DobbyCodePatch)
// ──────────────────────────────────────────────────────────────────────────────
static bool patch_code(uintptr_t addr, const uint8_t* bytes, size_t len) {
    long   pgsz  = sysconf(_SC_PAGESIZE);
    uintptr_t ps = addr & ~(uintptr_t)(pgsz - 1);
    size_t    pl  = ((addr + len + pgsz - 1) & ~(uintptr_t)(pgsz - 1)) - ps;
    if (mprotect((void*)ps, pl, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) return false;
    memcpy((void*)addr, bytes, len);
    __builtin___clear_cache((char*)addr, (char*)(addr + len));
    mprotect((void*)ps, pl, PROT_READ | PROT_EXEC);
    return true;
}

static void apply_patch(Patch& p) {
    if (!g_il2cpp_base || p.applied) return;
    uintptr_t addr = g_il2cpp_base + p.offset;
    memcpy(p.orig, (void*)addr, 4);
    if (patch_code(addr, p.patch, 4)) { p.applied = true;  LOGI("ON  %s", p.name); }
}
static void revert_patch(Patch& p) {
    if (!g_il2cpp_base || !p.applied) return;
    uintptr_t addr = g_il2cpp_base + p.offset;
    if (patch_code(addr, p.orig, 4))  { p.applied = false; LOGI("OFF %s", p.name); }
}

// ──────────────────────────────────────────────────────────────────────────────
//  ImGui / touch state
// ──────────────────────────────────────────────────────────────────────────────
static bool g_imgui_init = false;
static bool g_menu_open  = true;
static pthread_mutex_t g_touch_mu = PTHREAD_MUTEX_INITIALIZER;
struct TouchEvent { float x, y; int action; };
static TouchEvent g_touch = {0.f, 0.f, -1};

// ──────────────────────────────────────────────────────────────────────────────
//  eglSwapBuffers hook
// ──────────────────────────────────────────────────────────────────────────────
typedef EGLBoolean (*PFN_eglSwapBuffers)(EGLDisplay, EGLSurface);
static PFN_eglSwapBuffers orig_eglSwapBuffers = nullptr;

static EGLBoolean hook_eglSwapBuffers(EGLDisplay display, EGLSurface surface) {
    if (!g_imgui_init) {
        EGLint w = 1080, h = 1920;
        eglQuerySurface(display, surface, EGL_WIDTH,  &w);
        eglQuerySurface(display, surface, EGL_HEIGHT, &h);
        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io  = ImGui::GetIO();
        io.DisplaySize = ImVec2((float)w, (float)h);
        io.IniFilename = nullptr;
        ImGui::StyleColorsDark();
        ImGui_ImplOpenGL3_Init("#version 100");
        g_imgui_init = true;
        LOGI("ImGui init %dx%d", w, h);
    }

    {
        pthread_mutex_lock(&g_touch_mu);
        TouchEvent te = g_touch;
        g_touch.action = -1;
        pthread_mutex_unlock(&g_touch_mu);
        if (te.action >= 0) {
            ImGuiIO& io   = ImGui::GetIO();
            io.MousePos   = ImVec2(te.x, te.y);
            io.MouseDown[0] = (te.action == AMOTION_EVENT_ACTION_DOWN ||
                               te.action == AMOTION_EVENT_ACTION_MOVE);
        }
    }

    ImGui_ImplOpenGL3_NewFrame();
    ImGui::NewFrame();

    if (g_menu_open) {
        ImGui::SetNextWindowSize(ImVec2(340.f, 60.f + kPatchCount * 28.f), ImGuiCond_Once);
        ImGui::SetNextWindowPos(ImVec2(20.f, 120.f), ImGuiCond_Once);
        ImGui::Begin("Taurus Shield", &g_menu_open,
                     ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoCollapse);
        for (int i = 0; i < kPatchCount; i++) {
            Patch& p = g_patches[i];
            if (ImGui::Checkbox(p.name, &p.enabled))
                p.enabled ? apply_patch(p) : revert_patch(p);
        }
        ImGui::End();
    }

    ImGui::Render();
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
    return orig_eglSwapBuffers(display, surface);
}

// ──────────────────────────────────────────────────────────────────────────────
//  AInputQueue_getEvent hook
// ──────────────────────────────────────────────────────────────────────────────
typedef int (*PFN_AInputQueue_getEvent)(AInputQueue*, AInputEvent**);
static PFN_AInputQueue_getEvent orig_AInputQueue_getEvent = nullptr;

static int hook_AInputQueue_getEvent(AInputQueue* queue, AInputEvent** event) {
    int r = orig_AInputQueue_getEvent(queue, event);
    if (r >= 0 && *event &&
        AInputEvent_getType(*event) == AINPUT_EVENT_TYPE_MOTION) {
        int action = AMotionEvent_getAction(*event) & AMOTION_EVENT_ACTION_MASK;
        pthread_mutex_lock(&g_touch_mu);
        g_touch = { AMotionEvent_getX(*event, 0), AMotionEvent_getY(*event, 0), action };
        pthread_mutex_unlock(&g_touch_mu);
    }
    return r;
}

// ──────────────────────────────────────────────────────────────────────────────
//  /proc/self/maps helper
// ──────────────────────────────────────────────────────────────────────────────
static uintptr_t find_lib_base(const char* name) {
    char line[512];
    FILE* f = fopen("/proc/self/maps", "r");
    if (!f) return 0;
    uintptr_t base = 0;
    while (fgets(line, (int)sizeof(line), f)) {
        if (strstr(line, name) && strstr(line, "r-xp")) {
            base = (uintptr_t)strtoull(line, nullptr, 16);
            break;
        }
    }
    fclose(f);
    return base;
}

// ──────────────────────────────────────────────────────────────────────────────
//  Background setup thread
// ──────────────────────────────────────────────────────────────────────────────
static void* setup_thread(void*) {
    for (int i = 0; i < 400 && !g_il2cpp_base; i++) {
        g_il2cpp_base = find_lib_base("libil2cpp.so");
        if (!g_il2cpp_base) usleep(50000);
    }
    LOGI(g_il2cpp_base ? "il2cpp base 0x%lX" : "il2cpp NOT found", g_il2cpp_base);

    bool ok = false;
    for (int i = 0; i < 400 && !ok; i++) {
        if (find_lib_base("libunity.so")) {
            xhook_enable_sigsegv_protection(1);
            xhook_register(".*\\.so$", "eglSwapBuffers",
                           (void*)hook_eglSwapBuffers,
                           (void**)&orig_eglSwapBuffers);
            xhook_register(".*\\.so$", "AInputQueue_getEvent",
                           (void*)hook_AInputQueue_getEvent,
                           (void**)&orig_AInputQueue_getEvent);
            if (xhook_refresh(0) == 0 && orig_eglSwapBuffers) {
                LOGI("xhook OK — egl=%p ainput=%p",
                     (void*)orig_eglSwapBuffers,
                     (void*)orig_AInputQueue_getEvent);
                ok = true;
            } else {
                xhook_clear();
            }
        }
        if (!ok) usleep(50000);
    }
    if (!ok) LOGE("xhook FAILED after 20 s");
    return nullptr;
}

__attribute__((constructor))
static void onLoad() {
    LOGI("libmatrix-hook.so loaded");
    pthread_t t;
    if (pthread_create(&t, nullptr, setup_thread, nullptr) == 0)
        pthread_detach(t);
}
