#!/usr/bin/python3
"""Generated-test XComposite pixmap -> GPU blit -> Android-owned AHB.
No full-frame readback. One source/receiver pixel is read for synchronization
and correctness only. Producer completion uses native fence FDs. Release waits are CPU-bounded after observed KGSL hangs.
"""
import array
import ctypes as c
import os
import re
import select
import socket
import struct
import subprocess

def fn(lib,name,result,args):
    f=getattr(lib,name);f.restype=result;f.argtypes=args;return f

def wait_cpu_fence(fd,timeout_ms=100):
    """Wait only on a sync-file signal, never submit a cross-driver GPU wait.
    Caller retains FD ownership and closes it, including on timeout/error.
    """
    poll=select.poll();poll.register(fd,select.POLLIN|select.POLLERR)
    events=poll.poll(timeout_ms)
    if not events:raise TimeoutError('GPU release fence timed out')
    mask=events[0][1]
    if mask&(select.POLLERR|select.POLLHUP|select.POLLNVAL) or not mask&select.POLLIN:
        raise RuntimeError('GPU release fence failed')

def apply_driver_policy(policy):
    """Set app-private Mesa diagnostics before loading its EGL library."""
    if policy not in ('default','sysmem','linear'):
        raise ValueError('Invalid GPU driver diagnostic policy')
    if policy=='sysmem':os.environ['FD_MESA_DEBUG']='sysmem'
    if policy=='linear':os.environ['FD_MESA_DEBUG']='notile,noubwc'
    return policy

def validate_linear_buffer(width,height,stride,allocation_size):
    """Reject layouts that could make a GPU import read past its allocation."""
    if not (1<=width<=4096 and 1<=height<=4096):
        raise RuntimeError('GPU buffer dimensions invalid')
    if stride<width*4 or stride%4 or allocation_size<stride*height:
        raise RuntimeError('GPU buffer stride/allocation invalid')

