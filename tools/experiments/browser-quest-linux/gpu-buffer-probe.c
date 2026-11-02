/* Generated-content Android GPU sharing probe. SPDX-License-Identifier: MIT */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <stdint.h>
#include <stdlib.h>
#include <errno.h>
#include <poll.h>
static int extension(const char *list, const char *name) {
    size_t n = strlen(name); const char *p = list;
    while (p && (p = strstr(p, name))) {
        if ((p == list || p[-1] == ' ') && (!p[n] || p[n] == ' ')) return 1;
        p += n;
    }
    return 0;
}
/* Native Android owns the gralloc metadata; Linux receives its generated
 * buffer handle and renders into its linear RGBA dma-buf. Ownership is serialized
 * with glFinish/ack for this spike; production native fences are still required. */
static int shared_import(const char *path, unsigned width, unsigned height, int continuous) {
    int server=-1,client=-1,passed=0;
    GLuint texture=0,fbo=0;
    AHardwareBuffer *buffer=NULL;
    EGLDisplay display=eglGetCurrentDisplay();
    EGLImageKHR image=EGL_NO_IMAGE_KHR;
    const char *error="socket";
    unsigned pixels[3][4]={{0}};
    unsigned frames=0, fences=0, releases=0;
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC get_client=(void *)eglGetProcAddress("eglGetNativeClientBufferANDROID");
    PFNEGLCREATEIMAGEKHRPROC create=(void *)eglGetProcAddress("eglCreateImageKHR");
    PFNEGLDESTROYIMAGEKHRPROC destroy=(void *)eglGetProcAddress("eglDestroyImageKHR");
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target=(void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
    server=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0);
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(server<0 || strlen(path)>=sizeof(address.sun_path))goto done;
    strcpy(address.sun_path,path);unlink(path);
    if(bind(server,(void *)&address,sizeof(address)) || chmod(path,0600) || listen(server,1))goto done;
    struct pollfd pending={.fd=server,.events=POLLIN};
    if(poll(&pending,1,continuous?8000:2500)!=1){error="accept_timeout";goto done;}
    client=accept4(server,NULL,NULL,SOCK_CLOEXEC);
    if(client<0)goto done;
    struct timeval timeout={.tv_sec=2};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    struct ucred peer; socklen_t length=sizeof(peer);
    if(getsockopt(client,SOL_SOCKET,SO_PEERCRED,&peer,&length) || peer.uid!=getuid()){error="peer_uid";goto done;}
    AHardwareBuffer_Desc desc={.width=width,.height=height,.layers=1,.format=AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
        .usage=AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT|AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE|AHARDWAREBUFFER_USAGE_CPU_READ_RARELY};
    if(AHardwareBuffer_allocate(&desc,&buffer)){error="allocation";goto done;}
    AHardwareBuffer_describe(buffer,&desc);
    if(!get_client || !create || !destroy || !target){error="functions";goto done;}
    EGLint ia[]={EGL_IMAGE_PRESERVED_KHR,EGL_TRUE,EGL_NONE};
    image=create(display,EGL_NO_CONTEXT,EGL_NATIVE_BUFFER_ANDROID,get_client(buffer),ia);
    if(image==EGL_NO_IMAGE_KHR){error="native_image";goto done;}
    glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);target(GL_TEXTURE_2D,image);
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){error="framebuffer";goto done;}
    uint32_t header[4]={0x4e464142,desc.width,desc.height,desc.stride*4};
    if(send(client,header,sizeof(header),MSG_NOSIGNAL)!=sizeof(header)){error="header";goto done;}
    if(AHardwareBuffer_sendHandleToUnixSocket(buffer,client)){error="send_handle";goto done;}
    if(continuous) {
        for(unsigned sample=0;sample<2000;sample++) {
            char command=0;
            union {struct cmsghdr alignment;char data[CMSG_SPACE(sizeof(int))];} control;
            memset(&control,0,sizeof(control));
            struct iovec vector={.iov_base=&command,.iov_len=1};
            struct msghdr message={.msg_iov=&vector,.msg_iovlen=1,.msg_control=control.data,.msg_controllen=sizeof(control.data)};
            if(recvmsg(client,&message,MSG_CMSG_CLOEXEC)!=1){error="capture_command";goto done;}
            int fence_fd=-1;
            struct cmsghdr *cmsg=CMSG_FIRSTHDR(&message);
            if(cmsg && cmsg->cmsg_level==SOL_SOCKET && cmsg->cmsg_type==SCM_RIGHTS && cmsg->cmsg_len==CMSG_LEN(sizeof(int)))memcpy(&fence_fd,CMSG_DATA(cmsg),sizeof(fence_fd));
            if(command=='Q'){
                if(fence_fd>=0)close(fence_fd);
                passed=frames>0 && frames==fences && frames==releases;error=passed?"none":"no_frames";goto done;
            }
            if((command!='F' && command!='P') || fence_fd<0 || (message.msg_flags&(MSG_TRUNC|MSG_CTRUNC))){if(fence_fd>=0)close(fence_fd);error="capture_protocol";goto done;}
            struct pollfd incoming={.fd=fence_fd,.events=POLLIN|POLLERR};
            int ready=poll(&incoming,1,100);close(fence_fd);
            if(ready!=1 || !(incoming.revents&POLLIN) || (incoming.revents&(POLLERR|POLLHUP|POLLNVAL))){error="fence_wait";goto done;}
            fences++;
            unsigned char pixel[16]={0};
            const GLint positions[4][2]={{100,100},{1100,100},{100,620},{1100,620}};
            unsigned samples=command=='P'?4:1;
            for(unsigned n=0;n<samples;n++)glReadPixels(positions[n][0],positions[n][1],1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel+4*n);
            glFinish();
            if(glGetError()){error="capture_read";goto done;}
            for(int c=0;c<4;c++)pixels[0][c]=pixel[c];
            PFNEGLCREATESYNCKHRPROC create_sync=(void *)eglGetProcAddress("eglCreateSyncKHR");
            PFNEGLDESTROYSYNCKHRPROC destroy_sync=(void *)eglGetProcAddress("eglDestroySyncKHR");
            PFNEGLDUPNATIVEFENCEFDANDROIDPROC dup_sync=(void *)eglGetProcAddress("eglDupNativeFenceFDANDROID");
            if(!create_sync || !destroy_sync || !dup_sync){error="release_functions";goto done;}
            EGLSyncKHR sync=create_sync(display,EGL_SYNC_NATIVE_FENCE_ANDROID,NULL);
            if(sync==EGL_NO_SYNC_KHR){error="release_create";goto done;}
            glFlush();int release=dup_sync(display,sync);destroy_sync(display,sync);
            if(release<0){error="release_export";goto done;}
            memset(&control,0,sizeof(control));vector.iov_base=pixel;vector.iov_len=4*samples;
            message=(struct msghdr){.msg_iov=&vector,.msg_iovlen=1,.msg_control=control.data,.msg_controllen=sizeof(control.data)};
            cmsg=CMSG_FIRSTHDR(&message);cmsg->cmsg_level=SOL_SOCKET;cmsg->cmsg_type=SCM_RIGHTS;cmsg->cmsg_len=CMSG_LEN(sizeof(int));memcpy(CMSG_DATA(cmsg),&release,sizeof(release));
            ssize_t sent=sendmsg(client,&message,MSG_NOSIGNAL);close(release);
            if(sent!=(ssize_t)(4*samples)){error="capture_ack";goto done;}
            releases++;
            frames++;
        }
        error="capture_limit";goto done;
    }
    passed=1;
    for(int i=0;i<3;i++) {
        char command=0;
        if(recv(client,&command,1,0)!=1 || command!='0'+i){error="frame_command";passed=0;break;}
        unsigned char pixel[4]={0};glReadPixels(10,10,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);glFinish();
        for(int c=0;c<4;c++)pixels[i][c]=pixel[c];
        if(glGetError() || pixel[i]!=255 || pixel[(i+1)%3]!=0 || pixel[(i+2)%3]!=0)passed=0;
        if(send(client,"K",1,MSG_NOSIGNAL)!=1){passed=0;break;}
    }
    error=passed?"none":"pixels";
