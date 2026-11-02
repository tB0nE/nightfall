package app.nightfall.browserlab;

import android.view.Surface;
import java.io.File;
import java.nio.charset.StandardCharsets;

/** Opt-in GPU AHB -> existing Surface renderer. The worker owns native lifetime. */
final class GpuFrameRenderer implements FrameRenderer {
    static { System.loadLibrary("nightfall_browser_gpu"); }
    private static final java.util.concurrent.atomic.AtomicBoolean ACTIVE=new java.util.concurrent.atomic.AtomicBoolean();
    private final Object lock = new Object();
    private final Thread worker;
    private volatile boolean stopped;
    private long handle;
    private int targetHz = 60;
    private Process producer;
    private Thread producerWorker;
    private final File base;
    private final boolean generatedOnly;
    GpuFrameRenderer(File base, Surface surface) {this(base,surface,false);}
    GpuFrameRenderer(File base, Surface surface, boolean ownProducer) {this(base,surface,ownProducer,false);}
    GpuFrameRenderer(File base, Surface surface, boolean ownProducer,boolean generatedOnly) {
        this.base=base;this.generatedOnly=generatedOnly;
        if(!ACTIVE.compareAndSet(false,true)) {surface.release();throw new IllegalStateException("Previous GPU renderer has not stopped");}
        File endpoint=new File(base,"rootfs/tmp/nf-gpu.sock");
        if(endpoint.exists() && !endpoint.delete()){ACTIVE.set(false);surface.release();throw new IllegalStateException("Stale GPU endpoint");}
        final int[] dimensions={1280,720};
        if(ownProducer && !generatedOnly)try(java.io.RandomAccessFile source=new java.io.RandomAccessFile(new File(base,"rootfs/tmp/nightfall-framebuffer/Xvfb_screen0"),"r")) {
            source.seek(16);dimensions[0]=source.readInt();dimensions[1]=source.readInt();
            if(!((dimensions[0]==1280 && dimensions[1]==720)||(dimensions[0]==1920 && dimensions[1]==1080)))throw new java.io.IOException("Unsupported GPU dimensions");
        }catch(Exception error){ACTIVE.set(false);surface.release();throw new IllegalStateException("GPU source dimensions unavailable",error);}
        worker = new Thread(() -> {
            long state = 0;
            try {
                synchronized (lock) {
                    if (stopped) return;
                    state = nativeCreate(surface, new File(base,"rootfs/tmp/nf-gpu.sock").getPath(),dimensions[0],dimensions[1]);
                    if (state == 0) throw new IllegalStateException("Native GPU renderer allocation failed");
                    handle = state; nativeSetHz(handle,targetHz);
                }
                String result = nativeRun(state);
                if (result == null) throw new IllegalStateException("Native GPU renderer returned no status");
                if(ownProducer && "error".equals(new org.json.JSONObject(result).optString("state")))BrowserLabService.gpuFailure("native_renderer");
                try (java.io.FileOutputStream output = new java.io.FileOutputStream(new File(base,"gpu-surface-status.json"))) {
                    output.write(result.getBytes(StandardCharsets.UTF_8));
                }
            } catch (Exception error) {
                android.util.Log.e("GpuFrameRenderer","GPU renderer failed",error);
                if(ownProducer && !stopped)BrowserLabService.gpuFailure("renderer_exception");
            } finally {
                synchronized (lock) { stopped=true;if (state != 0) nativeDestroy(state); handle = 0; }
                stopProducer();surface.release();ACTIVE.set(false);
            }
        },"LinuxGpuFrames");
        try {worker.start();if(ownProducer)startProducer();} catch(RuntimeException error) {ACTIVE.set(false);surface.release();throw error;}
    }
    @Override public void setTargetHz(int hz) {
        if (hz<30 || hz>120) throw new IllegalArgumentException("Unsupported frame target");
        synchronized (lock) { targetHz=hz;if(handle!=0)nativeSetHz(handle,hz); }
        try(java.io.FileOutputStream output=new java.io.FileOutputStream(new File(base,"rootfs/tmp/nf-gpu-target-hz"))) {
            output.write(Integer.toString(hz).getBytes(StandardCharsets.US_ASCII));
        }catch(Exception error){android.util.Log.w("GpuFrameRenderer","Cannot update capture cadence");}
    }
    @Override public void stop() {
        synchronized (lock) { stopped=true;if(handle!=0)nativeStop(handle); }
        try { worker.join(2500);if(producerWorker!=null)producerWorker.join(2000); } catch (InterruptedException error) { Thread.currentThread().interrupt(); }
    }
    private void startProducer() {
        producerWorker=new Thread(() -> {
            try {
                File endpoint=new File(base,"rootfs/tmp/nf-gpu.sock");
                long deadline=android.os.SystemClock.elapsedRealtime()+7500;
                while(!stopped && !endpoint.exists() && android.os.SystemClock.elapsedRealtime()<deadline)Thread.sleep(20);
                if(stopped)return;
                if(!endpoint.exists())throw new java.io.IOException("GPU endpoint unavailable");
                String lib="/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu";
                ProcessBuilder builder=new ProcessBuilder("/system/bin/sh",new File(base,"enter.sh").getPath(),
                    "/usr/bin/env","LD_PRELOAD=/tmp/libnightfall-kgsl-compat.so:/opt/mesa-va/usr/lib/aarch64-linux-gnu/libtva_drm_shim_wayland.so",
                    "LD_LIBRARY_PATH="+lib+":/usr/lib/aarch64-linux-gnu:/opt/mesa-va/usr/lib/aarch64-linux-gnu",
                    "LIBGL_DRIVERS_PATH="+lib+"/dri","GBM_BACKENDS_PATH="+lib+"/gbm",
                    "TERMUX_VA_BRIDGE=1","TERMUX_VA_GPU_BACKEND=kgsl","TERMUX_VA_X11_DRI3=1",
                    "GALLIUM_DRIVER=kgsl","MESA_LOADER_DRIVER_OVERRIDE=kgsl","EGL_PLATFORM=surfaceless",
                    "/usr/bin/python3",generatedOnly ? "/tmp/probe-gpu-surface-generated.py" : "/tmp/gpu-browser-capture.py");
                if(generatedOnly) {
                    org.json.JSONObject settings=new org.json.JSONObject(new String(java.nio.file.Files.readAllBytes(new File(base,"direct-frame-config.json").toPath()),StandardCharsets.UTF_8));
                    String x11Mode=settings.optString("generated_surface_x11_mode","off");
                    if(!"off".equals(x11Mode) && !"idle".equals(x11Mode) && !"capture".equals(x11Mode) && !"idle-gles".equals(x11Mode) && !"capture-gles".equals(x11Mode) && !"startup".equals(x11Mode))throw new java.io.IOException("Invalid generated X11 test mode");
                    builder.command().add("--x11-mode");builder.command().add(x11Mode);
                }
                builder.environment().put("NF_LINUX_BASE",base.getPath());builder.environment().put("NF_LINUX_ID","1000:1000");
                builder.redirectErrorStream(true).redirectOutput(new File(base,"gpu-live.log"));
                Process child;
                synchronized(lock){if(stopped)return;producer=builder.start();child=producer;}
                child.waitFor();
            }catch(InterruptedException error){Thread.currentThread().interrupt();}
            catch(Exception error){android.util.Log.e("GpuFrameRenderer","Capture producer failed",error);}
            finally {
                boolean failed=false;
                synchronized(lock){if(!stopped){stopped=true;if(handle!=0)nativeStop(handle);failed=true;}}
                if(failed && !generatedOnly)BrowserLabService.gpuFailure("capture_producer_exit");
            }
        },"LinuxGpuProducer");
        producerWorker.start();
    }
    private void stopProducer() {
        Process child;synchronized(lock){child=producer;}
        if(child==null)return;
        try {
            if(!child.waitFor(1000,java.util.concurrent.TimeUnit.MILLISECONDS)){
                child.destroy();if(!child.waitFor(1000,java.util.concurrent.TimeUnit.MILLISECONDS))child.destroyForcibly();
            }
        }catch(InterruptedException error){Thread.currentThread().interrupt();child.destroy();}
    }
    boolean isAlive() { return worker.isAlive(); }
    private static native long nativeCreate(Surface surface,String path,int width,int height);
    private static native String nativeRun(long state);
    private static native void nativeStop(long state);
    private static native void nativeSetHz(long state,int hz);
    private static native void nativeDestroy(long state);
}
