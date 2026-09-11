// hyprcrt - a system-wide CRT filter for Hyprland. Plugin entry point.
// MIT (c) 2026 Dan Expo. Hyprland is BSD-3-Clause (c) vaxerski.
#define WLR_USE_UNSTABLE
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/gl/GLFramebuffer.hpp>
#include <hyprland/src/render/pass/PassElement.hpp>
#include <hyprland/src/render/transformer/Transformer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/view/WLSurface.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/protocols/core/Compositor.hpp>
#include <hyprland/src/protocols/types/ContentType.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/FloatValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>
#include <hyprland/src/debug/log/Logger.hpp>
#include <hyprutils/signal/Signal.hpp>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

#include <filesystem>
#include <format>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <regex>
#include <sstream>
#include <unordered_map>
#include <vector>
#include <unistd.h>

#include "Chain.hpp"
#include "Look.hpp"

#define HYPRCRT_VERSION "0.2.0"

inline HANDLE PHANDLE = nullptr;

using namespace Hyprutils::Signal;
using Render::GL::g_pHyprOpenGL;

// ------------------------------------------------------------------------------------------------ state

struct SConfig {
    SP<Config::Values::CBoolValue>   enabled;
    SP<Config::Values::CStringValue> preset;
    SP<Config::Values::CIntValue>    curve, lines, mask, glow, gamma, sharp, pitch, pitchFullscreen, maskPitch, glowFrames;
    SP<Config::Values::CFloatValue>  gain;
    SP<Config::Values::CBoolValue>   textsafe, haloHalf, blockScanout, capture, stats, lowPower;
    SP<Config::Values::CStringValue> scope, match, media, monitors, shaderDir;
};

struct SMonitorState {
    CCrtChain chain;
    bool      active        = false; // in scope this frame
    bool      selfScheduled = false; // we asked for the next frame (afterglow decay)
    int       glowFrames    = 0;
    int       pitch         = 1;
    SLook     look;
    bool      failed = false;
};

class CCrtTransformer;

struct SWindowState {
    PHLWINDOWREF     window;
    CCrtTransformer* transformer = nullptr;
};

struct SState {
    SConfig                                   cfg;
    std::map<std::string, std::string>        overrides; // hyprctl crt set ..., and the state file on top at every config reload
    std::unordered_map<MONITORID, UP<SMonitorState>> monitors;
    std::vector<SWindowState>                 windows;
    std::vector<CHyprSignalListener>          listeners;
    SP<SHyprCtlCommand>                       ctl;
    bool                                      runtimeEnabled = true; // crt:toggle
    bool                                      bypass         = false; // crt:bypass, hold-to-compare: off without forgetting anything
    bool                                      weBlockedScanout = false;
    std::string                               shaderDir;
    std::string                               lastError;
    std::string                               dumpPath; // crt dump <file.ppm>: write the next filtered frame
    std::string                               loadedMarker; // written while we are loaded, removed on a clean exit (crash-loop guard)
    struct {
        std::string pattern;
        std::regex  re;
        bool        ok = false;
    } matchRe, mediaRe;
};

inline UP<SState> g_state;

// ------------------------------------------------------------------------------------------------ helpers

static std::string expandHome(std::string path) {
    if (path.starts_with("~/")) {
        const char* home = getenv("HOME");
        if (home)
            path = std::string(home) + path.substr(1);
    }
    return path;
}

static std::string defaultShaderDir() {
    if (const char* d = getenv("HYPRCRT_SHADERS"); d && *d)
        return d;
    if (const char* x = getenv("XDG_DATA_HOME"); x && *x)
        return std::string(x) + "/hyprcrt/shaders";
    return expandHome("~/.local/share/hyprcrt/shaders");
}

static std::string ov(const std::string& key, const std::string& fallback) {
    auto it = g_state->overrides.find(key);
    return it == g_state->overrides.end() ? fallback : it->second;
}

static int ovInt(const std::string& key, int fallback) {
    auto it = g_state->overrides.find(key);
    if (it == g_state->overrides.end())
        return fallback;
    try {
        return std::stoi(it->second);
    } catch (...) { return fallback; }
}

static float ovFloat(const std::string& key, float fallback) {
    auto it = g_state->overrides.find(key);
    if (it == g_state->overrides.end())
        return fallback;
    try {
        return std::stof(it->second);
    } catch (...) { return fallback; }
}

static bool ovBool(const std::string& key, bool fallback) {
    auto it = g_state->overrides.find(key);
    if (it == g_state->overrides.end())
        return fallback;
    const auto& v = it->second;
    return v == "1" || v == "true" || v == "on" || v == "yes";
}

static bool enabled() {
    return g_state->runtimeEnabled && !g_state->bypass && ovBool("enabled", g_state->cfg.enabled->value());
}

static bool lowPower() {
    return ovBool("low_power", g_state->cfg.lowPower->value());
}

// halation/afterglow resolution and the afterglow decay budget, with the low-power profile applied
static bool haloHalfNow() {
    return lowPower() || ovBool("halo_half", g_state->cfg.haloHalf->value());
}

static int glowFramesNow() {
    const int n = ovInt("glow_frames", g_state->cfg.glowFrames->value());
    return lowPower() ? std::min(n, 4) : n;
}

static std::string currentPreset() {
    return ov("preset", g_state->cfg.preset->value());
}

static SKnobs effectiveKnobs() {
    SKnobs k;
    const auto& c = g_state->cfg;
    k.curve       = c.curve->value();
    k.lines       = c.lines->value();
    k.mask        = c.mask->value();
    k.glow        = c.glow->value();
    k.gamma       = c.gamma->value();
    k.sharp       = c.sharp->value();
    const auto preset = currentPreset();
    if (preset != "custom")
        applyPreset(preset, k); // a named preset overrides the six config knobs
    k.curve     = ovInt("curve", k.curve);
    k.lines     = ovInt("lines", k.lines);
    k.mask      = ovInt("mask", k.mask);
    k.glow      = ovInt("glow", k.glow);
    k.gamma     = ovInt("gamma", k.gamma);
    k.sharp     = ovInt("sharp", k.sharp);
    k.maskPitch = ovInt("mask_pitch", c.maskPitch->value());
    k.gain      = ovFloat("gain", c.gain->value());
    k.textsafe  = ovBool("textsafe", c.textsafe->value());
    return k;
}

