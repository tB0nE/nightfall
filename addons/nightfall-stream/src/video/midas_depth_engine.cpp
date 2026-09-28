#include "midas_depth_engine.h"
#include "nf_log.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include "tensorflow/lite/interpreter.h"
#include "tensorflow/lite/kernels/register.h"
#include "tensorflow/lite/model.h"

#ifdef NIGHTFALL_HAS_NCNN_VULKAN
#include "gpu.h"
#endif

namespace {
constexpr const char *TAG = "MidasDepthEngine";
constexpr int HIST_BINS = 512;
constexpr float DEFAULT_PERCENTILE_CLIP = 0.02f;
// Same values as DepthEstimator.java's RANGE_TAU_SECONDS/DEPTH_TAU_SECONDS -
// see that file's comment for the derivation (tau = dt_ref / -ln(1 - alpha)
// against MiDaS's own typical ~145ms achieved cadence).
constexpr float RANGE_TAU_SECONDS = 0.89f;
constexpr float DEPTH_TAU_SECONDS = 0.158f;

int64_t now_ns() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}
} // namespace

MidasDepthEngine::MidasDepthEngine() {}

void MidasDepthEngine::set_backend_status(const std::string &status) {
    std::lock_guard<std::mutex> lock(backend_status_mutex_);
    backend_status_ = status;
}

std::string MidasDepthEngine::get_backend_status() const {
    std::lock_guard<std::mutex> lock(backend_status_mutex_);
    return backend_status_;
}

MidasDepthEngine::~MidasDepthEngine() {
    {
        std::lock_guard<std::mutex> lock(submit_mutex_);
        shutdown_ = true;
    }
    submit_cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    active_vulkan_model_.store(nullptr);
    model_zipdepth_384_.net.reset();
    model_zipdepth_256_.net.reset();
    model_midas_256_vulkan_.net.reset();
    model_midas_192_vulkan_.net.reset();
    model_da_252_vulkan_.net.reset();
    if (vulkan_available_) ncnn::destroy_gpu_instance();
#endif
}

#ifdef NIGHTFALL_HAS_NCNN_VULKAN
void MidasDepthEngine::register_vulkan_model(VulkanDepthModel &model, const char *stem,
                                              const char *name, int size, int index,
                                              bool input_nhwc, float percentile_clip) {
    model.name = name;
    model.stem = stem;
    model.size = size;
    model.index = index;
    model.input_nhwc = input_nhwc;
    model.percentile_clip = percentile_clip;
}

bool MidasDepthEngine::load_vulkan_model(VulkanDepthModel &model) {
    model.load_attempted.store(true);
    model.net = std::make_unique<ncnn::Net>();
    model.net->opt.use_vulkan_compute = true;
    model.net->opt.use_fp16_packed = true;
    model.net->opt.use_fp16_storage = true;
    model.net->opt.use_fp16_arithmetic = true;
    model.net->opt.num_threads = 4;
    model.net->set_vulkan_device(ncnn::get_default_gpu_index());

    const std::string prefix = model_dir_ + "/" + model.stem;
    if (model.net->load_param((prefix + ".ncnn.param").c_str()) != 0 ||
        model.net->load_model((prefix + ".ncnn.bin").c_str()) != 0) {
        NF_LOGE(TAG, "Failed to load Vulkan model: %s", prefix.c_str());
        model.net.reset();
        return false;
    }
    model.loaded.store(true);
    NF_LOG(TAG, "Loaded %s (%dx%d Vulkan, device=%s)", model.name.c_str(), model.size, model.size,
           ncnn::get_gpu_device(ncnn::get_default_gpu_index())->info.device_name());
    return true;
}

MidasDepthEngine::VulkanDepthModel *MidasDepthEngine::vulkan_model_for_index(int model_index) {
    if (model_index == 3) return &model_midas_256_vulkan_;
    if (model_index == 10) return &model_midas_192_vulkan_;
    if (model_index == 1) return &model_da_252_vulkan_;
    if (model_index == 14) return &model_zipdepth_384_;
    if (model_index == 18) return &model_zipdepth_256_;
    return nullptr;
}

