#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include "opus_decoder.h"
#include "platform_audio.h"
#include <memory>
#include <atomic>

extern "C" {
#include <Limelight.h>
}

namespace godot {

class AudioRenderer : public RefCounted {
    GDCLASS(AudioRenderer, RefCounted);

public:
    AudioRenderer();
    ~AudioRenderer();

    int init(int audio_configuration, const POPUS_MULTISTREAM_CONFIGURATION opus_config, void *context, int ar_flags);
    void start();
    void stop();
    void cleanup();
    void decode_and_play_sample(const char *sample_data, int sample_length);
    void play_local_pcm(const float *data, size_t frames);
    void set_muted(bool muted);
    bool is_muted() const;
    void set_volume_boost_db(float db);
    float get_volume_boost_db() const;

    bool is_initialized() const;
    int get_channels() const;
    int get_sample_rate() const;
    float get_latency_ms() const;
    String get_backend_name() const;

protected:
    static void _bind_methods();

private:
    void _downmix_to_stereo(const float *multi, float *stereo);
    void _apply_volume_boost(float *samples, int count) const;

    static AudioRenderer *active_instance_;
    friend class StreamConnection;

    static int _cb_init(int audioConfiguration, const POPUS_MULTISTREAM_CONFIGURATION opusConfig, void *context, int arFlags);
    static void _cb_start();
    static void _cb_stop();
    static void _cb_cleanup();
    static void _cb_decode_and_play_sample(char *sampleData, int sampleLength);

    Ref<OpusDecoderWrapper> opus_decoder_;
    std::unique_ptr<nightfall::PlatformAudio> audio_backend_;
    PackedByteArray opus_data_buf_;

    int audio_configuration_ = 0;
    int channels_ = 0;
    int sample_rate_ = 48000;
    int samples_per_frame_ = 240;
    unsigned char channel_mapping_[8] = {};

    std::atomic<bool> initialized_{false};
    std::atomic<bool> running_{false};
    std::atomic<bool> muted_{false};
    std::atomic<float> volume_boost_db_{0.0f};
    std::atomic<float> volume_gain_{1.0f};
};

} // namespace godot