static std::string scopeMode() {
    return ov("scope", g_state->cfg.scope->value());
}

static bool monitorListed(PHLMONITOR m) {
    const auto list = ov("monitors", g_state->cfg.monitors->value());
    if (list.empty())
        return true;
    std::stringstream ss(list);
    std::string       item;
    while (std::getline(ss, item, ',')) {
        while (!item.empty() && item.front() == ' ')
            item.erase(item.begin());
        while (!item.empty() && item.back() == ' ')
            item.pop_back();
        if (item == m->m_name)
            return true;
    }
    return false;
}

static bool windowMatchesPattern(PHLWINDOW w, const std::string& pattern, decltype(SState::matchRe)& cache) {
    if (pattern.empty() || !w)
        return false;
    if (cache.pattern != pattern || !cache.ok) {
        cache.pattern = pattern;
        try {
            cache.re = std::regex(pattern, std::regex::ECMAScript | std::regex::icase);
            cache.ok = true;
        } catch (...) {
            cache.ok = false;
            return false;
        }
    }
    return std::regex_search(w->m_class, cache.re) || std::regex_search(w->m_initialClass, cache.re) || std::regex_search(w->m_title, cache.re);
}

// scope rules / window: the user's own regex
static bool windowMatches(PHLWINDOW w) {
    return windowMatchesPattern(w, ov("match", g_state->cfg.match->value()), g_state->matchRe);
}

// scope auto: a windowed media player or emulator is a picture too
static bool windowIsMedia(PHLWINDOW w) {
    return windowMatchesPattern(w, ov("media", g_state->cfg.media->value()), g_state->mediaRe);
}

static bool windowFullscreen(PHLWINDOW w) {
    return w && Fullscreen::controller()->isFullscreen(w);
}

// the integer factor a fullscreen window's buffer is scaled by, when it is an integer, else 0
static int windowIntegerFactor(PHLWINDOW w, PHLMONITOR m) {
    if (!w || !w->wlSurface() || !w->wlSurface()->resource())
        return 0;
    const auto& size = w->wlSurface()->resource()->m_current.bufferSize;
    if (size.y < 1)
        return 0;
    const double f  = m->m_pixelSize.y / size.y;
    const int    fi = static_cast<int>(std::lround(f));
    if (fi >= 1 && fi <= 8 && std::abs(f - fi) < 0.02)
        return fi;
    return 0;
}

// is this monitor filtered this frame, at what pitch, and is it the plain desktop (text-safe applies)?
static bool monitorInScope(PHLMONITOR m, int& pitch, bool& desktop) {
    if (!enabled() || !m || !monitorListed(m))
        return false;
    const auto mode = scopeMode();
    if (mode == "off" || mode == "window")
        return false;

    const auto FS = Fullscreen::controller()->getFullscreenWindow(m);
    bool       in = false;
    if (mode == "all")
        in = true;
    else if (mode == "fullscreen" || mode == "auto") // auto: fullscreen here, windowed media players through their own transformer
        in = FS != nullptr;
    else if (mode == "games")
        in = FS && FS->getContentType() == NContentType::CONTENT_TYPE_GAME;
    else if (mode == "rules")
        in = FS && windowMatches(FS);
    if (!in)
        return false;

    desktop            = FS == nullptr;
    const int cfgPitch = ovInt("pitch", g_state->cfg.pitch->value());
    if (cfgPitch > 0)
        pitch = std::clamp(cfgPitch, 1, 8);
    else if (FS) {
        // a game scaled by an integer gets its own factor; video and browsers get the "480-line tube" pitch
        const int f = windowIntegerFactor(FS, m);
        pitch       = f > 1 ? f : std::clamp(ovInt("pitch_fullscreen", g_state->cfg.pitchFullscreen->value()), 1, 8);
    } else
        pitch = 1;
    return true;
}

static SMonitorState& stateFor(PHLMONITOR m) {
    auto& p = g_state->monitors[m->m_id];
    if (!p)
        p = makeUnique<SMonitorState>();
    return *p;
}

static void notify(const std::string& text, bool error = false) {
    HyprlandAPI::addNotification(PHANDLE, "[hyprcrt] " + text, error ? CHyprColor{1.0, 0.3, 0.3, 1.0} : CHyprColor{0.6, 0.9, 0.6, 1.0}, error ? 8000 : 3000);
    if (error)
        g_state->lastError = text;
    Log::logger->log(error ? Log::ERR : Log::INFO, "[hyprcrt] {}", text);
}

static bool ensureShaders(CCrtChain& chain) {
    if (chain.shadersLoaded())
        return true;
    std::string err;
    if (!chain.loadShaders(g_state->shaderDir, err)) {
        notify("shader load failed: " + err, true);
        return false;
    }
    chain.setTiming(g_state->cfg.stats->value());
    return true;
}

static void updateScanoutBlock() {
    static auto PDS = CConfigValue<Config::INTEGER>("render:direct_scanout");
    const bool  want = enabled() && ovBool("block_scanout", g_state->cfg.blockScanout->value()) && *PDS != 0 && scopeMode() != "off";
    if (want && !g_state->weBlockedScanout) {
        g_pHyprRenderer->m_directScanoutBlocked = true;
        g_state->weBlockedScanout               = true;
    } else if (!want && g_state->weBlockedScanout) {
        g_pHyprRenderer->m_directScanoutBlocked = false;
        g_state->weBlockedScanout               = false;
    }
}

static void damageAll() {
    for (auto& m : State::monitorState()->monitors())
        g_pHyprRenderer->damageMonitor(m);
}

// The chain switches blend, scissor and stencil off with plain glDisable(). Hyprland caches those three
// in setCapStatus() and skips the GL call when its cache already agrees, so switch them off through
// Hyprland first (cache and GL state then match what the chain leaves behind) and switch blend back on
// through Hyprland after, which now really re-enables it.
static void glStateBeforeChain() {
    g_pHyprOpenGL->blend(false);
    g_pHyprOpenGL->scissor(nullptr);
    g_pHyprOpenGL->setCapStatus(GL_STENCIL_TEST, false);
}

