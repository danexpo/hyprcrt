// hyprcrt Chain.cpp - see Chain.hpp. MIT (c) 2026 Dan Expo.
#include "Chain.hpp"
#include <EGL/egl.h>
#include <fstream>
#include <sstream>
#include <vector>
#include <format>

static const char* VERT = "#version 300 es\n"
                          "in vec2 pos;\n"
                          "out vec2 v_texcoord;\n"
                          "void main() { v_texcoord = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n";

static const char* FRAG_HEADER = "#version 300 es\nprecision highp float;\n";

static std::string slurp(const std::string& path, std::string& err) {
    std::ifstream f(path);
    if (!f.good()) {
        err = "cannot read " + path;
        return "";
    }
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static GLuint compile(GLenum type, const std::string& src, std::string& err, const std::string& what) {
    GLuint      sh = glCreateShader(type);
    const char* s  = src.c_str();
    glShaderSource(sh, 1, &s, nullptr);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[4096] = {};
        glGetShaderInfoLog(sh, sizeof log, nullptr, log);
        err = what + ": " + log;
        glDeleteShader(sh);
        return 0;
    }
    return sh;
}

static bool buildProgram(SProgram& p, const std::string& common, const std::string& fragPath, std::string& err) {
    p.release();
    std::string frag = slurp(fragPath, err);
    if (frag.empty())
        return false;
    GLuint vs = compile(GL_VERTEX_SHADER, VERT, err, "vertex");
    if (!vs)
        return false;
    GLuint fs = compile(GL_FRAGMENT_SHADER, FRAG_HEADER + common + "\n" + frag, err, fragPath);
    if (!fs) {
        glDeleteShader(vs);
        return false;
    }
    p.id = glCreateProgram();
    glAttachShader(p.id, vs);
    glAttachShader(p.id, fs);
    glBindAttribLocation(p.id, 0, "pos");
    glLinkProgram(p.id);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(p.id, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[4096] = {};
        glGetProgramInfoLog(p.id, sizeof log, nullptr, log);
        err = fragPath + " link: " + log;
        p.release();
        return false;
    }
    glUseProgram(p.id);
    if (p.loc("tex") >= 0)
        glUniform1i(p.loc("tex"), 0);
    if (p.loc("tex2") >= 0)
        glUniform1i(p.loc("tex2"), 1);
    if (p.loc("texA") >= 0)
        glUniform1i(p.loc("texA"), 2);
    return true;
}

GLint SProgram::loc(const char* name) {
    auto it = locs.find(name);
    if (it != locs.end())
        return it->second;
    GLint l    = glGetUniformLocation(id, name);
    locs[name] = l;
    return l;
}

void SProgram::release() {
    if (id)
        glDeleteProgram(id);
    id = 0;
    locs.clear();
}

bool STarget::alloc(int w_, int h_, GLenum internalFormat, GLenum format, GLenum type) {
    if (tex && w == w_ && h == h_ && ifmt == internalFormat)
        return true;
    release();
    w    = w_;
    h    = h_;
    ifmt = internalFormat;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, internalFormat, w, h, 0, format, type, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    const bool ok = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (!ok)
        release();
    return ok;
}

void STarget::clear() {
    if (!fbo)
        return;
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
}

void STarget::release() {
    if (fbo)
        glDeleteFramebuffers(1, &fbo);
    if (tex)
        glDeleteTextures(1, &tex);
    fbo = tex = 0;
    w = h = 0;
}

CCrtChain::~CCrtChain() {
    // destroy() must have been called with the context current; if not, leak rather than crash
}

bool CCrtChain::shadersLoaded() const {
    return m_loaded;
}

bool CCrtChain::loadShaders(const std::string& dir, std::string& err) {
    m_loaded           = false;
    std::string common = slurp(dir + "/common.glsl", err);
    if (common.empty())
        return false;
    const std::string p = dir + "/passes/";
    if (!buildProgram(m_down, common, p + "down.frag", err) || !buildProgram(m_glow, common, p + "glow.frag", err) ||
        !buildProgram(m_haloH, common, p + "halo_h.frag", err) || !buildProgram(m_haloV, common, p + "halo_v.frag", err) ||
        !buildProgram(m_beam, common, p + "beam.frag", err) || !buildProgram(m_scan, common, p + "scan.frag", err) ||
        !buildProgram(m_glass, common, p + "glass.frag", err))
        return false;
    m_loaded = true;
    initTimer();
    return true;
}

void CCrtChain::destroy() {
    for (auto* p : {&m_down, &m_glow, &m_haloH, &m_haloV, &m_beam, &m_scan, &m_glass})
        p->release();
    for (auto* t : {&m_src, &m_glowA, &m_glowB, &m_haloHT, &m_halo, &m_line, &m_flat})
        t->release();
    if (m_vbo)
        glDeleteBuffers(1, &m_vbo);
    if (m_vao)
        glDeleteVertexArrays(1, &m_vao);
    if (m_query && m_deleteQueries)
        m_deleteQueries(1, &m_query);
    m_vao = m_vbo = m_query = 0;
    m_loaded = false;
    m_W = m_H = m_pitch = 0;
}

