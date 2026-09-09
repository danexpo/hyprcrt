/* Offscreen GLES 3.2 benchmark: cost of CRT post-processing at monitor resolution.
   Passthrough vs a Lottes-style single-pass CRT vs a 6-pass "tube model" pipeline. */
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
#include <time.h>
#include <math.h>

static int W = 3440, H = 1440;
static double now(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec*1e-9; }

static const char* VS =
"#version 300 es\nin vec2 pos; out vec2 v_texcoord; void main(){ v_texcoord = pos*0.5+0.5; gl_Position = vec4(pos,0.0,1.0);}";

#define HDR "#version 300 es\nprecision highp float;\nin vec2 v_texcoord;\nuniform sampler2D tex;\nuniform sampler2D tex2;\nuniform vec2 fullSize;\nlayout(location=0) out vec4 fragColor;\n"

static const char* FS_PASS = HDR "void main(){ fragColor = texture(tex, v_texcoord); }";

/* Lottes-style single pass (after Timothy Lottes' public domain CRT shader): warp, 3x3 gaussian beam, mask, gamma */
static const char* FS_LOTTES = HDR
"const float hardPix=-3.0, hardScan=-8.0, maskDark=0.5, maskLight=1.5; const vec2 warp=vec2(1.0/32.0,1.0/24.0);\n"
"vec3 toLin(vec3 c){return pow(c, vec3(2.2));}\n"
"vec3 fetch(vec2 pos, vec2 off){ pos=(floor(pos*fullSize+off)+0.5)/fullSize; if(max(abs(pos.x-0.5),abs(pos.y-0.5))>0.5) return vec3(0.0); return toLin(texture(tex,pos).rgb);}\n"
"vec2 dist(vec2 pos){ pos=pos*fullSize; return -((pos-floor(pos))-vec2(0.5));}\n"
"float gaus(float p,float s){return exp2(s*p*p);}\n"
"vec3 horz3(vec2 pos,float off){ vec3 b=fetch(pos,vec2(-1.0,off)),c=fetch(pos,vec2(0.0,off)),d=fetch(pos,vec2(1.0,off)); float dst=dist(pos).x; float wb=gaus(dst-1.0,hardPix),wc=gaus(dst,hardPix),wd=gaus(dst+1.0,hardPix); return (b*wb+c*wc+d*wd)/(wb+wc+wd);}\n"
"float scan(vec2 pos,float off){ return gaus(dist(pos).y+off,hardScan);}\n"
"vec3 tri(vec2 pos){ return horz3(pos,-1.0)*scan(pos,-1.0)+horz3(pos,0.0)*scan(pos,0.0)+horz3(pos,1.0)*scan(pos,1.0);}\n"
"vec2 warpf(vec2 pos){ pos=pos*2.0-1.0; pos*=vec2(1.0+(pos.y*pos.y)*warp.x,1.0+(pos.x*pos.x)*warp.y); return pos*0.5+0.5;}\n"
"vec3 mask(vec2 pos){ pos.x+=pos.y*3.0; vec3 m=vec3(maskDark); pos.x=fract(pos.x/6.0); if(pos.x<0.333)m.r=maskLight; else if(pos.x<0.666)m.g=maskLight; else m.b=maskLight; return m;}\n"
"void main(){ vec2 pos=warpf(v_texcoord); vec3 c=tri(pos)*mask(gl_FragCoord.xy); fragColor=vec4(pow(c,vec3(1.0/2.2)),1.0);}";