static void glStateAfterChain() {
    g_pHyprOpenGL->blend(true);
}

// ------------------------------------------------------------------------------------------------ the pass element

class CCrtPassElement : public IPassElement {
  public:
    CCrtPassElement(PHLMONITORREF m) : m_monitor(m) {}
    virtual ~CCrtPassElement() = default;

    virtual std::vector<UP<IPassElement>> draw() override {
        const auto m = m_monitor.lock();
        if (!m || !g_state)
            return {};
        auto&      st     = stateFor(m);
        const auto mainFB = g_pHyprRenderer->m_renderData.mainFB;
        if (!mainFB || !mainFB->getTexture() || st.failed)
            return {};
        if (!ensureShaders(st.chain)) {
            st.failed = true;
            return {};
        }
        const int  W  = static_cast<int>(m->m_pixelSize.x);
        const int  H  = static_cast<int>(m->m_pixelSize.y);
        glStateBeforeChain();
        const bool ok = st.chain.run(mainFB->getTexture()->m_texID, W, H, st.look, st.pitch, haloHalfNow(), 0, [mainFB] { g_pHyprRenderer->bindFB(mainFB); });
        glStateAfterChain();
        if (!ok) {
            st.failed = true;
            notify("GL error while filtering " + m->m_name + " (" + st.chain.lastError() + "); filter disabled on this output until reload", true);
        } else if (!g_state->dumpPath.empty()) {
            // the filtered frame straight out of the main FB (what the screen gets), as a P6 ppm
            // glReadPixels reads the READ binding, which the chain left on one of its own targets
            if (auto* glfb = dynamic_cast<Render::GL::CGLFramebuffer*>(mainFB.get()))
                glBindFramebuffer(GL_READ_FRAMEBUFFER, glfb->getFBID());
            while (glGetError() != GL_NO_ERROR) {}
            std::vector<unsigned char> px(static_cast<size_t>(W) * H * 4);
            glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px.data());
            if (glGetError() != GL_NO_ERROR) { // a float main buffer (HDR / fp16): read floats and quantise
                std::vector<float> fpx(static_cast<size_t>(W) * H * 4);
                glReadPixels(0, 0, W, H, GL_RGBA, GL_FLOAT, fpx.data());
                for (size_t i = 0; i < fpx.size(); i++)
                    px[i] = static_cast<unsigned char>(std::clamp(fpx[i], 0.f, 1.f) * 255.f + 0.5f);
            }
            // written beside the target and renamed into place, so a reader (hyprcrt shot) that starts as soon
            // as the file is non-empty never sees a partial frame
            const std::string tmpPath = g_state->dumpPath + ".tmp";
            if (FILE* f = fopen(tmpPath.c_str(), "wb")) {
                fprintf(f, "P6\n%d %d\n255\n", W, H);
                for (int y = 0; y < H; y++)
                    for (int x = 0; x < W; x++)
                        fwrite(&px[(static_cast<size_t>(y) * W + x) * 4], 1, 3, f);
                fclose(f);
                if (rename(tmpPath.c_str(), g_state->dumpPath.c_str()) == 0)
                    notify("dumped " + g_state->dumpPath);
                else {
                    notify("cannot write " + g_state->dumpPath, true);
                    std::filesystem::remove(tmpPath);
                }
            } else
                notify("cannot write " + g_state->dumpPath, true);
            g_state->dumpPath.clear();
        }
        return {};
    }

    virtual bool needsLiveBlur() override {
        return false;
    }
    virtual bool needsPrecomputeBlur() override {
        return false;
    }
    virtual bool undiscardable() override {
        return true;
    }
    virtual bool disableSimplification() override {
        return true;
    }
    virtual std::optional<CBox> boundingBox() override {
        const auto m = m_monitor.lock();
        if (!m)
            return std::nullopt;
        return CBox{0, 0, m->m_size.x, m->m_size.y};
    }
    virtual CRegion opaqueRegion() override {
        return {};
    }
    virtual const char* passName() override {
        return "CCrtPassElement";
    }
    virtual ePassElementType type() override {
        return EK_CUSTOM;
    }

  private:
    PHLMONITORREF m_monitor;
};

// ------------------------------------------------------------------------------------------------ per-window mode

class CCrtTransformer : public Render::IWindowTransformer {
  public:
    CCrtTransformer(PHLWINDOWREF w) : m_window(w) {}
    virtual ~CCrtTransformer() {
        // the window deletes its transformers from its destructor; nobody else gets a chance to free the GL side
        if (g_pHyprOpenGL) {
            g_pHyprOpenGL->makeEGLCurrent();
            destroyGL();
        }
    }

