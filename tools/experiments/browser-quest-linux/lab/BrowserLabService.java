package app.nightfall.browserlab;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import java.io.File;

/** Keeps the lab runtime and audio owned by a foreground media service during VR tests. */
public final class BrowserLabService extends Service {
    private static volatile BrowserLabService active;
    private static final android.os.Handler UI = new android.os.Handler(android.os.Looper.getMainLooper());
    @Override public void onCreate() { super.onCreate(); active = this; }
    static void suspendAudio() {
        BrowserLabService current = active;
        if (current == null) return;
        LinuxAudioPlayer previous = current.audio;
        UI.post(() -> {
            if (active == current && previous != null && current.audio == previous) {
                current.audio = null; previous.stop();
            }
        });
    }
    static void resumeAudio() {
        BrowserLabService current = active;
        UI.post(() -> {
            if (current != null && active == current && current.audio == null && current.linux != null && current.linux.isAlive()) {
                current.audio = new LinuxAudioPlayer(current, new File(current.getFilesDir(), "linux"));
                current.audio.start();
            }
        });
    }
    private volatile Process linux, codecDaemon;
    private LinuxAudioPlayer audio;
    private boolean gpuFaulted;
    public static volatile String status = "Linux browser stopped";

    @Override public IBinder onBind(Intent intent) { return null; }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && "stop".equals(intent.getAction())) { stopSelf(); return START_NOT_STICKY; }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel("linux-browser", "Linux browser lab",
                NotificationManager.IMPORTANCE_LOW));
        PendingIntent show = PendingIntent.getActivity(this, 0, new Intent(this, BrowserLabActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, BrowserLabService.class).setAction("stop"),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        startForeground(1, new Notification.Builder(this, "linux-browser")
                .setSmallIcon(android.R.drawable.ic_media_play).setContentTitle("Linux browser lab running")
                .setContentText("Browser and audio remain active while you use Nightfall")
                .setContentIntent(show).addAction(new Notification.Action.Builder(null, "Stop", stop).build())
                .setOngoing(true).build());
        if (linux != null && linux.isAlive()) {
            if (intent != null && intent.getBooleanExtra("probe_frames", false)) DirectFrameProbe.start(this);
            return START_NOT_STICKY;
        }
        DirectFrameService.stopForRuntime(false); // No mapped reader may outlive Xvfb's backing file.
        File base = new File(getFilesDir(), "linux");
        if (!new File(base, "rootfs/opt/google/chrome/chrome").exists()) {
            status = "Linux files have not been deployed yet"; stopSelf(); return START_NOT_STICKY;
        }
        try {
            new File(base,"rootfs/tmp/nightfall-chrome.pid").delete();
            new File(base,"rootfs/tmp/nightfall-framebuffer/Xvfb_screen0").delete();
            boolean unsafe = intent != null && intent.getBooleanExtra("unsafe_no_sandbox", false);
            boolean gpu=DirectFrameService.gpuRequested(base);
            ProcessBuilder builder = new ProcessBuilder("/system/bin/sh", new File(base, "enter.sh").getPath(),
                    "/usr/bin/env", "NF_GPU_DIRECT="+(gpu?"1":"0"),
                    "/bin/bash", "/tmp/start-desktop.sh", unsafe ? "--unsafe-no-sandbox" : "--sandbox",
                    intent != null && intent.getBooleanExtra("generated_gpu_test",false) ? "--generated-gpu-test" : "--normal");
            if (gpu) startGpuCodec(base);
            builder.environment().put("NF_LINUX_BASE", base.getPath());
            builder.environment().put("NF_LINUX_ID", "1000:1000");
            builder.redirectErrorStream(true);
            File previous = new File(base, "desktop.log");
            if (previous.exists()) previous.renameTo(new File(base, "desktop.previous.log"));
            builder.redirectOutput(previous);
            linux = builder.start();
            status = unsafe ? "Lab browser + Android audio active (Chrome sandbox disabled)"
                    : "Starting Linux browser with Chrome sandbox enabled";
            audio = new LinuxAudioPlayer(this, base); audio.start();
            Process current = linux;
            new Thread(() -> {
                try {
                    int exit = current.waitFor();
                    if (linux == current) { status = "Linux browser exited: " + exit; stopSelf(); }
                } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
            }, "LinuxRuntimeWait").start();
        } catch (Exception error) { status = "Startup failed: " + error; stopSelf(); }
        return START_NOT_STICKY;
    }

    static void gpuFailure(String stage) {
        BrowserLabService current=active;if(current==null)return;
        synchronized(current){if(current.gpuFaulted)return;current.gpuFaulted=true;}
        // Do not leave faulted Mesa clients submitting after capture has failed.
        Process runtime=current.linux;if(runtime!=null)runtime.destroy();
        try {
            File base=new File(current.getFilesDir(),"linux");File config=new File(base,"direct-frame-config.json");
            org.json.JSONObject settings=new org.json.JSONObject(new String(java.nio.file.Files.readAllBytes(config.toPath()),java.nio.charset.StandardCharsets.UTF_8));
            settings.put("gpu_renderer",false);
            try(java.io.FileOutputStream out=new java.io.FileOutputStream(config)){out.write(settings.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));}
            org.json.JSONObject failure=new org.json.JSONObject().put("stage",stage).put("gpu_disabled",true).put("time_ms",System.currentTimeMillis());
            try(java.io.FileOutputStream out=new java.io.FileOutputStream(new File(base,"gpu-runtime-failure.json"))){out.write(failure.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));}
        }catch(Exception error){android.util.Log.e("LinuxGpuRuntime","Cannot persist GPU failure",error);}
        status="GPU browser stopped after a capture/graphics error; experimental GPU mode disabled";
        android.util.Log.e("LinuxGpuRuntime",status+" ("+stage+")");
        UI.post(() -> {if(active==current)current.stopSelf();});
    }
    static boolean runtimeReady() {
        BrowserLabService current=active;
        if(current==null || current.linux==null || !current.linux.isAlive())return false;
        File base=new File(current.getFilesDir(),"linux/rootfs/tmp");
        return new File(base,"nightfall-chrome.pid").isFile() && new File(base,"nightfall-framebuffer/Xvfb_screen0").isFile();
    }
    private void startGpuCodec(File base) throws Exception {
        File socket=new File(base,"rootfs/tmp/nightfall-va/browser.sock");
        socket.getParentFile().mkdirs();
        if(socket.exists() && !socket.delete())throw new java.io.IOException("Stale browser codec socket");
        codecDaemon=new ProcessBuilder(new File(base,"termux-va").getPath(),"--sock",socket.getPath())
                .redirectErrorStream(true).redirectOutput(new File(base,"browser-codec.log")).start();
        long deadline=android.os.SystemClock.elapsedRealtime()+1500;
        while(!socket.exists() && codecDaemon.isAlive() && android.os.SystemClock.elapsedRealtime()<deadline)Thread.sleep(20);
        if(!socket.exists())throw new java.io.IOException("Browser codec unavailable");
    }
    @Override public void onDestroy() {
        DirectFrameService.stopForRuntime();
        if (audio != null) { audio.stop(); audio = null; }
        if (active == this) active = null;
        if (codecDaemon != null) { codecDaemon.destroy(); codecDaemon=null; }
        if (linux != null) { Process current = linux; linux = null; current.destroy(); }
        stopForeground(true);
        super.onDestroy();
    }
}