/* 6-pass tube model at 1:1 (afterglow history, halation blur H/V, beam, scan+mask, glass) */
static const char* FS_GLOW = HDR /* tex=src, tex2=prev glow -> new glow (fp16) */
"void main(){ vec3 s=pow(texture(tex,v_texcoord).rgb,vec3(2.2)); vec3 p=texture(tex2,v_texcoord).rgb; float g=dot(s,vec3(0.3,0.59,0.11)); fragColor=vec4(p*vec3(0.55,0.50,0.33)+0.05*mix(vec3(g),s,0.3),1.0);}";
static const char* FS_HALOH = HDR /* tex=src, tex2=glow -> 7-tap horizontal */
"const float k[7]=float[7](1.0/27.0,3.0/27.0,6.0/27.0,7.0/27.0,6.0/27.0,3.0/27.0,1.0/27.0);\n"
"void main(){ vec3 a=vec3(0.0); for(int i=-3;i<=3;i++){ vec2 uv=v_texcoord+vec2(float(i)/fullSize.x,0.0); a+=k[i+3]*(pow(texture(tex,uv).rgb,vec3(2.2))+texture(tex2,uv).rgb);} fragColor=vec4(a,1.0);}";
static const char* FS_HALOV = HDR
"const float k[7]=float[7](1.0/27.0,3.0/27.0,6.0/27.0,7.0/27.0,6.0/27.0,3.0/27.0,1.0/27.0);\n"
"void main(){ vec3 a=vec3(0.0); for(int i=-3;i<=3;i++){ a+=k[i+3]*texture(tex,v_texcoord+vec2(0.0,float(i)/fullSize.y)).rgb;} fragColor=vec4(a,1.0);}";
static const char* FS_BEAM = HDR /* horizontal spot: 4 taps of linear src -> line (fp16) */
"const float hard=-4.0; void main(){ vec2 p=v_texcoord*fullSize; float fu=fract(p.x-0.5); vec3 a=vec3(0.0); float ws=0.0; for(int k=-1;k<=2;k++){ float d=float(k)-fu; float w=exp2(hard*d*d); vec2 uv=(floor(p-0.5)+vec2(float(k),0.0)+0.5)/fullSize; a+=w*pow(texture(tex,uv).rgb,vec3(2.2)); ws+=w;} fragColor=vec4(a/ws,1.0);}";
static const char* FS_SCAN = HDR /* tex=line, tex2=halo -> flat (rgba8): two nearest scanlines, brightness-dependent sigma, energy gain, mask, encode */
"void main(){ vec2 p=v_texcoord*fullSize; float v=p.y-0.5; float d0=fract(v); vec2 uv0=(vec2(p.x,floor(v)+0.5))/fullSize; vec2 uv1=uv0+vec2(0.0,1.0/fullSize.y);\n"
" vec3 l0=texture(tex,uv0).rgb, l1=texture(tex,uv1).rgb; float b0=dot(l0,vec3(0.3,0.59,0.11)), b1=dot(l1,vec3(0.3,0.59,0.11));\n"
" float s0=0.32+0.12*b0, s1=0.32+0.12*b1; float g0=min(1.0/(s0*1.7724539),1.28), g1=min(1.0/(s1*1.7724539),1.28);\n"
" vec3 c=l0*exp(-(d0*d0)/(s0*s0))*g0 + l1*exp(-((1.0-d0)*(1.0-d0))/(s1*s1))*g1; c=c*(1.0-0.14)+0.14*texture(tex2,v_texcoord).rgb;\n"
" int ph=int(mod(floor(p.x),3.0)); vec3 m=vec3(0.8); if(ph==0)m.r=1.26; else if(ph==1)m.g=1.26; else m.b=1.26; m*=1.0/((1.26+1.6)/3.0);\n"
" if(mod(floor(p.y)+3.0*float(int(mod(floor(p.x/3.0),2.0))),8.0)<1.0) m*=0.55; c*=m; fragColor=vec4(pow(clamp(c,0.0,1.0),vec3(1.0/2.4)),1.0);}";
static const char* FS_GLASS = HDR
"void main(){ vec2 pos=v_texcoord*2.0-1.0; vec2 w=pos*vec2(1.0+pos.y*pos.y*0.031,1.0+pos.x*pos.x*0.041); vec2 a=abs(w); float vig=1.0-0.22*(pos.x*pos.x*pos.x*pos.x+pos.y*pos.y*pos.y*pos.y)*0.5; if(a.x>1.0||a.y>1.0) vig=0.0; fragColor=vec4(texture(tex,w*0.5+0.5).rgb*vig,1.0);}";