    virtual SP<Render::IFramebuffer> transform(SP<Render::IFramebuffer> in) override {
        const auto w = m_window.lock();
        const auto m = g_pHyprRenderer->m_renderData.pMonitor.lock();
        if (!w || !m || !in || !in->getTexture() || m_failed || !g_state || !enabled())
            return in;
        if (scopeMode() == "auto" && windowFullscreen(w))
            return in; // the monitor pass has it now
        if (!ensureShaders(m_chain)) {
            m_failed = true;
            return in;
        }
        const int W = static_cast<int>(in->m_size.x), H = static_cast<int>(in->m_size.y);
        if (!m_out) {
            m_out = g_pHyprRenderer->createFB("hyprcrt window");
        }
        if (!m_out->isAllocated() || m_out->m_size != in->m_size) {
            m_out->release();
            m_out->alloc(W, H, in->m_drmFormat != DRM_FORMAT_INVALID ? in->m_drmFormat : DRM_FORMAT_ARGB8888);
        }
        m_out->setImageDescription(in->imageDescription());
        const int   cfgPitch = ovInt("pitch", g_state->cfg.pitch->value());
        int         pitch    = cfgPitch > 0 ? std::clamp(cfgPitch, 1, 8) : std::clamp(ovInt("pitch_fullscreen", g_state->cfg.pitchFullscreen->value()), 1, 8);
        if (cfgPitch <= 0) {
            // the window's own integer factor: buffer rows vs the rows it covers on screen
            if (w->wlSurface() && w->wlSurface()->resource()) {
                const auto& bs   = w->wlSurface()->resource()->m_current.bufferSize;
                const auto  box  = w->getFullWindowBoundingBox();
                const float rows = box.h * m->m_scale;
                if (bs.y > 0 && rows > 0) {
                    const double f  = rows / bs.y;
                    const int    fi = static_cast<int>(std::lround(f));
                    if (fi >= 1 && fi <= 8 && std::abs(f - fi) < 0.05)
                        pitch = fi;
                }
            }
        }
        SKnobs knobs   = effectiveKnobs();
        knobs.textsafe = false; // a matched window is a picture, not the desktop
        const SLook look = computeLook(knobs, pitch);
        auto        out  = m_out;
        glStateBeforeChain();
        const bool  ok   = m_chain.run(in->getTexture()->m_texID, W, H, look, pitch, haloHalfNow(), in->getTexture()->m_texID, [out] { out->bind(); });
        glStateAfterChain();
        if (!ok) {
            m_failed = true;
            notify("GL error while filtering window " + w->m_class + " (" + m_chain.lastError() + "); filter disabled for it", true);
            return in;
        }
        return m_out;
    }

    void destroyGL() {
        m_chain.destroy();
        if (m_out)
            m_out->release();
        m_out.reset();
    }

  private:
    PHLWINDOWREF            m_window;
    CCrtChain               m_chain;
    SP<Render::IFramebuffer> m_out;
    bool                    m_failed = false;
};

static void detachWindow(SWindowState& ws) {
    if (const auto w = ws.window.lock()) {
        std::erase_if(w->m_transformers, [&](const UP<Render::IWindowTransformer>& t) {
            if (t.get() != ws.transformer)
                return false;
            g_pHyprOpenGL->makeEGLCurrent();
            static_cast<CCrtTransformer*>(t.get())->destroyGL();
            return true;
        });
    }
    ws.transformer = nullptr;
}

static void syncWindow(PHLWINDOW w) {
    if (!w || !g_state)
        return;
    const auto mode = scopeMode();
    const bool want = enabled() && w->m_isMapped && ((mode == "window" && windowMatches(w)) || (mode == "auto" && !windowFullscreen(w) && windowIsMedia(w)));
    auto       it   = std::ranges::find_if(g_state->windows, [&](const SWindowState& s) { return s.window.lock() == w; });
    if (want && it == g_state->windows.end()) {
        auto t = makeUnique<CCrtTransformer>(w);
        g_state->windows.push_back({.window = w, .transformer = t.get()});
        w->m_transformers.emplace_back(std::move(t));
        g_pHyprRenderer->damageMonitor(w->m_monitor.lock());
    } else if (!want && it != g_state->windows.end()) {
        detachWindow(*it);
        g_state->windows.erase(it);
        g_pHyprRenderer->damageMonitor(w->m_monitor.lock());
    }
}

static void syncAllWindows() {
    // drop dead windows first
    std::erase_if(g_state->windows, [](const SWindowState& s) { return s.window.expired(); });
    for (auto& w : Desktop::windowState()->windows())
        syncWindow(w);
}

static void detachAllWindows() {
    for (auto& ws : g_state->windows)
        detachWindow(ws);
    g_state->windows.clear();
}

// ------------------------------------------------------------------------------------------------ render events

static void onRenderStage(eRenderStage stage) {
    if (!g_state)
        return;
    auto& rd = g_pHyprRenderer->m_renderData;

    if (stage == RENDER_BEGIN) {
        const auto m = rd.pMonitor.lock();
        if (!m)
            return;
        auto&      st        = stateFor(m);
        const bool wasActive = st.active;
        st.active            = false;
        // screencopy / screen sharing never reach these stages, but on Hyprland 0.56 they copy the main buffer
        // after this chain has drawn into it, so an output capture is filtered (tests/run-capture-test.sh);
        // plugin:crt:capture stays reserved.
        int  pitch   = 1;
        bool desktop = true;
        if (!monitorInScope(m, pitch, desktop))
            return;
        st.active = true;
        st.pitch  = pitch;
        if (!wasActive)
            st.chain.resetGlow(); // whatever the trail held when this output left scope is stale now
        SKnobs knobs  = effectiveKnobs();
        knobs.textsafe = knobs.textsafe && desktop; // text-safe is for the desktop, never for a fullscreen picture
        st.look        = computeLook(knobs, pitch);
        // the filter is non-local (blur, warp, history): this frame must be a full one
        rd.damage      = CRegion{0.0, 0.0, m->m_transformedSize.x * 10.0, m->m_transformedSize.y * 10.0};
        rd.finalDamage = rd.damage;
        if (!st.selfScheduled)
            st.glowFrames = glowFramesNow(); // real content: restart the trail countdown
        st.selfScheduled = false;
        return;
    }

    if (stage == RENDER_LAST_MOMENT) {
        const auto m = rd.pMonitor.lock();
        if (!m)
            return;
        auto& st = stateFor(m);
        if (!st.active)
            return;
        g_pHyprRenderer->addPassElement(makeUnique<CCrtPassElement>(m));
        return;
    }

    if (stage == RENDER_POST) {
        const auto m = rd.pMonitor.lock();
        if (!m)
            return;
        auto& st = stateFor(m);
        if (!st.active || st.look.glow == 0 || st.glowFrames <= 0)
            return;
        // the phosphor is still decaying: ask for another full frame
        st.glowFrames--;
        st.selfScheduled = true;
        g_pHyprRenderer->damageMonitor(m);
    }
}

static void onMonitorRemoved(PHLMONITOR m) {
    if (!g_state || !m)
        return;
    auto it = g_state->monitors.find(m->m_id);
    if (it == g_state->monitors.end())
        return;
    g_pHyprOpenGL->makeEGLCurrent();
    it->second->chain.destroy();
    g_state->monitors.erase(it);
}

