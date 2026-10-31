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
    private Process linux;
    private LinuxAudioPlayer audio;
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
        if (linux != null && linux.isAlive()) return START_NOT_STICKY;
        File base = new File(getFilesDir(), "linux");
        if (!new File(base, "rootfs/opt/google/chrome/chrome").exists()) {
            status = "Linux files have not been deployed yet"; stopSelf(); return START_NOT_STICKY;
        }
        try {
            boolean unsafe = intent != null && intent.getBooleanExtra("unsafe_no_sandbox", false);
            ProcessBuilder builder = new ProcessBuilder("/system/bin/sh", new File(base, "enter.sh").getPath(),
                    "/bin/bash", "/tmp/start-desktop.sh", unsafe ? "--unsafe-no-sandbox" : "--sandbox");
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

    @Override public void onDestroy() {
        if (audio != null) audio.stop();
        if (linux != null) { Process current = linux; linux = null; current.destroy(); }
        stopForeground(true);
        super.onDestroy();
    }
}
