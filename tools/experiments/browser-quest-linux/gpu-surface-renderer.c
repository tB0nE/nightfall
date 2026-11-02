/* Experimental AHB -> existing Android Surface renderer. SPDX-License-Identifier: MIT */
#define _GNU_SOURCE
#include <jni.h>
#include <errno.h>
#include <android/native_window_jni.h>
#include <android/hardware_buffer.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    ANativeWindow *window;
    pthread_mutex_t lock;
    atomic_int stop, hz;
    int listener, client, width, height;
    char path[108];
} Renderer;
/* EGL_DEFAULT_DISPLAY is shared with framework rendering in this process.
 * Initialize once; never terminate the process-wide display from a session. */
static pthread_once_t display_once=PTHREAD_ONCE_INIT;
static EGLDisplay process_display=EGL_NO_DISPLAY;
static void initialize_display(void) {
    EGLDisplay display=eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if(eglInitialize(display,NULL,NULL))process_display=display;
}
static double seconds(void) { struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9; }
static void close_socket(Renderer *r,int *field) {
    pthread_mutex_lock(&r->lock);
    if(*field>=0){close(*field);*field=-1;}
    pthread_mutex_unlock(&r->lock);
}
static GLuint shader(GLenum kind,const char *source) {
    GLuint s=glCreateShader(kind);glShaderSource(s,1,&source,NULL);glCompileShader(s);
    GLint ok=0;glGetShaderiv(s,GL_COMPILE_STATUS,&ok);if(!ok){glDeleteShader(s);return 0;}return s;
}
JNIEXPORT jlong JNICALL Java_app_nightfall_browserlab_GpuFrameRenderer_nativeCreate(JNIEnv *env,jclass cls,jobject surface,jstring path,jint width,jint height) {
    (void)cls;
    if(!surface || !path || width<128 || height<128 || width>4096 || height>4096)return 0;
    const char *text=(*env)->GetStringUTFChars(env,path,NULL);if(!text)return 0;
    Renderer *r=calloc(1,sizeof(*r));
    if(!r || strlen(text)>=sizeof(r->path)){free(r);(*env)->ReleaseStringUTFChars(env,path,text);return 0;}
    strcpy(r->path,text);(*env)->ReleaseStringUTFChars(env,path,text);
    r->window=ANativeWindow_fromSurface(env,surface);
    if(!r->window){free(r);return 0;}
    pthread_mutex_init(&r->lock,NULL);r->listener=r->client=-1;r->width=width;r->height=height;
    atomic_init(&r->stop,0);atomic_init(&r->hz,60);return (jlong)(uintptr_t)r;
}
JNIEXPORT void JNICALL Java_app_nightfall_browserlab_GpuFrameRenderer_nativeStop(JNIEnv *env,jclass cls,jlong handle) {
    (void)env;(void)cls;Renderer *r=(void *)(uintptr_t)handle;if(!r)return;
    atomic_store(&r->stop,1);pthread_mutex_lock(&r->lock);
    if(r->client>=0)shutdown(r->client,SHUT_RDWR);
    if(r->listener>=0)shutdown(r->listener,SHUT_RDWR);
    pthread_mutex_unlock(&r->lock);
}
JNIEXPORT void JNICALL Java_app_nightfall_browserlab_GpuFrameRenderer_nativeSetHz(JNIEnv *env,jclass cls,jlong handle,jint hz) {
    (void)env;(void)cls;Renderer *r=(void *)(uintptr_t)handle;if(r && hz>=30 && hz<=120)atomic_store(&r->hz,hz);
}
JNIEXPORT void JNICALL Java_app_nightfall_browserlab_GpuFrameRenderer_nativeDestroy(JNIEnv *env,jclass cls,jlong handle) {
    (void)env;(void)cls;Renderer *r=(void *)(uintptr_t)handle;if(!r)return;
    close_socket(r,&r->client);close_socket(r,&r->listener);ANativeWindow_release(r->window);pthread_mutex_destroy(&r->lock);free(r);
}
JNIEXPORT jstring JNICALL Java_app_nightfall_browserlab_GpuFrameRenderer_nativeRun(JNIEnv *env,jclass cls,jlong handle) {
    (void)cls;Renderer *r=(void *)(uintptr_t)handle;if(!r)return NULL;
    EGLDisplay display=EGL_NO_DISPLAY;EGLContext context=EGL_NO_CONTEXT;EGLSurface surface=EGL_NO_SURFACE;
    EGLImageKHR image=EGL_NO_IMAGE_KHR;AHardwareBuffer *buffer=NULL;
    GLuint texture=0,fbo=0,program=0,vs=0,fs=0;int acquire_fd=-1,release_fd=-1;
    unsigned frames=0,imports=0,exports=0;double started=seconds(),draw_seconds=0,next_post=started;
    const char *stage="egl_init";int clean=0;
    PFNEGLCREATEIMAGEKHRPROC create_image=(void *)eglGetProcAddress("eglCreateImageKHR");
    PFNEGLDESTROYIMAGEKHRPROC destroy_image=(void *)eglGetProcAddress("eglDestroyImageKHR");
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC native_buffer=(void *)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target=(void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    PFNEGLCREATESYNCKHRPROC create_sync=(void *)eglGetProcAddress("eglCreateSyncKHR");
    PFNEGLDESTROYSYNCKHRPROC destroy_sync=(void *)eglGetProcAddress("eglDestroySyncKHR");
    PFNEGLDUPNATIVEFENCEFDANDROIDPROC dup_fence=(void *)eglGetProcAddress("eglDupNativeFenceFDANDROID");
    if(!create_image || !destroy_image || !native_buffer || !target || !create_sync || !destroy_sync || !dup_fence){stage="egl_functions";goto done;}
    pthread_once(&display_once,initialize_display);display=process_display;if(display==EGL_NO_DISPLAY)goto done;
    EGLint attributes[]={EGL_SURFACE_TYPE,EGL_WINDOW_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES3_BIT_KHR,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_ALPHA_SIZE,8,EGL_NONE};
    EGLConfig config;EGLint count=0;
    if(!eglChooseConfig(display,attributes,&config,1,&count) || !count){stage="egl_config";goto done;}
    EGLint visual=0;eglGetConfigAttrib(display,config,EGL_NATIVE_VISUAL_ID,&visual);
    if(ANativeWindow_setBuffersGeometry(r->window,r->width,r->height,visual)){stage="window_geometry";goto done;}
    EGLint context_attributes[]={EGL_CONTEXT_CLIENT_VERSION,3,EGL_NONE};
    context=eglCreateContext(display,config,EGL_NO_CONTEXT,context_attributes);
    surface=eglCreateWindowSurface(display,config,r->window,NULL);
    if(context==EGL_NO_CONTEXT || surface==EGL_NO_SURFACE || !eglMakeCurrent(display,surface,surface,context)){stage="egl_window";goto done;}
    eglSwapInterval(display,0);
    AHardwareBuffer_Desc description={.width=r->width,.height=r->height,.layers=1,.format=AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
        .usage=AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE|AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT|AHARDWAREBUFFER_USAGE_CPU_READ_RARELY};
    if(AHardwareBuffer_allocate(&description,&buffer)){stage="ahb_allocate";goto done;}
    AHardwareBuffer_describe(buffer,&description);
    EGLint image_attributes[]={EGL_IMAGE_PRESERVED_KHR,EGL_TRUE,EGL_NONE};
    image=create_image(display,EGL_NO_CONTEXT,EGL_NATIVE_BUFFER_ANDROID,native_buffer(buffer),image_attributes);
    if(image==EGL_NO_IMAGE_KHR){stage="ahb_image";goto done;}
    glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);target(GL_TEXTURE_2D,image);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){stage="ahb_framebuffer";goto done;}
    vs=shader(GL_VERTEX_SHADER,"#version 300 es\nout vec2 uv;void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=vec2(p.x,1.-p.y);gl_Position=vec4(p*2.-1.,0,1);}");
    fs=shader(GL_FRAGMENT_SHADER,"#version 300 es\nprecision mediump float;in vec2 uv;uniform sampler2D image;out vec4 color;void main(){color=vec4(texture(image,uv).rgb,1.);}");
    if(!vs || !fs){stage="shader_compile";goto done;}
    program=glCreateProgram();glAttachShader(program,vs);glAttachShader(program,fs);glLinkProgram(program);
    GLint linked=0;glGetProgramiv(program,GL_LINK_STATUS,&linked);if(!linked){stage="shader_link";goto done;}
    int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0);
    pthread_mutex_lock(&r->lock);r->listener=listener;pthread_mutex_unlock(&r->lock);
    if(listener<0){stage="socket";goto done;}
    struct sockaddr_un address={.sun_family=AF_UNIX};strcpy(address.sun_path,r->path);unlink(r->path);
    if(bind(listener,(void *)&address,sizeof(address)) || chmod(r->path,0600) || listen(listener,1)){stage="socket_bind";goto done;}
    double deadline=seconds()+8;
    struct pollfd pending={.fd=listener,.events=POLLIN};
    while(!atomic_load(&r->stop) && seconds()<deadline){if(poll(&pending,1,100)>0)break;}
    if(atomic_load(&r->stop)){clean=1;stage="stopped";goto done;}
    if(seconds()>=deadline){stage="accept_timeout";goto done;}
    int client=accept4(listener,NULL,NULL,SOCK_CLOEXEC);
    pthread_mutex_lock(&r->lock);r->client=client;pthread_mutex_unlock(&r->lock);
    if(client<0){stage="accept";goto done;}
    struct ucred peer;socklen_t peer_length=sizeof(peer);
    if(getsockopt(client,SOL_SOCKET,SO_PEERCRED,&peer,&peer_length) || peer.uid!=getuid()){stage="peer_uid";goto done;}
    struct timeval timeout={.tv_sec=2};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    uint32_t header[4]={0x4e464142,description.width,description.height,description.stride*4};
    if(send(client,header,sizeof(header),MSG_NOSIGNAL)!=sizeof(header) || AHardwareBuffer_sendHandleToUnixSocket(buffer,client)){stage="ahb_send";goto done;}
    started=seconds();next_post=started;
    while(!atomic_load(&r->stop)) {
        char command=0;union {struct cmsghdr alignment;char data[CMSG_SPACE(sizeof(int))];} control;memset(&control,0,sizeof(control));
        struct iovec vector={.iov_base=&command,.iov_len=1};
        struct msghdr message={.msg_iov=&vector,.msg_iovlen=1,.msg_control=control.data,.msg_controllen=sizeof(control.data)};
        if(recvmsg(client,&message,MSG_CMSG_CLOEXEC)!=1){stage=atomic_load(&r->stop)?"stopped":"receive";clean=atomic_load(&r->stop);goto done;}
        struct cmsghdr *cmsg=CMSG_FIRSTHDR(&message);
        if(cmsg && cmsg->cmsg_level==SOL_SOCKET && cmsg->cmsg_type==SCM_RIGHTS && cmsg->cmsg_len==CMSG_LEN(sizeof(int)))memcpy(&acquire_fd,CMSG_DATA(cmsg),sizeof(acquire_fd));
        if(command=='Q'){clean=frames>0;stage="closed";goto done;}
        if((command!='F' && command!='R' && command!='P') || acquire_fd<0 || (message.msg_flags&(MSG_TRUNC|MSG_CTRUNC))){stage="protocol";goto done;}
        /* KGSL hangs were observed under interactive load with GPU-side
         * cross-driver waits. Keep shared-buffer ownership CPU-bounded until
         * the driver fault is understood; there is still no pixel memcpy. */
        struct pollfd acquire_poll={.fd=acquire_fd,.events=POLLIN|POLLERR};
        double acquire_deadline=seconds()+.1;int ready;
        do {
            double remaining=acquire_deadline-seconds();
            if(remaining<=0){ready=0;break;}
            ready=poll(&acquire_poll,1,(int)(remaining*1000)+1);
        }while(ready<0 && errno==EINTR);
        if(ready<=0 || !(acquire_poll.revents&POLLIN) || (acquire_poll.revents&(POLLERR|POLLHUP|POLLNVAL))){stage=ready==0?"acquire_timeout":"acquire_failed";goto done;}
        close(acquire_fd);acquire_fd=-1;imports++;
        unsigned char reply[16]={'K',0,0,0};unsigned reply_size=4;
        if(command=='R' || command=='P'){
            const GLint positions[4][2]={{100,100},{1100,100},{100,620},{1100,620}};unsigned samples=command=='P'?4:1;
            glBindFramebuffer(GL_FRAMEBUFFER,fbo);
            for(unsigned i=0;i<samples;i++)glReadPixels(positions[i][0],positions[i][1],1,1,GL_RGBA,GL_UNSIGNED_BYTE,reply+4*i);
            reply_size=4*samples;
        }
        double draw_start=seconds();
        glBindFramebuffer(GL_FRAMEBUFFER,0);glViewport(0,0,r->width,r->height);glUseProgram(program);glUniform1i(glGetUniformLocation(program,"image"),0);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,texture);glDrawArrays(GL_TRIANGLES,0,3);
        EGLSyncKHR release=create_sync(display,EGL_SYNC_NATIVE_FENCE_ANDROID,NULL);
        if(release==EGL_NO_SYNC_KHR || glGetError()){if(release!=EGL_NO_SYNC_KHR)destroy_sync(display,release);stage="draw_fence";goto done;}
        glFlush();release_fd=dup_fence(display,release);destroy_sync(display,release);if(release_fd<0){stage="release_export";goto done;}
        if(!eglSwapBuffers(display,surface)){stage="swap";goto done;}
        draw_seconds+=seconds()-draw_start;frames++;
        memset(&control,0,sizeof(control));vector.iov_base=reply;vector.iov_len=reply_size;
        message=(struct msghdr){.msg_iov=&vector,.msg_iovlen=1,.msg_control=control.data,.msg_controllen=sizeof(control.data)};
        cmsg=CMSG_FIRSTHDR(&message);cmsg->cmsg_level=SOL_SOCKET;cmsg->cmsg_type=SCM_RIGHTS;cmsg->cmsg_len=CMSG_LEN(sizeof(int));memcpy(CMSG_DATA(cmsg),&release_fd,sizeof(release_fd));
        if(sendmsg(client,&message,MSG_NOSIGNAL)!=(ssize_t)reply_size){stage="release_send";goto done;}close(release_fd);release_fd=-1;exports++;
        next_post+=1.0/atomic_load(&r->hz);double pause=next_post-seconds();if(pause>0 && pause<.1){struct timespec t={.tv_sec=0,.tv_nsec=(long)(pause*1e9)};nanosleep(&t,NULL);}else next_post=seconds();
    }
    clean=1;stage="stopped";