void CCrtChain::initTimer() {
    if (m_timerOk)
        return;
    m_genQueries          = reinterpret_cast<decltype(m_genQueries)>(eglGetProcAddress("glGenQueriesEXT"));
    m_deleteQueries       = reinterpret_cast<decltype(m_deleteQueries)>(eglGetProcAddress("glDeleteQueriesEXT"));
    m_beginQuery          = reinterpret_cast<decltype(m_beginQuery)>(eglGetProcAddress("glBeginQueryEXT"));
    m_endQuery            = reinterpret_cast<decltype(m_endQuery)>(eglGetProcAddress("glEndQueryEXT"));
    m_getQueryObjectuiv   = reinterpret_cast<decltype(m_getQueryObjectuiv)>(eglGetProcAddress("glGetQueryObjectuivEXT"));
    m_getQueryObjectui64v = reinterpret_cast<decltype(m_getQueryObjectui64v)>(eglGetProcAddress("glGetQueryObjectui64vEXT"));
    m_timerOk = m_genQueries && m_deleteQueries && m_beginQuery && m_endQuery && m_getQueryObjectuiv && m_getQueryObjectui64v;
    if (m_timerOk)
        m_genQueries(1, &m_query);
}

bool CCrtChain::ensureQuad() {
    if (m_vao)
        return true;
    glGenVertexArrays(1, &m_vao);
    glGenBuffers(1, &m_vbo);
    glBindVertexArray(m_vao);
    glBindBuffer(GL_ARRAY_BUFFER, m_vbo);
    const float verts[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    glBufferData(GL_ARRAY_BUFFER, sizeof verts, verts, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    return true;
}

void CCrtChain::drawQuad() {
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

void CCrtChain::bindTex(int unit, GLuint tex) {
    glActiveTexture(GL_TEXTURE0 + unit);
    glBindTexture(GL_TEXTURE_2D, tex);
}

bool CCrtChain::ensureTargets(int W, int H, int pitch, bool haloHalf) {
    if (m_W == W && m_H == H && m_pitch == pitch && m_haloHalf == haloHalf && m_line.tex)
        return true;
    m_W        = W;
    m_H        = H;
    m_pitch    = pitch;
    m_haloHalf = haloHalf;
    m_srcW     = std::max(1, W / pitch);
    m_srcH     = std::max(1, H / pitch);
    const int g = (pitch == 1 && haloHalf) ? 2 : 1;
    m_gW        = std::max(1, m_srcW / g);
    m_gH        = std::max(1, m_srcH / g);

    auto allocLinear = [&](STarget& t, int w, int h) {
        if (m_halfFloat && t.alloc(w, h, GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT))
            return true;
        m_halfFloat = false; // driver refused a float target: fall back to 8-bit everywhere
        return t.alloc(w, h, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE);
    };

    bool ok = true;
    if (pitch > 1)
        ok &= m_src.alloc(m_srcW, m_srcH, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE);
    else
        m_src.release();
    ok &= allocLinear(m_glowA, m_gW, m_gH);
    ok &= allocLinear(m_glowB, m_gW, m_gH);
    ok &= allocLinear(m_haloHT, m_gW, m_gH);
    ok &= allocLinear(m_halo, m_gW, m_gH);
    ok &= allocLinear(m_line, W, m_srcH);
    ok &= m_flat.alloc(W, H, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE);
    m_glowDirty = true;
    return ok;
}

void CCrtChain::resetGlow() {
    m_glowDirty = true;
}

bool CCrtChain::run(GLuint srcTex, int W, int H, const SLook& look, int pitch, bool haloHalf, GLuint alphaTex, const std::function<void()>& bindTarget) {
    if (!m_loaded || W < 2 || H < 2)
        return false;
    pitch = std::clamp(pitch, 1, 8);
    if (!ensureQuad() || !ensureTargets(W, H, pitch, haloHalf))
        return false;

    GLint prevProg = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prevProg);
    GLint prevVp[4];
    glGetIntegerv(GL_VIEWPORT, prevVp);

    const bool timing = m_timing && m_timerOk;
    if (timing) {
        if (m_queryPending) {
            GLuint avail = 0;
            m_getQueryObjectuiv(m_query, GL_QUERY_RESULT_AVAILABLE, &avail);
            if (avail) {
                GLuint64 ns = 0;
                m_getQueryObjectui64v(m_query, GL_QUERY_RESULT, &ns);
                m_lastGpuMs    = ns / 1.0e6f;
                m_queryPending = false;
            }
        }
        if (!m_queryPending)
            m_beginQuery(GL_TIME_ELAPSED_EXT, m_query);
    }

    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_STENCIL_TEST);
    glBindVertexArray(m_vao);

    auto target = [&](const STarget& t) {
        glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
        glViewport(0, 0, t.w, t.h);
    };
    m_lastError.clear();
    auto check = [&](const char* pass) {
        if (!m_lastError.empty())
            return;
        if (const GLenum e = glGetError(); e != GL_NO_ERROR)
            m_lastError = std::string(pass) + ": GL error 0x" + std::format("{:x}", e);
    };
    while (glGetError() != GL_NO_ERROR) {} // start clean: errors left behind by earlier draws are not ours

    if (m_glowDirty) {
        m_glowA.clear();
        m_glowB.clear();
        m_glowDirty = false;
    }

    // 1. the virtual source
    GLuint src = srcTex;
    if (pitch > 1) {
        target(m_src);
        glUseProgram(m_down.id);
        glUniform2f(m_down.loc("srcSize"), static_cast<float>(W), static_cast<float>(H));
        glUniform2f(m_down.loc("outSize"), static_cast<float>(m_srcW), static_cast<float>(m_srcH));
        glUniform1i(m_down.loc("pitch"), pitch);
        bindTex(0, srcTex);
        drawQuad();
        src = m_src.tex;
    }
    check("down");

    // 2. afterglow: decay the trail and take in a little of the new frame
    STarget& glowPrev = m_flip ? m_glowB : m_glowA;
    STarget& glowNew  = m_flip ? m_glowA : m_glowB;
    m_flip            = !m_flip;
    target(glowNew);
    glUseProgram(m_glow.id);
    glUniform1f(m_glow.loc("glowIn"), look.glowIn);
    glUniform3f(m_glow.loc("decay"), look.glowR, look.glowG, look.glowB);
    bindTex(0, src);
    bindTex(1, glowPrev.tex);
    drawQuad();
    check("glow");

    // 3./4. halation: picture + afterglow through the 7-tap blur, each way
    target(m_haloHT);
    glUseProgram(m_haloH.id);
    glUniform2f(m_haloH.loc("texelStep"), 1.f / m_gW, 0.f);
    bindTex(0, src);
    bindTex(1, glowNew.tex);
    drawQuad();
    target(m_halo);
    glUseProgram(m_haloV.id);
    glUniform2f(m_haloV.loc("texelStep"), 0.f, 1.f / m_gH);
    bindTex(0, m_haloHT.tex);
    drawQuad();
    check("halo");

    // 5. the horizontal spot: every source row at output width
    target(m_line);
    glUseProgram(m_beam.id);
    glUniform1f(m_beam.loc("hard"), look.hardPix);
    glUniform1f(m_beam.loc("hardR"), look.hardPixR);
    glUniform1f(m_beam.loc("srcW"), static_cast<float>(m_srcW));
    bindTex(0, src);
    drawQuad();
    check("beam");

    // 6. the beam down the screen, the mask, the halation, the encode
    const bool glass = look.curve && look.warpX > 0.f;
    if (glass)
        target(m_flat);
    else {
        bindTarget();
        glViewport(0, 0, W, H);
    }
    glUseProgram(m_scan.id);
    glUniform2f(m_scan.loc("outSize"), static_cast<float>(W), static_cast<float>(H));
    glUniform1f(m_scan.loc("pitch"), static_cast<float>(pitch));
    glUniform1f(m_scan.loc("srcH"), static_cast<float>(m_srcH));
    glUniform1f(m_scan.loc("haloAmt"), look.haloAmt);
    glUniform1f(m_scan.loc("sigDark"), look.sigDark);
    glUniform1f(m_scan.loc("sigBright"), look.sigBright);
    glUniform1f(m_scan.loc("cap"), look.boostCap);
    glUniform1i(m_scan.loc("flatLines"), look.flatLines ? 1 : 0);
    glUniform1i(m_scan.loc("maskMode"), look.mask);
    glUniform1f(m_scan.loc("maskPitch"), look.maskPitch);
    glUniform1f(m_scan.loc("maskLight"), look.maskLight);
    glUniform1f(m_scan.loc("maskDark"), look.maskDark);
    glUniform1f(m_scan.loc("slotDim"), look.slotDim);
    glUniform1f(m_scan.loc("invGamma"), look.invGamma);
    glUniform1f(m_scan.loc("gain"), look.gain);
    glUniform1i(m_scan.loc("alphaFrom"), (!glass && alphaTex) ? 1 : 0);
    bindTex(0, m_line.tex);
    bindTex(1, m_halo.tex);
    bindTex(2, alphaTex ? alphaTex : m_line.tex);
    drawQuad();
    check("scan");

    // 7. the glass
    if (glass) {
        bindTarget();
        glViewport(0, 0, W, H);
        glUseProgram(m_glass.id);
        glUniform1f(m_glass.loc("warpX"), look.warpX);
        glUniform1f(m_glass.loc("warpY"), look.warpY);
        glUniform1f(m_glass.loc("vignette"), look.vignette);
        glUniform1i(m_glass.loc("alphaFrom"), alphaTex ? 1 : 0);
        bindTex(0, m_flat.tex);
        bindTex(2, alphaTex ? alphaTex : m_flat.tex);
        drawQuad();
        check("glass");
    }

    if (timing && !m_queryPending) {
        m_endQuery(GL_TIME_ELAPSED_EXT);
        m_queryPending = true;
    }

    // hand the state back the way Hyprland expects it
    glBindVertexArray(0);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0);
    glUseProgram(prevProg);
    glViewport(prevVp[0], prevVp[1], prevVp[2], prevVp[3]);
    check("restore");
    return m_lastError.empty();
}
