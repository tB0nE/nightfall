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
/* Fixed generated-test protocol: one linear RGBA fd, three sequential clears.
 * glFinish/acknowledgements serialize ownership for this correctness spike.
 * Production asynchronous fences and a real output Surface remain separate. */
static int shared_import(const char *path) {
    int server=-1, client=-1, fd=-1, passed=0;
    GLuint memory=0, texture=0, fbo=0, unpack=0;
    const char *error="socket";
    unsigned pixels[3][4]={{0}};
    GLenum parameter_error=0, storage_error=0;
    PFNGLCREATEMEMORYOBJECTSEXTPROC create=(void *)eglGetProcAddress("glCreateMemoryObjectsEXT");
    PFNGLDELETEMEMORYOBJECTSEXTPROC destroy=(void *)eglGetProcAddress("glDeleteMemoryObjectsEXT");
    PFNGLIMPORTMEMORYFDEXTPROC import=(void *)eglGetProcAddress("glImportMemoryFdEXT");
    PFNGLBUFFERSTORAGEMEMEXTPROC storage=(void *)eglGetProcAddress("glBufferStorageMemEXT");
    server=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0);
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(server<0 || strlen(path)>=sizeof(address.sun_path))goto done;
    strcpy(address.sun_path,path);unlink(path);
    if(bind(server,(void *)&address,sizeof(address)) || chmod(path,0600) || listen(server,1))goto done;
    struct pollfd pending={.fd=server,.events=POLLIN};
    if(poll(&pending,1,2500)!=1){error="accept_timeout";goto done;}
    client=accept4(server,NULL,NULL,SOCK_CLOEXEC);
    if(client<0)goto done;
    struct timeval timeout={.tv_sec=2};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    struct ucred peer; socklen_t length=sizeof(peer);
    if(getsockopt(client,SOL_SOCKET,SO_PEERCRED,&peer,&length) || peer.uid!=getuid()){error="peer_uid";goto done;}
    uint32_t header[5]={0};
    union {struct cmsghdr alignment; char bytes[CMSG_SPACE(sizeof(int))];} control;
    memset(&control,0,sizeof(control));
    struct iovec vector={.iov_base=header,.iov_len=sizeof(header)};
    struct msghdr message={.msg_iov=&vector,.msg_iovlen=1,.msg_control=control.bytes,.msg_controllen=sizeof(control.bytes)};
    if(recvmsg(client,&message,MSG_CMSG_CLOEXEC)!=sizeof(header) || (message.msg_flags&(MSG_TRUNC|MSG_CTRUNC))){error="header";goto done;}
    struct cmsghdr *cmsg=CMSG_FIRSTHDR(&message);
    if(!cmsg || cmsg->cmsg_level!=SOL_SOCKET || cmsg->cmsg_type!=SCM_RIGHTS || cmsg->cmsg_len!=CMSG_LEN(sizeof(int))){error="fd";goto done;}
    memcpy(&fd,CMSG_DATA(cmsg),sizeof(fd));
    if(header[0]!=0x4e464742 || header[1]!=128 || header[2]!=128 || header[3]!=512 || header[4]!=65536){error="layout";goto done;}
    if(!create || !destroy || !import || !storage){error="functions";goto done;}
    create(1,&memory);import(memory,header[4],GL_HANDLE_TYPE_OPAQUE_FD_EXT,fd);
    GLenum glerror=glGetError();
    if(glerror){error="import_memory_fd";goto done;}
    fd=-1; /* Ownership transferred to GL. */
    glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA,128,128,0,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
    parameter_error=glGetError();
    glGenBuffers(1,&unpack);glBindBuffer(GL_PIXEL_UNPACK_BUFFER,unpack);
    storage(GL_PIXEL_UNPACK_BUFFER,65536,memory,0);
    storage_error=glGetError();
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);
    if(parameter_error || storage_error){error="buffer_storage";goto done;}
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE){error="framebuffer";goto done;}
    if(send(client,"K",1,MSG_NOSIGNAL)!=1)goto done;
    passed=1;
    for(int i=0;i<3;i++) {
        char command=0;
        if(recv(client,&command,1,0)!=1 || command!='0'+i){error="frame_command";passed=0;break;}
        glBindTexture(GL_TEXTURE_2D,texture);glBindBuffer(GL_PIXEL_UNPACK_BUFFER,unpack);
        glTexSubImage2D(GL_TEXTURE_2D,0,0,0,128,128,GL_RGBA,GL_UNSIGNED_BYTE,NULL);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);
        unsigned char pixel[4]={0};glReadPixels(10,10,1,1,GL_RGBA,GL_UNSIGNED_BYTE,pixel);glFinish();
        for(int c=0;c<4;c++)pixels[i][c]=pixel[c];
        if(glGetError() || pixel[2-i]!=255 || pixel[(3-i)%3]!=0 || pixel[(4-i)%3]!=0)passed=0;
        if(send(client,"K",1,MSG_NOSIGNAL)!=1){passed=0;break;}
    }
    error=passed?"none":"pixels";
done:
    printf("\"parameter_error\":%u,\"storage_error\":%u,",parameter_error,storage_error);
    printf("\"shared\":{\"passed\":%s,\"stage\":\"%s\",\"egl_error\":%u,\"gl_error\":%u,\"pixels\":[[%u,%u,%u,%u],[%u,%u,%u,%u],[%u,%u,%u,%u]]}",passed?"true":"false",error,eglGetError(),glGetError(),pixels[0][0],pixels[0][1],pixels[0][2],pixels[0][3],pixels[1][0],pixels[1][1],pixels[1][2],pixels[1][3],pixels[2][0],pixels[2][1],pixels[2][2],pixels[2][3]);
    glBindFramebuffer(GL_FRAMEBUFFER,0);
    if(fbo)glDeleteFramebuffers(1,&fbo);
    if(texture)glDeleteTextures(1,&texture);
    if(unpack)glDeleteBuffers(1,&unpack);
    if(memory && destroy)destroy(1,&memory);
    if(fd>=0)close(fd);
    if(client>=0)close(client);
    if(server>=0)close(server);
    unlink(path);
    return passed;
}
int main(int argc, char **argv) {
    alarm(argc==2?8:4);
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
    if(argc==2)ca[1]=3;
    EGLContext context=eglCreateContext(d,config,EGL_NO_CONTEXT,ca);
    EGLSurface surface=eglCreatePbufferSurface(d,config,sa);
    if (!eglMakeCurrent(d,surface,surface,context)) return 3;
    const char *gl_extensions=(const char *)glGetString(GL_EXTENSIONS);
    printf("\"memory_object_fd\":%d,\"renderer\":\"%s\",",extension(gl_extensions,"GL_EXT_memory_object_fd"),glGetString(GL_RENDERER));
    if(argc==2) {
        fflush(stdout);
        int passed=shared_import(argv[1]);puts("}");
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
