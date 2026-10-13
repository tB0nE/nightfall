#pragma once
#ifdef __ANDROID__
#include "platform_audio.h"
#include <jni.h>

namespace nightfall {
void log_audio_diagnostic(const char *message);
class AndroidAudioBackend final : public PlatformAudio {
public:
    ~AndroidAudioBackend() override { shutdown(); }
    bool initialize(int rate, int channels, int period) override;
    void shutdown() override;
    bool write_pcm(const float *data, size_t frames) override;
    void pause() override;
    void resume() override;
    int get_latency_ms() const override;
    std::string get_backend_name() const override { return "AudioTrack/PCM16/USAGE_GAME"; }
private:
    jmethodID open_ = nullptr, write_ = nullptr, close_ = nullptr, pause_ = nullptr, resume_ = nullptr, latency_ = nullptr;
    jfloatArray samples_ = nullptr;
    int capacity_ = 0, channels_ = 2;
    bool initialized_ = false;
};
}
#endif