done:
    if(atomic_load(&r->stop)){clean=1;stage="stopped";}
    if(acquire_fd>=0)close(acquire_fd);if(release_fd>=0)close(release_fd);
    close_socket(r,&r->client);close_socket(r,&r->listener);unlink(r->path);
    if(context!=EGL_NO_CONTEXT){glBindFramebuffer(GL_FRAMEBUFFER,0);if(fbo)glDeleteFramebuffers(1,&fbo);if(texture)glDeleteTextures(1,&texture);if(program)glDeleteProgram(program);if(vs)glDeleteShader(vs);if(fs)glDeleteShader(fs);}
    if(image!=EGL_NO_IMAGE_KHR)destroy_image(display,image);if(buffer)AHardwareBuffer_release(buffer);
    if(display!=EGL_NO_DISPLAY){eglMakeCurrent(display,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);if(surface!=EGL_NO_SURFACE)eglDestroySurface(display,surface);if(context!=EGL_NO_CONTEXT)eglDestroyContext(display,context);}
    double elapsed=seconds()-started;char status[768];
    snprintf(status,sizeof(status),"{\"state\":\"%s\",\"stage\":\"%s\",\"posted_frames\":%u,\"imported_fences\":%u,\"exported_fences\":%u,\"elapsed_s\":%.6f,\"posted_fps\":%.3f,\"mean_draw_ms\":%.3f,\"width\":%d,\"height\":%d,\"drawing\":\"native_egl_ahb\",\"full_frame_cpu_copy\":false,\"interop_wait\":\"cpu_poll_100ms\"}",clean?"stopped":"error",stage,frames,imports,exports,elapsed,elapsed>0?frames/elapsed:0,frames?draw_seconds*1000/frames:0,r->width,r->height);
    return (*env)->NewStringUTF(env,status);
}