std::vector<float> MidasDepthEngine::run_vulkan_inference(VulkanDepthModel &model,
                                                           const uint8_t *rgba,
                                                           int width, int height) {
    ncnn::Mat input;
    if (model.input_nhwc) {
        // pnnx preserves Depth Anything's [H,W,C] input as an ncnn Mat with
        // w=3, h=H, c=W. Populate its contiguous storage in RGB pixel order;
        // the graph's first Permute converts it to NCHW for the network.
        input = ncnn::Mat(3, width, height);
        float *values = input;
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const uint8_t *pixel = rgba + (y * width + x) * 4;
                const size_t offset = static_cast<size_t>(y * width + x) * 3;
                values[offset] = pixel[0] / 255.0f;
                values[offset + 1] = pixel[1] / 255.0f;
                values[offset + 2] = pixel[2] / 255.0f;
            }
        }
    } else {
        input = ncnn::Mat::from_pixels(rgba, ncnn::Mat::PIXEL_RGBA2RGB, width, height);
        if (!input.empty()) {
            const float norm[3] = {1.0f / 255.0f, 1.0f / 255.0f, 1.0f / 255.0f};
            input.substract_mean_normalize(nullptr, norm);
        }
    }
    if (input.empty()) return {};

    ncnn::Extractor extractor = model.net->create_extractor();
    if (extractor.input("in0", input) != 0) {
        NF_LOGE(TAG, "Vulkan input failed for %s", model.name.c_str());
        return {};
    }
    ncnn::Mat output;
    if (extractor.extract("out0", output) != 0 || output.empty()) {
        NF_LOGE(TAG, "Vulkan inference failed for %s", model.name.c_str());
        return {};
    }
    if (output.total() != static_cast<size_t>(model.size * model.size)) {
        NF_LOGE(TAG, "Unexpected Vulkan output for %s (%zu values)",
                model.name.c_str(), output.total());
        return {};
    }
    const float *values = output;
    return std::vector<float>(values, values + output.total());
}
#endif

bool MidasDepthEngine::load_model(DepthModel &model, const std::string &path, const char *name, int size,
                                  int index, InputLayout input_layout, bool invert_output,
                                  float percentile_clip) {
    model.name = name;
    model.size = size;
    model.index = index;
    model.input_layout = input_layout;
    model.invert_output = invert_output;
    model.percentile_clip = percentile_clip;
    model.flat_model = tflite::FlatBufferModel::BuildFromFile(path.c_str());
    if (!model.flat_model) {
        NF_LOGE(TAG, "Failed to load model file: %s", path.c_str());
        return false;
    }

    tflite::ops::builtin::BuiltinOpResolver resolver;
    tflite::InterpreterBuilder builder(*model.flat_model, resolver);
    builder(&model.interpreter);
    if (!model.interpreter) {
        NF_LOGE(TAG, "Failed to build interpreter for: %s", path.c_str());
        return false;
    }

    model.interpreter->SetNumThreads(4);
    if (model.interpreter->AllocateTensors() != kTfLiteOk) {
        NF_LOGE(TAG, "AllocateTensors failed for: %s", path.c_str());
        return false;
    }

    // Read quantization params directly from the loaded model's own tensor
    // metadata (see midas_depth_engine.h's comment) rather than hardcoding -
    // both MiDaS-192 and MiDaS-256 are w8a8 (uint8 I/O), each independently
    // calibrated.
    const TfLiteTensor *input_tensor = model.interpreter->input_tensor(0);
    const TfLiteTensor *output_tensor = model.interpreter->output_tensor(0);
    const TfLiteType expected_input_type = input_layout == InputLayout::QuantizedNhWC ? kTfLiteUInt8 : kTfLiteFloat32;
    if (input_tensor->type != expected_input_type ||
        (output_tensor->type != kTfLiteUInt8 && output_tensor->type != kTfLiteFloat32) ||
        input_tensor->bytes != size * size * 3 * (expected_input_type == kTfLiteUInt8 ? 1 : 4) ||
        output_tensor->bytes != size * size * (output_tensor->type == kTfLiteUInt8 ? 1 : 4)) {
        NF_LOGE(TAG, "Unexpected tensors for %s (input type=%d bytes=%zu, output type=%d bytes=%zu)",
                name, input_tensor->type, input_tensor->bytes, output_tensor->type, output_tensor->bytes);
        model.interpreter.reset();
        model.flat_model.reset();
        return false;
    }
    model.input_scale = input_tensor->params.scale;
    model.input_zero_point = input_tensor->params.zero_point;
    model.output_scale = output_tensor->params.scale;
    model.output_zero_point = output_tensor->params.zero_point;

    model.loaded = true;
    NF_LOG(TAG, "Loaded %s (%dx%d, in_scale=%f in_zp=%d out_scale=%f out_zp=%d)",
           name, size, size, model.input_scale, model.input_zero_point,
           model.output_scale, model.output_zero_point);
    return true;
}