def receive_release(connection,expected):
    """A frame is reusable only after exactly one valid release fence."""
    pixel,controls,flags,_=connection.recvmsg(expected,socket.CMSG_SPACE(8*4))
    releases=[]
    try:
        for level,kind,data in controls:
            if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                received=array.array('i');received.frombytes(data[:len(data)//4*4])
                releases.extend(received)
        if not pixel:
            raise EOFError('Surface owner closed')
        if flags&(socket.MSG_TRUNC|socket.MSG_CTRUNC) or len(releases)!=1 or len(pixel)!=expected:
            raise RuntimeError('Invalid release fence packet')
        wait_cpu_fence(releases[0])
        return pixel
    finally:
        for fd in releases:os.close(fd)

class GpuCapture:
    def __init__(self,env,display=':9',window=None,mode='composite'):
        if mode not in ('composite','solid','generated'):raise ValueError('Invalid GPU capture mode')
        self.mode=mode
        self.connection=socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET)
        self.connection.settimeout(2);self.connection.connect('/tmp/nf-gpu.sock')
        header=self.connection.recv(16)
        if len(header)!=16:raise RuntimeError('AHB header missing')
        magic,self.width,self.height,stride=struct.unpack('=4I',header)
        if magic!=0x4e464142 or (self.width,self.height) not in ((1280,720),(1920,1080)) or not self.width*4<=stride<=16384:raise RuntimeError('AHB layout invalid')
        self.fds=[]
        for _ in range(3):
            _,controls,flags,_=self.connection.recvmsg(65536,socket.CMSG_SPACE(64))
            for level,kind,data in controls:
                if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                    fds=array.array('i');fds.frombytes(data[:len(data)//4*4]);self.fds.extend(fds)
            if flags&(socket.MSG_CTRUNC|socket.MSG_TRUNC):raise RuntimeError('AHB handle truncated')
            if self.fds:break
        candidates=[fd for fd in self.fds if os.fstat(fd).st_size>=stride*self.height]
        if len(candidates)!=1:raise RuntimeError('AHB pixel allocation ambiguous')
        if mode!='generated':
            self.x=c.CDLL('libX11.so.6');self.comp=c.CDLL('libXcomposite.so.1')
            self.dpy=fn(self.x,'XOpenDisplay',c.c_void_p,[c.c_char_p])(display.encode())
            if not self.dpy:raise RuntimeError('X display missing')
            if window is None:
                tree=subprocess.run(['/usr/bin/xwininfo','-display',display,'-root','-tree'],env=env,capture_output=True,text=True,check=True,timeout=2).stdout
                matches=re.findall(r'(0x[0-9a-f]+) "nf-generated-test',tree)
                if len(matches)!=1:raise RuntimeError('Generated window not uniquely identified')
                window=int(matches[0],16)
            self.window=window
            self.xerrors=[]
            class XError(c.Structure):
                _fields_=[('type',c.c_int),('display',c.c_void_p),('resource',c.c_ulong),('serial',c.c_ulong),('code',c.c_ubyte)]
            self.handler=c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_void_p)(lambda d,e:self.xerrors.append(c.cast(e,c.POINTER(XError)).contents.code) or 0)
            self.previous_handler=fn(self.x,'XSetErrorHandler',c.c_void_p,[c.c_void_p])(self.handler)
            fn(self.comp,'XCompositeRedirectWindow',None,[c.c_void_p,c.c_ulong,c.c_int])(self.dpy,self.window,0)
            fn(self.x,'XSync',c.c_int,[c.c_void_p,c.c_int])(self.dpy,0)
            self.pixmap=fn(self.comp,'XCompositeNameWindowPixmap',c.c_ulong,[c.c_void_p,c.c_ulong])(self.dpy,self.window)
            fn(self.x,'XSync',c.c_int,[c.c_void_p,c.c_int])(self.dpy,0)
            if self.xerrors:raise RuntimeError('Composite X errors '+str(self.xerrors))
            xcb=c.CDLL('libxcb.so.1');dri=c.CDLL('libxcb-dri3.so.0');self.xcb=xcb
            screen=c.c_int();self.xconn=fn(xcb,'xcb_connect',c.c_void_p,[c.c_char_p,c.POINTER(c.c_int)])(display.encode(),c.byref(screen))
            class Cookie(c.Structure):_fields_=[('sequence',c.c_uint)]
            cookie=fn(dri,'xcb_dri3_buffer_from_pixmap',Cookie,[c.c_void_p,c.c_uint])(self.xconn,self.pixmap)
            error=c.c_void_p()
            reply=fn(dri,'xcb_dri3_buffer_from_pixmap_reply',c.c_void_p,[c.c_void_p,Cookie,c.POINTER(c.c_void_p)])(self.xconn,cookie,c.byref(error))
            if not reply:
                code=(c.c_ubyte*2).from_address(error.value)[1] if error.value else -1
                if error.value:fn(c.CDLL(None),'free',None,[c.c_void_p])(error)
                raise RuntimeError('DRI3 pixmap export failed code '+str(code))
            _,nfd,_,_,size,w,h,pitch,depth,bpp=struct.unpack('=BBHIIHHHBB12x',c.string_at(reply,32))
            if nfd!=1 or bpp!=32 or depth not in (24,32) or not 1<=w<=4096 or not 1<=h<=4096:raise RuntimeError('Source layout invalid')
            fd=fn(dri,'xcb_dri3_buffer_from_pixmap_reply_fds',c.POINTER(c.c_int),[c.c_void_p,c.c_void_p])(self.xconn,reply)[0]
            self.fds.append(fd);fn(c.CDLL(None),'free',None,[c.c_void_p])(reply)
            validate_linear_buffer(w,h,pitch,size)
            validate_linear_buffer(w,h,pitch,os.fstat(fd).st_size)
            validate_linear_buffer(self.width,self.height,stride,os.fstat(candidates[0]).st_size)
            self.source_size=(w,h)
        else:
            self.source_size=(self.width,self.height)
        validate_linear_buffer(self.width,self.height,stride,os.fstat(candidates[0]).st_size)
        self.egl=c.CDLL('libEGL.so.1');self.gl=c.CDLL('libGLESv2.so.2')
        egl=self.egl;gl=self.gl
        self.display=fn(egl,'eglGetDisplay',c.c_void_p,[c.c_void_p])(None)
        a,b=c.c_int(),c.c_int()
        if not fn(egl,'eglInitialize',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_int)])(self.display,c.byref(a),c.byref(b)):raise RuntimeError('Capture EGL init failed')
        extensions=fn(egl,'eglQueryString',c.c_char_p,[c.c_void_p,c.c_int])(self.display,0x3055).decode().split()
        self.capabilities={'native_fence':'EGL_ANDROID_native_fence_sync' in extensions,'wait_sync':'EGL_KHR_wait_sync' in extensions}
        fn(egl,'eglBindAPI',c.c_uint,[c.c_uint])(0x30A0)
        config=c.c_void_p();count=c.c_int()
        if not fn(egl,'eglChooseConfig',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_void_p),c.c_int,c.POINTER(c.c_int)])(self.display,(c.c_int*5)(0x3033,1,0x3040,0x40,0x3038),c.byref(config),1,c.byref(count)) or not count.value:raise RuntimeError('Capture GLES3 config missing')
        self.context=fn(egl,'eglCreateContext',c.c_void_p,[c.c_void_p,c.c_void_p,c.c_void_p,c.POINTER(c.c_int)])(self.display,config,None,(c.c_int*3)(0x3098,3,0x3038))
        self.surface=fn(egl,'eglCreatePbufferSurface',c.c_void_p,[c.c_void_p,c.c_void_p,c.POINTER(c.c_int)])(self.display,config,(c.c_int*5)(0x3057,1,0x3056,1,0x3038))
        self.current=fn(egl,'eglMakeCurrent',c.c_uint,[c.c_void_p]*4)
        if not self.current(self.display,self.surface,self.surface,self.context):raise RuntimeError('Capture EGL context failed')
        proc=fn(egl,'eglGetProcAddress',c.c_void_p,[c.c_char_p])
        create=c.CFUNCTYPE(c.c_void_p,c.c_void_p,c.c_void_p,c.c_uint,c.c_void_p,c.POINTER(c.c_int))(proc(b'eglCreateImageKHR'))
        target=c.CFUNCTYPE(None,c.c_uint,c.c_void_p)(proc(b'glEGLImageTargetTexture2DOES'))
        self.destroy=c.CFUNCTYPE(c.c_uint,c.c_void_p,c.c_void_p)(proc(b'eglDestroyImageKHR'))
        self.textures=(c.c_uint*2)();self.fbos=(c.c_uint*2)();self.images=[]
        fn(gl,'glGenTextures',None,[c.c_int,c.c_void_p])(2,self.textures)
        fn(gl,'glGenFramebuffers',None,[c.c_int,c.c_void_p])(2,self.fbos)
        buffers=[] if mode=='generated' else [(0,fd,w,h,pitch,0x34325241 if depth==32 else 0x34325258)]
        buffers.append((1,candidates[0],self.width,self.height,stride,0x34324241))
        for i,buffer,pixels_w,pixels_h,bytes_stride,fourcc in buffers:
            attrs=(c.c_int*13)(0x3057,pixels_w,0x3056,pixels_h,0x3271,fourcc,0x3272,buffer,0x3273,0,0x3274,bytes_stride,0x3038)
            image=create(self.display,None,0x3270,None,attrs)
            if not image:raise RuntimeError('Capture EGLImage '+str(i)+' failed')
            self.images.append(image)
            fn(gl,'glBindTexture',None,[c.c_uint,c.c_uint])(0xde1,self.textures[i]);target(0xde1,image)
            fn(gl,'glBindFramebuffer',None,[c.c_uint,c.c_uint])(0x8d40,self.fbos[i])
            fn(gl,'glFramebufferTexture2D',None,[c.c_uint]*4+[c.c_int])(0x8d40,0x8ce0,0xde1,self.textures[i],0)
            if fn(gl,'glCheckFramebufferStatus',c.c_uint,[c.c_uint])(0x8d40)!=0x8cd5:raise RuntimeError('Capture framebuffer '+str(i)+' incomplete')
        self.create_sync=c.CFUNCTYPE(c.c_void_p,c.c_void_p,c.c_uint,c.POINTER(c.c_int))(proc(b'eglCreateSyncKHR'))
        self.dup_fence=c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_void_p)(proc(b'eglDupNativeFenceFDANDROID'))
        self.destroy_sync=c.CFUNCTYPE(c.c_uint,c.c_void_p,c.c_void_p)(proc(b'eglDestroySyncKHR'))
        if not self.capabilities['native_fence']:raise RuntimeError('Native fence export unavailable')
        self.wait_sync=c.CFUNCTYPE(c.c_uint,c.c_void_p,c.c_void_p,c.c_int)(proc(b'eglWaitSyncKHR'))
        self.release_fences=0
        self.frames=0
    def frame(self,points=False,check_pixel=False):
        gl=self.gl
        if self.mode=='composite':
            # This read establishes Xvfb-side completion, not a general
            # ownership protocol for every external writer of the source.
            image=fn(self.x,'XGetImage',c.c_void_p,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int])(self.dpy,self.window,1,1,1,1,c.c_ulong(-1),2)
            if not image:raise RuntimeError('Source sync read failed')
            fn(self.x,'XDestroyImage',c.c_int,[c.c_void_p])(image)
            w,h=self.source_size
            fn(gl,'glBindFramebuffer',None,[c.c_uint,c.c_uint])(0x8ca8,self.fbos[0])
            fn(gl,'glBindFramebuffer',None,[c.c_uint,c.c_uint])(0x8ca9,self.fbos[1])
            fn(gl,'glBlitFramebuffer',None,[c.c_int]*8+[c.c_uint,c.c_uint])(0,0,w,h,0,0,self.width,self.height,0x4000,0x2600)
        else:
            # Isolation only: keep imports and destination handoff unchanged,
            # but issue no XGetImage or source read/blit commands per frame.
            fn(gl,'glBindFramebuffer',None,[c.c_uint,c.c_uint])(0x8d40,self.fbos[1])
            fn(gl,'glClearColor',None,[c.c_float]*4)(1.0 if self.frames%120<60 else 0.0,0.25,0.75,1.0)
            fn(gl,'glClear',None,[c.c_uint])(0x4000)
        error=fn(gl,'glGetError',c.c_uint,[])()
        if error:raise RuntimeError('Capture blit error '+hex(error))
        sync=self.create_sync(self.display,0x3144,(c.c_int*1)(0x3038))
        if not sync:raise RuntimeError('Native fence creation failed')
        fence_fd=-1
        try:
            fn(gl,'glFlush',None,[])()
            fence_fd=self.dup_fence(self.display,sync)
            if fence_fd<0:raise RuntimeError('Native fence FD export failed')
            self.connection.sendmsg([b'P' if points else b'R' if check_pixel else b'F'],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',[fence_fd]))])
        finally:
            if fence_fd>=0:os.close(fence_fd)
            self.destroy_sync(self.display,sync)
        expected=16 if points else 4
        pixel=receive_release(self.connection,expected)
        self.release_fences+=1
        self.frames+=1;return [list(pixel[i:i+4]) for i in range(0,16,4)] if points else list(pixel)
    def source_points(self):
        result=[]
        for x,y in [(100,100),(1100,100),(100,620),(1100,620)]:
            image=fn(self.x,'XGetImage',c.c_void_p,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int])(self.dpy,self.window,x,y,1,1,c.c_ulong(-1),2)
            if not image:raise RuntimeError('Source quadrant read failed')
            pixel=fn(self.x,'XGetPixel',c.c_ulong,[c.c_void_p,c.c_int,c.c_int])(image,0,0)
            result.append([(pixel>>16)&255,(pixel>>8)&255,pixel&255])
            fn(self.x,'XDestroyImage',c.c_int,[c.c_void_p])(image)
        return result
    def close(self):
        try:self.connection.sendall(b'Q')
        except OSError:pass  # A stopped Surface owner may already have closed IPC.
        finally:self.connection.close()
        gl=self.gl
        fn(gl,'glDeleteFramebuffers',None,[c.c_int,c.c_void_p])(2,self.fbos)
        fn(gl,'glDeleteTextures',None,[c.c_int,c.c_void_p])(2,self.textures)
        for image in self.images:self.destroy(self.display,image)
        self.current(self.display,None,None,None)
        fn(self.egl,'eglDestroySurface',c.c_uint,[c.c_void_p,c.c_void_p])(self.display,self.surface)
        fn(self.egl,'eglDestroyContext',c.c_uint,[c.c_void_p,c.c_void_p])(self.display,self.context)
        fn(self.egl,'eglTerminate',c.c_uint,[c.c_void_p])(self.display)
        for fd in self.fds:os.close(fd)
        if hasattr(self,'x'):
            fn(self.x,'XFreePixmap',c.c_int,[c.c_void_p,c.c_ulong])(self.dpy,self.pixmap)
            fn(self.comp,'XCompositeUnredirectWindow',None,[c.c_void_p,c.c_ulong,c.c_int])(self.dpy,self.window,0)
            fn(self.x,'XCloseDisplay',c.c_int,[c.c_void_p])(self.dpy)
            fn(self.x,'XSetErrorHandler',c.c_void_p,[c.c_void_p])(self.previous_handler)
            fn(self.xcb,'xcb_disconnect',None,[c.c_void_p])(self.xconn)