static void reloadShaders() {
    g_pHyprOpenGL->makeEGLCurrent();
    for (auto& [id, st] : g_state->monitors) {
        st->chain.destroy();
        st->failed = false;
    }
    for (auto& ws : g_state->windows)
        if (ws.transformer)
            ws.transformer->destroyGL();
    damageAll();
}

static void applyStateFile();

static void onConfigReloaded() {
    if (!g_state)
        return;
    applyStateFile(); // what the hyprcrt command last set outlives the reload
    const auto dir = expandHome(g_state->cfg.shaderDir->value());
    const auto nd  = dir.empty() ? defaultShaderDir() : dir;
    if (nd != g_state->shaderDir) {
        g_state->shaderDir = nd;
        reloadShaders();
    }
    updateScanoutBlock();
    syncAllWindows();
    damageAll();
}

// ------------------------------------------------------------------------------------------------ control surface

static const char* KNOBS[] = {"curve", "lines", "mask", "glow", "gamma", "sharp"};

static bool isKnob(const std::string& k) {
    for (auto* n : KNOBS)
        if (k == n)
            return true;
    return false;
}

static int knobTop(const std::string& k) {
    return k == "curve" ? 1 : k == "mask" ? 3 : 4;
}

static void afterChange() {
    updateScanoutBlock();
    syncAllWindows();
    for (auto& [id, st] : g_state->monitors)
        st->chain.resetGlow();
    damageAll();
}

static std::string jsonEsc(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const unsigned char c : in) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20)
                    out += std::format("\\u{:04x}", c);
                else
                    out += static_cast<char>(c);
        }
    }
    return out;
}

static std::string statusJson() {
    const SKnobs k = effectiveKnobs();
    std::string  mons;
    for (auto& m : State::monitorState()->monitors()) {
        auto it = g_state->monitors.find(m->m_id);
        const bool active = it != g_state->monitors.end() && it->second->active;
        const int  pitch  = it != g_state->monitors.end() ? it->second->pitch : 0;
        const float ms    = it != g_state->monitors.end() ? it->second->chain.lastGpuMs() : 0.f;
        mons += std::format("{}{{\"name\":\"{}\",\"active\":{},\"pitch\":{},\"gpu_ms\":{:.3f}}}", mons.empty() ? "" : ",", jsonEsc(m->m_name), active ? "true" : "false", pitch, ms);
    }
    return std::format("{{\"version\":\"{}\",\"enabled\":{},\"preset\":\"{}\",\"scope\":\"{}\",\"mode\":\"plugin\","
                       "\"knobs\":{{\"curve\":{},\"lines\":{},\"mask\":{},\"glow\":{},\"gamma\":{},\"sharp\":{},\"pitch\":{},\"pitch_fullscreen\":{},\"mask_pitch\":{},\"gain\":{:.3f},\"textsafe\":{}}},"
                       "\"bypass\":{},\"low_power\":{},\"match\":\"{}\",\"media\":\"{}\","
                       "\"windows\":{},\"scanout_blocked\":{},\"shader_dir\":\"{}\",\"last_error\":\"{}\",\"monitors\":[{}]}}",
                       HYPRCRT_VERSION, enabled() ? "true" : "false", jsonEsc(currentPreset()), jsonEsc(scopeMode()), k.curve, k.lines, k.mask, k.glow, k.gamma, k.sharp,
                       ovInt("pitch", g_state->cfg.pitch->value()), ovInt("pitch_fullscreen", g_state->cfg.pitchFullscreen->value()), k.maskPitch, k.gain, k.textsafe ? "true" : "false",
                       g_state->bypass ? "true" : "false", lowPower() ? "true" : "false", jsonEsc(ov("match", g_state->cfg.match->value())), jsonEsc(ov("media", g_state->cfg.media->value())),
                       g_state->windows.size(), g_state->weBlockedScanout ? "true" : "false", jsonEsc(g_state->shaderDir), jsonEsc(g_state->lastError), mons);
}

// the same ranges and messages as bin/hyprcrt's check_value: a bad value is refused, never stored; "" when it is fine
static std::string valueError(const std::string& a, const std::string& b) {
    if (a == "scope" && b != "auto" && b != "all" && b != "fullscreen" && b != "games" && b != "rules" && b != "window" && b != "off")
        return "scope must be auto|all|fullscreen|games|rules|window|off";
    const auto intIn = [&b](int lo, int hi) { return b.size() == 1 && b[0] >= '0' + lo && b[0] <= '0' + hi; };
    if (a == "pitch" && !intIn(0, 8))
        return "pitch must be an integer 0-8 (0 = auto)";
    if (a == "pitch_fullscreen" && !intIn(1, 8))
        return "pitch_fullscreen must be an integer 1-8";
    if (a == "mask_pitch" && !intIn(1, 3))
        return "mask_pitch must be an integer 1-3";
    if (a == "gain") {
        const bool shape = !b.empty() && b.find_first_not_of("0123456789.") == std::string::npos && std::ranges::count(b, '.') <= 1 && b != ".";
        float      g     = 0.f;
        try {
            g = shape ? std::stof(b) : 0.f;
        } catch (...) {}
        if (!(g >= 0.25f && g <= 4.f))
            return "gain must be a number 0.25-4";
    }
    if ((a == "textsafe" || a == "low_power") && b != "0" && b != "1" && b != "true" && b != "false" && b != "on" && b != "off" && b != "yes" && b != "no")
        return a + " must be 0 or 1 (true/false, on/off, yes/no)";
    if (isKnob(a) && !intIn(0, knobTop(a)))
        return a + " must be an integer 0-" + std::to_string(knobTop(a));
    return "";
}

// The state file the hyprcrt command keeps for both modes ($XDG_CONFIG_HOME/hyprcrt/state.conf, key=value):
// what the user last chose. Applied at load and on top of every config reload, so a preset or `hyprcrt off`
// survives both; plugin:crt:* values are the defaults underneath, and a bare `hyprctl crt ...` lasts until
// the next reload. Lines that do not pass the same checks as `set` are skipped.
static std::string stateFilePath() {
    const char*       xc  = getenv("XDG_CONFIG_HOME");
    const std::string dir = (xc && *xc ? std::string(xc) : expandHome("~/.config")) + "/hyprcrt";
    std::error_code   ec;
    if (!std::filesystem::exists(dir + "/state.conf", ec) && std::filesystem::exists(dir + "/lite.conf", ec))
        return dir + "/lite.conf"; // its old name; bin/hyprcrt renames it the next time it runs
    return dir + "/state.conf";
}