void MidasDepthEngine::initialize(const std::string &model_dir) {
    if (initialized_) return;
    model_dir_ = model_dir;

    bool ok_256 = load_model(model_256_, model_dir + "/midas-midas-v2-w8a8.tflite", "MiDaS-256", 256, 3, InputLayout::QuantizedNhWC);
    bool ok_192 = load_model(model_192_, model_dir + "/midas-v21-small-192-int8.tflite", "MiDaS-192", 192, 10, InputLayout::QuantizedNhWC);
    bool ok_yolo_256 = load_model(model_yolo_256_, model_dir + "/yolo26n-depth-256-w8a32.tflite", "YOLO26-N-256", 256, 7, InputLayout::FloatNchW, true, 0.10f);
    bool ok_yolo_320 = load_model(model_yolo_320_, model_dir + "/yolo26n-depth-320-w8a32.tflite", "YOLO26-N-320", 320, 8, InputLayout::FloatNchW, true, 0.10f);
    bool ok_yolo_384 = load_model(model_yolo_384_, model_dir + "/yolo26n-depth-384-w8a32.tflite", "YOLO26-N-384", 384, 4, InputLayout::FloatNchW, true, 0.10f);
    bool ok_da_196 = load_model(model_da_196_, model_dir + "/depth-anything-v2-small-196.tflite", "Depth Anything V2-196", 196, 11, InputLayout::FloatNhWC);
    bool ok_da_252 = load_model(model_da_252_, model_dir + "/depth-anything-v2-small-252.tflite", "Depth Anything V2-252", 252, 1, InputLayout::FloatNhWC);

#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    ncnn::create_gpu_instance();
    vulkan_available_ = ncnn::get_gpu_count() > 0;
    if (vulkan_available_) {
        register_vulkan_model(model_midas_256_vulkan_, "midas-v21-small-256-vulkan", "MiDaS-256", 256, 3);
        register_vulkan_model(model_midas_192_vulkan_, "midas-v21-small-192-vulkan", "MiDaS-192", 192, 10);
        register_vulkan_model(model_da_252_vulkan_, "depth-anything-v2-252-vulkan", "Depth Anything V2-252", 252, 1, true);
        register_vulkan_model(model_zipdepth_384_, "zipdepth-base-384-vulkan", "ZipDepth-384", 384, 14);
        register_vulkan_model(model_zipdepth_256_, "zipdepth-base-256-vulkan", "ZipDepth-256", 256, 18);
    } else {
        NF_LOGE(TAG, "No Vulkan compute device found; ZipDepth GPU inference unavailable");
    }
#endif

    if (!ok_256 && !ok_192 && !vulkan_available_) {
        NF_LOGE(TAG, "No depth models could be loaded from %s - AI-3D depth unavailable", model_dir.c_str());
        return;
    }

    active_model_ = ok_256 ? &model_256_ : (ok_192 ? &model_192_ : nullptr);
    if (active_model_) active_model_index_ = ok_256 ? 3 : 10;
    initialized_ = true;
    worker_ = std::thread(&MidasDepthEngine::worker_loop, this);
    NF_LOG(TAG, "Initialized (MiDaS-256=%s, MiDaS-192=%s, YOLO-256=%s, YOLO-320=%s, YOLO-384=%s, DA-196=%s, DA-252=%s)",
           ok_256 ? "true" : "false", ok_192 ? "true" : "false", ok_yolo_256 ? "true" : "false",
           ok_yolo_320 ? "true" : "false", ok_yolo_384 ? "true" : "false", ok_da_196 ? "true" : "false",
           ok_da_252 ? "true" : "false");
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    NF_LOG(TAG, "Vulkan depth library registered for lazy loading (MiDaS-256, MiDaS-192, DA-V2-252, ZipDepth-384, ZipDepth-256)");
#endif
}

