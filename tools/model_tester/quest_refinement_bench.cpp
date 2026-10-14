// Standalone Android GLES microbenchmark; does not modify/install Nightfall.
// Usage: bench DIR GUIDE_WIDTH GUIDE_HEIGHT
// DIR contains depth.r8 (512x288), guide.rgb and the two experimental shaders.
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

static std::string read(const std::string& p) {
    std::ifstream f(p, std::ios::binary);
    if (!f) throw std::runtime_error("cannot read " + p);
    return {std::istreambuf_iterator<char>(f), {}};
}
static GLuint shader(GLenum type, const std::string& src) {
    GLuint s=glCreateShader(type); const char* p=src.c_str();
    glShaderSource(s,1,&p,nullptr);glCompileShader(s);
    GLint ok;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
    if(!ok){char log[8192];glGetShaderInfoLog(s,sizeof(log),nullptr,log);throw std::runtime_error(log);}
    return s;
}
static GLuint program(std::string fragment) {
    // Production GLES shaders already declare precision after extensions.
    // Only desktop trial shaders need precision injected here.
    bool desktop=fragment.find("#version 430 core")==0;
    fragment.replace(0,fragment.find('\n'),desktop ? "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;" : "#version 300 es");
    GLuint v=shader(GL_VERTEX_SHADER,"#version 300 es\nout vec2 v_plain;\nvoid main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));v_plain=p;gl_Position=vec4(p*2.0-1.0,0,1);}");
    GLuint f=shader(GL_FRAGMENT_SHADER,fragment),p=glCreateProgram();
    glAttachShader(p,v);glAttachShader(p,f);glLinkProgram(p);
    GLint ok;glGetProgramiv(p,GL_LINK_STATUS,&ok);
    if(!ok){char log[8192];glGetProgramInfoLog(p,sizeof(log),nullptr,log);throw std::runtime_error(log);}
    glDeleteShader(v);glDeleteShader(f);return p;
}
static GLuint texture(int w,int h,GLenum format,GLenum internal,const void* data) {
    GLuint t;glGenTextures(1,&t);glBindTexture(GL_TEXTURE_2D,t);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D,0,internal,w,h,0,format,internal==GL_RGBA16F?GL_HALF_FLOAT:GL_UNSIGNED_BYTE,data);return t;
}
static void draw(GLuint p,GLuint fbo,GLuint depth,GLuint guide,int w,int h) {
    glBindFramebuffer(GL_FRAMEBUFFER,fbo);glViewport(0,0,w,h);glUseProgram(p);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,depth);
    glUniform1i(glGetUniformLocation(p,"u_depth"),0);
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,guide);
    glUniform1i(glGetUniformLocation(p,"u_guide"),1);
    glUniform1f(glGetUniformLocation(p,"u_radius"),2.f);
    glUniform1f(glGetUniformLocation(p,"u_strength"),.75f);
    const GLfloat identity[16]={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1};
    glUniformMatrix4fv(glGetUniformLocation(p,"u_texmatrix"),1,GL_FALSE,identity);
    glDrawArrays(GL_TRIANGLES,0,3);
}
int main(int argc,char** argv) try {
    if(argc!=4)throw std::runtime_error("usage: bench DIR GUIDE_WIDTH GUIDE_HEIGHT");
    std::string dir=argv[1];int gw=atoi(argv[2]),gh=atoi(argv[3]);
    auto depth=read(dir+"/depth.r8"),guide=read(dir+"/guide.rgb");
    if(depth.size()!=512*288 || guide.size()!=size_t(gw)*gh*3)throw std::runtime_error("fixture size mismatch");
    EGLDisplay display=eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if(!eglInitialize(display,nullptr,nullptr))throw std::runtime_error("eglInitialize failed");
    EGLint attrs[]={EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_NONE};
    EGLConfig config;EGLint n;
    eglChooseConfig(display,attrs,&config,1,&n);if(!n)throw std::runtime_error("no EGL config");
    EGLint ca[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE},pa[]={EGL_WIDTH,1,EGL_HEIGHT,1,EGL_NONE};
    auto ctx=eglCreateContext(display,config,EGL_NO_CONTEXT,ca);auto surface=eglCreatePbufferSurface(display,config,pa);
    if(!eglMakeCurrent(display,surface,surface,ctx))throw std::runtime_error("eglMakeCurrent failed");
    printf("GPU=%s GL=%s guide=%dx%d depth=512x288\n",glGetString(GL_RENDERER),glGetString(GL_VERSION),gw,gh);
    bool hasTimer=false;GLint extCount;glGetIntegerv(GL_NUM_EXTENSIONS,&extCount);
    for(int i=0;i<extCount;i++)if(std::string((const char*)glGetStringi(GL_EXTENSIONS,i))=="GL_EXT_disjoint_timer_query")hasTimer=true;
    if(!hasTimer)throw std::runtime_error("GPU timer queries unavailable; refusing CPU-only timing");
    auto gen=(PFNGLGENQUERIESEXTPROC)eglGetProcAddress("glGenQueriesEXT");
    auto begin=(PFNGLBEGINQUERYEXTPROC)eglGetProcAddress("glBeginQueryEXT");
    auto end=(PFNGLENDQUERYEXTPROC)eglGetProcAddress("glEndQueryEXT");
    auto result=(PFNGLGETQUERYOBJECTUI64VEXTPROC)eglGetProcAddress("glGetQueryObjectui64vEXT");
    auto del=(PFNGLDELETEQUERIESEXTPROC)eglGetProcAddress("glDeleteQueriesEXT");
    if(!gen||!begin||!end||!result||!del)throw std::runtime_error("missing query functions");
    GLuint align=program(read(dir+"/edge_alignment.glsl")),cleanup=program(read(dir+"/depth_contour_cleanup.glsl"));
    if(std::ifstream(dir+"/edge_alignment_oes.glsl")) {
        GLuint oes=program(read(dir+"/edge_alignment_oes.glsl"));glDeleteProgram(oes);
        printf("Production external-OES alignment shader compiled and linked\n");
    }
    GLuint linear=program("#version 430 core\nin vec2 v_plain;uniform sampler2D u_depth;out vec4 fragColor;void main(){fragColor=vec4(texture(u_depth,v_plain).r);}");
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);
    GLuint dt=texture(512,288,GL_RED,GL_R8,depth.data()),gt=texture(gw,gh,GL_RGB,GL_RGB8,guide.data());
    GLuint vao;glGenVertexArrays(1,&vao);glBindVertexArray(vao);
    for(auto size: {std::pair<int,int>{512,288},{480,270},{640,360},{960,540}}) {
        int w=size.first,h=size.second;
        GLuint a=texture(w,h,GL_RGBA,GL_RGBA8,nullptr),b=texture(w,h,GL_RGBA,GL_RGBA16F,nullptr),fb[2];
        glGenFramebuffers(2,fb);
        for(int i=0;i<2;i++){glBindFramebuffer(GL_FRAMEBUFFER,fb[i]);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,i?b:a,0);if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE)throw std::runtime_error("incomplete FBO");}
        for(int round=0;round<2;round++) for(int mode=0;mode<3;mode++) {
            auto render=[&](){draw(mode?align:linear,fb[0],dt,gt,w,h);if(mode==2)draw(cleanup,fb[1],a,gt,w,h);};
            for(int i=0;i<30;i++)render();glFinish();
            std::vector<double> gpu,cpu;int rejected=0;
            for(int i=0;i<100;i++) {
                GLint disjoint;glGetIntegerv(GL_GPU_DISJOINT_EXT,&disjoint);
                GLuint q;gen(1,&q);glFinish();auto start=std::chrono::steady_clock::now();
                begin(GL_TIME_ELAPSED_EXT,q);render();end(GL_TIME_ELAPSED_EXT);glFinish();
                auto done=std::chrono::steady_clock::now();GLuint64 ns;result(q,GL_QUERY_RESULT_EXT,&ns);del(1,&q);
                glGetIntegerv(GL_GPU_DISJOINT_EXT,&disjoint);
                if(disjoint){rejected++;continue;}
                gpu.push_back(ns/1e6);cpu.push_back(std::chrono::duration<double,std::milli>(done-start).count());
            }
            if(gpu.empty())throw std::runtime_error("all GPU timings disjoint");
            std::sort(gpu.begin(),gpu.end());std::sort(cpu.begin(),cpu.end());
            printf("round=%d size=%dx%d mode=%s valid=%zu disjoint=%d gpu_p50_ms=%.4f gpu_p95_ms=%.4f wall_p50_ms=%.4f\n",round,w,h,mode==0?"linear":mode==1?"alignment":"alignment+cleanup",gpu.size(),rejected,gpu[gpu.size()/2],gpu[(gpu.size()-1)*95/100],cpu[cpu.size()/2]);fflush(stdout);
        }
        glDeleteFramebuffers(2,fb);glDeleteTextures(1,&a);glDeleteTextures(1,&b);
    }
    if(glGetError()!=GL_NO_ERROR)throw std::runtime_error("GL error during benchmark");
    eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);eglDestroySurface(display,surface);eglDestroyContext(display,ctx);eglTerminate(display);
    return 0;
} catch(const std::exception& e){fprintf(stderr,"ERROR: %s\n",e.what());return 1;}
