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
    static void stopForRuntime() {stopForRuntime(true);}
    static void stopForRuntime(boolean includePending) {
        DirectFrameService current = active;
        if (current != null) synchronized (current) { if(includePending || current.renderer!=null)current.stopFrames(); }
    }
    private FrameRenderer renderer;
    private Surface pendingSurface;
    private long attachGeneration;
    private int targetHz=60;
    private String attachError="", pendingAction, pendingValue;
    private LinuxRfbInput input;
    private LinuxBrowserControl control;
    private IBinder owner;
    private final IBinder.DeathRecipient death = () -> { synchronized (DirectFrameService.this) { stopFrames(); } };
    private void checkCaller() {
        String[] packages = getPackageManager().getPackagesForUid(Binder.getCallingUid());
        if (packages != null) for (String name : packages)
            if ("app.nightfall.quest".equals(name)) return;
        throw new SecurityException("Only installed Nightfall may connect to the frame lab");
    }
    static boolean gpuRequested(File base) {
        try {
            byte[] bytes=java.nio.file.Files.readAllBytes(new File(base,"direct-frame-config.json").toPath());
            return new org.json.JSONObject(new String(bytes,java.nio.charset.StandardCharsets.UTF_8)).optBoolean("gpu_renderer",false);
        } catch(Exception ignored) {return false;}
    }
    private static boolean generatedTestRequested(File base) {
        try {return new org.json.JSONObject(new String(java.nio.file.Files.readAllBytes(new File(base,"direct-frame-config.json").toPath()),java.nio.charset.StandardCharsets.UTF_8)).optBoolean("generated_gpu_test",false);}
        catch(Exception ignored){return false;}
    }
    private static boolean generatedMinimalRequested(File base) {
        try {return new org.json.JSONObject(new String(java.nio.file.Files.readAllBytes(new File(base,"direct-frame-config.json").toPath()),java.nio.charset.StandardCharsets.UTF_8)).optBoolean("generated_minimal_gpu_test",false);}
        catch(Exception ignored){return false;}
    }
    private void stopFrames() {
        attachGeneration++;
        if(pendingSurface!=null){pendingSurface.release();pendingSurface=null;}
        pendingAction=pendingValue=null;
        if (renderer != null || control != null || input != null) BrowserLabService.suspendAudio();
        if (input != null) { input.close(); input = null; }
        if (control != null) { control.close(); control = null; }
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
                    stopFrames();owner=token;
                    try {owner.linkToDeath(death,0);}catch(RemoteException error){owner=null;surface.release();throw error;}
                    pendingSurface=surface;attachError="";long generation=attachGeneration;
                    // Return immediately to Nightfall's UI; startup is asynchronous.
                    try {
                        final boolean generatedMinimal=generatedMinimalRequested(new File(getFilesDir(),"linux"));
                        if(!generatedMinimal)startForegroundService(new Intent(DirectFrameService.this,BrowserLabService.class).putExtra("unsafe_no_sandbox",true)
                            .putExtra("generated_gpu_test",generatedTestRequested(new File(getFilesDir(),"linux"))));
                        new Thread(() -> attachWhenReady(generation,generatedMinimal),"LinuxFrameAttach").start();
                    }catch(RuntimeException error){stopFrames();throw error;}
                } else if (code == 2) stopFrames();
                else if (code == 3) {
                    int hz = data.readInt();
                    if(hz<30 || hz>120)throw new IllegalArgumentException("Unsupported frame target");
                    targetHz=hz;if (renderer != null) renderer.setTargetHz(hz);
                }
                else if (code == 4) {
                    float x = data.readFloat(), y = data.readFloat(); int action = data.readInt();
                    if (input != null) input.pointer(x, y, action);
                } else if (code == 5) {
                    int key = data.readInt(); boolean down = data.readInt() != 0; int modifiers = data.readInt();
                    if (input != null) input.key(key, down, modifiers);
                } else if (code == 6) { if (input != null) input.release(); }
                else if (code == 7) {
                    String action = data.readString(), value = data.readString();
                    if (control != null) control.navigate(action, value);
                    else {pendingAction=action;pendingValue=value;}
                } else if (code == 8) {
                    reply.writeNoException(); reply.writeString(control == null ? "{\"state\":\""+(attachError.isEmpty()?"starting":"error")+"\"}" : control.snapshot()); return true;
                }
                else return false;
            }
            reply.writeNoException();
            return true;
        }
    };
    private void attachWhenReady(long generation,boolean generatedMinimal) {
        long deadline=android.os.SystemClock.elapsedRealtime()+10000;
        try {
            while(!generatedMinimal && android.os.SystemClock.elapsedRealtime()<deadline) {
                synchronized(this){if(generation!=attachGeneration || pendingSurface==null)return;}
                if(BrowserLabService.runtimeReady())break;
                Thread.sleep(25);
            }
            synchronized(this) {
                if(generation!=attachGeneration || pendingSurface==null)return;
                if(!generatedMinimal && !BrowserLabService.runtimeReady()){attachError="Runtime startup timed out";stopFrames();return;}
                File base=new File(getFilesDir(),"linux");Surface target=pendingSurface;pendingSurface=null;
                try {
                    renderer=generatedMinimal?new GpuFrameRenderer(base,target,true,true):gpuRequested(base)?new GpuFrameRenderer(base,target,true):new DirectFrameRenderer(base,target);
                    renderer.setTargetHz(targetHz);
                    if(!generatedMinimal) {
                        control=new LinuxBrowserControl(base);input=new LinuxRfbInput(base,control);
                        if(pendingAction!=null)control.navigate(pendingAction,pendingValue);
                        BrowserLabService.resumeAudio();
                    }
                    pendingAction=pendingValue=null;
                }catch(RuntimeException | LinkageError error){if(renderer==null)target.release();attachError=error.getClass().getSimpleName();stopFrames();}
            }
        }catch(InterruptedException error){Thread.currentThread().interrupt();}
    }
    @Override public IBinder onBind(Intent intent) { return bridge; }
    @Override public synchronized void onDestroy() {
        stopFrames(); if (active == this) active = null; super.onDestroy();
    }
}