MidasDepthEngine::DepthModel *MidasDepthEngine::model_for_index(int model_index) {
    DepthModel *candidate = nullptr;
    switch (model_index) {
        case 1: candidate = &model_da_252_; break;
        case 4: candidate = &model_yolo_384_; break;
        case 7: candidate = &model_yolo_256_; break;
        case 8: candidate = &model_yolo_320_; break;
        case 10: candidate = &model_192_; break;
        case 11: candidate = &model_da_196_; break;
        default: candidate = &model_256_; break;
    }
    if (candidate->loaded) return candidate;
    if (model_256_.loaded) return &model_256_;
    if (model_192_.loaded) return &model_192_;
    return nullptr;
}

void MidasDepthEngine::set_active_model(int model_index) {
    configure(model_index, 1);
}

int MidasDepthEngine::get_backend_capabilities(int model_index) const {
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    if (vulkan_available_ && (model_index == 1 || model_index == 3 || model_index == 10 ||
                              model_index == 14 || model_index == 18)) {
        return 2;
    }
#endif
    return 1;
}

int MidasDepthEngine::configure(int model_index, int requested_backend) {
    if (!initialized_) return 1;

#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    VulkanDepthModel *vulkan_target = vulkan_model_for_index(model_index);
    const bool wants_gpu = requested_backend == 0 || requested_backend == 2;
    if (wants_gpu && vulkan_target) {
        while (is_inferencing_.load()) std::this_thread::yield();
        {
            std::lock_guard<std::mutex> lock(postprocess_mutex_);
            smoothed_valid_ = false;
            range_valid_ = false;
            last_post_process_time_ns_ = 0;
        }
        active_model_.store(nullptr);
        active_vulkan_model_.store(vulkan_target);
        active_model_index_ = vulkan_target->index;
        if (vulkan_target->load_attempted.load() && !vulkan_target->loaded.load()) {
            set_backend_status("Vulkan model failed to load: " + vulkan_target->name);
        } else {
            set_backend_status("");
        }
        NF_LOG(TAG, "Selected model %s (Vulkan%s)", vulkan_target->name.c_str(),
               vulkan_target->loaded.load() ? "" : ", lazy load pending");
        return 2;
    }
    active_vulkan_model_.store(nullptr);
    if (wants_gpu && (model_index == 1 || model_index == 3 || model_index == 10 ||
                      model_index == 14 || model_index == 18)) {
        set_backend_status("Vulkan depth unavailable; using CPU fallback");
    } else {
        set_backend_status("");
    }
#else
    (void)requested_backend;
    set_backend_status((model_index == 14 || model_index == 18)
            ? "Vulkan depth support is unavailable in this build" : "");
#endif

    DepthModel *target = model_for_index(model_index);
    if (!target) return 1;

    if (active_model_ == target) return 1;

    // Wait out any in-flight inference before switching, same as
    // DepthEstimator.java's setActiveModel() busy-wait - avoids a race
    // where a result computed against the OLD model lands after the switch.
    while (is_inferencing_.load()) {
        std::this_thread::yield();
    }

    {
        std::lock_guard<std::mutex> lock(postprocess_mutex_);
        smoothed_valid_ = false;
        range_valid_ = false;
        last_post_process_time_ns_ = 0;
    }
    active_model_ = target;
    active_model_index_ = target->index;
    NF_LOG(TAG, "Switched to model %s (CPU)", target->name.c_str());
    return 1;
}

int MidasDepthEngine::get_model_size() const {
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    VulkanDepthModel *vulkan_model = active_vulkan_model_.load();
    if (vulkan_model) return vulkan_model->size;
#endif
    DepthModel *model = active_model_.load();
    if (!initialized_ || !model) return 256;
    return model->size;
}

