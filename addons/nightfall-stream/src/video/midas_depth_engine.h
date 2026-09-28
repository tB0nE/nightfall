#pragma once

// Native (JNI-free) depth estimation for Linux - a direct C++ port of the
// selectable Android DepthEstimator.java models. Same math/algorithm as the
// Java version (robustRange/postProcess/temporalSmooth), same async
// single-inference-in-flight submit/drop semantics (mirrors Java's single-
// thread ExecutorService + AtomicBoolean isInferencing), just without the
// JNI hop - there's no JVM on desktop Linux.

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

#ifdef NIGHTFALL_HAS_NCNN_VULKAN
#include "net.h"
#endif

class MidasDepthEngine {
public:
    MidasDepthEngine();
    ~MidasDepthEngine();

    // Loads all selectable Android-parity models from the given directory (see depth_bridge.cpp
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
    // every platform (1=DA-252, 3=MiDaS-256, 4/7/8=YOLO26-N,
    // 10=MiDaS-192, 11=DA-196) - see
    // DepthEstimator.java's setActiveModel() for the authoritative mapping.
    // Any unavailable or unrecognized index falls back to MiDaS-256.
    void set_active_model(int model_index);

    // Selects the model and execution backend together. Returns the effective
    // backend using DepthBridge's 1=CPU/2=GPU convention. ZipDepth-384/256
    // support Vulkan; the retained MiDaS/DA-V2 library remains on TFLite CPU.
    int configure(int model_index, int requested_backend);
    int get_backend_capabilities(int model_index) const;
    std::string get_backend_status() const;

    // Live worker telemetry consumed by the same status-bar/performance
    // overlay API as Android. Inference time covers model input preparation,
    // dispatch, and output readback, but excludes Nightfall's common depth
    // normalization/temporal smoothing pass.
    float get_last_inference_ms() const { return last_inference_ms_.load(); }
    float get_last_inference_hz() const { return last_inference_hz_.load(); }
    float get_last_age_ms() const { return last_depth_age_ms_.load(); }
    int get_last_skipped_frames() const { return last_skipped_frames_.load(); }

    // Native output resolution (square) of whichever model is currently
    // active - depth_estimator.gd sizes its capture viewport off this via
    // DepthBridge::get_depth_model_size(), same as Android.
    int get_model_size() const;

private:
    enum class InputLayout {
        QuantizedNhWC,
        FloatNhWC,
        FloatNchW,
    };

    struct DepthModel {
        std::string name;
        int size = 0;
        int index = 3;
        InputLayout input_layout = InputLayout::QuantizedNhWC;
        bool invert_output = false;
        float percentile_clip = 0.02f;
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

#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    struct VulkanDepthModel {
        std::string name;
        int size = 0;
        int index = 0;
        std::string stem;
        bool input_nhwc = false;
        float percentile_clip = 0.02f;
        std::unique_ptr<ncnn::Net> net;
        std::atomic<bool> loaded{false};
        std::atomic<bool> load_attempted{false};
    };
#endif

    bool load_model(DepthModel &model, const std::string &path, const char *name, int size,
                    int index, InputLayout input_layout, bool invert_output = false,
                    float percentile_clip = 0.02f);
    std::vector<float> run_inference(DepthModel &model, const uint8_t *rgba, int width, int height);
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    void register_vulkan_model(VulkanDepthModel &model, const char *stem,
                               const char *name, int size, int index,
                               bool input_nhwc = false, float percentile_clip = 0.02f);
    bool load_vulkan_model(VulkanDepthModel &model);
    std::vector<float> run_vulkan_inference(VulkanDepthModel &model, const uint8_t *rgba,
                                            int width, int height);
    VulkanDepthModel *vulkan_model_for_index(int model_index);
#endif

    // Ported verbatim from DepthEstimator.java - see its own comments for
    // the full reasoning (percentile-clip histogram range, dt-scaled EMA
    // smoothing via RANGE_TAU_SECONDS/DEPTH_TAU_SECONDS, per-texel temporal
    // smoothing). dilateAndBlur is never used here (MiDaS's own call site on
    // Android never sets it either - the warp shader's own joint-bilateral
    // upsample already does edge-aware smoothing).
    void robust_range(const std::vector<float> &v, float percentile_clip, float *lo_out, float *hi_out) const;
    std::vector<uint8_t> post_process(const std::vector<float> &raw, int size, float percentile_clip);
    DepthModel *model_for_index(int model_index);

    void worker_loop();

    DepthModel model_256_;
    DepthModel model_192_;
    DepthModel model_yolo_256_;
    DepthModel model_yolo_320_;
    DepthModel model_yolo_384_;
    DepthModel model_da_196_;
    DepthModel model_da_252_;
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    VulkanDepthModel model_zipdepth_384_;
    VulkanDepthModel model_zipdepth_256_;
    VulkanDepthModel model_midas_256_vulkan_;
    VulkanDepthModel model_midas_192_vulkan_;
    VulkanDepthModel model_da_252_vulkan_;
    std::atomic<VulkanDepthModel *> active_vulkan_model_{nullptr};
    bool vulkan_available_ = false;
#endif
    // atomic - written from the calling thread (set_active_model()) and
    // read from worker_loop() on the dedicated inference thread; a plain
    // pointer here would be a real data race even though it happened not to
    // be the cause of the 2026-08-20 segfault (see submit_frame()'s rgba_len
    // check for that one).
    std::atomic<DepthModel *> active_model_{nullptr};
    std::atomic<int> active_model_index_{3};
    void set_backend_status(const std::string &status);
    mutable std::mutex backend_status_mutex_;
    std::string backend_status_;
    std::string model_dir_;

    std::thread worker_;
    std::mutex submit_mutex_;
    std::condition_variable submit_cv_;
    bool has_pending_ = false;
    std::vector<uint8_t> pending_rgba_;
    int pending_width_ = 0;
    int pending_height_ = 0;
    int64_t pending_capture_time_ns_ = 0;
    std::atomic<bool> is_inferencing_{false};
    bool shutdown_ = false;

    // Worker-owned rolling window with atomic snapshots for the Godot thread.
    int64_t telemetry_window_start_ns_ = 0;
    int64_t telemetry_total_inference_ns_ = 0;
    int telemetry_completed_frames_ = 0;
    std::atomic<int> submitted_frames_{0};
    std::atomic<int> dropped_frames_{0};
    std::atomic<float> last_inference_ms_{0.0f};
    std::atomic<float> last_inference_hz_{0.0f};
    std::atomic<float> last_depth_age_ms_{0.0f};
    std::atomic<int> last_skipped_frames_{0};

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
