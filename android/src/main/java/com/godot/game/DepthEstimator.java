package com.godot.game;

import android.content.Context;
import android.content.res.AssetFileDescriptor;
import android.util.Log;

import org.tensorflow.lite.Interpreter;
import org.tensorflow.lite.gpu.GpuDelegate;
import org.tensorflow.lite.gpu.GpuDelegateFactory;

import java.io.FileInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.MappedByteBuffer;
import java.nio.channels.FileChannel;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public class DepthEstimator {
    private static final String TAG = "DepthEstimator";
    public static final int BACKEND_AUTO = 0;
    public static final int BACKEND_CPU = 1;
    public static final int BACKEND_GPU = 2;
    public static final int BACKEND_CAP_CPU = 1;
    public static final int BACKEND_CAP_GPU = 2;
    private static final long GPU_INFERENCE_INTERVAL_NS = 50_000_000L;
    private static final int OUTPUT_SIZE = 256;

    private static final String MODEL_MIDAS = "midas-midas-v2-w8a8.tflite";
    // midas-midas-v2-w8a8.tflite's actual per-tensor quantization parameters,
    // read directly from the model via ai-edge-litert's Interpreter.get_input/
    // output_details() (2026-08-18) - NOT assumed. Both the input ("image")
    // and output ("depth_estimates") tensors are UINT8, not float32:
    //   input:  scale=0.00487531116232276, zero_point=24
    //   output: scale=6.514299392700195,   zero_point=0
    // Getting either of these wrong doesn't throw - the interpreter runs
    // "successfully" and produces silently garbage output (confirmed:
    // sending raw 0..255 pixel bytes as input, and reading the output
    // ByteBuffer via asFloatBuffer() as if it were float32, both "worked"
    // with zero exceptions but produced near-black noise). The real/dequantized
    // value is (quantized - zero_point) * scale; quantizing the other
    // direction is round(real / scale) + zero_point, clamped to 0..255.
    private static final float MIDAS_INPUT_SCALE = 0.00487531116232276f;
    private static final int MIDAS_INPUT_ZERO_POINT = 24;
    private static final float MIDAS_OUTPUT_SCALE = 6.514299392700195f;
    private static final int MIDAS_OUTPUT_ZERO_POINT = 0;
    // MiDaS-small re-exported/re-calibrated at 192x192 (2026-08-20), same
    // w8a8-style full-int8 UINT8 I/O boundary as the 256px model above but
    // with its OWN independently-calibrated scale/zero_point - verified
    // directly via ai-edge-litert's Interpreter, NOT assumed to match the
    // 256px model's params (they don't: this one's input zero_point is 0,
    // not 24). A cheaper/faster comparison point against the 256px model at
    // the same architecture, offered as its own selectable option rather
    // than replacing MiDaS-256.
    private static final int MIDAS_192_INPUT_SIZE = 192;
    private static final String MODEL_MIDAS_192 = "midas-v21-small-192-int8.tflite";
    private static final float MIDAS_192_INPUT_SCALE = 0.003921568859368563f;
    private static final int MIDAS_192_INPUT_ZERO_POINT = 0;
    private static final float MIDAS_192_OUTPUT_SCALE = 5.250738620758057f;
    private static final int MIDAS_192_OUTPUT_ZERO_POINT = 0;
    // Depth Anything V2 Small, re-converted (2026-08-19/20) via onnx2tf -kt
    // input (fixes a layout-mangling bug that made every prior export
    // produce spatially incoherent output - see git history) - weight-only/
    // dynamic-range int8 (float32 I/O, quantization is internal-only), so
    // like YOLO26 these use the same plain 0..1 float32 boundary as
    // runInferenceDA always has. Two sizes: 252 (14*18, closest clean
    // ViT-S patch-size-14 multiple to a ~256px target) and 196 (14*14, the
    // closest clean multiple to a ~192px target) - DA V2's ViT backbone
    // requires input dims be multiples of 14, unlike MiDaS/YOLO's fully
    // convolutional architectures. The originally-deployed fp16 asset here
    // is GONE (2026-08-20) - it never actually loaded on this CPU path
    // ("input_type == kTfLiteFloat32 ... was not true" on every attempt),
    // so there's no working baseline being replaced, only a genuinely new
    // capability. dilateAndBlur is FALSE for both (2026-08-20, was TRUE) -
    // confirmed via direct visual comparison in the desktop test harness
    // that the old radius=6/blur=14 smoothing was destroying real fine
    // detail (individual ribbon folds, fabric texture) that's actually
    // present in DA V2's native output; the warp shader's own joint-
    // bilateral upsample (depth_upsample.gdshader) already does edge-aware
    // smoothing against the real color frame, same reasoning as MiDaS/YOLO26
    // below.
    private static final int DA_196_INPUT_SIZE = 196;
    private static final String MODEL_DA_196 = "depth-anything-v2-small-196.tflite";
    private static final int DA_252_INPUT_SIZE = 252;
    private static final String MODEL_DA_252 = "depth-anything-v2-small-252.tflite";
    // YOLO26-depth: Ultralytics' new monocular-depth export, verified via
    // direct TFLite Interpreter inspection (2026-08-18) - int8-quantized
    // BUT with float32 I/O tensors (the quantization is internal-only), so
    // unlike MiDaS these take/return plain 0..1 float32 like runInferenceDA.
    // Critically the input layout is NCHW (channel-planar: all R, then all
    // G, then all B), NOT NHWC (per-pixel interleaved) like MiDaS/DA - see
    // runInferenceYolo() for the resulting different buffer-fill algorithm.
    // Per-model, not shared - not the checkpoints' native/trained 768. Both were
    // re-exported at reduced resolution (2026-08-19) after confirming on-device
    // that 768 is far too slow to be usable on this platform (no NNAPI hardware
    // acceleration available to 3rd-party apps here - it's a pure CPU/XNNPACK
    // cost). Re-exported AGAIN (2026-08-20) using w8a32 (dynamic/weight-only
    // int8: int8 weights, float32 activations, no calibration data needed) -
    // the original static full-int8 exports (int8 weights AND activations,
    // calibrated on only 4 images) had a confirmed collapse bug (single
    // constant output) on at least one busy/high-texture photo and were
    // visibly blockier/more pixelated everywhere else; w8a32 fixes the
    // collapse and gives noticeably cleaner object boundaries, confirmed via
    // direct visual comparison in the desktop test harness. Still NCHW,
    // still float32 I/O - drop-in compatible with the exact same buffer-fill/
    // extraction code, no Java changes needed beyond the asset filenames.
    private static final int YOLO_N_256_INPUT_SIZE = 256;
    private static final int YOLO_N_320_INPUT_SIZE = 320;
    private static final int YOLO_N_384_INPUT_SIZE = 384;
    private static final String MODEL_YOLO_N_256 = "yolo26n-depth-256-w8a32.tflite";
    private static final String MODEL_YOLO_N_320 = "yolo26n-depth-320-w8a32.tflite";
    private static final String MODEL_YOLO_N_384 = "yolo26n-depth-384-w8a32.tflite";
    // Small's int8 quantization turned out fragile at 256 - real desktop-UI-
    // style low-texture content (large uniform regions: solid window
    // backgrounds, our own menu screenshot) triggered postProcess()'s
    // degenerate-input fallback (near-zero output variance -> a
    // uniform-color depth map) far more often than nano did at the same
    // resolution, even though both share the exact same architecture/stride
    // (verified via model.model.yaml - small only widens channels, same
    // downsampling stage count). 320 measurably reduces (not eliminates)
    // this - fixed 2 of 3 known-bad test images, still degenerate on the
    // worst (lowest-texture) one. Root cause is likely the export's weak
    // default int8 calibration set (depth8.yaml, only 4 images, flagged as
    // insufficient in the export log) rather than resolution per se -
    // revisit with a custom, more-representative calibration set if it's
    // ever worth reviving.
    // REMOVED FROM SELECTION (2026-08-19), not deleted - settings_controller.gd's
    // ai_3d_model_labels no longer has a YOLO26-S entry and build.sh no longer
    // bundles its asset, so model index 5 below is unreachable in practice
    // (loadInterpreter() soft-fails harmlessly on the missing asset file, same
    // pattern used for every other retired/dormant model here). Left in
    // place rather than ripped out in case the calibration fix above makes
    // it worth reviving.
    private static final int YOLO_S_INPUT_SIZE = 320;
    private static final String MODEL_YOLO_S = "yolo26s-depth-int8.tflite";

    // MiDaS v2.1-small re-exported for TFLite's GPU delegate (2026-08-19),
    // reproducing Gilleece/moonlight-android-xr's approach after confirming
    // NNAPI hardware acceleration isn't available on this platform. Genuinely
    // different from our int8 CPU MiDaS model in every way that matters here:
    // - NHWC layout (same per-pixel-interleaved fill as runInferenceDA/Midas,
    //   NOT the NCHW channel-planar fill YOLO26 needs). Plain float32 I/O
    //   (verified directly via ai-edge-litert's Interpreter) - NOT the
    //   literal fp16-I/O sibling export this originally shipped as. That
    //   fp16-I/O version failed on-device: "tensorflow/lite/kernels/conv.cc:
    //   361 input_type == kTfLiteFloat32 ... was not true, Node number 3
    //   (CONV_2D) failed to prepare" - the GPU delegate wasn't actually
    //   claiming those nodes (silently, no exception at delegate-creation
    //   time), so the un-delegated fp16-typed nodes fell through to a CPU
    //   builtin kernel that flatly rejects float16 tensors. This float32
    //   sibling (from the identical onnx2tf-lowered graph, same op
    //   composition) + GPU delegate's setPrecisionLossAllowed(true) below
    //   gets the same internal fp16-math GPU speedup without a literal
    //   fp16 I/O boundary to trip over - this is almost certainly what
    //   Gilleece/moonlight-android-xr's own "ship fp16" claim actually means
    //   (TFLite's standard weight-only fp16 quantization, which keeps
    //   float32 I/O), not the more aggressive full-fp16-tensor export
    //   onnx2tf's flatbuffer_direct backend defaults to alongside it.
    // - ImageNet mean/std normalization is baked into the graph itself (a
    //   SUB+MUL pair right after the input), unlike our other models - the
    //   Java boundary still just sends plain 0..1 pixel/255.0f, same as
    //   every other model here, no extra normalization step needed.
    // - Op composition (73 CONV_2D, 24 DEPTHWISE_CONV_2D, 5 RESIZE_BILINEAR,
    //   143 nodes total) matches Gilleece's reported clean graph exactly -
    //   converted via onnx2tf with -ofgd -kt input, NOT the naive TFLite
    //   export path (which decomposes every depthwise conv into ~17000
    //   per-channel convs, useless for the GPU delegate).
    // The GLES experiment exposes this as an Android-only option. Quest 3
    // The scheduled latest-frame worker below owns its 20Hz cadence so Godot
    // render-loop jitter cannot queue stale work or slow the inference clock.
    private static final String MODEL_MIDAS_GPU = "midas-v21-small-256-gpu.tflite";
    private static final int MIDAS_GPU_INPUT_SIZE = 256;
    // MiDaS-192-GPU (2026-08-24) - same onnx2tf -ofgd -kt input recipe as
    // the 256px model above, just re-run against the ONNX graph's input
    // resized to 192x192. MiDaS-small's Resize ops use relative scale
    // factors (not hardcoded absolute sizes), so the architecture is
    // resolution-agnostic - verified the resulting graph has the exact same
    // clean 73 CONV_2D/24 DEPTHWISE_CONV_2D/5 RESIZE_BILINEAR composition as
    // the 256px model, and confirmed non-degenerate real inference output,
    // before bundling. Same NHWC/float32-I/O/no-external-normalization
    // properties as MIDAS_GPU above - registered as a second GpuVariant
    // keyed to modelIndex 10 (MiDaS-192's CPU model index) rather than
    // duplicating runInferenceMidasGpu()/ensureMidasGpuLoaded()'s logic.
    private static final String MODEL_MIDAS_192_GPU = "midas-v21-small-192-gpu.tflite";
    private static final int MIDAS_192_GPU_INPUT_SIZE = 192;

    private Interpreter tfliteMidas;
    private Interpreter tfliteMidas192;
    private Interpreter tfliteDA196;
    private Interpreter tfliteDA252;
    private Interpreter tfliteYoloN256;
    private Interpreter tfliteYoloN320;
    private Interpreter tfliteYoloN384;
    private Interpreter tfliteYoloS;

    // Generic GPU-backed model slot (2026-08-24, replacing the original
    // single-model-hardcoded MiDaS-256-GPU-only fields) - one GpuVariant per
    // GPU-capable CPU model index, keyed in gpuVariants below. Each owns its
    // own Interpreter/GpuDelegate/buffers (a GpuDelegate binds to exactly
    // one Interpreter) and its own lazy-load/failure state, same semantics
    // as the original single-model fields just made per-model instead of
    // hardcoded to MiDaS-256. NHWC/float32-I/O fill (runInferenceGpu below)
    // is shared across all variants registered here - only valid for the
    // MiDaS-small architecture family; a future YOLO/DA-V2 GPU variant with
    // a different layout would need its own fill function, not a new field
    // on this class.
    private static final class GpuVariant {
        final String label;
        final String assetFile;
        final int inputSize;
        Interpreter interp;
        GpuDelegate delegate;
        ByteBuffer inputBuf;
        ByteBuffer outputBuf;
        boolean loadAttempted;
        boolean permanentlyUnavailable;
        String failureReason = "";

        GpuVariant(String label, String assetFile, int inputSize) {
            this.label = label;
            this.assetFile = assetFile;
            this.inputSize = inputSize;
        }
    }

    // Keyed by the CPU model index this GPU variant substitutes for (see
    // switchActiveModel()'s modelIndex mapping - 3=MiDaS-256, 10=MiDaS-192).
    private final java.util.Map<Integer, GpuVariant> gpuVariants = new java.util.HashMap<>();
    // The GPU variant currently in use, or null when running a CPU model -
    // orthogonal to activeModelIndex (which stays the real requested model
    // index either way, not a fake placeholder index).
    private volatile GpuVariant activeGpuVariant;
    private Interpreter activeInterpreter;
    private ByteBuffer inputBufferMidas;
    private ByteBuffer outputBufferMidas;
    private ByteBuffer inputBufferMidas192;
    private ByteBuffer outputBufferMidas192;
    private ByteBuffer inputBufferDA196;
    private ByteBuffer outputBufferDA196;
    private ByteBuffer inputBufferDA252;
    private ByteBuffer outputBufferDA252;
    private ByteBuffer inputBufferYoloN256;
    private ByteBuffer outputBufferYoloN256;
    private ByteBuffer inputBufferYoloN320;
    private ByteBuffer outputBufferYoloN320;
    private ByteBuffer inputBufferYoloN384;
    private ByteBuffer outputBufferYoloN384;
    private ByteBuffer inputBufferYoloS;
    private ByteBuffer outputBufferYoloS;
    private volatile boolean initialized = false;
    private volatile int activeModelIndex = 0;
    private volatile int requestedModelIndex = 3;
    private volatile int requestedBackend = BACKEND_AUTO;
    private volatile int effectiveBackend = BACKEND_CPU;
    private volatile String backendStatus = "";

    private static final class PendingFrame {
        final byte[] pixels;
        final int width;
        final int height;

        PendingFrame(byte[] pixels, int width, int height) {
            this.pixels = pixels;
            this.width = width;
            this.height = height;
        }
    }

    private final ScheduledExecutorService executor = Executors.newSingleThreadScheduledExecutor();
    private final AtomicBoolean isInferencing = new AtomicBoolean(false);
    private final AtomicBoolean gpuWorkerScheduled = new AtomicBoolean(false);
    private final AtomicReference<PendingFrame> latestGpuFrame = new AtomicReference<>();
    private final AtomicReference<byte[]> latestDepthMap = new AtomicReference<>();
    private final AtomicLong submittedFrames = new AtomicLong();
    private final AtomicLong droppedFrames = new AtomicLong();
    private long telemetryWindowStartNs;
    private long telemetryTotalDurationNs;
    private long telemetryTotalPrepareNs;
    private long telemetryTotalInvokeNs;
    private long telemetryTotalPostprocessNs;
    private int telemetryCompletedFrames;
    private long lastGpuPrepareNs;
    private long lastGpuInvokeNs;
    private long lastGpuPostprocessNs;
    private volatile long nextGpuInferenceNs;

    private float[] smoothedDepthFloat = null;

    private Context appContext;

    public synchronized boolean initialize(Context context) {
        if (initialized) return true;
        appContext = context.getApplicationContext();

        try {
            // midas-midas-v2-w8a8.tflite ("w8a8" = 8-bit weights AND
            // activations) takes a quantized UINT8 input tensor (raw
            // 0..255 pixel bytes, no normalization) - NOT float32. Sending
            // float32 here throws "Cannot copy to a TensorFlowLite tensor
            // (image) with 196608 bytes from a Java Buffer with 786432
            // bytes" (exactly 4x, the float32/uint8 ratio) on EVERY
            // inference call, deterministically - confirmed via full-session
            // log analysis (2026-08-18): 0 successes out of hundreds of
            // calls, regardless of what other models had run before. Caught
            // by submitFrame()'s try/catch, logged as "Async inference
            // failed" but easy to miss next to the similarly-worded per-call
            // "Inference: Xms" duration log that still prints from the
            // finally block regardless of success. Only affects this w8a8
            // model - the DA/YOLO buffers (genuinely different, float32
            // models) are untouched.
            inputBufferMidas = ByteBuffer.allocateDirect(1 * OUTPUT_SIZE * OUTPUT_SIZE * 3)
                    .order(ByteOrder.nativeOrder());
            // Output tensor ("depth_estimates") is ALSO quantized UINT8, not
            // float32 - see MIDAS_OUTPUT_SCALE/ZERO_POINT above. 1 byte/pixel,
            // not 4.
            outputBufferMidas = ByteBuffer.allocateDirect(1 * OUTPUT_SIZE * OUTPUT_SIZE * 1)
                    .order(ByteOrder.nativeOrder());

            inputBufferMidas192 = ByteBuffer.allocateDirect(1 * MIDAS_192_INPUT_SIZE * MIDAS_192_INPUT_SIZE * 3)
                    .order(ByteOrder.nativeOrder());
            outputBufferMidas192 = ByteBuffer.allocateDirect(1 * MIDAS_192_INPUT_SIZE * MIDAS_192_INPUT_SIZE * 1)
                    .order(ByteOrder.nativeOrder());

            inputBufferDA196 = ByteBuffer.allocateDirect(1 * DA_196_INPUT_SIZE * DA_196_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferDA196 = ByteBuffer.allocateDirect(1 * DA_196_INPUT_SIZE * DA_196_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());
            inputBufferDA252 = ByteBuffer.allocateDirect(1 * DA_252_INPUT_SIZE * DA_252_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferDA252 = ByteBuffer.allocateDirect(1 * DA_252_INPUT_SIZE * DA_252_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            inputBufferYoloN256 = ByteBuffer.allocateDirect(1 * YOLO_N_256_INPUT_SIZE * YOLO_N_256_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferYoloN256 = ByteBuffer.allocateDirect(1 * YOLO_N_256_INPUT_SIZE * YOLO_N_256_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());
            inputBufferYoloN320 = ByteBuffer.allocateDirect(1 * YOLO_N_320_INPUT_SIZE * YOLO_N_320_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferYoloN320 = ByteBuffer.allocateDirect(1 * YOLO_N_320_INPUT_SIZE * YOLO_N_320_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());
            inputBufferYoloN384 = ByteBuffer.allocateDirect(1 * YOLO_N_384_INPUT_SIZE * YOLO_N_384_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferYoloN384 = ByteBuffer.allocateDirect(1 * YOLO_N_384_INPUT_SIZE * YOLO_N_384_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());
            inputBufferYoloS = ByteBuffer.allocateDirect(1 * YOLO_S_INPUT_SIZE * YOLO_S_INPUT_SIZE * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            outputBufferYoloS = ByteBuffer.allocateDirect(1 * YOLO_S_INPUT_SIZE * YOLO_S_INPUT_SIZE * 1 * 4)
                    .order(ByteOrder.nativeOrder());

            tfliteMidas = loadInterpreter(MODEL_MIDAS);

            try {
                tfliteMidas192 = loadInterpreter(MODEL_MIDAS_192);
                Log.i(TAG, "MiDaS-192 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "MiDaS-192 model not available", e);
                tfliteMidas192 = null;
            }

            try {
                tfliteDA196 = loadInterpreter(MODEL_DA_196);
                Log.i(TAG, "Depth Anything V2-196 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "Depth Anything V2-196 model not available", e);
                tfliteDA196 = null;
            }

            try {
                tfliteDA252 = loadInterpreter(MODEL_DA_252);
                Log.i(TAG, "Depth Anything V2-252 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "Depth Anything V2-252 model not available", e);
                tfliteDA252 = null;
            }

            try {
                tfliteYoloN256 = loadInterpreter(MODEL_YOLO_N_256);
                Log.i(TAG, "YOLO26-depth nano-256 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "YOLO26-depth nano-256 model not available", e);
                tfliteYoloN256 = null;
            }

            try {
                tfliteYoloN320 = loadInterpreter(MODEL_YOLO_N_320);
                Log.i(TAG, "YOLO26-depth nano-320 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "YOLO26-depth nano-320 model not available", e);
                tfliteYoloN320 = null;
            }

            try {
                tfliteYoloN384 = loadInterpreter(MODEL_YOLO_N_384);
                Log.i(TAG, "YOLO26-depth nano-384 model loaded");
            } catch (Exception e) {
                Log.w(TAG, "YOLO26-depth nano-384 model not available", e);
                tfliteYoloN384 = null;
            }

            try {
                tfliteYoloS = loadInterpreter(MODEL_YOLO_S);
                Log.i(TAG, "YOLO26-depth small model loaded");
            } catch (Exception e) {
                Log.w(TAG, "YOLO26-depth small model not available", e);
                tfliteYoloS = null;
            }

            // GPU variants are lazy-loaded on first actual use (see
            // ensureGpuVariantLoaded()), not eagerly here - just registering
            // the slot/asset-filename/input-size, same as the original
            // single-model MiDaS-256-GPU deferred-load pattern.
            gpuVariants.put(3, new GpuVariant("MiDaS-256-GPU", MODEL_MIDAS_GPU, MIDAS_GPU_INPUT_SIZE));
            gpuVariants.put(10, new GpuVariant("MiDaS-192-GPU", MODEL_MIDAS_192_GPU, MIDAS_192_GPU_INPUT_SIZE));

            activeInterpreter = tfliteMidas;
            activeModelIndex = 3;
            initialized = true;
            Log.i(TAG, "Initialized successfully (MiDaS=" + (tfliteMidas != null) + ", MiDaS192=" + (tfliteMidas192 != null)
                    + ", DA196=" + (tfliteDA196 != null) + ", DA252=" + (tfliteDA252 != null)
                    + ", YoloN256=" + (tfliteYoloN256 != null) + ", YoloN320=" + (tfliteYoloN320 != null)
                    + ", YoloN384=" + (tfliteYoloN384 != null) + ", YoloS=" + (tfliteYoloS != null) + ")");
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Failed to initialize", e);
            return false;
        }
    }

    private Interpreter loadInterpreter(String modelFile) throws IOException {
        MappedByteBuffer buffer = loadModelFile(modelFile);
        try {
            Interpreter.Options opts = new Interpreter.Options();
            opts.setUseNNAPI(true);
            opts.setNumThreads(4);
            Interpreter interp = new Interpreter(buffer, opts);
            Log.i(TAG, modelFile + " loaded with NNAPI");
            return interp;
        } catch (Exception e) {
            Log.w(TAG, "NNAPI failed for " + modelFile + ", falling back to CPU", e);
            Interpreter.Options opts = new Interpreter.Options();
            opts.setNumThreads(4);
            return new Interpreter(buffer, opts);
        }
    }

    public void setActiveModel(int modelIndex) {
        configureDepth(modelIndex, BACKEND_CPU);
    }

    public int getBackendCapabilities(int modelIndex) {
        int capabilities = BACKEND_CAP_CPU;
        GpuVariant v = gpuVariants.get(modelIndex);
        if (v != null && !v.permanentlyUnavailable) {
            capabilities |= BACKEND_CAP_GPU;
        }
        return capabilities;
    }

    public int getEffectiveBackend() {
        return effectiveBackend;
    }

    public String getBackendStatus() {
        return backendStatus;
    }

    public synchronized void configureDepth(int modelIndex, int backend) {
        if (!initialized) return;
        requestedModelIndex = modelIndex;
        requestedBackend = backend >= BACKEND_AUTO && backend <= BACKEND_GPU ? backend : BACKEND_AUTO;

        boolean gpuSupported = (getBackendCapabilities(modelIndex) & BACKEND_CAP_GPU) != 0;
        boolean useGpu = requestedBackend != BACKEND_CPU && gpuSupported;
        effectiveBackend = useGpu ? BACKEND_GPU : BACKEND_CPU;
        GpuVariant requestedVariant = gpuVariants.get(modelIndex);
        if (requestedBackend == BACKEND_GPU && !gpuSupported) {
            backendStatus = requestedVariant != null && requestedVariant.permanentlyUnavailable && !requestedVariant.failureReason.isEmpty()
                    ? requestedVariant.failureReason
                    : "GPU depth is unavailable for this model; using CPU";
        } else {
            backendStatus = "";
        }

        switchActiveModel(modelIndex, useGpu);
        Log.i(TAG, "Depth configured: model=" + modelNameFor(modelIndex)
                + " requested=" + backendName(requestedBackend)
                + " effective=" + backendName(effectiveBackend)
                + (backendStatus.isEmpty() ? "" : " status=" + backendStatus));
    }

    private static String backendName(int backend) {
        switch (backend) {
            case BACKEND_GPU: return "GPU";
            case BACKEND_CPU: return "CPU";
            default: return "Auto";
        }
    }

    // Pure lookup, no side effects - shared by switchActiveModel() and the
    // GPU-failure fallback in runScheduledGpuInference() (which can't call
    // switchActiveModel() directly - it busy-waits on isInferencing, which
    // is already held by the very inference worker that would be calling it,
    // a guaranteed deadlock). normalizeModelIndex() mirrors the same
    // "unrecognized index folds into MiDaS-256" rule.
    private Interpreter cpuInterpreterFor(int modelIndex) {
        if (modelIndex == 1 && tfliteDA252 != null) return tfliteDA252;
        if (modelIndex == 4 && tfliteYoloN384 != null) return tfliteYoloN384;
        if (modelIndex == 5 && tfliteYoloS != null) return tfliteYoloS;
        if (modelIndex == 7 && tfliteYoloN256 != null) return tfliteYoloN256;
        if (modelIndex == 8 && tfliteYoloN320 != null) return tfliteYoloN320;
        if (modelIndex == 10 && tfliteMidas192 != null) return tfliteMidas192;
        if (modelIndex == 11 && tfliteDA196 != null) return tfliteDA196;
        return tfliteMidas;
    }

    private static int normalizeModelIndex(int modelIndex) {
        switch (modelIndex) {
            case 1: case 4: case 5: case 7: case 8: case 10: case 11:
                return modelIndex;
            default:
                // MiDaS-Std and MiDaS-Fast (see settings_controller.gd) share
                // one interpreter - the separate "crude warp" MiDaS instance
                // that used to live at index 0 is gone, so fold any other/
                // unrecognized index into this one too rather than requiring
                // index 3 exactly.
                return 3;
        }
    }

    private void switchActiveModel(int modelIndex, boolean useGpu) {
        if (!initialized) return;
        modelIndex = normalizeModelIndex(modelIndex);
        Interpreter target = cpuInterpreterFor(modelIndex);
        // The requested GPU variant (if any) - lazy-loaded on first actual
        // inference (see ensureGpuVariantLoaded()), not here, so v.interp is
        // legitimately still null the first time this switch happens.
        // activeInterpreter (the CPU target resolved above) only exists to
        // satisfy submitFrame()'s "is anything loaded at all" check in that
        // case, not to select which inference method runs - that's driven by
        // activeGpuVariant being non-null, checked in submitFrame() below.
        GpuVariant variant = useGpu ? gpuVariants.get(modelIndex) : null;
        if (activeModelIndex != modelIndex || activeGpuVariant != variant) {
            while (isInferencing.get()) {
                Thread.yield();
            }
            latestGpuFrame.set(null);
            nextGpuInferenceNs = 0;
            smoothedDepthFloat = null;
            rangeValid = false;
            lastPostProcessTimeNs = 0;
            activeInterpreter = target;
            activeModelIndex = modelIndex;
            activeGpuVariant = variant;
            String modelName = modelNameFor(modelIndex) + (variant != null ? " (GPU)" : "");
            Log.i(TAG, "Switched to model " + modelName);
        }
    }

    private static String modelNameFor(int modelIndex) {
        switch (modelIndex) {
            case 1: return "Depth Anything V2-252";
            case 4: return "YOLO26-Depth-N-384";
            case 5: return "YOLO26-Depth-S";
            case 7: return "YOLO26-Depth-N-256";
            case 8: return "YOLO26-Depth-N-320";
            case 10: return "MiDaS-192";
            case 11: return "Depth Anything V2-196";
            default: return "MiDaS-256";
        }
    }

    public int getActiveModel() {
        return activeModelIndex;
    }

    public void submitFrame(byte[] rgbaPixels, int width, int height) {
        if (!initialized || activeInterpreter == null) return;
        if (rgbaPixels == null || rgbaPixels.length < width * height * 4) return;
        final int modelIdx = activeModelIndex;
        final GpuVariant gpuVariant = activeGpuVariant;
        if (gpuVariant != null) {
            PendingFrame previous = latestGpuFrame.getAndSet(new PendingFrame(rgbaPixels, width, height));
            if (previous != null) {
                droppedFrames.incrementAndGet();
            }
            scheduleGpuInference(gpuVariant);
            return;
        }
        if (!isInferencing.compareAndSet(false, true)) {
            droppedFrames.incrementAndGet();
            return;
        }

        submittedFrames.incrementAndGet();
        final byte[] frameCopy = rgbaPixels;
        executor.submit(() -> {
            long startTime = System.nanoTime();
            try {
                byte[] result = runCpuInference(modelIdx, frameCopy, width, height);
                if (result != null) {
                    latestDepthMap.set(result);
                }
            } catch (Exception e) {
                Log.e(TAG, "Async inference failed", e);
            } finally {
                isInferencing.set(false);
                long durationNs = System.nanoTime() - startTime;
                recordTelemetry(modelIdx, false, durationNs);
            }
        });
    }

    // Extracted (2026-08-24) so the GPU-failure fallback path in
    // runScheduledGpuInference() can dispatch to the right CPU model
    // generically instead of hardcoding tfliteMidas - MUST only be called
    // from the single-thread executor (same constraint as before extraction).
    private byte[] runCpuInference(int modelIdx, byte[] frameCopy, int width, int height) {
        if (modelIdx == 1) {
            return runInferenceDA(tfliteDA252, inputBufferDA252, outputBufferDA252, DA_252_INPUT_SIZE, frameCopy, width, height);
        } else if (modelIdx == 4) {
            return runInferenceYolo(tfliteYoloN384, inputBufferYoloN384, outputBufferYoloN384, YOLO_N_384_INPUT_SIZE, frameCopy, width, height);
        } else if (modelIdx == 5) {
            return runInferenceYolo(tfliteYoloS, inputBufferYoloS, outputBufferYoloS, YOLO_S_INPUT_SIZE, frameCopy, width, height);
        } else if (modelIdx == 7) {
            return runInferenceYolo(tfliteYoloN256, inputBufferYoloN256, outputBufferYoloN256, YOLO_N_256_INPUT_SIZE, frameCopy, width, height);
        } else if (modelIdx == 8) {
            return runInferenceYolo(tfliteYoloN320, inputBufferYoloN320, outputBufferYoloN320, YOLO_N_320_INPUT_SIZE, frameCopy, width, height);
        } else if (modelIdx == 10) {
            return runInferenceMidas(tfliteMidas192, inputBufferMidas192, outputBufferMidas192, MIDAS_192_INPUT_SIZE,
                    MIDAS_192_INPUT_SCALE, MIDAS_192_INPUT_ZERO_POINT, MIDAS_192_OUTPUT_SCALE, MIDAS_192_OUTPUT_ZERO_POINT,
                    frameCopy, width, height);
        } else if (modelIdx == 11) {
            return runInferenceDA(tfliteDA196, inputBufferDA196, outputBufferDA196, DA_196_INPUT_SIZE, frameCopy, width, height);
        } else {
            return runInferenceMidas(tfliteMidas, inputBufferMidas, outputBufferMidas, OUTPUT_SIZE,
                    MIDAS_INPUT_SCALE, MIDAS_INPUT_ZERO_POINT, MIDAS_OUTPUT_SCALE, MIDAS_OUTPUT_ZERO_POINT,
                    frameCopy, width, height);
        }
    }

    private void scheduleGpuInference(GpuVariant variant) {
        if (!initialized || activeGpuVariant != variant || !gpuWorkerScheduled.compareAndSet(false, true)) {
            return;
        }
        long delayNs = Math.max(0L, nextGpuInferenceNs - System.nanoTime());
        executor.schedule(() -> runScheduledGpuInference(variant), delayNs, TimeUnit.NANOSECONDS);
    }

    private void runScheduledGpuInference(GpuVariant variant) {
        long startNs = System.nanoTime();
        long scheduledNs = nextGpuInferenceNs;
        nextGpuInferenceNs = scheduledNs <= 0 || startNs - scheduledNs >= GPU_INFERENCE_INTERVAL_NS
                ? startNs + GPU_INFERENCE_INTERVAL_NS
                : scheduledNs + GPU_INFERENCE_INTERVAL_NS;
        gpuWorkerScheduled.set(false);

        if (!initialized || activeGpuVariant != variant) {
            latestGpuFrame.set(null);
            nextGpuInferenceNs = 0;
            return;
        }

        PendingFrame frame = latestGpuFrame.getAndSet(null);
        if (frame == null) {
            return;
        }

        int fallbackModelIndex = activeModelIndex;
        isInferencing.set(true);
        submittedFrames.incrementAndGet();
        try {
            ensureGpuVariantLoaded(variant);
            byte[] result;
            if (variant.interp != null) {
                result = runInferenceGpu(variant, frame.pixels, frame.width, frame.height);
            } else {
                // GPU delegate/model failed to load - fall back to this
                // variant's CPU counterpart for the rest of this session (no
                // per-frame retry). Set fallback state inline rather than via
                // a separate helper - this IS the single-threaded inference
                // worker itself, so there's no other in-flight inference to
                // wait for; the surrounding try/finally already owns
                // isInferencing.
                String reason = variant.failureReason.isEmpty()
                        ? "GPU delegate initialization failed"
                        : variant.failureReason;
                variant.permanentlyUnavailable = true;
                variant.failureReason = reason;
                effectiveBackend = BACKEND_CPU;
                backendStatus = reason;
                activeGpuVariant = null;
                activeInterpreter = cpuInterpreterFor(fallbackModelIndex);
                smoothedDepthFloat = null;
                rangeValid = false;
                lastPostProcessTimeNs = 0;
                Log.w(TAG, reason + "; CPU depth will continue without retrying GPU this session");
                result = runCpuInference(fallbackModelIndex, frame.pixels, frame.width, frame.height);
            }
            if (result != null) {
                latestDepthMap.set(result);
            }
        } catch (Exception e) {
            Log.e(TAG, "Async GPU inference failed", e);
        } finally {
            isInferencing.set(false);
            recordTelemetry(fallbackModelIndex, true, System.nanoTime() - startNs);
        }

        if (latestGpuFrame.get() != null && activeGpuVariant == variant) {
            scheduleGpuInference(variant);
        }
    }

    private void recordTelemetry(int modelIndex, boolean isGpu, long durationNs) {
        long nowNs = System.nanoTime();
        if (telemetryWindowStartNs == 0 || !isGpu) {
            telemetryWindowStartNs = nowNs;
            telemetryTotalDurationNs = 0;
            telemetryTotalPrepareNs = 0;
            telemetryTotalInvokeNs = 0;
            telemetryTotalPostprocessNs = 0;
            telemetryCompletedFrames = 0;
        }
        telemetryTotalDurationNs += durationNs;
        telemetryTotalPrepareNs += lastGpuPrepareNs;
        telemetryTotalInvokeNs += lastGpuInvokeNs;
        telemetryTotalPostprocessNs += lastGpuPostprocessNs;
        telemetryCompletedFrames++;
        long elapsedNs = nowNs - telemetryWindowStartNs;
        if (elapsedNs < 1_000_000_000L) return;

        float divisor = Math.max(telemetryCompletedFrames, 1);
        Log.i(TAG, String.format(java.util.Locale.US,
                "Perf: model=%s total=%.1fms prepare=%.1fms invoke=%.1fms post=%.1fms completed=%.1fHz submitted=%d dropped=%d",
                modelNameFor(modelIndex) + "-GPU", telemetryTotalDurationNs / divisor / 1_000_000.0f,
                telemetryTotalPrepareNs / divisor / 1_000_000.0f,
                telemetryTotalInvokeNs / divisor / 1_000_000.0f,
                telemetryTotalPostprocessNs / divisor / 1_000_000.0f,
                telemetryCompletedFrames * 1_000_000_000.0f / elapsedNs,
                submittedFrames.getAndSet(0), droppedFrames.getAndSet(0)));
        telemetryWindowStartNs = nowNs;
        telemetryTotalDurationNs = 0;
        telemetryTotalPrepareNs = 0;
        telemetryTotalInvokeNs = 0;
        telemetryTotalPostprocessNs = 0;
        telemetryCompletedFrames = 0;
    }

    public byte[] getLatestDepth() {
        return latestDepthMap.getAndSet(null);
    }

    // real (0..1 normalized pixel) -> quantized uint8, given a specific
    // model's own scale/zero_point - MiDaS-256 and MiDaS-192 are calibrated
    // independently and do NOT share these (confirmed via direct tensor
    // inspection: 192's input zero_point is 0, 256's is 24), so this can no
    // longer hardcode one model's constants.
    private static byte quantizeMidasInput(int rawPixelByte, float scale, int zeroPoint) {
        float real = (rawPixelByte & 0xFF) / 255.0f;
        int q = Math.round(real / scale) + zeroPoint;
        q = Math.max(0, Math.min(255, q));
        return (byte) q;
    }

    // size read as a param (not a shared constant) since DA-196 and DA-252
    // are genuinely different native resolutions (ViT patch-size-14
    // constraint - see MODEL_DA_196/252 comment). dilateAndBlur is FALSE for
    // both (2026-08-20, was TRUE/hardcoded) - see that comment for why.
    private byte[] runInferenceDA(Interpreter interp, ByteBuffer inputBuf, ByteBuffer outputBuf, int size, byte[] rgbaPixels, int width, int height) {
        inputBuf.rewind();
        outputBuf.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / size;
        float scaleY = (float) height / size;

        for (int y = 0; y < size; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < size; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                inputBuf.putFloat((rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                inputBuf.putFloat((rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                inputBuf.putFloat((rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        inputBuf.rewind();

        interp.run(inputBuf, outputBuf);
        outputBuf.rewind();

        return postProcess(extractFloatOutput(outputBuf, size * size), size, false);
    }

    // YOLO26-depth's exported TFLite input tensor is NCHW (channel-planar:
    // every R value, then every G value, then every B value) rather than the
    // NHWC (per-pixel interleaved R,G,B) layout MiDaS/DA use - verified
    // directly against the exported model's input tensor shape, not assumed.
    // That means the usual sequential relative put()/putFloat() fill (which
    // writes one pixel's R,G,B consecutively) is wrong here: each channel
    // has to land in its own contiguous plane. Absolute-position putFloat(
    // index, value) writes let us fill all three planes in a single pass
    // over the source image instead of doing three separate passes.
    // Normalization is plain 0..1 (Ultralytics' standard convention), no
    // ImageNet mean/std - the model's own int8 quantization is internal to
    // the graph, invisible at this float32 I/O boundary.
    private byte[] runInferenceYolo(Interpreter interp, ByteBuffer inputBuf, ByteBuffer outputBuf, int size, byte[] rgbaPixels, int width, int height) {
        inputBuf.rewind();
        outputBuf.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / size;
        float scaleY = (float) height / size;
        int planeElems = size * size;

        for (int y = 0; y < size; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            int rowBase = y * size;
            for (int x = 0; x < size; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                int planeIdx = rowBase + x;
                inputBuf.putFloat(planeIdx * 4, (rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                inputBuf.putFloat((planeElems + planeIdx) * 4, (rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                inputBuf.putFloat((planeElems * 2 + planeIdx) * 4, (rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        inputBuf.rewind();

        interp.run(inputBuf, outputBuf);
        outputBuf.rewind();

        // YOLO26-depth outputs regular/metric-style depth (larger value =
        // FARTHER) - the OPPOSITE convention from MiDaS/DA's inverse-depth
        // (larger value = NEARER). Confirmed via direct visual comparison
        // against MiDaS on real photos with clear foreground/background
        // structure (2026-08-19, both int8 and fp32 exports): YOLO's raw
        // output consistently had background surfaces reading as "near" and
        // foreground subjects reading as "far" - this, not model capacity,
        // is what was making the depth look "blended"/wrong on-device, since
        // postProcess()'s downstream pipeline (robustRange/normalize, the
        // heatmap's red=near/blue=far convention, and critically the warp
        // shader's parallax offset direction) all assume the MiDaS
        // convention throughout. Negating here - the one place that needs to
        // know about this per-model difference - keeps postProcess() itself
        // fully model-agnostic, matching every other model's call site.
        float[] raw = extractFloatOutput(outputBuf, planeElems);
        for (int i = 0; i < raw.length; i++) {
            raw[i] = -raw[i];
        }

        // No dilate/blur - same reasoning as MiDaS below (shader's joint-bilateral
        // upsample already handles edges better than a CPU blur would).
        return postProcess(raw, size, false, YOLO_PERCENTILE_CLIP);
    }

    // No dilate/blur here - the warp shader does its own edge-aware joint
    // bilateral upsample against the actual color frame
    // (depth_upsample.gdshader), which snaps depth to real edges instead of
    // averaging small objects (taskbar icons, widgets) away like a CPU blur
    // would. Takes its own scale/zero_point pair (2026-08-20) rather than
    // the module-level MIDAS_*_SCALE/ZERO_POINT constants directly - MiDaS-
    // 192 is independently calibrated from MiDaS-256 and would silently
    // produce garbage output if run through the other model's params (see
    // quantizeMidasInput()'s comment - this is the exact failure mode that
    // already burned this project once).
    private byte[] runInferenceMidas(Interpreter interp, ByteBuffer inputBuf, ByteBuffer outputBuf, int size,
                                       float inScale, int inZeroPoint, float outScale, int outZeroPoint,
                                       byte[] rgbaPixels, int width, int height) {
        inputBuf.rewind();
        outputBuf.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / size;
        float scaleY = (float) height / size;

        for (int y = 0; y < size; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < size; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                inputBuf.put(quantizeMidasInput(rgbaPixels[srcIdx], inScale, inZeroPoint));
                inputBuf.put(quantizeMidasInput(rgbaPixels[srcIdx + 1], inScale, inZeroPoint));
                inputBuf.put(quantizeMidasInput(rgbaPixels[srcIdx + 2], inScale, inZeroPoint));
            }
        }
        inputBuf.rewind();

        interp.run(inputBuf, outputBuf);
        outputBuf.rewind();

        return postProcess(dequantizeMidasOutput(outputBuf, size * size, outScale, outZeroPoint), size, false);
    }

    // Only ever called from the GPU inference worker (runScheduledGpuInference(),
    // itself only ever scheduled onto the single-thread executor) - MUST run
    // on that same thread, not eagerly in initialize() like every CPU model,
    // because the GPU delegate binds to whichever thread creates it and
    // every future interp.run() call has to happen on that same thread (see
    // MODEL_MIDAS_GPU's comment above). Loading it eagerly in initialize()
    // (which runs on the app's main/UI thread) would create the delegate on
    // the wrong thread entirely. Generalized (2026-08-24) from the original
    // MiDaS-256-GPU-only ensureMidasGpuLoaded() - each GpuVariant loads/fails
    // independently, so one model's GPU delegate failing doesn't affect
    // another's.
    private void ensureGpuVariantLoaded(GpuVariant v) {
        if (v.loadAttempted) return;
        v.loadAttempted = true;
        try {
            v.inputBuf = ByteBuffer.allocateDirect(1 * v.inputSize * v.inputSize * 3 * 4)
                    .order(ByteOrder.nativeOrder());
            v.outputBuf = ByteBuffer.allocateDirect(1 * v.inputSize * v.inputSize * 1 * 4)
                    .order(ByteOrder.nativeOrder());
            MappedByteBuffer buffer = loadModelFile(v.assetFile);
            GpuDelegateFactory.Options gpuOptions = new GpuDelegateFactory.Options();
            // Matches Gilleece/moonlight-android-xr's own config - the model
            // is fp16, so allowing precision loss just means "run at the
            // model's own native precision" rather than upcasting to fp32.
            gpuOptions.setPrecisionLossAllowed(true);
            gpuOptions.setInferencePreference(GpuDelegateFactory.Options.INFERENCE_PREFERENCE_SUSTAINED_SPEED);
            // The bundled Nightfall LiteRT GPU JNI creates its Qualcomm OpenCL
            // context with CL_PRIORITY_HINT_LOW_QCOM. OpenCL is substantially
            // faster than LiteRT's OpenGL backend on Quest, while the context
            // priority keeps render work ahead of inference dispatches.
            gpuOptions.setForceBackend(GpuDelegateFactory.Options.GpuBackend.OPENCL);
            v.delegate = new GpuDelegate(gpuOptions);
            Interpreter.Options opts = new Interpreter.Options();
            opts.addDelegate(v.delegate);
            v.interp = new Interpreter(buffer, opts);
            Log.i(TAG, v.label + " model loaded with GPU delegate");
        } catch (Exception e) {
            Log.w(TAG, v.label + " model/GPU delegate not available", e);
            v.failureReason = "GPU delegate initialization failed: " + e.getClass().getSimpleName();
            v.interp = null;
            if (v.delegate != null) {
                v.delegate.close();
                v.delegate = null;
            }
        }
    }

    // NHWC (per-pixel interleaved, same fill order as runInferenceDA/Midas -
    // NOT the NCHW channel-planar fill YOLO26 needs) and plain float32 I/O,
    // verified directly against the exported model (see MODEL_MIDAS_GPU
    // comment for why this is float32, not fp16, despite running through the
    // GPU delegate). No external ImageNet normalization here - it's baked
    // into the graph itself, so this sends the exact same plain 0..1
    // pixel/255.0f every other model here uses. Only valid for the
    // MiDaS-small architecture family (both variants registered today share
    // this) - a future YOLO/DA-V2 GPU variant would need its own fill
    // function (NCHW layout, or a ViT patch-size constraint) rather than
    // reusing this one.
    private byte[] runInferenceGpu(GpuVariant v, byte[] rgbaPixels, int width, int height) {
        lastGpuPrepareNs = 0;
        lastGpuInvokeNs = 0;
        lastGpuPostprocessNs = 0;
        if (v.interp == null) return null;
        long prepareStartNs = System.nanoTime();
        v.inputBuf.rewind();
        v.outputBuf.rewind();

        int srcRowBytes = width * 4;
        float scaleX = (float) width / v.inputSize;
        float scaleY = (float) height / v.inputSize;

        for (int y = 0; y < v.inputSize; y++) {
            int srcY = Math.min((int) (y * scaleY), height - 1);
            int srcRowOff = srcY * srcRowBytes;
            for (int x = 0; x < v.inputSize; x++) {
                int srcX = Math.min((int) (x * scaleX), width - 1);
                int srcIdx = srcRowOff + srcX * 4;
                v.inputBuf.putFloat((rgbaPixels[srcIdx] & 0xFF) / 255.0f);
                v.inputBuf.putFloat((rgbaPixels[srcIdx + 1] & 0xFF) / 255.0f);
                v.inputBuf.putFloat((rgbaPixels[srcIdx + 2] & 0xFF) / 255.0f);
            }
        }
        v.inputBuf.rewind();
        lastGpuPrepareNs = System.nanoTime() - prepareStartNs;

        long invokeStartNs = System.nanoTime();
        v.interp.run(v.inputBuf, v.outputBuf);
        lastGpuInvokeNs = System.nanoTime() - invokeStartNs;
        v.outputBuf.rewind();

        long postprocessStartNs = System.nanoTime();
        byte[] result = postProcess(extractFloatOutput(v.outputBuf, v.inputSize * v.inputSize), v.inputSize, false);
        lastGpuPostprocessNs = System.nanoTime() - postprocessStartNs;
        return result;
    }

    // dequantize (quantized - zero_point) * scale, given a specific model's
    // own scale/zero_point (see runInferenceMidas()'s comment for why this
    // can't be a shared constant anymore).
    private static float[] dequantizeMidasOutput(ByteBuffer output, int count, float scale, int zeroPoint) {
        output.rewind();
        float[] raw = new float[count];
        for (int i = 0; i < count; i++) {
            int q = output.get(i) & 0xFF;
            raw[i] = (q - zeroPoint) * scale;
        }
        return raw;
    }

    // Plain float32 output tensor extraction, for models that genuinely are
    // float32 (runInferenceDA) - not quantized like the w8a8 MiDaS model.
    private static float[] extractFloatOutput(ByteBuffer output, int count) {
        output.rewind();
        FloatBuffer floatOut = output.asFloatBuffer();
        float[] raw = new float[count];
        for (int i = 0; i < count; i++) {
            raw[i] = floatOut.get(i);
        }
        return raw;
    }

    // Ported from Gilleece/moonlight-android-xr's xr_renderer.c
    // nativeUploadDepth()/robustRange(): literal per-frame min/max lets a
    // single stray pixel own the whole mapping - on one of their measured
    // frames the 2nd..98th percentile span was only 638 of an 805-wide
    // min/max range, meaning a fifth of the usable 0..1 depth range was
    // being spent on a handful of outlier pixels instead of the actual
    // scene. Our old code did exactly that (literal min/max), and did it
    // TWICE (once on the raw model output, again on the already-smoothed
    // result), compounding the loss - this was very likely the dominant
    // cause of the depth effect measuring "shallow" even after the warp
    // itself got fixed, more so than the parallax constant.
    private static final int HIST_BINS = 512;
    private static final float DEFAULT_PERCENTILE_CLIP = 0.02f;
    // YOLO26-N only (2026-08-19) - see postProcess()'s percentileClip param
    // comment. Starting point for the "tighter clip -> more contrast"
    // experiment; tune further based on how it looks on-device.
    private static final float YOLO_PERCENTILE_CLIP = 0.10f;
    // How fast the normalization RANGE itself (smoothLo/smoothHi) and the
    // final per-texel depth values (in temporalSmooth) track new inferences -
    // expressed as TIME CONSTANTS (seconds), not fixed per-call blend
    // factors like the old RANGE_ALPHA/DEPTH_ALPHA this replaces (2026-08-19).
    // A fixed per-call alpha means the REAL-TIME smoothing strength scales
    // with how often postProcess() actually gets called - and that call
    // rate now genuinely differs per model (confirmed on-device: MiDaS
    // ~6.9Hz achieved vs YOLO26-N ~10Hz, both gated by their own inference
    // time via submitFrame()'s isInferencing lock, regardless of the shared
    // 20Hz submit_interval target). At the SAME fixed alpha, YOLO26-N's
    // faster real cadence made it re-converge toward each new (noisy)
    // estimate faster in wall-clock terms than MiDaS - visibly grainier/
    // less smooth despite using identical constants, not because the model
    // itself is noisier. Converting to alpha_eff = 1 - exp(-dt/tau) (dt =
    // actual elapsed time since the last call, not the nominal interval)
    // makes the REAL-TIME convergence rate the same regardless of call
    // frequency: a model calling more often blends by a smaller amount
    // more often, netting out to the same overall smoothing per second as
    // a model calling less often with a larger per-call blend - instead of
    // just applying a stronger blend more often.
    // Tau values are derived from the OLD alpha constants evaluated at
    // MiDaS's own typical achieved interval (~145ms, ~6.9Hz) specifically so
    // MiDaS's current, confirmed-good "nicely defined and smooth" feel is
    // preserved almost exactly at its own cadence (alpha_eff varies slightly
    // with MiDaS's natural per-frame timing jitter now instead of being
    // pinned at a single value, which is more correct, not a regression):
    // tau = dt_ref / -ln(1 - alpha) -> RANGE: 0.145 / -ln(0.85) ~= 0.89,
    // DEPTH: 0.145 / -ln(0.40) ~= 0.158.
    private static final float RANGE_TAU_SECONDS = 0.89f;
    private static final float DEPTH_TAU_SECONDS = 0.158f;
    private float smoothLo = 0.0f;
    private float smoothHi = 1.0f;
    private boolean rangeValid = false;
    // 0 (not System.nanoTime(), which can legitimately be 0 or negative on
    // some clocks) means "no previous call yet" - reset alongside
    // smoothedDepthFloat/rangeValid in setActiveModel() on a model switch so
    // the dt clock doesn't measure time since a DIFFERENT model's last call.
    private long lastPostProcessTimeNs = 0;

    // Takes the already-decoded real-valued depth array, not a raw
    // ByteBuffer - the float32 output tensor (runInferenceDA) and the
    // quantized UINT8 one (runInferenceMidas) decode completely differently
    // at the source (see each call site), and this logic downstream is
    // identical either way once it's a plain float[].
    private byte[] postProcess(float[] raw, int size, boolean dilateAndBlur) {
        return postProcess(raw, size, dilateAndBlur, DEFAULT_PERCENTILE_CLIP);
    }

    // percentileClip: how much of the raw output's histogram tails to trim
    // before stretching the rest to fill 0..1 - see robustRange(). Exposed
    // per-call (2026-08-19) for YOLO26-N specifically: its raw foreground/
    // background separation looked visibly "blended" next to MiDaS's at the
    // same 2%/98% default, plausibly because a smaller network + int8
    // quantization leaves less real dynamic range to work with, so the
    // default trim doesn't concentrate the stretch onto the scene's actual
    // structure as effectively. A tighter clip forces more of the 0..1 range
    // onto whatever real separation the model DOES have, at the cost of
    // clipping more of the tails (already-somewhat-arbitrary content anyway,
    // per robustRange()'s own reasoning below). Cheap - just changes two
    // threshold constants passed into an existing histogram scan, no
    // measurable added compute, and doesn't touch MiDaS/DA's own call sites.
    private byte[] postProcess(float[] raw, int size, boolean dilateAndBlur, float percentileClip) {
        int count = size * size;

        long now = System.nanoTime();
        // Clamped to [1/60, 1.0]s - the lower bound guards against a
        // near-zero/degenerate dt inflating alpha_eff toward 1 (an
        // effectively unsmoothed passthrough) if postProcess() were ever
        // somehow called twice in the same instant; the upper bound caps
        // the opposite case (a long stall making the very next update jump
        // by an enormous, saturated alpha instead of just converging fully,
        // which happens anyway once dt exceeds a few tau's worth of time).
        float dt = lastPostProcessTimeNs == 0 ? DEPTH_TAU_SECONDS
                : Math.max(1f / 60f, Math.min((now - lastPostProcessTimeNs) / 1_000_000_000f, 1.0f));
        lastPostProcessTimeNs = now;

        float[] loHi = robustRange(raw, count, percentileClip);
        if (!rangeValid) {
            smoothLo = loHi[0];
            smoothHi = loHi[1];
            rangeValid = true;
        } else {
            float rangeAlpha = 1f - (float) Math.exp(-dt / RANGE_TAU_SECONDS);
            smoothLo += rangeAlpha * (loHi[0] - smoothLo);
            smoothHi += rangeAlpha * (loHi[1] - smoothHi);
        }
        float scale = 1.0f / Math.max(smoothHi - smoothLo, 1e-6f);

        float[] normalized = new float[count];
        for (int i = 0; i < count; i++) {
            float v = (raw[i] - smoothLo) * scale;
            normalized[i] = Math.max(0.0f, Math.min(1.0f, v));
        }

        float[] preSmooth = normalized;
        if (dilateAndBlur) {
            float[] dilated = dilate(normalized, size, 6);
            preSmooth = separableBoxBlur(dilated, size, 14);
        }
        float[] smoothed = temporalSmooth(preSmooth, size, dt);

        byte[] depthBytes = new byte[count];
        for (int i = 0; i < count; i++) {
            float v = Math.max(0.0f, Math.min(1.0f, smoothed[i]));
            depthBytes[i] = (byte) (v * 255.0f);
        }
        return depthBytes;
    }

    // percentileClip/(1-percentileClip) percentile of the model output (e.g.
    // 0.02 -> 2nd/98th), via a histogram - see the postProcess() comment
    // above for why this replaces literal min/max, and postProcess()'s
    // percentileClip param comment for why this is tunable per call now.
    private float[] robustRange(float[] v, int count, float percentileClip) {
        float lo = v[0], hi = v[0];
        for (int i = 1; i < count; i++) {
            if (v[i] < lo) lo = v[i];
            if (v[i] > hi) hi = v[i];
        }
        if (hi <= lo) {
            return new float[]{lo, lo + 1.0f};
        }

        int[] hist = new int[HIST_BINS];
        float binScale = HIST_BINS / (hi - lo);
        for (int i = 0; i < count; i++) {
            int b = (int) ((v[i] - lo) * binScale);
            if (b < 0) b = 0;
            if (b >= HIST_BINS) b = HIST_BINS - 1;
            hist[b]++;
        }

        int loTarget = (int) (count * percentileClip);
        int hiTarget = (int) (count * (1.0f - percentileClip));
        int acc = 0;
        int loBin = 0, hiBin = HIST_BINS - 1;
        for (int b = 0; b < HIST_BINS; b++) {
            acc += hist[b];
            if (acc >= loTarget) {
                loBin = b;
                break;
            }
        }
        acc = 0;
        for (int b = 0; b < HIST_BINS; b++) {
            acc += hist[b];
            if (acc >= hiTarget) {
                hiBin = b;
                break;
            }
        }

        float binWidth = (hi - lo) / HIST_BINS;
        float robustLo = lo + loBin * binWidth;
        float robustHi = lo + (hiBin + 1) * binWidth;
        if (robustHi <= robustLo) {
            robustHi = robustLo + 1e-3f;
        }
        return new float[]{robustLo, robustHi};
    }

    private float[] dilate(float[] depth, int size, int radius) {
        float[] horizontal = new float[depth.length];
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                float maxVal = 0.0f;
                for (int dx = -radius; dx <= radius; dx++) {
                    int nx = Math.min(Math.max(x + dx, 0), size - 1);
                    float v = depth[y * size + nx];
                    if (v > maxVal) maxVal = v;
                }
                horizontal[y * size + x] = maxVal;
            }
        }
        float[] result = new float[depth.length];
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                float maxVal = 0.0f;
                for (int dy = -radius; dy <= radius; dy++) {
                    int ny = Math.min(Math.max(y + dy, 0), size - 1);
                    float v = horizontal[ny * size + x];
                    if (v > maxVal) maxVal = v;
                }
                result[y * size + x] = maxVal;
            }
        }
        return result;
    }

    private float[] separableBoxBlur(float[] depth, int size, int radius) {
        float[] horizontal = new float[depth.length];
        int diam = radius * 2 + 1;
        for (int y = 0; y < size; y++) {
            float sum = 0.0f;
            for (int x = -radius; x <= radius; x++) {
                int nx = Math.min(Math.max(x, 0), size - 1);
                sum += depth[y * size + nx];
            }
            horizontal[y * size + 0] = sum / diam;
            for (int x = 1; x < size; x++) {
                int addX = Math.min(x + radius, size - 1);
                int remX = Math.max(x - radius - 1, 0);
                sum += depth[y * size + addX] - depth[y * size + remX];
                horizontal[y * size + x] = sum / diam;
            }
        }
        float[] result = new float[depth.length];
        for (int x = 0; x < size; x++) {
            float sum = 0.0f;
            for (int y = -radius; y <= radius; y++) {
                int ny = Math.min(Math.max(y, 0), size - 1);
                sum += horizontal[ny * size + x];
            }
            result[0 * size + x] = sum / diam;
            for (int y = 1; y < size; y++) {
                int addY = Math.min(y + radius, size - 1);
                int remY = Math.max(y - radius - 1, 0);
                sum += horizontal[addY * size + x] - horizontal[remY * size + x];
                result[y * size + x] = sum / diam;
            }
        }
        return result;
    }

    // Per-texel EMA, real-time-rate (not fixed-per-call) via DEPTH_TAU_SECONDS
    // - see its comment above for why. Values entering here are already
    // normalized into a stable [0,1] band by postProcess()'s robust+smoothed
    // range, so a simple time-scaled blend is enough. The previous version
    // (before even the fixed-alpha one) instead measured how much the WHOLE
    // frame changed and picked a smoothing amount from that, which could hit
    // exactly zero on a fully static desktop (the common case) and
    // permanently freeze the entire depth map at whatever one inference
    // produced - small/ambiguous static elements (a clock widget, a subtly-3D
    // background) that happened to get a weak first estimate stayed weak
    // forever. A rate that never truly reaches zero (dt-scaled or not) keeps
    // denoising even when nothing on screen is moving.
    private float[] temporalSmooth(float[] newDepth, int size, float dt) {
        int len = size * size;
        if (smoothedDepthFloat == null) {
            smoothedDepthFloat = newDepth.clone();
            return newDepth;
        }

        float depthAlpha = 1f - (float) Math.exp(-dt / DEPTH_TAU_SECONDS);
        float[] result = new float[len];
        for (int i = 0; i < len; i++) {
            float prev = smoothedDepthFloat[i];
            float curr = newDepth[i];
            result[i] = prev + depthAlpha * (curr - prev);
        }
        smoothedDepthFloat = result;

        return result;
    }

    public synchronized void close() {
        if (tfliteMidas != null) {
            tfliteMidas.close();
            tfliteMidas = null;
        }
        if (tfliteMidas192 != null) {
            tfliteMidas192.close();
            tfliteMidas192 = null;
        }
        if (tfliteDA196 != null) {
            tfliteDA196.close();
            tfliteDA196 = null;
        }
        if (tfliteDA252 != null) {
            tfliteDA252.close();
            tfliteDA252 = null;
        }
        if (tfliteYoloN256 != null) {
            tfliteYoloN256.close();
            tfliteYoloN256 = null;
        }
        if (tfliteYoloN320 != null) {
            tfliteYoloN320.close();
            tfliteYoloN320 = null;
        }
        if (tfliteYoloN384 != null) {
            tfliteYoloN384.close();
            tfliteYoloN384 = null;
        }
        if (tfliteYoloS != null) {
            tfliteYoloS.close();
            tfliteYoloS = null;
        }
        for (GpuVariant v : gpuVariants.values()) {
            if (v.interp != null) {
                v.interp.close();
                v.interp = null;
            }
            if (v.delegate != null) {
                v.delegate.close();
                v.delegate = null;
            }
        }
        gpuVariants.clear();
        activeGpuVariant = null;
        activeInterpreter = null;
        initialized = false;
        executor.shutdownNow();
    }

    // Native output resolution of whichever model is currently active - the
    // caller (depth_estimator.gd) sizes its viewport/texture off this, so it
    // has to reflect activeModelIndex rather than a single fixed constant.
    // Every YOLO26-N variant and -S run at different resolutions from each
    // other, not just from MiDaS/DA.
    public int getModelSize() {
        if (activeModelIndex == 1) {
            return DA_252_INPUT_SIZE;
        }
        if (activeModelIndex == 4) {
            return YOLO_N_384_INPUT_SIZE;
        }
        if (activeModelIndex == 5) {
            return YOLO_S_INPUT_SIZE;
        }
        if (activeModelIndex == 7) {
            return YOLO_N_256_INPUT_SIZE;
        }
        if (activeModelIndex == 8) {
            return YOLO_N_320_INPUT_SIZE;
        }
        if (activeModelIndex == 10) {
            return MIDAS_192_INPUT_SIZE;
        }
        if (activeModelIndex == 11) {
            return DA_196_INPUT_SIZE;
        }
        return OUTPUT_SIZE;
    }

    public boolean isInitialized() {
        return initialized;
    }

    private MappedByteBuffer loadModelFile(String filename) throws IOException {
        AssetFileDescriptor fd = appContext.getAssets().openFd(filename);
        FileInputStream is = new FileInputStream(fd.getFileDescriptor());
        FileChannel ch = is.getChannel();
        long offset = fd.getStartOffset();
        long length = fd.getDeclaredLength();
        return ch.map(FileChannel.MapMode.READ_ONLY, offset, length);
    }
}