void MidasDepthEngine::submit_frame(const uint8_t *rgba, size_t rgba_len, int width, int height) {
    if (!initialized_) return;
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
    if (!active_model_ && !active_vulkan_model_) return;
#else
    if (!active_model_) return;
#endif
    if (!rgba || width <= 0 || height <= 0) return;
    submitted_frames_.fetch_add(1);
    if (is_inferencing_.load()) {
        dropped_frames_.fetch_add(1);
        return; // drop - matches Android's isInferencing.compareAndSet policy
    }

    size_t needed = static_cast<size_t>(width) * static_cast<size_t>(height) * 4;
    if (rgba_len < needed) {
        // Real bug found 2026-08-20: depth_viewport's SubViewport resize
        // (192<->256, switching MiDaS models) doesn't necessarily apply to
        // the very next captured frame synchronously, so width/height (from
        // the just-updated model_size) can briefly disagree with the
        // ACTUAL captured image's real buffer size - reading needed bytes
        // from a smaller buffer segfaulted. Drop this one frame instead;
        // the next submit (after the viewport catches up) will be correctly
        // sized again.
        NF_LOGE("MidasDepthEngine", "submit_frame: buffer too small (got %zu, need %zu for %dx%d) - dropping frame",
                rgba_len, needed, width, height);
        return;
    }

    {
        std::lock_guard<std::mutex> lock(submit_mutex_);
        pending_rgba_.assign(rgba, rgba + needed);
        pending_width_ = width;
        pending_height_ = height;
        pending_capture_time_ns_ = now_ns();
        has_pending_ = true;
    }
    submit_cv_.notify_one();
}

std::vector<uint8_t> MidasDepthEngine::get_latest_depth() {
    std::lock_guard<std::mutex> lock(result_mutex_);
    if (!has_result_) return {};
    has_result_ = false;
    return std::move(latest_result_);
}

void MidasDepthEngine::worker_loop() {
    while (true) {
        std::vector<uint8_t> rgba;
        int width = 0, height = 0;
        int64_t capture_time_ns = 0;
        {
            std::unique_lock<std::mutex> lock(submit_mutex_);
            submit_cv_.wait(lock, [this] { return has_pending_ || shutdown_; });
            if (shutdown_) return;
            rgba = std::move(pending_rgba_);
            width = pending_width_;
            height = pending_height_;
            capture_time_ns = pending_capture_time_ns_;
            has_pending_ = false;
        }

        is_inferencing_.store(true);
        const int64_t inference_start_ns = now_ns();
        bool inference_completed = false;
        DepthModel *model = active_model_;
#ifdef NIGHTFALL_HAS_NCNN_VULKAN
        VulkanDepthModel *vulkan_model = active_vulkan_model_;
        if (vulkan_model && !vulkan_model->loaded.load() && !vulkan_model->load_attempted.load()) {
            NF_LOG(TAG, "Lazy-loading %s Vulkan model", vulkan_model->name.c_str());
            if (!load_vulkan_model(*vulkan_model)) {
                set_backend_status("Vulkan model failed to load: " + vulkan_model->name);
            } else {
                set_backend_status("");
            }
        }
        if (vulkan_model && vulkan_model->loaded.load()) {
            std::vector<float> raw = run_vulkan_inference(*vulkan_model, rgba.data(), width, height);
            if (!raw.empty()) {
                const int64_t inference_end_ns = now_ns();
                std::vector<uint8_t> depth = post_process(raw, vulkan_model->size,
                                                          vulkan_model->percentile_clip);
                std::lock_guard<std::mutex> lock(result_mutex_);
                latest_result_ = std::move(depth);
                has_result_ = true;
                telemetry_total_inference_ns_ += inference_end_ns - inference_start_ns;
                inference_completed = true;
            }
        } else
#endif
        if (model && model->loaded) {
            std::vector<float> raw = run_inference(*model, rgba.data(), width, height);
            if (!raw.empty()) {
                const int64_t inference_end_ns = now_ns();
                std::vector<uint8_t> depth = post_process(raw, model->size, model->percentile_clip);
                std::lock_guard<std::mutex> lock(result_mutex_);
                latest_result_ = std::move(depth);
                has_result_ = true;
                telemetry_total_inference_ns_ += inference_end_ns - inference_start_ns;
                inference_completed = true;
            }
        }
        if (inference_completed) {
            const int64_t completed_ns = now_ns();
            last_depth_age_ms_.store(static_cast<float>(completed_ns - capture_time_ns) / 1e6f);
            telemetry_completed_frames_++;
            if (telemetry_window_start_ns_ == 0) telemetry_window_start_ns_ = inference_start_ns;
            const int64_t elapsed_ns = completed_ns - telemetry_window_start_ns_;
            if (elapsed_ns >= 1000000000LL) {
                const float divisor = static_cast<float>(std::max(telemetry_completed_frames_, 1));
                last_inference_ms_.store(static_cast<float>(telemetry_total_inference_ns_) / divisor / 1e6f);
                last_inference_hz_.store(divisor * 1e9f / static_cast<float>(elapsed_ns));
                const int submitted = submitted_frames_.exchange(0);
                const int dropped = dropped_frames_.exchange(0);
                last_skipped_frames_.store(dropped);
                NF_LOG(TAG, "Perf: model=%d inference=%.1fms completed=%.1fHz submitted=%d dropped=%d age=%.1fms",
                       active_model_index_.load(), last_inference_ms_.load(), last_inference_hz_.load(),
                       submitted, dropped, last_depth_age_ms_.load());
                telemetry_window_start_ns_ = completed_ns;
                telemetry_total_inference_ns_ = 0;
                telemetry_completed_frames_ = 0;
            }
        }
        is_inferencing_.store(false);
    }
}