static void applyStateFile() {
    std::ifstream f(stateFilePath());
    if (!f.good())
        return;
    std::map<std::string, std::string> kv;
    for (std::string line; std::getline(f, line);) {
        const auto eq = line.find('=');
        if (!line.empty() && line[0] != '#' && eq != std::string::npos)
            kv[line.substr(0, eq)] = line.substr(eq + 1);
    }
    if (kv.contains("enabled"))
        g_state->runtimeEnabled = kv["enabled"] == "1";
    if (const auto p = kv["preset"]; p == "plain" || p == "scanlines" || p == "monitor" || p == "television" || p == "custom") {
        g_state->overrides["preset"] = p;
        for (auto* n : KNOBS) { // as `preset` does: a named preset brings its own knobs, custom takes the file's
            g_state->overrides.erase(n);
            if (p == "custom" && kv.contains(n) && valueError(n, kv[n]).empty())
                g_state->overrides[n] = kv[n];
        }
    }
    for (const char* k : {"pitch", "pitch_fullscreen", "mask_pitch", "gain", "textsafe", "scope", "low_power", "match", "media"})
        if (kv.contains(k) && valueError(k, kv[k]).empty())
            g_state->overrides[k] = kv[k];
}

static SDispatchResult applyCommand(const std::string& cmdline) {
    std::stringstream ss(cmdline);
    std::string       cmd, a, b;
    ss >> cmd >> a >> b;
    if (cmd == "toggle") {
        g_state->runtimeEnabled = !g_state->runtimeEnabled;
        afterChange();
        notify(g_state->runtimeEnabled ? "on (" + currentPreset() + ")" : "off");
        return {};
    }
    if (cmd == "on" || cmd == "off") {
        g_state->runtimeEnabled = cmd == "on";
        afterChange();
        return {};
    }
    if (cmd == "bypass") {
        // hold-to-compare: "on" shows the plain picture until "off"; nothing else changes
        const bool want = a == "toggle" ? !g_state->bypass : a != "off" && a != "0";
        if (want == g_state->bypass)
            return {};
        g_state->bypass = want;
        afterChange();
        return {};
    }
    if (cmd == "preset") {
        if (a != "custom" && a != "plain" && a != "scanlines" && a != "monitor" && a != "television")
            return {.success = false, .error = "unknown preset (plain|scanlines|monitor|television|custom)"};
        g_state->overrides["preset"] = a;
        for (auto* n : KNOBS)
            g_state->overrides.erase(n);
        g_state->runtimeEnabled = true;
        afterChange();
        notify("preset " + a);
        return {};
    }
    if (cmd == "cycle") {
        static const char* ring[] = {"plain", "scanlines", "monitor", "television"};
        const auto         cur    = currentPreset();
        int                idx    = 0;
        for (int i = 0; i < 4; i++)
            if (cur == ring[i])
                idx = i;
        const int dir = a == "-1" ? -1 : 1;
        return applyCommand(std::string("preset ") + ring[(idx + 4 + dir) % 4]);
    }
    if (cmd == "set") {
        if (a.empty() || b.empty())
            return {.success = false, .error = "usage: set <key> <value>"};
        if (isKnob(a)) {
            // touching a knob makes the preset custom, as in an-earlier-project's menu
            const SKnobs k = effectiveKnobs();
            g_state->overrides["preset"] = "custom";
            g_state->overrides["curve"]  = std::to_string(k.curve);
            g_state->overrides["lines"]  = std::to_string(k.lines);
            g_state->overrides["mask"]   = std::to_string(k.mask);
            g_state->overrides["glow"]   = std::to_string(k.glow);
            g_state->overrides["gamma"]  = std::to_string(k.gamma);
            g_state->overrides["sharp"]  = std::to_string(k.sharp);
            int v = 0;
            try {
                if (b.starts_with("+") || b.starts_with("-"))
                    v = std::stoi(g_state->overrides[a]) + std::stoi(b);
                else
                    v = std::stoi(b);
            } catch (...) { return {.success = false, .error = "value must be an integer or +N/-N"}; }
            const int top            = knobTop(a);
            g_state->overrides[a] = std::to_string(((v % (top + 1)) + (top + 1)) % (top + 1));
        } else if (a == "pitch" || a == "pitch_fullscreen" || a == "mask_pitch" || a == "gain" || a == "textsafe" || a == "scope" || a == "match" || a == "media" || a == "monitors" ||
                   a == "enabled" || a == "block_scanout" || a == "halo_half" || a == "capture" || a == "glow_frames" || a == "low_power") {
            if (const auto err = valueError(a, b); !err.empty())
                return {.success = false, .error = err};
            // `set match/media` takes the rest of the line, so a regex may contain spaces
            if (a == "match" || a == "media") {
                std::string rest;
                std::getline(ss, rest);
                b += rest;
            }
            g_state->overrides[a] = b;
        }
        else
            return {.success = false, .error = "unknown key " + a};
        afterChange();
        return {};
    }
    if (cmd == "dump") {
        if (a.empty())
            return {.success = false, .error = "usage: dump <file.ppm>"};
        bool anyActive = false;
        for (auto& [id, st] : g_state->monitors)
            anyActive = anyActive || st->active;
        if (!anyActive)
            return {.success = false, .error = "no monitor is being filtered right now (scope/preset/bypass); nothing to dump"};
        g_state->dumpPath = expandHome(a);
        damageAll();
        return {};
    }
    if (cmd == "reload") {
        reloadShaders();
        notify("shaders reloaded");
        return {};
    }
    return {.success = false, .error = "unknown command (toggle|on|off|bypass|preset|cycle|set|reload|dump)"};
}

