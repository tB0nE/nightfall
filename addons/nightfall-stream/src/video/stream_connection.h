#pragma once

#include "video/decode_unit_queue.h"
#include "video/depth_bridge.h"
#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/classes/shader_material.hpp>
#include <atomic>
#include <string>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <vector>
#include <chrono>
#include <memory>
#include <deque>

extern "C" {
#include <Limelight.h>
#include <libavutil/pixfmt.h>
#include <libavutil/frame.h>
struct AVPacket;
struct AVFrame;
}

namespace godot {

class FfmpegDecoder;
class TextureUploader;
class AudioRenderer;
class InputBridge;
class RenderingDevice;
#ifdef __ANDROID__
class AndroidMediaCodec;
#endif

class StreamConnection : public Node {
    GDCLASS(StreamConnection, Node);

public:
    StreamConnection();
    ~StreamConnection();

    void start(const String &host, const Dictionary &server_info, const Dictionary &stream_config, bool disable_hw = false);
    void stop();
    bool is_streaming() const;
    int probe_video_format(int codec_preference, bool disable_hw);
    Dictionary probe_all_video_formats();
    int get_server_codec_mode_support() const;

    void set_local_capture_mode(bool enabled);
    bool get_local_capture_mode() const;

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

    String get_decoder_name() const;
    int get_video_width() const;
    int get_video_height() const;
    bool is_hw_decode() const;

    static String get_error_string(int error_code);

protected:
    static void _bind_methods();

private:
    static StreamConnection *active_instance_;

    static int _cb_decoder_setup(int videoFormat, int width, int height, int redrawRate, void *context, int drFlags);
    static void _cb_decoder_start();
    static void _cb_decoder_stop();
    static void _cb_decoder_cleanup();
    static int _cb_submit_decode_unit(PDECODE_UNIT decodeUnit);

    static void _cb_connection_started();
    static void _cb_connection_terminated(int errorCode);
    static void _cb_stage_starting(int stage);
    static void _cb_stage_complete(int stage);
    static void _cb_stage_failed(int stage, int errorCode);
    static void _cb_rumble(unsigned short controllerNumber, unsigned short lowFreqMotor, unsigned short highFreqMotor);
    static void _cb_connection_status_update(int connectionStatus);
    static void _cb_set_hdr_mode(bool hdrEnabled);
    static void _cb_rumble_triggers(uint16_t controllerNumber, uint16_t leftTriggerMotor, uint16_t rightTriggerMotor);
    static void _cb_set_motion_event_state(uint16_t controllerNumber, uint8_t motionType, uint16_t reportRateHz);
    static void _cb_set_controller_led(uint16_t controllerNumber, uint8_t r, uint8_t g, uint8_t b);
    static void _cb_log_message(const char *format, ...);

    void _connection_thread_func();
    void _decode_thread_func();
    void _clear_packet_queue();

    AVColorSpace _resolve_frame_colorspace(AVFrame *frame) const;

    static bool _extract_h264_sps_pps(const uint8_t *data, int size,
                                       uint8_t **sps, int *sps_size,
                                       uint8_t **pps, int *pps_size);
    static uint8_t *_build_avcc_extradata(const uint8_t *sps, int sps_size,
                                           const uint8_t *pps, int pps_size,
                                           int *out_size);
    void _try_h264_hw_upgrade();

    std::atomic<bool> is_streaming_{false};
    std::atomic<bool> decoder_ready_{false};

    uint8_t *h264_extradata_ = nullptr;
    int h264_extradata_size_ = 0;
    std::atomic<bool> h264_hw_upgrade_pending_{false};
    std::atomic<bool> h264_hw_upgraded_{false};

    Ref<FfmpegDecoder> decoder_;
    Ref<TextureUploader> uploader_;
    Ref<AudioRenderer> audio_renderer_;
    Ref<InputBridge> input_bridge_;
    Ref<DepthBridge> depth_bridge_;

    std::atomic<int> frames_dropped_{0};
    std::atomic<int> frames_decoded_{0};
    std::atomic<int> last_frame_latency_us_{0};
    std::atomic<int64_t> last_submit_time_us_{0};

    DecodeUnitQueue packet_queue_;
    mutable std::mutex queue_mutex_;
    std::condition_variable queue_cv_;
    std::thread decode_thread_;
    std::thread connection_thread_;

    String host_address_;
    std::string host_address_std_;
    std::string rtsp_url_std_;
    std::string app_version_std_;
    std::string gfe_version_std_;
    SERVER_INFORMATION server_info_{};
    STREAM_CONFIGURATION stream_config_{};

