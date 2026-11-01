package app.nightfall.browserlab;

import android.app.Service;
import android.content.Intent;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.RemoteException;
import android.view.Surface;
import java.io.File;

/** Explicit lab IPC: only the installed Nightfall UID can submit an output surface. */
public final class DirectFrameService extends Service {
    private static volatile DirectFrameService active;
    @Override public void onCreate() { super.onCreate(); active = this; }
    static void stopForRuntime() {
        DirectFrameService current = active;
        if (current != null) synchronized (current) { current.stopFrames(); }
    }
    private DirectFrameRenderer renderer;
    private LinuxRfbInput input;
    private IBinder owner;
    private final IBinder.DeathRecipient death = () -> { synchronized (DirectFrameService.this) { stopFrames(); } };
    private void checkCaller() {
        String[] packages = getPackageManager().getPackagesForUid(Binder.getCallingUid());
        if (packages != null) for (String name : packages)
            if ("app.nightfall.quest".equals(name)) return;
        throw new SecurityException("Only installed Nightfall may connect to the frame lab");
    }
    private void stopFrames() {
        if (input != null) { input.close(); input = null; }
        if (owner != null) { owner.unlinkToDeath(death, 0); owner = null; }
        if (renderer != null) { renderer.stop(); renderer = null; }
    }
    private final Binder bridge = new Binder() {
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
            checkCaller();
            data.enforceInterface("app.nightfall.browserlab.DirectFrames.v1");
            synchronized (DirectFrameService.this) {
                if (code == 1) {
                    Surface surface = data.readTypedObject(Surface.CREATOR);
                    IBinder token = data.readStrongBinder();
                    if (surface == null || !surface.isValid() || token == null)
                        throw new IllegalArgumentException("Valid surface and lifetime token required");
                    File base = new File(getFilesDir(), "linux");
                    if (!new File(base, "rootfs/tmp/nightfall-framebuffer/Xvfb_screen0").isFile()) {
                        surface.release();
                        throw new IllegalStateException("Linux framebuffer is not ready");
                    }
                    stopFrames();
                    owner = token;
                    try { owner.linkToDeath(death, 0); }
                    catch (RemoteException e) { owner = null; surface.release(); throw e; }
                    renderer = new DirectFrameRenderer(base, surface);
                    input = new LinuxRfbInput(base);
                } else if (code == 2) stopFrames();
                else if (code == 3) {
                    int hz = data.readInt();
                    if (renderer != null) renderer.setTargetHz(hz);
                }
                else if (code == 4) {
                    float x = data.readFloat(), y = data.readFloat(); int action = data.readInt();
                    if (input != null) input.pointer(x, y, action);
                } else if (code == 5) {
                    int key = data.readInt(); boolean down = data.readInt() != 0; int modifiers = data.readInt();
                    if (input != null) input.key(key, down, modifiers);
                } else if (code == 6) { if (input != null) input.release(); }
                else return false;
            }
            reply.writeNoException();
            return true;
        }
    };
    @Override public IBinder onBind(Intent intent) { return bridge; }
    @Override public synchronized void onDestroy() {
        stopFrames(); if (active == this) active = null; super.onDestroy();
    }
}
