package app.nightfall.browserlab;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.IBinder;
import java.io.File;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

/** Bounded generated-only lifecycle check of the normal :1 startup/capture path. */
public final class GpuRuntimeProbeService extends Service {
    private volatile boolean cancelled;
    @Override public IBinder onBind(Intent intent){return null;}
    @Override public int onStartCommand(Intent intent,int flags,int id) {
        NotificationManager manager=getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("gpu-runtime","Generated GPU runtime probe",NotificationManager.IMPORTANCE_LOW));
        startForeground(3,new Notification.Builder(this,"gpu-runtime").setSmallIcon(android.R.drawable.ic_menu_info_details)
                .setContentTitle("Bounded generated GPU browser test").setContentText("Stops automatically; no accounts").build());
        new Thread(() -> {
            File base=new File(getFilesDir(),"linux");JSONObject result=new JSONObject();JSONArray cycles=new JSONArray();
            try {
                if(!DirectFrameService.gpuRequested(base))throw new IllegalStateException("GPU test config required");
                startForegroundService(new Intent(this,BrowserLabService.class).putExtra("unsafe_no_sandbox",true).putExtra("generated_gpu_test",true));
                long deadline=android.os.SystemClock.elapsedRealtime()+10000;
                while(!cancelled && (!new File(base,"rootfs/tmp/nightfall-chrome.pid").exists() || !new File(base,"rootfs/tmp/nightfall-framebuffer/Xvfb_screen0").exists()) && android.os.SystemClock.elapsedRealtime()<deadline)Thread.sleep(50);
                if(cancelled)throw new InterruptedException();
                boolean passed=true;
                for(int cycle=0;cycle<2;cycle++) {
                    new File(base,"rootfs/tmp/gpu-live-status.json").delete();
                    GpuSurfaceProbe.start(base,true);
                    Thread.sleep(cycle==0?10000:4000);
                    JSONObject sink=GpuSurfaceProbe.stop(base);
                    JSONObject nativeStatus=read(new File(base,"gpu-surface-status.json"));
                    JSONObject producer=read(new File(base,"rootfs/tmp/gpu-live-status.json"));
                    boolean good=sink.optBoolean("passed") && !sink.optBoolean("worker_alive_after_stop",true)
                        && "stopped".equals(nativeStatus.optString("state")) && "stopped".equals(producer.optString("state"))
                        && producer.optLong("frames")>100 && !producer.has("cleanup_error");
                    cycles.put(new JSONObject().put("cycle",cycle+1).put("passed",good).put("surface",sink).put("native",nativeStatus).put("producer",producer));
                    passed &= good;
                }
                result.put("passed",passed);
            }catch(Exception error){try{result.put("passed",false).put("error",error.getClass().getSimpleName());}catch(Exception ignored){}}
            finally {
                try {GpuSurfaceProbe.stop(base);}catch(Exception ignored){}
                stopService(new Intent(this,BrowserLabService.class));
                try {
                    result.put("cycles",cycles).put("complete",true).put("limits","Generated temporary-profile :1 browser; ImageReader sink; no VR comfort or real account playback test.");
                    File temp=new File(base,"gpu-runtime-probe.tmp");
                    try(java.io.FileOutputStream out=new java.io.FileOutputStream(temp)){out.write(result.toString(2).getBytes(StandardCharsets.UTF_8));}
                    temp.renameTo(new File(base,"gpu-runtime-probe.json"));
                }catch(Exception ignored){}
                stopSelf();
            }
        },"GpuRuntimeProbe").start();
        return START_NOT_STICKY;
    }
    private static JSONObject read(File file)throws Exception{return new JSONObject(new String(java.nio.file.Files.readAllBytes(file.toPath()),StandardCharsets.UTF_8));}
    @Override public void onDestroy(){cancelled=true;super.onDestroy();}
}
