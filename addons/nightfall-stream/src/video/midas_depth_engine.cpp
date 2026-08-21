#include "midas_depth_engine.h"
#include "nf_log.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#include "tensorflow/lite/interpreter.h"
#include "tensorflow/lite/kernels/register.h"
#include "tensorflow/lite/model.h"

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

MidasDepthEngine::~MidasDepthEngine() {
    {
        std::lock_guard<std::mutex> lock(submit_mutex_);
        shutdown_ = true;
    }
    submit_cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

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

    bool ok_256 = load_model(model_256_, model_dir + "/midas-midas-v2-w8a8.tflite", "MiDaS-256", 256, 3, InputLayout::QuantizedNhWC);
    bool ok_192 = load_model(model_192_, model_dir + "/midas-v21-small-192-int8.tflite", "MiDaS-192", 192, 10, InputLayout::QuantizedNhWC);
    bool ok_yolo_256 = load_model(model_yolo_256_, model_dir + "/yolo26n-depth-256-w8a32.tflite", "YOLO26-N-256", 256, 7, InputLayout::FloatNchW, true, 0.10f);
    bool ok_yolo_320 = load_model(model_yolo_320_, model_dir + "/yolo26n-depth-320-w8a32.tflite", "YOLO26-N-320", 320, 8, InputLayout::FloatNchW, true, 0.10f);
    bool ok_yolo_384 = load_model(model_yolo_384_, model_dir + "/yolo26n-depth-384-w8a32.tflite", "YOLO26-N-384", 384, 4, InputLayout::FloatNchW, true, 0.10f);
    bool ok_da_196 = load_model(model_da_196_, model_dir + "/depth-anything-v2-small-196.tflite", "Depth Anything V2-196", 196, 11, InputLayout::FloatNhWC);
    bool ok_da_252 = load_model(model_da_252_, model_dir + "/depth-anything-v2-small-252.tflite", "Depth Anything V2-252", 252, 1, InputLayout::FloatNhWC);

    if (!ok_256 && !ok_192) {
        NF_LOGE(TAG, "No depth models could be loaded from %s - AI-3D depth unavailable", model_dir.c_str());
        return;
    }

    active_model_ = ok_256 ? &model_256_ : &model_192_;
    active_model_index_ = ok_256 ? 3 : 10;
    initialized_ = true;
    worker_ = std::thread(&MidasDepthEngine::worker_loop, this);
    NF_LOG(TAG, "Initialized (MiDaS-256=%s, MiDaS-192=%s, YOLO-256=%s, YOLO-320=%s, YOLO-384=%s, DA-196=%s, DA-252=%s)",
           ok_256 ? "true" : "false", ok_192 ? "true" : "false", ok_yolo_256 ? "true" : "false",
           ok_yolo_320 ? "true" : "false", ok_yolo_384 ? "true" : "false", ok_da_196 ? "true" : "false",
           ok_da_252 ? "true" : "false");
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
    if (!initialized_) return;

    DepthModel *target = model_for_index(model_index);
    if (!target) return;

    if (active_model_ == target) return;

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
    NF_LOG(TAG, "Switched to model %s", target->name.c_str());
}

int MidasDepthEngine::get_model_size() const {
    DepthModel *model = active_model_.load();
    if (!initialized_ || !model) return 256;
    return model->size;
}

void MidasDepthEngine::submit_frame(const uint8_t *rgba, size_t rgba_len, int width, int height) {
    if (!initialized_ || !active_model_) return;
    if (!rgba || width <= 0 || height <= 0) return;
    if (is_inferencing_.load()) return; // drop - matches Android's isInferencing.compareAndSet policy

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
        {
            std::unique_lock<std::mutex> lock(submit_mutex_);
            submit_cv_.wait(lock, [this] { return has_pending_ || shutdown_; });
            if (shutdown_) return;
            rgba = std::move(pending_rgba_);
            width = pending_width_;
            height = pending_height_;
            has_pending_ = false;
        }

        is_inferencing_.store(true);
        DepthModel *model = active_model_;
        if (model && model->loaded) {
            std::vector<float> raw = run_inference(*model, rgba.data(), width, height);
            if (!raw.empty()) {
                std::vector<uint8_t> depth = post_process(raw, model->size, model->percentile_clip);
                std::lock_guard<std::mutex> lock(result_mutex_);
                latest_result_ = std::move(depth);
                has_result_ = true;
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
