#pragma once

// Native (JNI-free) MiDaS depth estimation for Linux - a direct C++ port of
// DepthEstimator.java's MiDaS-only subset (MiDaS-192/256), used by
// depth_bridge.cpp's NIGHTFALL_PLATFORM_LINUX branch. Same math/algorithm as
// the Java version (robustRange/postProcess/temporalSmooth), same async
// single-inference-in-flight submit/drop semantics (mirrors Java's single-
// thread ExecutorService + AtomicBoolean isInferencing), just without the
// JNI hop - there's no JVM on desktop Linux. YOLO26/DA V2 are NOT ported
// here yet (see the depth-model-comparison work's DepthEstimator.java for
// what a future port needs) - any model index this doesn't recognize falls
// back to MiDaS-256, matching DepthEstimator.java's own
// setActiveModel()/else-branch fallback for unreachable/dormant indices.

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// Can't forward-declare these - as of TFLite v2.16.1, tflite::Interpreter is
// itself a type ALIAS (`using Interpreter = impl::Interpreter;` in
// tensorflow/lite/core/interpreter.h), not a plain class in the tflite
// namespace, so a `class Interpreter;` forward declaration is an invalid
// conflicting redeclaration once the real header is included elsewhere in
// the same translation unit. Including the real headers here is fine -
// they're include-guarded, and this header is only ever included from
// midas_depth_engine.cpp and depth_bridge.cpp (which only forward-declares
// MidasDepthEngine itself, not any TFLite type).
#include "tensorflow/lite/interpreter.h"
#include "tensorflow/lite/model.h"

class MidasDepthEngine {
public:
    MidasDepthEngine();
    ~MidasDepthEngine();

    // Loads both MiDaS models from the given directory (see depth_bridge.cpp
    // for how that directory is resolved - loose files next to the
    // executable, not through Godot's res:///PCK, same pattern as the
    // GDExtension .so itself). Safe to call once; subsequent calls are a
    // no-op if already initialized.
    void initialize(const std::string &model_dir);

    // rgba: expected to be width*height*4 bytes (RGBA8, matching
    // depth_viewport's SubViewport format on the GDScript side) - rgba_len
    // is the CALLER's actual buffer size and is checked against that
    // expectation before anything is read from it. Non-blocking - drops the
    // frame if an inference is already in flight (same policy as
    // DepthEstimator.java's submitFrame()) or if rgba_len is too small
    // (found 2026-08-20: depth_viewport.size can change (192<->256) when
    // switching MiDaS-192/256, and a Godot SubViewport resize doesn't
    // necessarily apply to the very next captured frame synchronously -
    // trusting width/height without checking the real buffer size crashed
    // on a real switch, this is the fix).
    void submit_frame(const uint8_t *rgba, size_t rgba_len, int width, int height);

    // Returns the most recent completed depth map (size*size single-channel
    // bytes) and clears it, or an empty vector if nothing new since the last
    // call - mirrors DepthBridge::get_depth_map()'s existing contract.
    std::vector<uint8_t> get_latest_depth();

    // Same model-index scheme main.gd/settings_controller.gd already send on
    // every platform (3=MiDaS-256, 10=MiDaS-192) - see
    // DepthEstimator.java's setActiveModel() for the authoritative mapping.
    // Any other index falls back to MiDaS-256.
    void set_active_model(int model_index);

    // Native output resolution (square) of whichever model is currently
    // active - depth_estimator.gd sizes its capture viewport off this via
    // DepthBridge::get_depth_model_size(), same as Android.
    int get_model_size() const;

private:
    struct MidasModel {
        std::string name;
        int size = 0;
        std::unique_ptr<tflite::FlatBufferModel> flat_model;
        std::unique_ptr<tflite::Interpreter> interpreter;
        // Read directly from the loaded model's own tensor metadata at load
        // time (ai-edge-litert Interpreter.get_input/output_details()'
        // pattern already established for this project's Python tooling) -
        // NOT hardcoded. Getting either wrong doesn't throw, it silently
        // produces garbage depth data (this exact failure mode already bit
        // this project once on Android, see git history).
        float input_scale = 1.0f;
        int input_zero_point = 0;
        float output_scale = 1.0f;
        int output_zero_point = 0;
        bool loaded = false;
    };

    bool load_model(MidasModel &model, const std::string &path, const char *name, int size);
    // Fills the interpreter's input tensor (NHWC, quantized uint8, same
    // nearest-neighbor downscale as DepthEstimator.java's runInferenceMidas()),
    // runs inference, dequantizes the output, and returns raw (unnormalized)
    // depth values in model.size*model.size row-major order.
    std::vector<float> run_inference(MidasModel &model, const uint8_t *rgba, int width, int height);

    // Ported verbatim from DepthEstimator.java - see its own comments for
    // the full reasoning (percentile-clip histogram range, dt-scaled EMA
    // smoothing via RANGE_TAU_SECONDS/DEPTH_TAU_SECONDS, per-texel temporal
    // smoothing). dilateAndBlur is never used here (MiDaS's own call site on
    // Android never sets it either - the warp shader's own joint-bilateral
    // upsample already does edge-aware smoothing).
    void robust_range(const std::vector<float> &v, float *lo_out, float *hi_out) const;
    std::vector<uint8_t> post_process(const std::vector<float> &raw, int size);

    void worker_loop();

    MidasModel model_256_;
    MidasModel model_192_;
    // atomic - written from the calling thread (set_active_model()) and
    // read from worker_loop() on the dedicated inference thread; a plain
    // pointer here would be a real data race even though it happened not to
    // be the cause of the 2026-08-20 segfault (see submit_frame()'s rgba_len
    // check for that one).
    std::atomic<MidasModel *> active_model_{nullptr};
    std::atomic<int> active_model_index_{3};

    std::thread worker_;
    std::mutex submit_mutex_;
    std::condition_variable submit_cv_;
    bool has_pending_ = false;
    std::vector<uint8_t> pending_rgba_;
    int pending_width_ = 0;
    int pending_height_ = 0;
    std::atomic<bool> is_inferencing_{false};
    bool shutdown_ = false;

    std::mutex result_mutex_;
    std::vector<uint8_t> latest_result_;
    bool has_result_ = false;

    // postProcess()'s running state - reset whenever the active model
    // switches (same as DepthEstimator.java's setActiveModel()).
    std::vector<float> smoothed_depth_;
    bool smoothed_valid_ = false;
    float smooth_lo_ = 0.0f;
    float smooth_hi_ = 1.0f;
    bool range_valid_ = false;
    int64_t last_post_process_time_ns_ = 0;
    std::mutex postprocess_mutex_;

    bool initialized_ = false;
};
