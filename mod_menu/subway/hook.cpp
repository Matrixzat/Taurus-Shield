/**
 * Taurus Shield — libmatrix-hook.so
 * Subway Surfers 3.62.1 | ARM64
 *
 * Architecture (learned from reverse-engineering libLITEAPKS.COM.so):
 *   - Dobby for reliable function-level hooks (same framework they use)
 *   - eglSwapBuffers hook → ImGui rendered directly on the GL surface
 *   - AInputQueue_getEvent hook → touch fed into ImGui (no Java overlay needed)
 *   - dl_iterate_phdr for libil2cpp.so base (APK-loaded or extracted)
 */

#include <android/log.h>
#include <android/input.h>
#include <dlfcn.h>
#include <jni.h>
#include <link.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

// EGL / GLES2
#include <EGL/egl.h>
#include <GLES2/gl2.h>

// Dobby hook framework
#include "dobby.h"

// ImGui with GLES2 backend
#define IMGUI_IMPL_OPENGL_ES2
#include "imgui.h"
#include "backends/imgui_impl_opengl3.h"

#define TAG  "matrix-hook"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ── Library base (dl_iterate_phdr — works for APK-loaded libs) ────────────────
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

// ── ARM64 patch byte builders ─────────────────────────────────────────────────
static inline uint32_t movz_w0(uint16_t v)      { return 0x52800000u | ((uint32_t)v << 5); }
static inline uint32_t movk_w0_lsl16(uint16_t v) { return 0x72A00000u | ((uint32_t)v << 5); }
static constexpr uint32_t RET_INSN  = 0xD65F03C0u;
static constexpr uint32_t FMOV_S0W0 = 0x1E270000u;

static int buildBoolPatch (bool v,    uint32_t out[4]) { out[0]=movz_w0(v?1:0); out[1]=RET_INSN; return 2; }
static int buildVoidPatch (          uint32_t out[4]) { out[0]=RET_INSN; return 1; }
static int buildInt32Patch(uint32_t v, uint32_t out[4]) {
    out[0]=movz_w0((uint16_t)(v&0xFFFF)); out[1]=movk_w0_lsl16((uint16_t)(v>>16)); out[2]=RET_INSN; return 3;
}
static int buildFloatPatch(float v, uint32_t out[4]) {
    uint32_t bits; memcpy(&bits,&v,4);
    out[0]=movz_w0((uint16_t)(bits&0xFFFF)); out[1]=movk_w0_lsl16((uint16_t)(bits>>16));
    out[2]=FMOV_S0W0; out[3]=RET_INSN; return 4;
}

// ── Feature definition ────────────────────────────────────────────────────────
struct SubPatch {
    uintptr_t offset;
    uint32_t  newInsns[4];
    int       nNew;
    uint32_t  origInsns[4];
    bool      origSaved;
};
struct Feature {
    const char* name;
    bool        enabled;
    int         nSub;
    SubPatch    subs[5];
};
static Feature gFeatures[8];