static GLuint mkShader(GLenum t,const char* s){ GLuint sh=glCreateShader(t); glShaderSource(sh,1,&s,NULL); glCompileShader(sh); GLint ok; glGetShaderiv(sh,GL_COMPILE_STATUS,&ok); if(!ok){ char log[4096]; glGetShaderInfoLog(sh,4096,NULL,log); fprintf(stderr,"shader error: %s\n",log); exit(1);} return sh;}
static GLuint mkProg(const char* fs){ GLuint p=glCreateProgram(); glAttachShader(p,mkShader(GL_VERTEX_SHADER,VS)); glAttachShader(p,mkShader(GL_FRAGMENT_SHADER,fs)); glLinkProgram(p); GLint ok; glGetProgramiv(p,GL_LINK_STATUS,&ok); if(!ok){fprintf(stderr,"link error\n"); exit(1);} glUseProgram(p); glUniform1i(glGetUniformLocation(p,"tex"),0); glUniform1i(glGetUniformLocation(p,"tex2"),1); glUniform2f(glGetUniformLocation(p,"fullSize"),(float)W,(float)H); return p;}
static GLuint mkTex(GLenum ifmt, GLenum fmt, GLenum type, const void* data){ GLuint t; glGenTextures(1,&t); glBindTexture(GL_TEXTURE_2D,t); glTexImage2D(GL_TEXTURE_2D,0,ifmt,W,H,0,fmt,type,data); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE); glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE); return t;}
static GLuint mkFB(GLuint tex){ GLuint f; glGenFramebuffers(1,&f); glBindFramebuffer(GL_FRAMEBUFFER,f); glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,tex,0); if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){fprintf(stderr,"fbo incomplete\n"); exit(1);} return f;}
static void pass(GLuint prog, GLuint in0, GLuint in1, GLuint fb){ glUseProgram(prog); glBindFramebuffer(GL_FRAMEBUFFER,fb); glViewport(0,0,W,H); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D,in0); glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D,in1); glDrawArrays(GL_TRIANGLE_STRIP,0,4);}