std::vector<float> MidasDepthEngine::run_inference(DepthModel &model, const uint8_t *rgba, int width, int height) {
    const int size = model.size;

    const int src_row_bytes = width * 4;
    const float scale_x = static_cast<float>(width) / size;
    const float scale_y = static_cast<float>(height) / size;
    uint8_t *quantized_input = nullptr;
    float *float_input = nullptr;
    if (model.input_layout == InputLayout::QuantizedNhWC) {
        quantized_input = model.interpreter->typed_input_tensor<uint8_t>(0);
    } else {
        float_input = model.interpreter->typed_input_tensor<float>(0);
    }

    const int plane_elems = size * size;
    for (int y = 0; y < size; y++) {
        int src_y = std::min(static_cast<int>(y * scale_y), height - 1);
        int src_row_off = src_y * src_row_bytes;
        for (int x = 0; x < size; x++) {
            int src_x = std::min(static_cast<int>(x * scale_x), width - 1);
            int src_idx = src_row_off + src_x * 4;
            const int pixel_index = y * size + x;
            for (int c = 0; c < 3; c++) {
                float real = rgba[src_idx + c] / 255.0f;
                if (quantized_input) {
                    int q = static_cast<int>(std::lround(real / model.input_scale)) + model.input_zero_point;
                    quantized_input[pixel_index * 3 + c] = static_cast<uint8_t>(std::max(0, std::min(255, q)));
                } else if (model.input_layout == InputLayout::FloatNchW) {
                    float_input[c * plane_elems + pixel_index] = real;
                } else {
                    float_input[pixel_index * 3 + c] = real;
                }
            }
        }
    }

    if (model.interpreter->Invoke() != kTfLiteOk) {
        NF_LOGE(TAG, "Inference failed for %s", model.name.c_str());
        return {};
    }

    const TfLiteTensor *output_tensor = model.interpreter->output_tensor(0);
    const int count = plane_elems;
    std::vector<float> raw(count);
    if (output_tensor->type == kTfLiteUInt8) {
        const uint8_t *output_data = model.interpreter->typed_output_tensor<uint8_t>(0);
        for (int i = 0; i < count; i++) {
            raw[i] = (static_cast<int>(output_data[i]) - model.output_zero_point) * model.output_scale;
        }
    } else {
        const float *output_data = model.interpreter->typed_output_tensor<float>(0);
        std::copy(output_data, output_data + count, raw.begin());
    }
    if (model.invert_output) {
        for (float &value : raw) value = -value;
    }
    return raw;
}