    int active_video_format_ = 0;
    AVColorSpace current_colorspace_ = AVCOL_SPC_BT709;
    AVColorRange current_color_range_ = AVCOL_RANGE_UNSPECIFIED;
    bool local_capture_mode_ = false;
#ifdef __ANDROID__
    struct CachedAhbImport {
        uint64_t buffer_id = 0;
        uint64_t generation = 0;
        RID texture;
        RID sampler;
        RID uniform_set;
        uint64_t owned_buffer_ptr = 0;
    };

    std::shared_ptr<AndroidMediaCodec> _get_native_codec() const;
    void _replace_native_codec(std::shared_ptr<AndroidMediaCodec> replacement);

    mutable std::mutex native_codec_mutex_;
    std::shared_ptr<AndroidMediaCodec> native_codec_;
    std::atomic<bool> native_codec_event_{false};

    // Compute pipeline for YCbCr → RGBA conversion
    RID compute_shader_;
    RID compute_pipeline_;
    RID dummy_sampler_;
    RID rgba_output_tex_;
    std::atomic<bool> compute_pipeline_ready_{false};
    // Set once per render generation, only after the FIRST successful compute
    // dispatch has written real video data into rgba_output_tex_ and that
    // result has actually been wired into the shader material's tex_y param
    // (see _render_compute_dispatch_rt). Before this flips true, the shader
    // material's tex_y - if set at all - is either unset or still pointing at
    // the previous (now torn-down) session's texture; GDScript's
    // bind_yuv_textures() polls is_display_ready() instead of trusting the
    // shader parameter's own RID validity, which stays "valid" even when it
    // wraps freed GPU memory.
    std::atomic<bool> display_wired_{false};
    int native_video_width_ = 0;
    int native_video_height_ = 0;
    int native_color_range_ = 0;
    int native_color_matrix_type_ = 0;

    void _ensure_compute_pipeline(RenderingDevice *rd, int width, int height,
                                  uint64_t generation);
    bool _get_or_create_ahb_import(RenderingDevice *rd, uint64_t buffer_ptr,
                                   uint64_t buffer_id, int width, int height,
                                   uint64_t generation);
    bool _retire_removed_ahb_imports(const std::vector<uint64_t> &buffer_ids);
    bool _retire_all_ahb_imports();
    void _render_compute_dispatch_rt();
    void _render_free_pipeline_rt();

    RID pending_free_pipeline_;
    RID pending_free_shader_;
    RID pending_free_sampler_;
    RID pending_free_tex_;
    // See _render_free_pipeline_rt(): the compute pipeline/shader/sampler/
    // output-texture retired by a stream restart can't be freed immediately
    // (confirmed UAF - the OpenXR compositor reads them on its own frame
    // timeline) but also shouldn't be orphaned forever (unbounded leak, one
    // full-resolution RGBA texture + pipeline per restart, visibly degrading
    // performance over a session with repeated codec/resolution/fps/bitrate
    // changes). Keep the last PIPELINE_FREE_DELAY_GENERATIONS retired
    // generations pending and only free the oldest once a newer one arrives -
    // each restart takes well over a second end to end, so this gives the
    // compositor multiple restart-cycles' worth of real slack.
    struct RetiredPipelineGeneration {
        RID pipeline;
        RID shader;
        RID sampler;
        RID tex;
    };
    std::deque<RetiredPipelineGeneration> pending_free_pipeline_generations_;
    static const int PIPELINE_FREE_DELAY_GENERATIONS = 2;

    std::atomic<uint64_t> render_generation_{1};
    std::mutex render_state_mutex_;
    uint64_t pending_buffer_id_ = 0;
    uint64_t pending_generation_ = 0;
    RID pending_uncached_texture_;
    RID pending_uncached_sampler_;
    uint64_t pending_uncached_buffer_ptr_ = 0;
    int pending_width_ = 0, pending_height_ = 0;
    bool pending_dispatch_cached_ = false;
    bool pending_dispatch_ready_ = false;
    std::mutex pending_mutex_;

    std::vector<CachedAhbImport> ahb_import_cache_;
    std::vector<CachedAhbImport> pending_free_ahb_imports_;
    uint64_t ahb_cache_hits_ = 0;
    uint64_t ahb_cache_misses_ = 0;
    std::mutex ahb_cache_mutex_;
#endif
};

} // namespace godot
