package com.godot.game;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.view.Surface;

/** DEV-only explicit Surface handoff; no pixels, credentials or ports cross IPC. */
final class LinuxFrameLabClient implements ServiceConnection {
    private final Context context;
    private final Surface surface;
    private final Runnable failed;
    private final IBinder lifetime = new Binder();
    private IBinder remote;
    private boolean bound, closed;
    private int targetHz = 30, sentHz;

    LinuxFrameLabClient(Context context, Surface surface, Runnable failed) {
        this.context = context.getApplicationContext();
        this.surface = surface;
        this.failed = failed;
    }

    void start() {
        Intent intent = new Intent().setComponent(new ComponentName(
                "app.nightfall.browserlab", "app.nightfall.browserlab.DirectFrameService"));
        bound = context.bindService(intent, this, Context.BIND_AUTO_CREATE);
        if (!bound) failed.run();
    }

    private void transact(int code) throws android.os.RemoteException {
        Parcel data = Parcel.obtain(), reply = Parcel.obtain();
        try {
            data.writeInterfaceToken("app.nightfall.browserlab.DirectFrames.v1");
            if (code == 1) { data.writeTypedObject(surface, 0); data.writeStrongBinder(lifetime); }
            if (code == 3) data.writeInt(targetHz);
            if (!remote.transact(code, data, reply, 0)) throw new IllegalStateException("Unsupported frame bridge");
            reply.readException();
        } finally { data.recycle(); reply.recycle(); }
    }

    @Override public void onServiceConnected(ComponentName name, IBinder binder) {
        if (closed) return;
        remote = binder;
        try { transact(1); sentHz = 0; updateTargetHz(targetHz); }
        catch (Exception error) {
            DiagnosticLog.error("LinuxFrameLab", "Direct frame attach failed", error);
            failed.run();
        }
    }
    @Override public void onServiceDisconnected(ComponentName name) { remote = null; if (!closed) failed.run(); }
    @Override public void onNullBinding(ComponentName name) { if (!closed) failed.run(); }
    @Override public void onBindingDied(ComponentName name) { remote = null; if (!closed) failed.run(); }

    void updateTargetHz(int hz) {
        targetHz = hz;
        if (remote == null || sentHz == hz || closed) return;
        try { transact(3); sentHz = hz; }
        catch (Exception error) {
            DiagnosticLog.error("LinuxFrameLab", "Frame target update failed", error);
            failed.run();
        }
    }

    void pointer(float x, float y, int action) { input(4, x, y, action, false, 0); }
    void key(int code, boolean down, int modifiers) { input(5, 0, 0, code, down, modifiers); }
    void releaseInput() { input(6, 0, 0, 0, false, 0); }

    private void input(int code, float x, float y, int value, boolean down, int modifiers) {
        if (remote == null || closed) return;
        Parcel data = Parcel.obtain(), reply = Parcel.obtain();
        try {
            data.writeInterfaceToken("app.nightfall.browserlab.DirectFrames.v1");
            if (code == 4) { data.writeFloat(x); data.writeFloat(y); data.writeInt(value); }
            if (code == 5) { data.writeInt(value); data.writeInt(down ? 1 : 0); data.writeInt(modifiers); }
            if (!remote.transact(code, data, reply, 0)) throw new IllegalStateException("Input bridge unavailable");
            reply.readException();
        } catch (Exception error) {
            DiagnosticLog.error("LinuxFrameLab", "Linux input forwarding failed", error);
        } finally { data.recycle(); reply.recycle(); }
    }

    void close() {
        closed = true;
        if (remote != null) {
            try { transact(2); }
            catch (Exception error) { DiagnosticLog.error("LinuxFrameLab", "Direct frame detach failed", error); }
            remote = null;
        }
        if (bound) { context.unbindService(this); bound = false; }
    }
}
