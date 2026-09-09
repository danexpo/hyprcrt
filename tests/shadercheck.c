/* shadercheck - compile a Hyprland screen shader offscreen and, optionally, run an image through it.
 *
 *   shadercheck shader.frag                      compile only (prints the driver's log on failure)
 *   shadercheck shader.frag in.ppm out.ppm       render in.ppm (P6) through the shader at its own size
 *   shadercheck shader.frag in.ppm out.ppm WxH   ... into a WxH output (the input is stretched like a
 *                                                monitor showing a smaller frame - not what Hyprland does,
 *                                                use the pre-scaled @3x sources instead)
 *
 * Mirrors what Hyprland's final pass gives the shader: `in vec2 v_texcoord` 0..1, `uniform sampler2D tex`
 * (linear filtering, clamp to edge), `uniform vec2 fullSize`. MIT (c) 2026 Dan Expo. */
#define _GNU_SOURCE
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl32.h>
#include <gbm.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char* VS = "#version 300 es\nin vec2 pos; out vec2 v_texcoord; void main(){ v_texcoord = pos*0.5+0.5; gl_Position = vec4(pos,0.0,1.0);}";

static char* slurp(const char* path) {
    FILE* f = fopen(path, "rb");
    if (!f) { perror(path); exit(1); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char* s = malloc(n + 1); if (fread(s, 1, n, f) != (size_t)n) { perror("read"); exit(1); } s[n] = 0; fclose(f); return s;
}
static unsigned char* readPPM(const char* path, int* w, int* h) {
    FILE* f = fopen(path, "rb"); if (!f) { perror(path); exit(1); }
    int maxv; if (fscanf(f, "P6 %d %d %d", w, h, &maxv) != 3) { fprintf(stderr, "not a P6 ppm\n"); exit(1); }
    fgetc(f);
    unsigned char* rgb = malloc((size_t)*w * *h * 3); if (fread(rgb, 1, (size_t)*w * *h * 3, f) != (size_t)*w * *h * 3) { fprintf(stderr, "short ppm\n"); exit(1); }
    fclose(f);
    unsigned char* rgba = malloc((size_t)*w * *h * 4);
    for (size_t i = 0; i < (size_t)*w * *h; i++) { rgba[i*4] = rgb[i*3]; rgba[i*4+1] = rgb[i*3+1]; rgba[i*4+2] = rgb[i*3+2]; rgba[i*4+3] = 255; }
    free(rgb); return rgba;
}
static GLuint mkShader(GLenum t, const char* s, const char* what) {
    GLuint sh = glCreateShader(t); glShaderSource(sh, 1, &s, NULL); glCompileShader(sh);
    GLint ok; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[8192]; glGetShaderInfoLog(sh, sizeof log, NULL, log); fprintf(stderr, "%s shader failed:\n%s\n", what, log); exit(2); }
    return sh;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: shadercheck shader.frag [in.ppm out.ppm [WxH]]\n"); return 1; }
    int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC); if (fd < 0) { perror("renderD128"); return 1; }
    struct gbm_device* gbm = gbm_create_device(fd);
    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlat = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    EGLDisplay dpy = getPlat(EGL_PLATFORM_GBM_KHR, gbm, NULL);
    if (!eglInitialize(dpy, NULL, NULL)) { fprintf(stderr, "eglInitialize failed\n"); return 1; }
    eglBindAPI(EGL_OPENGL_ES_API);
    EGLint cfgAttr[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE}; EGLConfig cfg; EGLint n = 0;
    eglChooseConfig(dpy, cfgAttr, &cfg, 1, &n);
    EGLint ctxAttr[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 2, EGL_NONE};
    EGLContext ctx = eglCreateContext(dpy, n ? cfg : EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, ctxAttr);
    eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx);

    char*  frag = slurp(argv[1]);
    GLuint prog = glCreateProgram();
    glAttachShader(prog, mkShader(GL_VERTEX_SHADER, VS, "vertex"));
    glAttachShader(prog, mkShader(GL_FRAGMENT_SHADER, frag, "fragment"));
    glLinkProgram(prog); GLint ok; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) { char log[8192]; glGetProgramInfoLog(prog, sizeof log, NULL, log); fprintf(stderr, "link failed:\n%s\n", log); return 2; }
    printf("compiled: %s\n", argv[1]);
    if (argc < 4) return 0;

    int W, H; unsigned char* px = readPPM(argv[2], &W, &H);
    int OW = W, OH = H; if (argc > 4) sscanf(argv[4], "%dx%d", &OW, &OH);
    GLuint vao, vbo; glGenVertexArrays(1, &vao); glBindVertexArray(vao); glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
    float verts[] = {-1, -1, 1, -1, -1, 1, 1, 1}; glBufferData(GL_ARRAY_BUFFER, sizeof verts, verts, GL_STATIC_DRAW); glEnableVertexAttribArray(0); glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
    GLuint tex; glGenTextures(1, &tex); glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    GLuint out; glGenTextures(1, &out); glBindTexture(GL_TEXTURE_2D, out); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, OW, OH, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    GLuint fb; glGenFramebuffers(1, &fb); glBindFramebuffer(GL_FRAMEBUFFER, fb); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, out, 0);
    glViewport(0, 0, OW, OH); glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "tex"), 0); glUniform2f(glGetUniformLocation(prog, "fullSize"), (float)OW, (float)OH);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); glFinish();
    unsigned char* res = malloc((size_t)OW * OH * 4); glReadPixels(0, 0, OW, OH, GL_RGBA, GL_UNSIGNED_BYTE, res);
    FILE* f = fopen(argv[3], "wb"); if (!f) { perror(argv[3]); return 1; }
    fprintf(f, "P6\n%d %d\n255\n", OW, OH);
    for (size_t i = 0; i < (size_t)OW * OH; i++) fwrite(res + i * 4, 1, 3, f);
    fclose(f); printf("wrote %s (%dx%d)\n", argv[3], OW, OH);
    return 0;
}
