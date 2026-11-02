package app.nightfall.browserlab;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

/** Bounded allocation or tiny offscreen EGL test in the app domain; never starts Chrome. */
public final class GpuAllocationService extends Service {
    private volatile Process process, codecDaemon, bufferExporter;
    private volatile boolean running, cancelled, decoderDisplayOrder, dumpGeneratedStream, usePpsDriver;
    @Override public IBinder onBind(Intent intent) { return null; }
    @Override public int onStartCommand(Intent intent, int flags, int id) {
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("gpu-allocation", "GPU allocation probe", NotificationManager.IMPORTANCE_LOW));
        startForeground(2, new Notification.Builder(this, "gpu-allocation")
                .setSmallIcon(android.R.drawable.ic_menu_info_details).setContentTitle("Bounded GPU allocation probe")
                .setContentText("No video; tiny allocations only").build());
        if (running) return START_NOT_STICKY;
        running = true;
        usePpsDriver = intent != null && intent.getBooleanExtra("pps_driver", false);
        dumpGeneratedStream = intent != null && intent.getBooleanExtra("ffmpeg_probe", false);
        decoderDisplayOrder = intent != null && intent.getBooleanExtra("codec_display_order", false);
        final boolean chromeSurfaceStop = intent != null && intent.getBooleanExtra("chrome_surface_stop", false);
        final boolean chromeSurfaceCapture = intent != null && intent.getBooleanExtra("chrome_surface_capture", false);
        final boolean chromeGpuCapture = intent != null && intent.getBooleanExtra("chrome_gpu_capture", false);
        final boolean gpuSharedProbe = intent != null && (intent.getBooleanExtra("gpu_shared_probe", false) || intent.getBooleanExtra("gpu_fence_loop",false));
        final boolean gpuBufferProbe = intent != null && intent.getBooleanExtra("gpu_buffer_probe", false);
        final boolean nativeEglOnly = intent != null && intent.getBooleanExtra("native_egl_only", false);
        final boolean dri3Server = intent != null && intent.getBooleanExtra("dri3_server", false);
        final boolean chromeVa = intent != null && intent.getBooleanExtra("chrome_va", false);
        final boolean elementaryProbe = intent != null && intent.getBooleanExtra("elementary_probe", false);
        final boolean ffmpegProbe = intent != null && intent.getBooleanExtra("ffmpeg_probe", false);
        final boolean vaProbe = intent != null && intent.getBooleanExtra("va_probe", false);
        final boolean mediaProbe = intent != null && intent.getBooleanExtra("media_probe", false);
        final boolean chromeVideo = intent != null && intent.getBooleanExtra("chrome_video", false);
        final boolean chromeSoftware = intent != null && intent.getBooleanExtra("chrome_software", false);
        final boolean chromeX11 = intent != null && intent.getBooleanExtra("chrome_x11", false);
        final boolean chromeProbe = intent != null && intent.getBooleanExtra("chrome_probe", false);
        final boolean minimalClear = intent != null && intent.getBooleanExtra("minimal_clear", false);
        final boolean eglProbe = intent != null && intent.getBooleanExtra("egl_probe", false);
        final boolean includeZink = intent != null && intent.getBooleanExtra("include_zink", false);
        new Thread(() -> {
            JSONObject result = new JSONObject();
            File base = new File(getFilesDir(), "linux");
            try {
                if (gpuSharedProbe) { runBufferSharingProbe(base, result, intent.getBooleanExtra("gpu_hd", false),intent.getBooleanExtra("gpu_fence_loop",false)); return; }
                if (mediaProbe || vaProbe || ffmpegProbe || elementaryProbe) { runMediaProbe(base, result, vaProbe || ffmpegProbe, ffmpegProbe, elementaryProbe); return; }
                if (chromeGpuCapture) {
                    File socket = new File(base,"rootfs/tmp/nf-gpu.sock");
                    if (socket.exists() && !socket.delete()) throw new java.io.IOException("Stale GPU socket");
                    if (chromeSurfaceCapture) { GpuSurfaceProbe.start(base); if(chromeSurfaceStop)GpuSurfaceProbe.stopEarlyForTest(); }
                    else bufferExporter = new ProcessBuilder(new File(base,"gpu-buffer-probe").getPath(),socket.getPath(),"1280","720","capture")
                            .redirectErrorStream(true).redirectOutput(new File(base,"gpu-capture-native.json")).start();
                    long deadline=android.os.SystemClock.elapsedRealtime()+1500;
                    while (!socket.exists() && (chromeSurfaceCapture || bufferExporter.isAlive()) && android.os.SystemClock.elapsedRealtime()<deadline) Thread.sleep(20);
                    if (!socket.exists()) throw new java.io.IOException("GPU endpoint unavailable");
                }
                if (chromeVa && !nativeEglOnly) startCodecDaemon(base);
                for (String mode : gpuBufferProbe ? new String[]{"buffer"} : chromeProbe ? new String[]{"chrome"} : eglProbe ? (includeZink ? new String[]{"kgsl", "zink"} : new String[]{"kgsl"}) : new String[]{"native", "proot"}) {
                    if (cancelled) break;
                    ProcessBuilder builder = "native".equals(mode)
                            ? new ProcessBuilder(new File(base, "kgsl-allocation-probe").getPath())
                            : new ProcessBuilder("/system/bin/sh", new File(base, "enter.sh").getPath(), "/tmp/kgsl-allocation-probe");
                    if (gpuBufferProbe) builder = new ProcessBuilder(new File(base, "gpu-buffer-probe").getPath());
                    if (eglProbe) builder = new ProcessBuilder("/system/bin/sh", new File(base, "enter.sh").getPath(),
                            "/usr/bin/env", "LD_PRELOAD=/tmp/libnightfall-kgsl-compat.so",
                            "LD_LIBRARY_PATH=/opt/mesa-freedreno/lib/aarch64-linux-gnu",
                            "LIBGL_DRIVERS_PATH=/opt/mesa-freedreno/lib/aarch64-linux-gnu/dri",
                            "VK_ICD_FILENAMES=/opt/mesa-freedreno/share/vulkan/icd.d/freedreno_icd.aarch64.json",
                            "GALLIUM_DRIVER=" + mode, "NIGHTFALL_EGL_DRIVER=" + mode,
                            "/usr/bin/python3", "/tmp/probe-linux-egl.py");
                    if (minimalClear) {
                        String lib="/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu";
                        builder=new ProcessBuilder("/system/bin/sh",new File(base,"enter.sh").getPath(),
                            "/usr/bin/env","LD_PRELOAD=/tmp/libnightfall-kgsl-compat.so:/opt/mesa-va/usr/lib/aarch64-linux-gnu/libtva_drm_shim_wayland.so",
                            "LD_LIBRARY_PATH="+lib+":/usr/lib/aarch64-linux-gnu:/opt/mesa-va/usr/lib/aarch64-linux-gnu",
                            "LIBGL_DRIVERS_PATH="+lib+"/dri","GBM_BACKENDS_PATH="+lib+"/gbm",
                            "GALLIUM_DRIVER=kgsl","MESA_LOADER_DRIVER_OVERRIDE=kgsl","EGL_PLATFORM=surfaceless",
                            "/usr/bin/python3","/tmp/probe-minimal-gpu-clear.py");
                    }
                    if(minimalClear && intent.getBooleanExtra("minimal_draw",false))builder.command().add("--draw");
                    if(minimalClear && intent.getBooleanExtra("minimal_diagnostics",false))builder.command().add("--diagnostics");
                    if(minimalClear && intent.getBooleanExtra("minimal_no_early_preamble",false))builder.command().add("--no-early-preamble");
                    if(minimalClear && intent.getBooleanExtra("minimal_no_preamble",false))builder.command().add("--no-preamble");
                    if(minimalClear && intent.getBooleanExtra("minimal_arithmetic_vertex",false))builder.command().add("--arithmetic-vertex");
                    if (chromeProbe) builder = new ProcessBuilder("/system/bin/sh", new File(base, "enter.sh").getPath(),
                            "/usr/bin/env", "LD_PRELOAD=/tmp/libnightfall-kgsl-compat.so",
                            "LD_LIBRARY_PATH=/opt/mesa-freedreno/lib/aarch64-linux-gnu",
                            "LIBGL_DRIVERS_PATH=/opt/mesa-freedreno/lib/aarch64-linux-gnu/dri",
                            "NF_CHROME_PROBE_BACKEND=" + (chromeX11 ? "x11" : "headless"),
                            "NF_CHROME_PROBE_RENDERER=" + (chromeSoftware ? "software" : "gpu"),
                            "NF_CHROME_PROBE_VIDEO=" + (chromeVideo ? "1" : "0"),
                            "NF_CHROME_PROBE_VA=" + (chromeVa ? "1" : "0"),
                            "NF_CHROME_PROBE_PPS=" + (usePpsDriver ? "1" : "0"),
                            "NF_CHROME_PROBE_DRI3=" + (dri3Server ? "1" : "0"),
                            "NF_CHROME_SURFACE_CAPTURE=" + (chromeSurfaceCapture ? "1" : "0"),
                            "NF_CHROME_GPU_CAPTURE=" + (chromeGpuCapture ? "1" : "0"),
                            "NF_CHROME_NATIVE_EGL_ONLY=" + (nativeEglOnly ? "1" : "0"),
                            "/usr/bin/python3", "/tmp/probe-chrome-gpu.py");
                    if (chromeProbe && chromeGpuCapture) {
                        String lib = "/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu";
                        builder.command().addAll(builder.command().size()-2,java.util.Arrays.asList(
                                "LD_LIBRARY_PATH="+lib+":/usr/lib/aarch64-linux-gnu:/opt/mesa-va/usr/lib/aarch64-linux-gnu",
                                "LD_PRELOAD=/tmp/libnightfall-kgsl-compat.so:/opt/mesa-va/usr/lib/aarch64-linux-gnu/libtva_drm_shim_wayland.so",
                                "LIBGL_DRIVERS_PATH="+lib+"/dri","GBM_BACKENDS_PATH="+lib+"/gbm",
                                "TERMUX_VA_BRIDGE=1","TERMUX_VA_GPU_BACKEND=kgsl","TERMUX_VA_X11_DRI3=1",
                                "GALLIUM_DRIVER=kgsl","MESA_LOADER_DRIVER_OVERRIDE=kgsl","EGL_PLATFORM=surfaceless"));
                    }
                    builder.environment().put("NF_LINUX_BASE", base.getPath());
                    builder.environment().put("NF_LINUX_ID", "1000:1000");
                    builder.redirectErrorStream(true);
                    builder.redirectOutput(new File(base, "gpu-allocation-" + mode + ".json"));
                    process = builder.start();
                    boolean done = process.waitFor(chromeProbe ? 20 : 5, TimeUnit.SECONDS);
                    if (!done) { process.destroyForcibly(); result.put(mode + "_timeout", true); }
                    else result.put(mode + "_exit", process.exitValue());
                    process = null;
                }
            } catch (Exception error) {
                try { result.put("error", error.getClass().getSimpleName()); } catch (Exception ignored) { }
            } finally {
                if (chromeSurfaceCapture) try {result.put("surface_probe",GpuSurfaceProbe.stop(base));}
                catch(Exception error){try{result.put("surface_probe_error",error.getClass().getSimpleName());}catch(Exception ignored){}}
                Process exporter = bufferExporter;
                if (exporter != null) try {
                    if (exporter.waitFor(1,TimeUnit.SECONDS)) result.put("buffer_export_exit",exporter.exitValue());
                    else exporter.destroyForcibly();
                } catch (Exception ignored) { exporter.destroyForcibly(); }
                Process pending = process; if (pending != null) pending.destroyForcibly();
                Process daemon = codecDaemon; if (daemon != null) daemon.destroyForcibly();
                try {
                    result.put("complete", true);
                    try (FileOutputStream output = new FileOutputStream(new File(base, "gpu-allocation-status.json"))) {
                        output.write(result.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8));
                    }
                } catch (Exception ignored) { }
                running = false; stopSelf();
            }
        }, "GpuAllocationProbe").start();
        return START_NOT_STICKY;
    }
    private void runBufferSharingProbe(File base, JSONObject result, boolean hd,boolean fenceLoop) throws Exception {
        File socket = new File(base,"rootfs/tmp/nf-gpu.sock");
        if (socket.exists() && !socket.delete()) throw new java.io.IOException("Stale GPU socket");
        ProcessBuilder nativeProbe=new ProcessBuilder(new File(base,"gpu-buffer-probe").getPath(),socket.getPath(),hd ? "1280" : "128",hd ? "720" : "128");
        if(fenceLoop)nativeProbe.command().add("capture");
        codecDaemon=nativeProbe.redirectErrorStream(true).redirectOutput(new File(base,"gpu-sharing-native.json")).start();
        long deadline = android.os.SystemClock.elapsedRealtime()+1500;
        while (!socket.exists() && codecDaemon.isAlive() && android.os.SystemClock.elapsedRealtime()<deadline) Thread.sleep(20);
        if (!socket.exists()) throw new java.io.IOException("GPU endpoint unavailable");
        String lib = "/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu";
        ProcessBuilder guest = new ProcessBuilder("/system/bin/sh",new File(base,"enter.sh").getPath(),
                "/usr/bin/env","LD_PRELOAD=/tmp/libnightfall-kgsl-compat.so:/opt/mesa-va/usr/lib/aarch64-linux-gnu/libtva_drm_shim_wayland.so",
                "LD_LIBRARY_PATH="+lib+":/usr/lib/aarch64-linux-gnu:/opt/mesa-va/usr/lib/aarch64-linux-gnu",
                "LIBGL_DRIVERS_PATH="+lib+"/dri","GBM_BACKENDS_PATH="+lib+"/gbm",
                "GALLIUM_DRIVER=kgsl","MESA_LOADER_DRIVER_OVERRIDE=kgsl","EGL_PLATFORM=surfaceless",
                "TERMUX_VA_BRIDGE=1","TERMUX_VA_GPU_BACKEND=kgsl","TERMUX_VA_X11_DRI3=1",
                "/usr/bin/python3",fenceLoop ? "/tmp/probe-gpu-fence-loop.py" : "/tmp/probe-gpu-buffer-share.py");
        guest.environment().put("NF_LINUX_BASE",base.getPath());guest.environment().put("NF_LINUX_ID","1000:1000");
        process = guest.redirectErrorStream(true).redirectOutput(new File(base,"gpu-sharing-linux.json")).start();
        if (!process.waitFor(6,TimeUnit.SECONDS)) { process.destroyForcibly(); result.put("guest_timeout",true); }
        else result.put("guest_exit",process.exitValue());
        if (!codecDaemon.waitFor(2,TimeUnit.SECONDS)) { codecDaemon.destroyForcibly();result.put("native_timeout",true); }
        else result.put("native_exit",codecDaemon.exitValue());
    }
    private File startCodecDaemon(File base) throws Exception {
        File socket = new File(base, "rootfs/tmp/nightfall-va/probe.sock");
        socket.getParentFile().mkdirs();
        if (socket.exists() && !socket.delete()) throw new java.io.IOException("Stale probe socket");
        ProcessBuilder daemonBuilder = new ProcessBuilder(new File(base, "termux-va").getPath(), "--sock", socket.getPath());
        if (dumpGeneratedStream) {
            File dump = new File(base,"rootfs/tmp/nf-generated-reconstructed.h264");
            if (dump.exists() && !dump.delete()) throw new java.io.IOException("Stale generated test dump");
            daemonBuilder.environment().put("NF_GENERATED_TEST_DUMP",dump.getPath());
        }
        if (decoderDisplayOrder) daemonBuilder.environment().put("DMD_NO_PICTURE_ORDER", "1");
        codecDaemon = daemonBuilder.redirectErrorStream(true).redirectOutput(new File(base, "media-probe-daemon.log")).start();
        long deadline = android.os.SystemClock.elapsedRealtime()+2000;
        while (!socket.exists() && codecDaemon.isAlive() && android.os.SystemClock.elapsedRealtime()<deadline) Thread.sleep(20);
        if (!socket.exists()) throw new java.io.IOException("Codec endpoint unavailable");
        return socket;
    }
    private void runMediaProbe(File base, JSONObject result, boolean vaProbe, boolean ffmpegProbe, boolean elementaryProbe) throws Exception {
        File socket = startCodecDaemon(base);
        String vaLib = usePpsDriver ? "/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu" : "/opt/mesa-va/usr/lib/aarch64-linux-gnu";
        ProcessBuilder probe = vaProbe ? new ProcessBuilder("/system/bin/sh", new File(base,"enter.sh").getPath(),
                "/usr/bin/env", "LD_PRELOAD=/tmp/libnightfall-kgsl-compat.so:/opt/mesa-va/usr/lib/aarch64-linux-gnu/libtva_drm_shim_wayland.so",
                "LD_LIBRARY_PATH=" + vaLib + ":/usr/lib/aarch64-linux-gnu:/opt/mesa-va/usr/lib/aarch64-linux-gnu:/opt/mesa-freedreno/lib/aarch64-linux-gnu",
                "LIBGL_DRIVERS_PATH=/opt/mesa-va/usr/lib/aarch64-linux-gnu/dri",
                "LIBVA_DRIVERS_PATH=" + vaLib + "/dri", "LIBVA_DRIVER_NAME=termuxva",
                "MESA_LOADER_DRIVER_OVERRIDE=kgsl", "TERMUX_VA_GPU_BACKEND=kgsl", "TERMUX_VA_BRIDGE=1",
                "TERMUX_VA_SOCKET=/tmp/nightfall-va/probe.sock", "DMD_WANT_SHM=0", "DMD_VA_LOG=1", "/usr/bin/python3", ffmpegProbe ? "/tmp/probe-ffmpeg-va.py" : "/tmp/probe-linux-va.py")
                : new ProcessBuilder(new File(base, "tva-probe").getPath(), socket.getPath(), "3000");
        if (elementaryProbe) probe = new ProcessBuilder("/system/bin/sh",new File(base,"enter.sh").getPath(),
                "/usr/bin/python3", "/tmp/tva-test-decode.py", "/tmp/nightfall-va/probe.sock",
                "/tmp/nf-generated-video.h264", "h264", "inline");
        probe.environment().put("NF_LINUX_BASE",base.getPath());
        probe.environment().put("NF_LINUX_ID","1000:1000");
        process = probe
                .redirectErrorStream(true).redirectOutput(new File(base, "media-probe-client.log")).start();
        if (!process.waitFor((ffmpegProbe || elementaryProbe) ? 8 : 5, TimeUnit.SECONDS)) { process.destroyForcibly(); result.put("media_timeout", true); }
        else result.put("media_exit", process.exitValue());
    }
    @Override public void onDestroy() {
        cancelled = true;
        try { GpuSurfaceProbe.stop(new File(getFilesDir(),"linux")); } catch(Exception ignored) { }
        Process exporter = bufferExporter; if (exporter != null) exporter.destroyForcibly();
        Process daemon = codecDaemon; if (daemon != null) daemon.destroyForcibly();
        Process pending = process; if (pending != null) pending.destroyForcibly();
        stopForeground(true); super.onDestroy();
    }
}