static void initFeatures() {
    uint32_t tmp[4];
    // 0 — No Ads
    gFeatures[0] = { "No Ads", true, 3, {} };
    { auto& s=gFeatures[0].subs[0]; s.offset=0x1043C64; s.nNew=buildVoidPatch(tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[0].subs[1]; s.offset=0x1150264; s.nNew=buildVoidPatch(tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[0].subs[2]; s.offset=0x3247894; s.nNew=buildBoolPatch(false,tmp); memcpy(s.newInsns,tmp,s.nNew*4); }

    // 1 — Coins x999999
    gFeatures[1] = { "Coins x999,999", true, 2, {} };
    { auto& s=gFeatures[1].subs[0]; s.offset=0x158EF98; s.nNew=buildInt32Patch(999999,tmp); memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[1].subs[1]; s.offset=0x32B4820; s.nNew=buildInt32Patch(999999,tmp); memcpy(s.newInsns,tmp,s.nNew*4); }

    // 2 — Jump x100 / 3x Height
    gFeatures[2] = { "Jump x100 / 3x Height", true, 2, {} };
    { auto& s=gFeatures[2].subs[0]; s.offset=0xF9EFD4; s.nNew=buildInt32Patch(100,tmp);   memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[2].subs[1]; s.offset=0xF9EFF4; s.nNew=buildFloatPatch(3.0f,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }

    // 3 — Speed x5
    gFeatures[3] = { "Speed x5", true, 3, {} };
    { auto& s=gFeatures[3].subs[0]; s.offset=0xF9F454; s.nNew=buildFloatPatch(5.0f,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[3].subs[1]; s.offset=0xF9F624; s.nNew=buildFloatPatch(5.0f,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[3].subs[2]; s.offset=0xF9F3C8; s.nNew=buildBoolPatch(true,tmp);   memcpy(s.newInsns,tmp,s.nNew*4); }

    // 4 — Low Gravity
    gFeatures[4] = { "Low Gravity (0.5x)", true, 2, {} };
    { auto& s=gFeatures[4].subs[0]; s.offset=0xF9F48C; s.nNew=buildFloatPatch(0.5f,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[4].subs[1]; s.offset=0xF9F674; s.nNew=buildFloatPatch(0.5f,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }

    // 5 — Powerups always on
    gFeatures[5] = { "Powerups Always On", true, 3, {} };
    { auto& s=gFeatures[5].subs[0]; s.offset=0xFC2538; s.nNew=buildBoolPatch(true,tmp);   memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[5].subs[1]; s.offset=0xFC2548; s.nNew=buildBoolPatch(true,tmp);   memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[5].subs[2]; s.offset=0xFC2578; s.nNew=buildBoolPatch(true,tmp);   memcpy(s.newInsns,tmp,s.nNew*4); }

    // 6 — Score Booster Max
    gFeatures[6] = { "Score Booster Max", true, 4, {} };
    { auto& s=gFeatures[6].subs[0]; s.offset=0x13918C4; s.nNew=buildBoolPatch(true,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[6].subs[1]; s.offset=0x13919DC; s.nNew=buildBoolPatch(true,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[6].subs[2]; s.offset=0x1392030; s.nNew=buildInt32Patch(5,tmp);    memcpy(s.newInsns,tmp,s.nNew*4); }
    { auto& s=gFeatures[6].subs[3]; s.offset=0x1021B20; s.nNew=buildBoolPatch(true,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }

    // 7 — Unlimited Revive
    gFeatures[7] = { "Unlimited Revive", true, 1, {} };
    { auto& s=gFeatures[7].subs[0]; s.offset=0x13D570C; s.nNew=buildBoolPatch(true,tmp);  memcpy(s.newInsns,tmp,s.nNew*4); }
}

// ── Apply / Revert via Dobby DobbyCodePatch ───────────────────────────────────
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
        DobbyCodePatch((void*)addr, (uint8_t*)sp.newInsns, (size_t)sp.nNew * 4);
    }
    LOGI("Feature[%d] '%s' ON", idx, f.name);
}

static void revertFeature(int idx) {
    if (!gBase) return;
    Feature& f = gFeatures[idx];
    for (int s = 0; s < f.nSub; s++) {
        SubPatch& sp = f.subs[s];
        if (sp.origSaved) {
            DobbyCodePatch((void*)(gBase + sp.offset), (uint8_t*)sp.origInsns, (size_t)sp.nNew * 4);
        }
    }
    LOGI("Feature[%d] '%s' OFF", idx, f.name);
}

static void applyAllEnabled() {
    for (int i = 0; i < 8; i++) {
        if (gFeatures[i].enabled) applyFeature(i);
    }
}

// ── Touch state (written by input hook, read on GL thread) ────────────────────
static pthread_mutex_t gTouchMtx  = PTHREAD_MUTEX_INITIALIZER;
static float           gTouchX    = -1.0f;
static float           gTouchY    = -1.0f;
static bool            gTouchDown = false;
static bool            gTouchNew  = false;   // new event flag

// ── AInputQueue_getEvent hook (for touch → ImGui) ────────────────────────────
typedef int32_t (*AInputQueue_getEvent_t)(AInputQueue*, AInputEvent**);
static AInputQueue_getEvent_t orig_AInputQueue_getEvent = nullptr;

static int32_t hook_AInputQueue_getEvent(AInputQueue* queue, AInputEvent** outEvent) {
    int32_t r = orig_AInputQueue_getEvent(queue, outEvent);
    if (r >= 0 && outEvent && *outEvent) {
        if (AInputEvent_getType(*outEvent) == AINPUT_EVENT_TYPE_MOTION) {
            int32_t action = AMotionEvent_getAction(*outEvent) & AMOTION_EVENT_ACTION_MASK;
            float x = AMotionEvent_getX(*outEvent, 0);
            float y = AMotionEvent_getY(*outEvent, 0);
            pthread_mutex_lock(&gTouchMtx);
            gTouchX    = x;
            gTouchY    = y;
            gTouchDown = (action == AMOTION_EVENT_ACTION_DOWN || action == AMOTION_EVENT_ACTION_MOVE);
            gTouchNew  = true;
            pthread_mutex_unlock(&gTouchMtx);
        }
    }
    return r;
}

// ── ImGui / eglSwapBuffers state ──────────────────────────────────────────────
static bool gImguiReady   = false;
static bool gMenuVisible  = false;
static int  gScreenW      = 1080;
static int  gScreenH      = 1920;

typedef EGLBoolean (*eglSwapBuffers_t)(EGLDisplay, EGLSurface);
static eglSwapBuffers_t orig_eglSwapBuffers = nullptr;

static EGLBoolean hook_eglSwapBuffers(EGLDisplay dpy, EGLSurface surface) {
    // ── One-time init ─────────────────────────────────────────────────────────
    if (!gImguiReady) {
        EGLint w = 0, h = 0;
        eglQuerySurface(dpy, surface, EGL_WIDTH,  &w);
        eglQuerySurface(dpy, surface, EGL_HEIGHT, &h);
        if (w > 0) gScreenW = w;
        if (h > 0) gScreenH = h;

        IMGUI_CHECKVERSION();
        ImGui::CreateContext();
        ImGuiIO& io = ImGui::GetIO();
        io.DisplaySize      = ImVec2((float)gScreenW, (float)gScreenH);
        io.IniFilename      = nullptr;
        io.LogFilename      = nullptr;

        // Scale UI for mobile — base on the shorter axis
        float base = (float)(gScreenW < gScreenH ? gScreenW : gScreenH);
        float scale = base / 540.0f;
        io.FontGlobalScale = scale;

        ImGui_ImplOpenGL3_Init("#version 100");

        ImGuiStyle& style = ImGui::GetStyle();
        style.WindowRounding   = 8.0f  * scale;
        style.FrameRounding    = 5.0f  * scale;
        style.ScrollbarRounding= 5.0f  * scale;
        style.GrabRounding     = 5.0f  * scale;
        style.ItemSpacing      = ImVec2(8*scale, 8*scale);
        style.FramePadding     = ImVec2(8*scale, 6*scale);
        style.WindowPadding    = ImVec2(12*scale, 12*scale);
        style.ScrollbarSize    = 18*scale;
        style.GrabMinSize      = 16*scale;

        // Taurus Shield colour theme
        ImVec4* c = style.Colors;
        c[ImGuiCol_WindowBg]         = ImVec4(0.05f, 0.05f, 0.05f, 0.92f);
        c[ImGuiCol_TitleBg]          = ImVec4(0.00f, 0.30f, 0.15f, 1.00f);
        c[ImGuiCol_TitleBgActive]    = ImVec4(0.00f, 0.42f, 0.22f, 1.00f);
        c[ImGuiCol_Button]           = ImVec4(0.00f, 0.35f, 0.18f, 1.00f);
        c[ImGuiCol_ButtonHovered]    = ImVec4(0.00f, 0.50f, 0.26f, 1.00f);
        c[ImGuiCol_ButtonActive]     = ImVec4(0.00f, 0.25f, 0.13f, 1.00f);
        c[ImGuiCol_CheckMark]        = ImVec4(0.00f, 1.00f, 0.55f, 1.00f);
        c[ImGuiCol_FrameBg]          = ImVec4(0.10f, 0.10f, 0.10f, 1.00f);
        c[ImGuiCol_FrameBgHovered]   = ImVec4(0.15f, 0.25f, 0.18f, 1.00f);
        c[ImGuiCol_FrameBgActive]    = ImVec4(0.08f, 0.18f, 0.12f, 1.00f);
        c[ImGuiCol_Header]           = ImVec4(0.00f, 0.30f, 0.15f, 1.00f);
        c[ImGuiCol_HeaderHovered]    = ImVec4(0.00f, 0.42f, 0.22f, 1.00f);
        c[ImGuiCol_HeaderActive]     = ImVec4(0.00f, 0.22f, 0.11f, 1.00f);
        c[ImGuiCol_SliderGrab]       = ImVec4(0.00f, 0.80f, 0.42f, 1.00f);
        c[ImGuiCol_SliderGrabActive] = ImVec4(0.00f, 1.00f, 0.55f, 1.00f);
        c[ImGuiCol_Separator]        = ImVec4(0.00f, 0.45f, 0.22f, 0.80f);
        c[ImGuiCol_ScrollbarBg]      = ImVec4(0.05f, 0.05f, 0.05f, 0.80f);
        c[ImGuiCol_ScrollbarGrab]    = ImVec4(0.00f, 0.40f, 0.20f, 1.00f);
        c[ImGuiCol_Tab]              = ImVec4(0.00f, 0.25f, 0.13f, 1.00f);
        c[ImGuiCol_TabActive]        = ImVec4(0.00f, 0.45f, 0.24f, 1.00f);

        gImguiReady = true;
        LOGI("ImGui ready — screen %dx%d  scale=%.2f", gScreenW, gScreenH, (double)scale);
    }

    // ── Feed touch events into ImGui ──────────────────────────────────────────
    {
        pthread_mutex_lock(&gTouchMtx);
        if (gTouchNew) {
            ImGuiIO& io = ImGui::GetIO();
            io.AddMousePosEvent(gTouchX, gTouchY);
            io.AddMouseButtonEvent(0, gTouchDown);
            gTouchNew = false;
        } else if (!gTouchDown) {
            // Reset mouse button when not touching
            ImGui::GetIO().AddMouseButtonEvent(0, false);
        }
        pthread_mutex_unlock(&gTouchMtx);
    }

    // ── Draw UI ───────────────────────────────────────────────────────────────
    ImGui_ImplOpenGL3_NewFrame();
    ImGui::NewFrame();

    float scale = (float)(gScreenW < gScreenH ? gScreenW : gScreenH) / 540.0f;

    // ── Always-visible MOD trigger button (top-right) ─────────────────────────
    float btnW = 90 * scale, btnH = 40 * scale;
    ImGui::SetNextWindowPos(ImVec2(gScreenW - btnW - 10*scale, 70*scale),
                            ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(btnW, btnH), ImGuiCond_Always);
    ImGui::SetNextWindowBgAlpha(0.85f);
    ImGui::Begin("##fab", nullptr,
        ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
        ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoMove  |
        ImGuiWindowFlags_NoSavedSettings);
    ImGui::PushStyleColor(ImGuiCol_Button,
        gMenuVisible ? ImVec4(0.6f,0.05f,0.05f,1) : ImVec4(0,0.4f,0.2f,1));
    if (ImGui::Button(gMenuVisible ? "X CLOSE" : "* MOD", ImVec2(-1, -1)))
        gMenuVisible = !gMenuVisible;
    ImGui::PopStyleColor();
    ImGui::End();

    // ── Main mod menu panel ───────────────────────────────────────────────────
    if (gMenuVisible) {
        float panelW = 320 * scale;
        float panelH = 480 * scale;
        ImGui::SetNextWindowPos(ImVec2(gScreenW - panelW - 10*scale, 120*scale),
                                ImGuiCond_Once);
        ImGui::SetNextWindowSize(ImVec2(panelW, panelH), ImGuiCond_Once);
        ImGui::Begin("TAURUS SHIELD", &gMenuVisible,
            ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings);

        ImGui::TextColored(ImVec4(0,1,0.55f,1), "Subway Surfers 3.62.1");
        ImGui::TextColored(ImVec4(0.5f,0.5f,0.5f,1), "libmatrix-hook  |  %d features",
                           8);
        ImGui::Separator();
        ImGui::Spacing();

        for (int i = 0; i < 8; i++) {
            bool prev = gFeatures[i].enabled;
            ImGui::PushID(i);
            if (ImGui::Checkbox(gFeatures[i].name, &gFeatures[i].enabled)) {
                if (gFeatures[i].enabled) applyFeature(i);
                else                       revertFeature(i);
            }
            ImGui::PopID();
        }

        ImGui::Spacing();
        ImGui::Separator();
        ImGui::Spacing();

        // Quick-action buttons
        if (ImGui::Button("Enable All",  ImVec2(-1, 35*scale))) {
            for (int i = 0; i < 8; i++) { gFeatures[i].enabled = true; applyFeature(i); }
        }
        if (ImGui::Button("Disable All", ImVec2(-1, 35*scale))) {
            for (int i = 0; i < 8; i++) { gFeatures[i].enabled = false; revertFeature(i); }
        }

        ImGui::Spacing();
        ImGui::TextColored(ImVec4(0.3f,0.3f,0.3f,1), "Base: 0x%lX", (unsigned long)gBase);

        ImGui::End();
    }

    ImGui::Render();
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());

    return orig_eglSwapBuffers(dpy, surface);
}

// ── Constructor ───────────────────────────────────────────────────────────────
__attribute__((constructor))
static void onLoad() {
    LOGI("matrix-hook loaded — Dobby %s", DobbyGetVersion());

    // 1) Init feature table
    initFeatures();

    // 2) Find libil2cpp.so base — wait up to 5 s
    for (int i = 0; i < 100 && !gBase; i++) {
        gBase = getLibBase("libil2cpp.so");
        if (!gBase) usleep(50000);
    }
    if (!gBase) {
        LOGE("libil2cpp.so not found — patches skipped");
    } else {
        LOGI("libil2cpp base: 0x%lX", (unsigned long)gBase);
        applyAllEnabled();
    }

    // 3) Hook eglSwapBuffers — find via EGL library
    void* libegl = dlopen("libEGL.so", RTLD_NOW | RTLD_GLOBAL);
    if (libegl) {
        void* fn = dlsym(libegl, "eglSwapBuffers");
        if (fn) {
            DobbyHook(fn, (void*)hook_eglSwapBuffers, (void**)&orig_eglSwapBuffers);
            LOGI("eglSwapBuffers hooked");
        } else {
            LOGE("eglSwapBuffers symbol not found");
        }
    } else {
        LOGE("libEGL.so dlopen failed: %s", dlerror());
    }

    // 4) Hook AInputQueue_getEvent — find in libandroid.so
    void* libandroid = dlopen("libandroid.so", RTLD_NOW | RTLD_GLOBAL);
    if (libandroid) {
        void* fn = dlsym(libandroid, "AInputQueue_getEvent");
        if (fn) {
            DobbyHook(fn, (void*)hook_AInputQueue_getEvent,
                      (void**)&orig_AInputQueue_getEvent);
            LOGI("AInputQueue_getEvent hooked");
        } else {
            LOGE("AInputQueue_getEvent symbol not found");
        }
    } else {
        LOGE("libandroid.so dlopen failed: %s", dlerror());
    }
}