void MidasDepthEngine::robust_range(const std::vector<float> &v, float percentile_clip, float *lo_out, float *hi_out) const {
    const int count = static_cast<int>(v.size());
    float lo = v[0], hi = v[0];
    for (int i = 1; i < count; i++) {
        lo = std::min(lo, v[i]);
        hi = std::max(hi, v[i]);
    }
    if (hi <= lo) {
        *lo_out = lo;
        *hi_out = lo + 1.0f;
        return;
    }

    int hist[HIST_BINS] = {0};
    float bin_scale = HIST_BINS / (hi - lo);
    for (int i = 0; i < count; i++) {
        int b = static_cast<int>((v[i] - lo) * bin_scale);
        b = std::max(0, std::min(HIST_BINS - 1, b));
        hist[b]++;
    }

    int lo_target = static_cast<int>(count * percentile_clip);
    int hi_target = static_cast<int>(count * (1.0f - percentile_clip));
    int acc = 0;
    int lo_bin = 0, hi_bin = HIST_BINS - 1;
    for (int b = 0; b < HIST_BINS; b++) {
        acc += hist[b];
        if (acc >= lo_target) {
            lo_bin = b;
            break;
        }
    }
    acc = 0;
    for (int b = 0; b < HIST_BINS; b++) {
        acc += hist[b];
        if (acc >= hi_target) {
            hi_bin = b;
            break;
        }
    }

    float bin_width = (hi - lo) / HIST_BINS;
    float robust_lo = lo + lo_bin * bin_width;
    float robust_hi = lo + (hi_bin + 1) * bin_width;
    if (robust_hi <= robust_lo) {
        robust_hi = robust_lo + 1e-3f;
    }
    *lo_out = robust_lo;
    *hi_out = robust_hi;
}

std::vector<uint8_t> MidasDepthEngine::post_process(const std::vector<float> &raw, int size, float percentile_clip) {
    std::lock_guard<std::mutex> lock(postprocess_mutex_);
    const int count = size * size;

    int64_t now = now_ns();
    float dt = last_post_process_time_ns_ == 0
                   ? DEPTH_TAU_SECONDS
                   : std::max(1.0f / 60.0f, std::min((now - last_post_process_time_ns_) / 1e9f, 1.0f));
    last_post_process_time_ns_ = now;

    float lo, hi;
    robust_range(raw, percentile_clip, &lo, &hi);
    if (!range_valid_) {
        smooth_lo_ = lo;
        smooth_hi_ = hi;
        range_valid_ = true;
    } else {
        float range_alpha = 1.0f - std::exp(-dt / RANGE_TAU_SECONDS);
        smooth_lo_ += range_alpha * (lo - smooth_lo_);
        smooth_hi_ += range_alpha * (hi - smooth_hi_);
    }
    float scale = 1.0f / std::max(smooth_hi_ - smooth_lo_, 1e-6f);

    std::vector<float> normalized(count);
    for (int i = 0; i < count; i++) {
        float v = (raw[i] - smooth_lo_) * scale;
        normalized[i] = std::max(0.0f, std::min(1.0f, v));
    }

    // temporalSmooth() ported inline - per-texel EMA at DEPTH_TAU_SECONDS,
    // same reasoning as DepthEstimator.java (a rate that never truly
    // reaches zero keeps denoising even on a fully static desktop).
    if (!smoothed_valid_ || static_cast<int>(smoothed_depth_.size()) != count) {
        smoothed_depth_ = normalized;
        smoothed_valid_ = true;
    } else {
        float depth_alpha = 1.0f - std::exp(-dt / DEPTH_TAU_SECONDS);
        for (int i = 0; i < count; i++) {
            smoothed_depth_[i] += depth_alpha * (normalized[i] - smoothed_depth_[i]);
        }
    }

    std::vector<uint8_t> depth_bytes(count);
    for (int i = 0; i < count; i++) {
        float v = std::max(0.0f, std::min(1.0f, smoothed_depth_[i]));
        depth_bytes[i] = static_cast<uint8_t>(v * 255.0f);
    }
    return depth_bytes;
}