static std::string ctlCommand(eHyprCtlOutputFormat format, std::string request) {
    // request is "crt <args>"
    std::string args = request.size() > 3 ? request.substr(3) : "";
    while (!args.empty() && args.front() == ' ')
        args.erase(args.begin());
    if (args.empty() || args == "status")
        return statusJson();
    const auto r = applyCommand(args);
    if (!r.success)
        return format == FORMAT_JSON ? std::format("{{\"ok\":false,\"error\":\"{}\"}}", r.error) : "error: " + r.error;
    return format == FORMAT_JSON ? statusJson() : "ok";
}

static int luaPreset(lua_State* L) {
    if (!lua_isstring(L, 1))
        return luaL_error(L, "hl.plugin.crt.preset: expected a preset name");
    const auto r = applyCommand(std::string("preset ") + lua_tostring(L, 1));
    if (!r.success)
        return luaL_error(L, "hl.plugin.crt.preset: %s", r.error.c_str());
    return 0;
}

static int luaSet(lua_State* L) {
    if (!lua_isstring(L, 1) || (!lua_isstring(L, 2) && !lua_isnumber(L, 2)))
        return luaL_error(L, "hl.plugin.crt.set: expected (key, value)");
    std::string v = lua_isnumber(L, 2) ? std::to_string(static_cast<int>(lua_tonumber(L, 2))) : lua_tostring(L, 2);
    const auto  r = applyCommand(std::string("set ") + lua_tostring(L, 1) + " " + v);
    if (!r.success)
        return luaL_error(L, "hl.plugin.crt.set: %s", r.error.c_str());
    return 0;
}