int main(int argc,char**argv){
  if(argc>2){W=atoi(argv[1]);H=atoi(argv[2]);}
  int fd=open("/dev/dri/renderD128",O_RDWR|O_CLOEXEC); if(fd<0){perror("renderD128");return 1;}
  struct gbm_device* gbm=gbm_create_device(fd); if(!gbm){fprintf(stderr,"gbm fail\n");return 1;}
  PFNEGLGETPLATFORMDISPLAYEXTPROC getPlat=(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
  EGLDisplay dpy=getPlat(EGL_PLATFORM_GBM_KHR,gbm,NULL); if(dpy==EGL_NO_DISPLAY){fprintf(stderr,"no display\n");return 1;}
  if(!eglInitialize(dpy,NULL,NULL)){fprintf(stderr,"eglInitialize fail\n");return 1;}
  eglBindAPI(EGL_OPENGL_ES_API);
  EGLint cfgAttr[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_NONE}; EGLConfig cfg; EGLint n=0;
  eglChooseConfig(dpy,cfgAttr,&cfg,1,&n);
  EGLint ctxAttr[]={EGL_CONTEXT_MAJOR_VERSION,3,EGL_CONTEXT_MINOR_VERSION,2,EGL_NONE};
  EGLContext ctx=eglCreateContext(dpy,n?cfg:EGL_NO_CONFIG_KHR,EGL_NO_CONTEXT,ctxAttr); if(ctx==EGL_NO_CONTEXT){fprintf(stderr,"ctx fail %x\n",eglGetError());return 1;}
  if(!eglMakeCurrent(dpy,EGL_NO_SURFACE,EGL_NO_SURFACE,ctx)){fprintf(stderr,"makecurrent fail %x\n",eglGetError());return 1;}
  printf("GL_RENDERER: %s\nGL_VERSION: %s\nresolution: %dx%d\n",glGetString(GL_RENDERER),glGetString(GL_VERSION),W,H);

  GLuint vao,vbo; glGenVertexArrays(1,&vao); glBindVertexArray(vao); glGenBuffers(1,&vbo); glBindBuffer(GL_ARRAY_BUFFER,vbo);
  float verts[]={-1,-1,1,-1,-1,1,1,1}; glBufferData(GL_ARRAY_BUFFER,sizeof verts,verts,GL_STATIC_DRAW); glEnableVertexAttribArray(0); glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,0);
  unsigned char* px=malloc((size_t)W*H*4); for(size_t i=0;i<(size_t)W*H*4;i++) px[i]=(unsigned char)(rand()&255);
  GLuint src=mkTex(GL_RGBA8,GL_RGBA,GL_UNSIGNED_BYTE,px);
  GLuint out=mkTex(GL_RGBA8,GL_RGBA,GL_UNSIGNED_BYTE,NULL), fbOut=mkFB(out);
  GLuint flat=mkTex(GL_RGBA8,GL_RGBA,GL_UNSIGNED_BYTE,NULL), fbFlat=mkFB(flat);
  GLuint glowA=mkTex(GL_RGBA16F,GL_RGBA,GL_HALF_FLOAT,NULL), fbGlowA=mkFB(glowA);
  GLuint glowB=mkTex(GL_RGBA16F,GL_RGBA,GL_HALF_FLOAT,NULL), fbGlowB=mkFB(glowB);
  GLuint haloH=mkTex(GL_RGBA16F,GL_RGBA,GL_HALF_FLOAT,NULL), fbHaloH=mkFB(haloH);
  GLuint halo=mkTex(GL_RGBA16F,GL_RGBA,GL_HALF_FLOAT,NULL), fbHalo=mkFB(halo);
  GLuint line=mkTex(GL_RGBA16F,GL_RGBA,GL_HALF_FLOAT,NULL), fbLine=mkFB(line);
  GLuint pPass=mkProg(FS_PASS), pLottes=mkProg(FS_LOTTES), pGlow=mkProg(FS_GLOW), pHaloH=mkProg(FS_HALOH), pHaloV=mkProg(FS_HALOV), pBeam=mkProg(FS_BEAM), pScan=mkProg(FS_SCAN), pGlass=mkProg(FS_GLASS);
  glDisable(GL_BLEND);
  const int WARM=30, N=300;
  #define BENCH(name, ...) do{ for(int i=0;i<WARM;i++){ __VA_ARGS__; } glFinish(); double t0=now(); for(int i=0;i<N;i++){ __VA_ARGS__; } glFinish(); double dt=(now()-t0)/N*1000.0; printf("%-46s %7.3f ms/frame\n",name,dt);}while(0)
  BENCH("passthrough blit (baseline final pass)", pass(pPass,src,0,fbOut));
  BENCH("single-pass Lottes-style CRT (9 taps, warp, mask)", pass(pLottes,src,0,fbOut));
  int flip=0;
  BENCH("6-pass tube model 1:1 (glow,haloH,haloV,beam,scan,glass)", { GLuint gp=flip?glowB:glowA, gn=flip?glowA:glowB, fgn=flip?fbGlowA:fbGlowB; flip=!flip; pass(pGlow,src,gp,fgn); pass(pHaloH,src,gn,fbHaloH); pass(pHaloV,haloH,0,fbHalo); pass(pBeam,src,0,fbLine); pass(pScan,line,halo,fbFlat); pass(pGlass,flat,0,fbOut); });
  /* half-resolution variant of the halation chain: glow/halo at W/2 x H/2 would be ~4x cheaper; shown for scale */
  BENCH("3 passes only (beam,scan,glass) - no halation/afterglow", { pass(pBeam,src,0,fbLine); pass(pScan,line,halo,fbFlat); pass(pGlass,flat,0,fbOut); });
  BENCH("Lottes-style on 25% area (damage-tracked partial redraw)", { glEnable(GL_SCISSOR_TEST); glScissor(0,0,W/2,H/2); pass(pLottes,src,0,fbOut); glDisable(GL_SCISSOR_TEST); });
  return 0;
}
