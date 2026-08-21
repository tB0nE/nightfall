#pragma once

#include "config/config_manager.h"
#include "config/computer_manager.h"
#include "video/depth_bridge.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/timer.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <atomic>

namespace godot {

class StreamConnection;
class FfmpegDecoder;
class TextureUploader;
class AudioRenderer;
class InputBridge;
class PipeWireCapture;
class DmaBufImporter;
class PipeWireAudio;
class X11Capture;

class NightfallStream : public Node {
    GDCLASS(NightfallStream, Node);

public:
    enum StreamState {
        STATE_IDLE = 0,
        STATE_CONNECTING = 1,
        STATE_CONNECTED = 2,
        STATE_DISCONNECTED = 3,
        STATE_RECONNECTING = 4,
        STATE_STOPPING = 5
    };

    NightfallStream();
    ~NightfallStream();

    void _ready() override;
    void _process(double delta) override;

    String get_version() const;
    int get_state() const;

    void start_stream(const String &host, const Dictionary &server_info, const Dictionary &stream_config, bool disable_hw = false);
    void stop_stream();

    int probe_video_format(int codec_preference, bool disable_hw);
    Dictionary probe_all_video_formats();
    int get_server_codec_mode_support() const;

    void set_auto_reconnect(bool enabled);
    bool get_auto_reconnect() const;
    void set_max_reconnect_attempts(int attempts);
    int get_max_reconnect_attempts() const;
    void set_reconnect_delay_ms(int ms);
    int get_reconnect_delay_ms() const;

    void set_local_capture_mode(bool enabled);
    bool get_local_capture_mode() const;
    Dictionary get_local_capture_region() const;
    void set_restore_token(const String &token);
    String get_restore_token() const;

    Ref<FfmpegDecoder> get_decoder() const;
    Ref<TextureUploader> get_texture_uploader() const;
    Ref<ShaderMaterial> get_shader_material() const;
    Ref<AudioRenderer> get_audio_renderer() const;
    Ref<InputBridge> get_input_bridge() const;
    Ref<DepthBridge> get_depth_bridge() const;

    int get_frames_dropped() const;
    int get_frames_decoded() const;
    int get_decode_queue_size() const;
    int get_last_frame_latency_us() const;
    bool is_display_ready() const;
    String get_codec_capabilities_info() const;

    String get_decoder_name() const;
    int get_video_width() const;
    int get_video_height() const;
    bool is_hw_decode() const;

    static String get_error_string(int error_code);

    Object *get_computer_manager() const;
    Object *get_config_manager() const;
    Object *get_stream_connection() const;

protected:
    static void _bind_methods();

private:
    void _on_pair_completed(bool success, const String &msg);
    void _on_stream_started();
    void _on_stream_terminated(int error_code, const String &error_message);
    void _on_stage_starting(const String &stage_name);
    void _on_stage_complete(const String &stage_name);
    void _on_stage_failed(const String &stage_name, int error_code);
    void _on_connection_status_update(int status);
    void _on_log_message(const String &message);
    void _on_h264_hw_upgraded();
    void _on_controller_rumble(int controller, int low_freq, int high_freq);
    void _on_controller_trigger_rumble(int controller, int left_motor, int right_motor);

    void _attempt_reconnect();
    void _reset_reconnect();
    void _do_reconnect();
    void _on_reconnect_timeout();

    StreamState state_ = STATE_IDLE;

    StreamConnection *stream_connection_ = nullptr;
    Ref<NightfallComputerManager> computer_manager_;
    Ref<NightfallConfigManager> config_manager_;
    HttpRequester *http_requester_ = nullptr;

    String last_host_;
    Dictionary last_server_info_;
    Dictionary last_stream_config_;
    bool last_disable_hw_ = false;

    bool auto_reconnect_ = true;
    int max_reconnect_attempts_ = 5;
    int reconnect_delay_ms_ = 2000;
    int reconnect_attempts_ = 0;
    Timer *reconnect_timer_ = nullptr;

    bool local_capture_mode_ = false;
    String restore_token_;

    PipeWireCapture *pipewire_capture_ = nullptr;
    DmaBufImporter *dmabuf_importer_ = nullptr;
    PipeWireAudio *pipewire_audio_ = nullptr;
    X11Capture *x11_capture_ = nullptr;

    double stage_progress_ = 0.0;
    String current_stage_;
};

} // namespace godot

VARIANT_ENUM_CAST(godot::NightfallStream::StreamState);