// ------------------------------------------------------------------------------------------------ plugin entry

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();
    if (HASH != CLIENT_HASH) {
        HyprlandAPI::addNotification(PHANDLE, "[hyprcrt] version mismatch: built for " + CLIENT_HASH.substr(0, 8) + ", running " + HASH.substr(0, 8) + ". Rebuild with crt-build.",
                                     CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
        throw std::runtime_error("[hyprcrt] version mismatch");
    }

    g_state = makeUnique<SState>();
    auto& c = g_state->cfg;

    using namespace Config::Values;
    c.enabled   = makeShared<CBoolValue>("plugin:crt:enabled", "Whether the CRT filter is enabled", true);
    c.preset    = makeShared<CStringValue>("plugin:crt:preset", "plain, scanlines, monitor, television or custom (use the six knobs)", "monitor");
    c.curve     = makeShared<CIntValue>("plugin:crt:curve", "Curved glass, vignette and corners (0/1)", 0, SIntValueOptions{.min = 0, .max = 1});
    c.lines     = makeShared<CIntValue>("plugin:crt:lines", "Scanline depth 0-4", 3, SIntValueOptions{.min = 0, .max = 4});
    c.mask      = makeShared<CIntValue>("plugin:crt:mask", "Phosphor mask: 0 none, 1 grille, 2 slot, 3 shadow", 1, SIntValueOptions{.min = 0, .max = 3});
    c.glow      = makeShared<CIntValue>("plugin:crt:glow", "Halation and afterglow 0-4", 2, SIntValueOptions{.min = 0, .max = 4});
    c.gamma     = makeShared<CIntValue>("plugin:crt:gamma", "Output gamma 0-4 (2.0 2.2 2.4 2.6 2.8)", 1, SIntValueOptions{.min = 0, .max = 4});
    c.sharp     = makeShared<CIntValue>("plugin:crt:sharp", "Beam sharpness 0-4", 3, SIntValueOptions{.min = 0, .max = 4});
    c.pitch     = makeShared<CIntValue>("plugin:crt:pitch", "Physical pixels per virtual scanline, 0 = auto (fullscreen integer factor, else pitch_fullscreen for fullscreen windows, 1 on the desktop)", 0, SIntValueOptions{.min = 0, .max = 8});
    c.pitchFullscreen = makeShared<CIntValue>("plugin:crt:pitch_fullscreen", "Auto pitch for a fullscreen window that is not integer-scaled (video, browsers): 3 on a 1440p monitor reads as a 480-line tube", 3, SIntValueOptions{.min = 1, .max = 8});
    c.maskPitch = makeShared<CIntValue>("plugin:crt:mask_pitch", "Physical pixels per mask stripe 1-3", 1, SIntValueOptions{.min = 1, .max = 3});
    c.gain      = makeShared<CFloatValue>("plugin:crt:gain", "Brightness compensation 0.25-4", 1.0f);
    c.textsafe  = makeShared<CBoolValue>("plugin:crt:textsafe", "At pitch 1 draw no scanlines and no mask so text stays readable", true);
    c.haloHalf  = makeShared<CBoolValue>("plugin:crt:halo_half", "At pitch 1 run the halation and afterglow at half resolution", true);
    c.scope     = makeShared<CStringValue>("plugin:crt:scope", "auto (fullscreen windows plus windowed media players), all, fullscreen, games, rules, window or off", "auto");
    c.match     = makeShared<CStringValue>("plugin:crt:match", "Regex on class/title for scope rules and window", "");
    c.media     = makeShared<CStringValue>("plugin:crt:media", "Regex on class/title of windowed apps that scope auto treats as a picture (players, emulators, games)",
                                           "^(mpv|vlc|kodi|haruna|smplayer|celluloid|io\\.github\\.celluloid_player\\.Celluloid|org\\.gnome\\.Totem|totem|stremio|freetube|jellyfin.*|plex.*|tv\\.plex\\.PlexHTPC|"
                                           "com\\.github\\.iwalton3\\.jellyfin-media-player|moonlight|com\\.moonlight_stream\\.Moonlight|steam_app_[0-9]+|gamescope|retroarch|org\\.libretro\\.RetroArch|"
                                           "dolphin-emu|pcsx2.*|duckstation.*|ppsspp.*|rpcs3|yuzu|ryujinx|cemu|mgba|snes9x.*|nestopia|mednafen|mame|flycast|melonds|xemu|ares|bsnes|higan)$");
    c.monitors  = makeShared<CStringValue>("plugin:crt:monitors", "Comma-separated monitor names, empty = all", "");
    c.blockScanout = makeShared<CBoolValue>("plugin:crt:block_scanout", "Keep fullscreen clients composited (so they are filtered) while enabled", true);
    c.capture   = makeShared<CBoolValue>("plugin:crt:capture", "Also filter screenshots and screen sharing", false);
    c.glowFrames = makeShared<CIntValue>("plugin:crt:glow_frames", "Extra full frames rendered after the picture settles, for the afterglow to decay", 12, SIntValueOptions{.min = 0, .max = 120});
    c.stats     = makeShared<CBoolValue>("plugin:crt:stats", "Measure GPU time per frame (hyprctl crt status)", false);
    c.lowPower  = makeShared<CBoolValue>("plugin:crt:low_power", "Cheaper profile for laptops on battery: half-resolution halation, a short afterglow", false);
    c.shaderDir = makeShared<CStringValue>("plugin:crt:shader_dir", "Directory with common.glsl and passes/, empty = ~/.local/share/hyprcrt/shaders", "");

    for (auto& v : std::initializer_list<SP<Config::Values::IValue>>{c.enabled, c.preset, c.curve, c.lines, c.mask, c.glow, c.gamma, c.sharp, c.pitch, c.pitchFullscreen, c.maskPitch, c.gain, c.textsafe,
                                                                     c.haloHalf, c.scope, c.match, c.media, c.monitors, c.blockScanout, c.capture, c.glowFrames, c.stats, c.lowPower, c.shaderDir})
        HyprlandAPI::addConfigValueV2(PHANDLE, v);

    g_state->shaderDir = defaultShaderDir();
    applyStateFile();

    auto& ev = Event::bus()->m_events;
    g_state->listeners.push_back(ev.render.stage.listen([](eRenderStage s) { onRenderStage(s); }));
    g_state->listeners.push_back(ev.monitor.removed.listen([](PHLMONITOR m) { onMonitorRemoved(m); }));
    g_state->listeners.push_back(ev.monitor.destroyMon.listen([](PHLMONITOR m) { onMonitorRemoved(m); }));
    g_state->listeners.push_back(ev.config.reloaded.listen([] { onConfigReloaded(); }));
    g_state->listeners.push_back(ev.window.open.listen([](PHLWINDOW w) { syncWindow(w); }));
    g_state->listeners.push_back(ev.window.updateRules.listen([](PHLWINDOW w) { syncWindow(w); }));
    g_state->listeners.push_back(ev.window.class_.listen([](PHLWINDOW w) { syncWindow(w); }));
    g_state->listeners.push_back(ev.window.title.listen([](PHLWINDOW w) { syncWindow(w); }));
    g_state->listeners.push_back(ev.window.fullscreen.listen([](PHLWINDOW w) {
        syncWindow(w);
        damageAll();
    }));
    g_state->listeners.push_back(ev.window.destroy.listen([](PHLWINDOWREF w) {
        std::erase_if(g_state->windows, [&](const SWindowState& s) { return s.window.expired() || s.window == w; });
    }));

    HyprlandAPI::addDispatcherV2(PHANDLE, "crt:toggle", [](std::string) { return applyCommand("toggle"); });
    HyprlandAPI::addDispatcherV2(PHANDLE, "crt:cycle", [](std::string a) { return applyCommand("cycle " + a); });
    HyprlandAPI::addDispatcherV2(PHANDLE, "crt:preset", [](std::string a) { return applyCommand("preset " + a); });
    HyprlandAPI::addDispatcherV2(PHANDLE, "crt:set", [](std::string a) { return applyCommand("set " + a); });
    HyprlandAPI::addDispatcherV2(PHANDLE, "crt:reload", [](std::string) { return applyCommand("reload"); });
    HyprlandAPI::addDispatcherV2(PHANDLE, "crt:bypass", [](std::string a) { return applyCommand("bypass " + (a.empty() ? "toggle" : a)); });

    g_state->ctl = HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{.name = "crt", .exact = false, .fn = ctlCommand});

    HyprlandAPI::addLuaFunction(PHANDLE, "crt", "preset", luaPreset);
    HyprlandAPI::addLuaFunction(PHANDLE, "crt", "set", luaSet);

    updateScanoutBlock();
    syncAllWindows();
    damageAll();

    // crash-loop guard: while we are loaded this file names the compositor pid; a clean unload removes it.
    // If it is still there at the next start and Hyprland wrote a crash report for that pid, the loader
    // (the toggle file crt-build writes, and `hyprcrt guard`) keeps the plugin off and tells the user.
    {
        const char* xs    = getenv("XDG_STATE_HOME");
        std::string state = xs && *xs ? std::string(xs) : expandHome("~/.local/state");
        std::error_code ec;
        std::filesystem::create_directories(state + "/hyprcrt", ec);
        g_state->loadedMarker = state + "/hyprcrt/plugin-loaded";
        if (std::ofstream f(g_state->loadedMarker); f.good())
            f << getpid() << "\n" << HYPRCRT_VERSION << "\n";
        std::filesystem::remove(state + "/hyprcrt/plugin-disabled", ec); // we are running: whatever kept us off is history
    }

    return {"hyprcrt", "A system-wide CRT filter: scanlines, phosphor mask, halation, afterglow, curved glass", "Dan Expo", HYPRCRT_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (!g_state)
        return;
    g_state->runtimeEnabled = false;
    if (g_state->weBlockedScanout)
        g_pHyprRenderer->m_directScanoutBlocked = false;
    g_pHyprRenderer->m_renderPass.removeAllOfType("CCrtPassElement");
    detachAllWindows();
    g_pHyprOpenGL->makeEGLCurrent();
    for (auto& [id, st] : g_state->monitors)
        st->chain.destroy();
    g_state->monitors.clear();
    g_state->listeners.clear();
    if (g_state->ctl)
        HyprlandAPI::unregisterHyprCtlCommand(PHANDLE, g_state->ctl);
    damageAll();
    if (!g_state->loadedMarker.empty()) {
        std::error_code ec;
        std::filesystem::remove(g_state->loadedMarker, ec);
    }
    g_state.reset();
}
