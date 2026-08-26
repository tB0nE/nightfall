#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#ifdef NIGHTFALL_PLATFORM_LINUX
#include <memory>
class MidasDepthEngine;
#endif

namespace godot {

class DepthBridge : public RefCounted {
    GDCLASS(DepthBridge, RefCounted);

public:
    enum DepthBackend {
        DEPTH_BACKEND_AUTO = 0,
        DEPTH_BACKEND_CPU = 1,
        DEPTH_BACKEND_GPU = 2,
    };

    enum DepthBackendCapability {
        DEPTH_BACKEND_CAP_CPU = 1,
        DEPTH_BACKEND_CAP_GPU = 2,
    };

    DepthBridge();
    ~DepthBridge();

    void submit_depth_frame(const PackedByteArray &frame_data, int width, int height);
    PackedByteArray get_depth_map();
    void set_depth_model(int model_index);
    void configure_depth(int model_index, int requested_backend);
    int get_depth_backend_capabilities(int model_index);
    int get_effective_depth_backend();
    String get_depth_backend_status();
    int get_depth_model_size();
    float get_depth_last_inference_ms();
    float get_depth_last_inference_hz();

protected:
    static void _bind_methods();

private:
    int selected_model_index_ = 3;
    int requested_backend_ = DEPTH_BACKEND_AUTO;
    int effective_backend_ = DEPTH_BACKEND_CPU;
    String backend_status_;
#ifdef NIGHTFALL_PLATFORM_LINUX
    // Native (JNI-free) depth engine - see midas_depth_engine.h.
    // Lazily constructed/initialized on first use (submit_depth_frame() or
    // set_depth_model()) rather than in the constructor, so a DepthBridge
    // that's never actually used for AI-3D never pays the model-load cost.
    std::unique_ptr<MidasDepthEngine> midas_engine_;
    void ensure_midas_engine();
#endif
};

} // namespace godot
