#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

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
};

} // namespace godot
