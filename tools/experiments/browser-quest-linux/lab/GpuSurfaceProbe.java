package app.nightfall.browserlab;

import android.graphics.PixelFormat;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.Surface;
import java.io.File;
import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicLong;
import org.json.JSONArray;
import org.json.JSONObject;

/** Generated-only real Surface sink; checks colours after EGL window rendering. */
final class GpuSurfaceProbe {
    private static ImageReader reader;
    private static GpuFrameRenderer renderer;
    private static HandlerThread drain;
    private static final AtomicLong frames=new AtomicLong(), matches=new AtomicLong();
    private static volatile String lastPixels="[]";
    private static long started;
    private static long earlyStopMs;
    private static boolean earlyWorkerAlive;
    private static JSONObject lastResult;
    static synchronized void start(File base) {start(base,false);}
    static synchronized void start(File base,boolean ownProducer) {
        if(renderer!=null)throw new IllegalStateException("Surface probe already active");
        frames.set(0);matches.set(0);lastPixels="[]";started=System.nanoTime();earlyStopMs=-1;earlyWorkerAlive=false;lastResult=null;
        drain=new HandlerThread("GpuSurfaceProbeDrain");drain.start();
        reader=ImageReader.newInstance(1280,720,PixelFormat.RGBA_8888,3);
        reader.setOnImageAvailableListener(sink -> {
            try(Image image=sink.acquireLatestImage()) {
                if(image==null)return;
                frames.incrementAndGet();Image.Plane plane=image.getPlanes()[0];ByteBuffer pixels=plane.getBuffer();
                int[][] positions={{100,100},{1100,100},{100,620},{1100,620}};
                int[][] expected={{255,0,0},{0,255,0},{0,0,255},{255,255,0}};
                JSONArray samples=new JSONArray();boolean correct=true;
                for(int p=0;p<4;p++) {
                    int at=positions[p][1]*plane.getRowStride()+positions[p][0]*plane.getPixelStride();
                    JSONArray point=new JSONArray();
                    for(int c=0;c<4;c++) {
                        int value=pixels.get(at+c)&255;point.put(value);
                        if(c<3 && Math.abs(value-expected[p][c])>5)correct=false;
                    }
                    samples.put(point);
                }
                lastPixels=samples.toString();if(correct)matches.incrementAndGet();
            } catch(Exception error) { android.util.Log.e("GpuSurfaceProbe","Surface sample failed",error); }
        },new Handler(drain.getLooper()));
        // Give the renderer its own Surface wrapper; the reader keeps its consumer.
        android.os.Parcel parcel=android.os.Parcel.obtain();Surface output;
        try { reader.getSurface().writeToParcel(parcel,0);parcel.setDataPosition(0);output=Surface.CREATOR.createFromParcel(parcel); }
        finally { parcel.recycle(); }
        renderer=new GpuFrameRenderer(base,output,ownProducer);
    }
    static synchronized void stopEarlyForTest() {
        final GpuFrameRenderer current=renderer;
        new Thread(() -> {
            try {Thread.sleep(7000);} catch(InterruptedException error){Thread.currentThread().interrupt();return;}
            synchronized(GpuSurfaceProbe.class) {
                if(renderer!=current || current==null)return;
                long before=System.nanoTime();current.stop();earlyStopMs=(System.nanoTime()-before)/1000000;
                earlyWorkerAlive=current.isAlive();
            }
        },"GpuSurfaceStopTest").start();
    }
    static synchronized JSONObject stop(File base) throws Exception {
        if(renderer==null && reader==null && drain==null)return lastResult==null ? new JSONObject().put("state","inactive") : lastResult;
        boolean workerAlive=false;
        if(renderer!=null){renderer.stop();workerAlive=renderer.isAlive();renderer=null;}
        if(reader!=null){reader.close();reader=null;}
        if(drain!=null){drain.quitSafely();drain.join(1000);drain=null;}
        JSONObject result=new JSONObject().put("worker_alive_after_stop",workerAlive).put("early_stop_ms",earlyStopMs).put("worker_alive_after_early_stop",earlyWorkerAlive).put("received_frames",frames.get()).put("matching_quadrant_frames",matches.get())
                .put("last_pixels",new JSONArray(lastPixels)).put("elapsed_s",(System.nanoTime()-started)/1e9)
                .put("passed",frames.get()>100 && matches.get()>0)
                .put("limits","Generated ImageReader Surface sink; includes diagnostic CPU pixel sampling, excludes Quest VR rendering.");
        try(java.io.FileOutputStream out=new java.io.FileOutputStream(new File(base,"gpu-surface-probe.json"))) {
            out.write(result.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        }
        lastResult=result;return result;
    }
}
