#!/usr/bin/python3
"""Guest-only, temporary-profile Chrome GPU diagnostic. No accounts or media."""
import base64
import ctypes as c
import importlib.util
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import time
import urllib.request

# Companion and external watchdog supply independent deadlines too.
signal.alarm(18)
spec = importlib.util.spec_from_file_location('diagnostics', '/tmp/browser-diagnostics.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
backend = os.environ.get('NF_CHROME_PROBE_BACKEND', 'headless')
if backend not in ('headless','x11'): raise ValueError('Invalid probe backend')
renderer_mode=os.environ.get('NF_CHROME_PROBE_RENDERER','gpu')
if renderer_mode not in ('gpu','software'): raise ValueError('Invalid renderer mode')
dri3_server=os.environ.get('NF_CHROME_PROBE_DRI3')=='1'
va_test=os.environ.get('NF_CHROME_PROBE_VA')=='1'
video_test=os.environ.get('NF_CHROME_PROBE_VIDEO')=='1'
native_only=os.environ.get('NF_CHROME_NATIVE_EGL_ONLY')=='1'
gpu_capture=os.environ.get('NF_CHROME_GPU_CAPTURE')=='1'
surface_capture=os.environ.get('NF_CHROME_SURFACE_CAPTURE')=='1'
capture=None
report = {'allowed_cpus':sorted(os.sched_getaffinity(0)), 'mode': backend+'-'+renderer_mode, 'va_requested':va_test, 'dri3_server':dri3_server, 'passed': False}
class NativeEglComplete(Exception):pass
process = None
xserver = None
clients = []
with tempfile.TemporaryDirectory(prefix='nf-chrome-gpu-', dir='/tmp') as profile:
    log_path = Path('/tmp/nightfall-chrome-gpu-probe.log')
    try:
        env = dict(os.environ, EGL_PLATFORM='surfaceless', GALLIUM_DRIVER='kgsl', MESA_LOADER_DRIVER_OVERRIDE='kgsl')
        interval_file=Path('/tmp/nf-xvfb-readback-ms')
        readback_settings=interval_file.read_text().strip().split(',') if interval_file.exists() else ['16','0']
        readback_ms=int(readback_settings[0])
        async_readback=len(readback_settings)>1 and readback_settings[1]=='1'
        env['NF_XVFB_ASYNC_READBACK']='1' if async_readback else '0'
        report['async_readback']=async_readback
        server_sysmem=len(readback_settings)>2 and readback_settings[2]=='1'
        report['server_sysmem']=server_sysmem
        coherent_readback=len(readback_settings)>3 and readback_settings[3]=='1'
        report['coherent_readback']=coherent_readback
        if coherent_readback:env['NF_KGSL_COHERENT_READBACK']='1'
        if readback_ms not in (0,16,33):raise ValueError('Invalid diagnostic readback interval')
        env['NF_XVFB_READBACK_MS']=str(readback_ms)
        report['readback_ms']=readback_ms
        va_flags=[]
        if va_test:
            driver_dir='/opt/mesa-va/usr/lib/aarch64-linux-gnu'
            fixed_driver='/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu' if os.environ.get('NF_CHROME_PROBE_PPS')=='1' else driver_dir
            env.update(LD_PRELOAD='/tmp/libnightfall-kgsl-compat.so:'+driver_dir+'/libtva_drm_shim_wayland.so',
                LD_LIBRARY_PATH=fixed_driver+':/usr/lib/aarch64-linux-gnu:'+driver_dir+':/opt/mesa-freedreno/lib/aarch64-linux-gnu',
                LIBGL_DRIVERS_PATH=fixed_driver+'/dri',LIBVA_DRIVERS_PATH=fixed_driver+'/dri',GBM_BACKENDS_PATH=fixed_driver+'/gbm',
                LIBVA_DRIVER_NAME='termuxva',TERMUX_VA_BRIDGE='1',TERMUX_VA_GPU_BACKEND='kgsl',
                TERMUX_VA_SOCKET='/tmp/nightfall-va/probe.sock',TERMUX_VA_X11_DRI3='1',TERMUX_VA_DRM_SHIM_LOG='1')
            va_flags=['--hardware-video-device-path=/dev/kgsl-3d0','--render-node-override=/dev/kgsl-3d0','--ignore-gpu-blocklist','--enable-zero-copy','--enable-native-gpu-memory-buffers','--enable-gpu-compositing','--vmodule=vaapi*=2',
                '--enable-features=AcceleratedVideoDecoder,VaapiVideoDecoder,VaapiVideoDecodeLinux,AcceleratedVideoDecodeLinuxGL,VaapiIgnoreDriverChecks',
                '--disable-features=AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiVideoMinResolutionForPerformance,PreferMappableSharedImage']
        if dri3_server:
            va_flags=[flag for flag in va_flags if flag!='--enable-zero-copy']
            va_flags+=['--disable-zero-copy','--disable-gpu-rasterization']
        if backend == 'x11':
            framebuffer_dir=Path(profile)/'framebuffer'; framebuffer_dir.mkdir()
            xserver_args=['/opt/nightfall-xvfb/Xvfb' if dri3_server else '/usr/bin/Xvfb', ':9', '-screen', '0', '1280x720x24', '-fbdir', str(framebuffer_dir), '-nolisten','tcp','-ac'] + (['-noreset','-vfbdevice','/dev/kgsl-3d0'] if dri3_server else [])
            with open('/tmp/nightfall-xvfb-probe.log','w') as server_log:
                xserver=subprocess.Popen(xserver_args,env=(dict(env,FD_MESA_DEBUG='sysmem') if server_sysmem else env) if dri3_server else None,stdout=server_log,stderr=server_log,start_new_session=True)
            env['DISPLAY'] = ':9'
            for attempt in range(20):
                if Path('/tmp/.X11-unix/X9').exists(): break
                if xserver.poll() is not None:raise RuntimeError('X server exited during initialization')
                time.sleep(.05)
        if backend=='x11':
            extensions=subprocess.run(['/usr/bin/xdpyinfo','-display',':9','-queryExtensions'],env=env,capture_output=True,text=True,timeout=2)
            report['x11_dri3_available']='DRI3' in extensions.stdout
            report['x11_present_available']='Present' in extensions.stdout
        if native_only:
            native=subprocess.run(['/usr/bin/python3','/tmp/probe-native-egl-window.py'],env=dict(env,EGL_PLATFORM='x11'),capture_output=True,text=True,timeout=6)
            report['native_egl']={'exit':native.returncode,'diagnostics':native.stderr[-5000:]}
            for line in native.stdout.splitlines():
                try:report['native_egl']['result']=json.loads(line)
                except ValueError:pass
            report['passed']=native.returncode==0 and report['native_egl'].get('result',{}).get('passed',False)
            raise NativeEglComplete()
        if dri3_server and not gpu_capture:
            test_xlib=c.CDLL('libX11.so.6')
            test_xlib.XOpenDisplay.argtypes=[c.c_char_p];test_xlib.XOpenDisplay.restype=c.c_void_p
            test_xlib.XDefaultRootWindow.argtypes=[c.c_void_p];test_xlib.XDefaultRootWindow.restype=c.c_ulong
            test_xlib.XDefaultGC.argtypes=[c.c_void_p,c.c_int];test_xlib.XDefaultGC.restype=c.c_void_p
            test_xlib.XSetForeground.argtypes=[c.c_void_p,c.c_void_p,c.c_ulong]
            test_xlib.XFillRectangle.argtypes=[c.c_void_p,c.c_ulong,c.c_void_p,c.c_int,c.c_int,c.c_uint,c.c_uint]
            test_xlib.XSync.argtypes=[c.c_void_p,c.c_int]
            test_xlib.XGetImage.argtypes=[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int];test_xlib.XGetImage.restype=c.c_void_p
            test_xlib.XGetPixel.argtypes=[c.c_void_p,c.c_int,c.c_int];test_xlib.XGetPixel.restype=c.c_ulong
            test_xlib.XDestroyImage.argtypes=[c.c_void_p];test_xlib.XCloseDisplay.argtypes=[c.c_void_p]
            dpy=test_xlib.XOpenDisplay(b':9')
            if not dpy:raise RuntimeError('Drawing test cannot connect to X server')
            samples=[]
            try:
                root=test_xlib.XDefaultRootWindow(dpy);gc=test_xlib.XDefaultGC(dpy,0)
                for color in (0xff0000,0x00ff00,0x0000ff):
                    test_xlib.XSetForeground(dpy,gc,color)
                    test_xlib.XFillRectangle(dpy,root,gc,0,0,300,200)
                    test_xlib.XSync(dpy,0)
                    image=test_xlib.XGetImage(dpy,root,100,50,1,1,c.c_ulong(-1),2)
                    if not image:raise RuntimeError('Drawing test cannot read X image')
                    pixel=test_xlib.XGetPixel(image,0,0)&0xffffff;test_xlib.XDestroyImage(image)
                    time.sleep(.05)
                    with (framebuffer_dir/'Xvfb_screen0').open('rb',buffering=0) as stream:
                        h=struct.unpack('>25I',stream.read(100));stream.seek(h[0]+h[19]*12+50*h[12]+100*(h[11]//8));mapped=int.from_bytes(stream.read(4),'little')&0xffffff
                    samples.append({'expected':color,'x11_pixel':pixel,'mapped_pixel':mapped})
            finally:test_xlib.XCloseDisplay(dpy)
            report['x11_solid_draw_test']={'samples':samples,'passed':all(s['expected']==s['x11_pixel']==s['mapped_pixel'] for s in samples)}
            dri_probe=subprocess.run(['/usr/bin/python3','/tmp/probe-dri3-buffer.py'],env=env,capture_output=True,text=True,timeout=5)
            report['dri3_buffer_test']={'exit':dri_probe.returncode,'output':dri_probe.stdout[-3000:],'diagnostics':dri_probe.stderr[-3000:]}
            gpu_probe=subprocess.run(['/usr/bin/python3','/tmp/probe-dri3-buffer.py'],env=dict(env,NF_DRI3_GPU_PAINT='1'),capture_output=True,text=True,timeout=5)
            report['dri3_gpu_producer_test']={'exit':gpu_probe.returncode,'output':gpu_probe.stdout[-3000:],'diagnostics':gpu_probe.stderr[-3000:]}
        chrome_env=dict(env)
        if dri3_server:
            chrome_env.pop('EGL_PLATFORM',None)
        with log_path.open('w') as log:
            process = subprocess.Popen([
                '/usr/bin/google-chrome-stable', '--ozone-platform='+backend,
                '--no-sandbox', '--disable-dev-shm-usage', '--no-first-run', '--no-default-browser-check',
                '--disable-background-networking', '--disable-component-update', '--disable-extensions',
                '--user-data-dir='+profile, '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=9222',
                '--window-size=1280,720',
                '--enable-logging=stderr', '--kiosk', '--test-type=nightfall-gpu-probe', '--app=about:blank'] + (['--headless'] if backend == 'headless' else []) + (['--use-gl=angle',('--use-angle=gles-egl' if va_test else '--use-angle=gl-egl'),'--enable-gpu'] if renderer_mode=='gpu' else ['--disable-gpu']) + va_flags, env=chrome_env, stdout=log, stderr=log, start_new_session=True)
        deadline = time.monotonic()+10
        while time.monotonic()<deadline:
            if process.poll() is not None: raise RuntimeError('Chrome exited before DevTools')
            try:
                with urllib.request.urlopen('http://127.0.0.1:9222/json/version',timeout=.5) as response:
                    version=json.load(response)
                break
            except (OSError,ValueError): time.sleep(.1)
        else: raise TimeoutError('Chrome startup deadline')
        browser = module.LocalCDP(version['webSocketDebuggerUrl']); clients.append(browser)
        info=browser.call('SystemInfo.getInfo').get('gpu',{})
        report['devices']=[{k:v for k,v in d.items() if k in ('vendorId','deviceId','vendorString','deviceString')} for d in info.get('devices',[])]
        report['features']=info.get('featureStatus',{})
        report['video_decode_capabilities']=info.get('videoDecoding',[])
        attrs=info.get('auxAttributes',{})
        report['driver']={k:attrs[k] for k in ('glVendor','glRenderer','glVersion','displayType','glImplementationParts','skiaBackendType') if k in attrs}
        with urllib.request.urlopen('http://127.0.0.1:9222/json/list',timeout=1) as response:
            pages=json.load(response)
        page=module.LocalCDP(next(p['webSocketDebuggerUrl'] for p in pages if p['type']=='page')); clients.append(page)
        page.call('Page.navigate',{'url':'data:text/html,<html><head><title>nf-generated-test</title></head><body></body></html>'})
        for attempt in range(30):
            ready=page.call('Runtime.evaluate',{'expression':"document.title==='nf-generated-test' && document.readyState==='complete'",'returnByValue':True})
            if ready.get('result',{}).get('value'): break
            time.sleep(.05)
        else: raise RuntimeError('Generated page did not finish loading')
        page.call('Page.bringToFront')
        expression='''(()=>{document.body.style.background='#204060';let c=document.createElement('canvas');c.width=320;c.height=180;document.body.append(c);let gl=c.getContext('webgl');if(!gl){let d=document.createElement('div');d.style.cssText='position:absolute;left:8px;top:8px;width:320px;height:180px;background:red';document.body.append(d);return {webgl:false}};gl.clearColor(1,0,0,1);gl.clear(gl.COLOR_BUFFER_BIT);let p=new Uint8Array(4);gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p);return {webgl:true,pixel:Array.from(p),renderer:gl.getParameter(gl.RENDERER),vendor:gl.getParameter(gl.VENDOR)}})()'''
        report['page']=page.call('Runtime.evaluate',{'expression':expression,'returnByValue':True}).get('result',{}).get('value',{})
        renderer=json.dumps(report.get('driver',{})).lower()
        report['hardware_renderer']=('fd740' in renderer or 'adreno' in renderer) and not any(s in renderer for s in ('swiftshader','llvmpipe','softpipe'))
        report['software_renderer']=not report['hardware_renderer']
        def cpu_ticks():
            total=0
            for stat_path in Path('/proc').glob('[0-9]*/stat'):
                try:
                    fields=stat_path.read_text().rsplit(')',1)[1].split()
                    if int(fields[3])==process.pid: total+=int(fields[11])+int(fields[12])
                except (OSError,ValueError,IndexError): pass
            return total
        benchmark_js="""(()=>{document.body.innerHTML='';document.body.style.cssText='margin:0;height:10000px;background:linear-gradient(#123,#abc)';let marker=document.createElement('div');marker.style.cssText='position:fixed;top:0;left:0;width:100%;height:20px;z-index:5';document.body.append(marker);for(let i=0;i<100;i++){let d=document.createElement('div');d.textContent='Generated scrolling benchmark row '+i;d.style.cssText='padding:20px;background:rgba(255,255,255,.2);margin:8px;box-shadow:0 2px 4px #333';document.body.append(d)}window.nfBench={frames:0,intervals:[],running:true};let last=0;function tick(t){if(!nfBench.running)return;if(last)nfBench.intervals.push(t-last);last=t;nfBench.frames++;marker.style.background=nfBench.frames%2?'rgb(255,0,0)':'rgb(0,255,0)';window.scrollTo(0,(nfBench.frames*12)%2500);requestAnimationFrame(tick)}requestAnimationFrame(tick);return true})()"""
        page.call('Runtime.evaluate',{'expression':benchmark_js,'returnByValue':True})
        geometry=page.call('Runtime.evaluate',{'expression':'({x:screenX,y:screenY,outerWidth,outerHeight,innerWidth,innerHeight})','returnByValue':True})['result']['value']
        report['window_geometry']=geometry
        border=max(0,(geometry['outerWidth']-geometry['innerWidth'])//2)
        content_x=max(0,geometry['x']+border)
        content_y=max(0,geometry['y']+geometry['outerHeight']-geometry['innerHeight']-border)
        if gpu_capture:
            capture_spec=importlib.util.spec_from_file_location('gpu_capture','/tmp/gpu-x11-capture.py')
            capture_module=importlib.util.module_from_spec(capture_spec);capture_spec.loader.exec_module(capture_module)
            capture=capture_module.GpuCapture(env)
        before=cpu_ticks(); started=time.monotonic(); changed=0; previous=None; observations=0
        if gpu_capture:
            next_capture=started
            while time.monotonic()-started<4:
                value=capture.frame()
                if previous is not None and previous!=value:changed+=1
                previous=value;observations+=1
                next_capture=max(next_capture+1/60,time.monotonic())
                time.sleep(max(0,next_capture-time.monotonic()))
        elif backend=='x11':
            with (framebuffer_dir/'Xvfb_screen0').open('rb',buffering=0) as frame_file:
                h=struct.unpack('>25I',frame_file.read(100)); offset=h[0]+h[19]*12+(content_y+10)*h[12]+(content_x+10)*(h[11]//8)
                while time.monotonic()-started<4:
                    frame_file.seek(offset); value=frame_file.read(4)
                    if previous is not None and previous!=value: changed+=1
                    previous=value;observations+=1;time.sleep(.005)
        else: time.sleep(4)
        elapsed=time.monotonic()-started; after=cpu_ticks()
        metrics=page.call('Runtime.evaluate',{'expression':"(()=>{nfBench.running=false;return {frames:nfBench.frames,intervals:nfBench.intervals}})()",'returnByValue':True}).get('result',{}).get('value',{})
        intervals=sorted(metrics.pop('intervals',[]))
        report['scroll_benchmark']={**metrics,'seconds':round(elapsed,3),'observed_framebuffer_changes':changed,'observations':observations,
            'cpu_core_equivalents':round((after-before)/os.sysconf('SC_CLK_TCK')/elapsed,3),
            'interval_ms_median':intervals[len(intervals)//2] if intervals else None,
            'interval_ms_p95':intervals[min(len(intervals)-1,int(len(intervals)*.95))] if intervals else None}
        if video_test:
            page.call('Media.enable')
            Path('/tmp/nf-generated-video.html').write_text('<!doctype html><title>Generated video test</title><body style="margin:0;background:black"><video id="v" muted autoplay playsinline style="width:100vw;height:100vh" src="file:///tmp/nf-generated-video.mp4"></video>')
            page.call('Page.navigate',{'url':'file:///tmp/nf-generated-video.html'})
            for attempt in range(40):
                ready=page.call('Runtime.evaluate',{'expression':"!!document.querySelector('video') && document.querySelector('video').readyState>=2",'returnByValue':True})
                if ready.get('result',{}).get('value'): break
                time.sleep(.05)
            else: raise RuntimeError('Generated clip did not become ready')
            page.call('Runtime.evaluate',{'expression':"v.play().then(()=>true)",'awaitPromise':True,'returnByValue':True})
            counter="(()=>{let q=v.getVideoPlaybackQuality();return {width:v.videoWidth,height:v.videoHeight,time:v.currentTime,paused:v.paused,total:q.totalVideoFrames,dropped:q.droppedVideoFrames,error:v.error?v.error.code:0}})()"
            first=page.call('Runtime.evaluate',{'expression':counter,'returnByValue':True})['result']['value']
            before=cpu_ticks();start=time.monotonic();capture_samples=[];next_counter=0;next_capture=start
            while time.monotonic()-start<4:
                if gpu_capture:
                    capture_start=time.monotonic();capture.frame();capture_samples.append((time.monotonic()-capture_start)*1000)
                    next_capture=max(next_capture+1/60,time.monotonic())
                    time.sleep(max(0,next_capture-time.monotonic()))
                else:time.sleep(.25)
                if time.monotonic()<next_counter:continue
                next_counter=time.monotonic()+.25
                last=page.call('Runtime.evaluate',{'expression':counter,'returnByValue':True})['result']['value']
            last=page.call('Runtime.evaluate',{'expression':counter,'returnByValue':True})['result']['value']
            elapsed=time.monotonic()-start; after=cpu_ticks()
            report['video_benchmark']={'seconds':round(elapsed,3),'start':first,'end':last,
                'frames_delta':last['total']-first['total'],'dropped_delta':last['dropped']-first['dropped'],
                'cpu_core_equivalents':round((after-before)/os.sysconf('SC_CLK_TCK')/elapsed,3),
                'decoder_properties':dict(page.media)}
            page.call('Runtime.evaluate',{'expression':'v.pause();true','returnByValue':True})
            video=report['video_benchmark']
            video['non_dropped_frames_per_second']=round(max(0,video['frames_delta']-video['dropped_delta'])/elapsed,2)
            # Capability/pixel correctness is distinct from smooth playback.
            video['drop_fraction']=round(video['dropped_delta']/max(1,video['frames_delta']),4)
            video['smooth_playback_candidate']=video['drop_fraction']<=.02
            if gpu_capture:
                ordered=sorted(capture_samples)
                video['gpu_capture']={'frames':len(ordered),'mean_ms':sum(ordered)/len(ordered),'median_ms':ordered[len(ordered)//2],'p95_ms':ordered[min(len(ordered)-1,int(len(ordered)*.95))]}
        # Restore a fixed generated red patch for capture/presentation validation.
        page.call('Runtime.evaluate',{'expression':"document.body.innerHTML='<div style=\"position:fixed;left:0;top:0;width:320px;height:180px;background:red\"></div>';window.scrollTo(0,0)",'returnByValue':True})
        page.call('Page.bringToFront')
        if dri3_server:
            tree=subprocess.run(['/usr/bin/xwininfo','-display',':9','-root','-tree'],env=env,capture_output=True,text=True,timeout=2)
            report['generated_window_tree']=tree.stdout[-5000:]
            # Only the generated test title is eligible; no real profiles/pages.
            import re
            window_ids=re.findall(r'(0x[0-9a-f]+) "Generated video test',tree.stdout)
            focus_lib=c.CDLL('libX11.so.6')
            focus_lib.XOpenDisplay.argtypes=[c.c_char_p];focus_lib.XOpenDisplay.restype=c.c_void_p
            focus_lib.XRaiseWindow.argtypes=[c.c_void_p,c.c_ulong]
            focus_lib.XSync.argtypes=[c.c_void_p,c.c_int];focus_lib.XCloseDisplay.argtypes=[c.c_void_p]
            focus_display=focus_lib.XOpenDisplay(b':9')
            if focus_display:
                for wid in window_ids:focus_lib.XRaiseWindow(focus_display,int(wid,16))
                focus_lib.XSync(focus_display,0);focus_lib.XCloseDisplay(focus_display)
            report['generated_windows_raised']=len(window_ids)
        captures=[]
        for sample in range(3):
            start=time.monotonic()
            shot=page.call('Page.captureScreenshot',{'format':'png'})
            png=base64.b64decode(shot['data'],validate=True)
            if not png.startswith(b'\x89PNG\r\n\x1a\n'): raise RuntimeError('Invalid generated screenshot')
            Path('/tmp/nightfall-chrome-gpu-generated.png').write_bytes(png)
            captures.append({'milliseconds':round((time.monotonic()-start)*1000,2),'bytes':len(png)})
        report['generated_frame_exports']=captures
        if backend == 'x11':
            time.sleep(.3)
            xwd=(framebuffer_dir/'Xvfb_screen0').read_bytes()
            Path('/tmp/nightfall-chrome-gpu-generated.xwd').write_bytes(xwd)
            h=struct.unpack('>25I',xwd[:100])
            offset=h[0]+h[19]*12+(content_y+50)*h[12]+(content_x+100)*(h[11]//8)
            value=int.from_bytes(xwd[offset:offset+h[11]//8],'little' if h[7]==0 else 'big')
            xlib=c.CDLL('libX11.so.6')
            xlib.XOpenDisplay.argtypes=[c.c_char_p];xlib.XOpenDisplay.restype=c.c_void_p
            xlib.XDefaultRootWindow.argtypes=[c.c_void_p];xlib.XDefaultRootWindow.restype=c.c_ulong
            xlib.XGetImage.argtypes=[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int];xlib.XGetImage.restype=c.c_void_p
            xlib.XGetPixel.argtypes=[c.c_void_p,c.c_int,c.c_int];xlib.XGetPixel.restype=c.c_ulong
            xlib.XDestroyImage.argtypes=[c.c_void_p];xlib.XCloseDisplay.argtypes=[c.c_void_p]
            dpy=xlib.XOpenDisplay(b':9')
            if dpy:
                image=xlib.XGetImage(dpy,xlib.XDefaultRootWindow(dpy),content_x+100,content_y+50,1,1,c.c_ulong(-1),2)
                if image:
                    report['x11_root_pixel']=xlib.XGetPixel(image,0,0)
                    xlib.XDestroyImage(image)
                if dri3_server and window_ids:
                    image=xlib.XGetImage(dpy,int(window_ids[0],16),100,50,1,1,c.c_ulong(-1),2)
                    if image:
                        report['generated_window_pixel']=xlib.XGetPixel(image,0,0)&0xffffff
                        xlib.XDestroyImage(image)
                xlib.XCloseDisplay(dpy)
            report['shared_framebuffer']={'width':h[4],'height':h[5],
                 'bits_per_pixel':h[11],'stride':h[12],
                 'sample_value':value,'pixel_offset':offset,'red_mask':h[14],
                 'generated_red_pixel_correct':(value&h[14])==h[14] and (value&(h[15]|h[16]))==0}

        if gpu_capture:
            time.sleep(.05)
            pixel=capture.frame(check_pixel=surface_capture)
            report['gpu_capture']={'native_pixel':pixel,'source_size':capture.source_size,'capabilities':capture.capabilities,'frames':capture.frames,'red_patch_correct':pixel[0]>=250 and pixel[1]<=5 and pixel[2]<=5}
        if gpu_capture:
            quadrant_script="(()=>{document.body.style.cssText='margin:0;background:black';document.body.innerHTML='';for(let [color,left,top] of [['red',0,0],['lime',50,0],['blue',0,50],['yellow',50,50]]){let d=document.createElement('div');d.style.cssText=`position:fixed;left:${left}vw;top:${top}vh;width:50vw;height:50vh;background:${color}`;document.body.append(d)}return {width:innerWidth,height:innerHeight}})()"
            report['quadrant_setup']=page.call('Runtime.evaluate',{'expression':quadrant_script,'returnByValue':True})
            time.sleep(.15)
            points=capture.frame(points=True)
            report['gpu_capture']['source_quadrants']=capture.source_points()
            report['gpu_capture']['frames']=capture.frames
            report['gpu_capture']['release_fences']=capture.release_fences
            expected=[(255,0,0),(0,255,0),(0,0,255),(255,255,0)]
            report['gpu_capture']['quadrant_pixels']=points
            report['gpu_capture']['quadrants_correct']=all(all(abs(actual[i]-wanted[i])<=5 for i in range(3)) for actual,wanted in zip(points,expected))
        report['passed']=(not video_test or (report['video_benchmark']['frames_delta']>0 and report['video_benchmark']['end']['error']==0)) and (report['hardware_renderer'] if renderer_mode=='gpu' else report['features'].get('gpu_compositing')!='enabled') and (backend!='x11' or ((report['gpu_capture']['red_patch_correct'] and report['gpu_capture']['quadrants_correct']) if gpu_capture else report['shared_framebuffer']['generated_red_pixel_correct']))
    except NativeEglComplete:pass
    except Exception as exc:
        report['error']=type(exc).__name__+': '+str(exc)
    finally:
        if capture is not None:
            try:capture.close()
            except Exception as error:report['capture_cleanup_error']=type(error).__name__+': '+str(error)
        for client in clients:
            try: client.close()
            except Exception: pass
        if process is not None:
            try: os.killpg(process.pid,signal.SIGTERM); process.wait(timeout=1)
            except (OSError,subprocess.TimeoutExpired):
                try: os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=1)
                except (OSError,subprocess.TimeoutExpired):pass
        if xserver is not None:
            try: os.killpg(xserver.pid,signal.SIGTERM);xserver.wait(timeout=1)
            except (OSError,subprocess.TimeoutExpired):
                try: os.killpg(xserver.pid,signal.SIGKILL);xserver.wait(timeout=1)
                except (OSError,subprocess.TimeoutExpired): pass
        report['va_diagnostics']=[line for line in log_path.read_text(errors='replace').splitlines() if any(key in line.lower() for key in ('vaapi','tva','libva','drm'))][-60:] if log_path.exists() and not native_only else []
        report['hardware_decode_confirmed']=bool(report.get('video_benchmark',{}).get('decoder_properties',{}).get('kIsPlatformVideoDecoder') in (True,'true'))
        if va_test and not native_only and not report['hardware_decode_confirmed']: report['passed']=False
        report['xserver_diagnostics']=Path('/tmp/nightfall-xvfb-probe.log').read_text(errors='replace')[-5000:] if backend=='x11' and Path('/tmp/nightfall-xvfb-probe.log').exists() else ''
        report['startup_diagnostics']=log_path.read_text(errors='replace')[-8000:] if log_path.exists() and not native_only else ''
print(json.dumps(report))
