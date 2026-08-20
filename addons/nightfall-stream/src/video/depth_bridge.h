#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#ifdef NIGHTFALL_PLATFORM_LINUX
#include <memory>
class MidasDepthEngine;
#endif

namespace godot {

class DepthBridge : public RefCounted {
    GDCLASS(DepthBridge, RefCounted);

public:
    DepthBridge();
    ~DepthBridge();

    void submit_depth_frame(const PackedByteArray &frame_data, int width, int height);
    PackedByteArray get_depth_map();
    void set_depth_model(int model_index);
    int get_depth_model_size();

protected:
    static void _bind_methods();

private:
#ifdef NIGHTFALL_PLATFORM_LINUX
    // Native (JNI-free) MiDaS-only depth engine - see midas_depth_engine.h.
    // Lazily constructed/initialized on first use (submit_depth_frame() or
    // set_depth_model()) rather than in the constructor, so a DepthBridge
    // that's never actually used for AI-3D never pays the model-load cost.
    std::unique_ptr<MidasDepthEngine> midas_engine_;
    void ensure_midas_engine();
#endif
};

} // namespace godot