done:
    printf("\"capture_frames\":%u,\"imported_fences\":%u,\"exported_fences\":%u,",frames,fences,releases);
    printf("\"shared\":{\"method\":\"android_hardware_buffer\",\"passed\":%s,\"stage\":\"%s\",\"egl_error\":%u,\"gl_error\":%u,\"pixels\":[[%u,%u,%u,%u],[%u,%u,%u,%u],[%u,%u,%u,%u]]}",passed?"true":"false",error,eglGetError(),glGetError(),pixels[0][0],pixels[0][1],pixels[0][2],pixels[0][3],pixels[1][0],pixels[1][1],pixels[1][2],pixels[1][3],pixels[2][0],pixels[2][1],pixels[2][2],pixels[2][3]);
    glBindFramebuffer(GL_FRAMEBUFFER,0);
    if(fbo)glDeleteFramebuffers(1,&fbo);
    if(texture)glDeleteTextures(1,&texture);
    if(image!=EGL_NO_IMAGE_KHR && destroy)destroy(display,image);
    if(buffer)AHardwareBuffer_release(buffer);
    if(client>=0)close(client);
    if(server>=0)close(server);
    unlink(path);
    return passed;
}
int main(int argc, char **argv) {
    alarm(argc==5?24:argc>=2?8:4);
    EGLDisplay d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    EGLint major = 0, minor = 0, count = 0;
    if (!eglInitialize(d, &major, &minor)) { puts("{\"error\":\"eglInitialize\"}"); return 1; }
    const char *extensions = eglQueryString(d, EGL_EXTENSIONS);
    printf("{\"egl\":[%d,%d],\"dma_buf_import\":%d,\"dma_buf_modifiers\":%d,\"native_buffer\":%d,\"native_fence\":%d,",major,minor,
        extension(extensions,"EGL_EXT_image_dma_buf_import"),extension(extensions,"EGL_EXT_image_dma_buf_import_modifiers"),
        extension(extensions,"EGL_ANDROID_image_native_buffer"),extension(extensions,"EGL_ANDROID_native_fence_sync"));
    EGLint attrs[] = {EGL_SURFACE_TYPE,EGL_PBUFFER_BIT,EGL_RENDERABLE_TYPE,EGL_OPENGL_ES2_BIT,EGL_RED_SIZE,8,EGL_GREEN_SIZE,8,EGL_BLUE_SIZE,8,EGL_NONE};
    EGLConfig config;
    if (!eglChooseConfig(d,attrs,&config,1,&count) || !count) return 2;
    EGLint ca[] = {EGL_CONTEXT_CLIENT_VERSION,2,EGL_NONE}, sa[] = {EGL_WIDTH,64,EGL_HEIGHT,64,EGL_NONE};
    if(argc>=2)ca[1]=3;
    EGLContext context=eglCreateContext(d,config,EGL_NO_CONTEXT,ca);
    EGLSurface surface=eglCreatePbufferSurface(d,config,sa);
    if (!eglMakeCurrent(d,surface,surface,context)) return 3;
    const char *gl_extensions=(const char *)glGetString(GL_EXTENSIONS);
    printf("\"memory_object_fd\":%d,\"renderer\":\"%s\",",extension(gl_extensions,"GL_EXT_memory_object_fd"),glGetString(GL_RENDERER));
    if(argc>=2) {
        fflush(stdout);
        unsigned width=argc>=4?(unsigned)atoi(argv[2]):128;
        unsigned height=argc>=4?(unsigned)atoi(argv[3]):128;
        if(!((width==128 && height==128) || (width==1280 && height==720)))return 6;
        int passed=shared_import(argv[1],width,height,argc==5 && strcmp(argv[4],"capture")==0);puts("}");
        eglMakeCurrent(d,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);
        eglDestroySurface(d,surface);eglDestroyContext(d,context);eglTerminate(d);
        return passed?0:5;
    }
    AHardwareBuffer *buffer=NULL;
    AHardwareBuffer_Desc desc={.width=64,.height=64,.layers=1,.format=AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM,
        .usage=AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT|AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE|AHARDWAREBUFFER_USAGE_CPU_READ_RARELY};
    int allocation=AHardwareBuffer_allocate(&desc,&buffer);
    printf("\"ahb_allocation\":%d,",allocation);
    int passed=0;
    if (!allocation) {
        AHardwareBuffer_describe(buffer,&desc);
        PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC client=(void *)eglGetProcAddress("eglGetNativeClientBufferANDROID");
        PFNEGLCREATEIMAGEKHRPROC create=(void *)eglGetProcAddress("eglCreateImageKHR");
        PFNEGLDESTROYIMAGEKHRPROC destroy=(void *)eglGetProcAddress("eglDestroyImageKHR");
        PFNGLEGLIMAGETARGETTEXTURE2DOESPROC target=(void *)eglGetProcAddress("glEGLImageTargetTexture2DOES");
        EGLint ia[]={EGL_IMAGE_PRESERVED_KHR,EGL_TRUE,EGL_NONE};
        EGLImageKHR image=client && create ? create(d,EGL_NO_CONTEXT,EGL_NATIVE_BUFFER_ANDROID,client(buffer),ia) : EGL_NO_IMAGE_KHR;
        if (image!=EGL_NO_IMAGE_KHR && target) {
            GLuint texture=0,fbo=0; glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
            target(GL_TEXTURE_2D,image);glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
            passed=glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE;
            for(int i=0;i<3 && passed;i++) {
                glClearColor(i==0,i==1,i==2,1);glClear(GL_COLOR_BUFFER_BIT);glFinish();
                unsigned char pixel[4]={0};glReadPixels(1,1,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);
                passed=pixel[i]==255 && pixel[(i+1)%3]==0 && pixel[(i+2)%3]==0 && glGetError()==GL_NO_ERROR;
            }
            glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&texture);destroy(d,image);
        }
        AHardwareBuffer_release(buffer);
    }
    printf("\"stride\":%u,\"generated_rgb_passed\":%s}\n",desc.stride,passed?"true":"false");
    eglMakeCurrent(d,EGL_NO_SURFACE,EGL_NO_SURFACE,EGL_NO_CONTEXT);eglDestroySurface(d,surface);eglDestroyContext(d,context);eglTerminate(d);
    return passed?0:4;
}
