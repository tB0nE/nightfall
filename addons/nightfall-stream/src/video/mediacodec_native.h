#pragma once

#ifdef __ANDROID__
#include <media/NdkMediaCodec.h>
#include <media/NdkImageReader.h>
#include <android/hardware_buffer.h>
#include <android/native_window.h>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <vector>

namespace godot {

struct NativeDecodedFrame {
    AHardwareBuffer *buffer = nullptr;
    int64_t pts = 0;
    int width = 0;
    int height = 0;
    bool rgba = false;
    bool external_texture = false;
    AImage *image = nullptr; // Owns the ImageReader slot until release_frame().
};

// Owns the asynchronous MediaCodec/ImageReader protocol. NDK callbacks only
// publish events; the decode thread remains the sole consumer of frames.
class AndroidMediaCodec {
public:
    using EventNotifier = std::function<void()>;

    enum class FeedResult {
        QUEUED,
        BACKPRESSURE,
        ERROR,
    };

    AndroidMediaCodec();
    ~AndroidMediaCodec();

    bool init(const char *mime, int width, int height, bool cpu_readback,
              ANativeWindow *external_output_window = nullptr,
              EventNotifier event_notifier = {});
    void shutdown();

    // Queues one compressed packet when an asynchronously supplied input index
    // is ready, distinguishing retryable backpressure from terminal failure.
    FeedResult feed_packet(const uint8_t *data, size_t size, int64_t pts);

    // Pops one callback-produced frame. This is a single-consumer interface;
    // timeout_us may be zero for a non-blocking drain.
    bool dequeue_frame(NativeDecodedFrame &out_frame, int64_t timeout_us = 5000);

    // Releases both the acquired ImageReader slot and the explicit AHB ref.
    void release_frame(NativeDecodedFrame &frame);

    // Stable IDs are available on Android API 31+ and enable import caching.
    bool is_import_cache_enabled() const { return buffer_cache_supported_.load(); }
    bool get_buffer_id(AHardwareBuffer *buffer, uint64_t &out_id) const;
    void take_removed_buffer_ids(std::vector<uint64_t> &out_ids);

    bool is_initialized() const { return codec_ != nullptr; }
    bool has_error() const { return async_error_.load() != AMEDIA_OK; }

private:
    struct OutputEvent {
        size_t index = 0;
        AMediaCodecBufferInfo info{};
        int width = 0;
        int height = 0;
        bool rendered = false;
    };

    static void _on_async_input_available(AMediaCodec *codec, void *userdata,
                                          int32_t index);
    static void _on_async_output_available(AMediaCodec *codec, void *userdata,
                                           int32_t index,
                                           AMediaCodecBufferInfo *info);
    static void _on_async_format_changed(AMediaCodec *codec, void *userdata,
                                         AMediaFormat *format);
    static void _on_async_error(AMediaCodec *codec, void *userdata,
                                media_status_t error, int32_t action_code,
                                const char *detail);
    static void _on_image_available(void *context, AImageReader *reader);
    static void _on_buffer_removed(void *context, AImageReader *reader,
                                   AHardwareBuffer *buffer);

    void _notify_event();
    void _release_frame_resources(NativeDecodedFrame &frame);
    void _reset_event_state();

    AMediaCodec *codec_ = nullptr;
    AImageReader *reader_ = nullptr;
    ANativeWindow *window_ = nullptr;
    std::atomic<int> width_{0};
    std::atomic<int> height_{0};
    bool reader_outputs_rgba_ = false;
    bool external_surface_output_ = false;
    bool owns_external_window_ = false;
    std::atomic<bool> started_{false};
    std::atomic<bool> eos_{false};
    std::atomic<bool> buffer_cache_supported_{false};

    // Serializes callback bodies, including the lightweight wakeup notifier,
    // with listener teardown so shutdown cannot return during a callback.
    std::mutex callback_mutex_;

    std::mutex event_mutex_;
    std::condition_variable event_cv_;
    std::deque<size_t> available_input_indices_;
    std::deque<OutputEvent> available_output_events_;
    OutputEvent pending_output_{};
    bool pending_output_valid_ = false;
    uint64_t image_event_generation_ = 0;
    bool stopping_ = true;
    std::atomic<media_status_t> async_error_{AMEDIA_OK};
    EventNotifier event_notifier_;

    std::mutex removed_buffers_mutex_;
    std::vector<uint64_t> removed_buffer_ids_;
};

} // namespace godot

#endif // __ANDROID__
