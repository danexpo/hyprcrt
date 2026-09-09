// hyprcrt Chain.hpp - the pass chain (down, glow, halo h/v, beam, scan, glass) over raw GLES 3.2.
// One instance per monitor (screen mode) or per window (window mode). MIT (c) 2026 Dan Expo.
#pragma once
#include <GLES3/gl32.h>
#include <GLES2/gl2ext.h>
#include <functional>
#include <string>
#include <unordered_map>
#include "Look.hpp"

struct SProgram {
    GLuint                                 id = 0;
    std::unordered_map<std::string, GLint> locs;
    GLint                                  loc(const char* name);
    void                                   release();
};

struct STarget {
    GLuint tex = 0, fbo = 0;
    int    w = 0, h = 0;
    GLenum ifmt = 0;
    bool   alloc(int w, int h, GLenum internalFormat, GLenum format, GLenum type);
    void   clear();
    void   release();
};

class CCrtChain {
  public:
    ~CCrtChain();

    // compile every pass from <dir>/passes/*.frag with <dir>/common.glsl spliced in. EGL context must be current.
    bool loadShaders(const std::string& dir, std::string& err);
    bool shadersLoaded() const;
    void destroy(); // EGL context must be current

    // Run the chain over srcTex (W x H physical pixels) and draw the result into the target that bindTarget()
    // makes current (the callback must leave the target bound; the chain sets the viewport itself).
    // alphaTex != 0 makes the output carry that texture's alpha (window mode). Returns false on GL failure.
    bool run(GLuint srcTex, int W, int H, const SLook& look, int pitch, bool haloHalf, GLuint alphaTex, const std::function<void()>& bindTarget);

    void  resetGlow();
    float lastGpuMs() const { return m_lastGpuMs; }
    const std::string& lastError() const { return m_lastError; }
    void  setTiming(bool on) { m_timing = on; }

  private:
    bool ensureTargets(int W, int H, int pitch, bool haloHalf);
    bool ensureQuad();
    void drawQuad();
    void bindTex(int unit, GLuint tex);

    SProgram m_down, m_glow, m_haloH, m_haloV, m_beam, m_scan, m_glass;
    STarget  m_src, m_glowA, m_glowB, m_haloHT, m_halo, m_line, m_flat;
    bool     m_flip = false, m_glowDirty = true, m_loaded = false, m_halfFloat = true;
    int      m_W = 0, m_H = 0, m_pitch = 0, m_srcW = 0, m_srcH = 0, m_gW = 0, m_gH = 0;
    bool     m_haloHalf = false;
    std::string m_lastError;
    GLuint   m_vao = 0, m_vbo = 0;

    // GL_EXT_disjoint_timer_query, optional
    bool   m_timing = false, m_timerOk = false, m_queryPending = false;
    GLuint m_query     = 0;
    float  m_lastGpuMs = 0.f;
    void (*m_genQueries)(GLsizei, GLuint*)                = nullptr;
    void (*m_deleteQueries)(GLsizei, const GLuint*)       = nullptr;
    void (*m_beginQuery)(GLenum, GLuint)                  = nullptr;
    void (*m_endQuery)(GLenum)                            = nullptr;
    void (*m_getQueryObjectuiv)(GLuint, GLenum, GLuint*)  = nullptr;
    void (*m_getQueryObjectui64v)(GLuint, GLenum, GLuint64*) = nullptr;
    void initTimer();
};
