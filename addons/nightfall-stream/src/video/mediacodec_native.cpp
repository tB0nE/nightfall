#include "mediacodec_native.h"

#ifdef __ANDROID__
#include "nf_log.h"
#include <chrono>
#include <cstring>
#include <dlfcn.h>
#include <utility>

namespace godot {

namespace {
using AHardwareBufferGetIdFn = int (*)(const AHardwareBuffer *, uint64_t *);

AHardwareBufferGetIdFn get_hardware_buffer_id_fn() {
    static auto fn = reinterpret_cast<AHardwareBufferGetIdFn>(
        dlsym(RTLD_DEFAULT, "AHardwareBuffer_getId"));
    return fn;
}

bool query_hardware_buffer_id(AHardwareBuffer *buffer, uint64_t &out_id) {
    auto fn = get_hardware_buffer_id_fn();
    return buffer && fn && fn(buffer, &out_id) == 0 && out_id != 0;
}
} // namespace

AndroidMediaCodec::AndroidMediaCodec() = default;

AndroidMediaCodec::~AndroidMediaCodec() {
    shutdown();
}

void AndroidMediaCodec::_reset_event_state() {
    std::lock_guard<std::mutex> lock(event_mutex_);
    available_input_indices_.clear();
    available_output_events_.clear();
    pending_output_ = OutputEvent{};
    pending_output_valid_ = false;
    image_event_generation_ = 0;
    stopping_ = false;
    async_error_ = AMEDIA_OK;
}

bool AndroidMediaCodec::init(const char *mime, int width, int height,
                             EventNotifier event_notifier) {
    shutdown();

    width_.store(width);
    height_.store(height);
    eos_.store(false);
    buffer_cache_supported_.store(false);
    {
        std::lock_guard<std::mutex> lock(event_mutex_);
        event_notifier_ = std::move(event_notifier);
    }
    _reset_event_state();

    // Create ImageReader with GPU sampling usage for direct Vulkan import.
    media_status_t status = AImageReader_newWithUsage(
        width, height, AIMAGE_FORMAT_YUV_420_888,
        AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE |
            AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN |
            AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN,
        4, &reader_);
    if (status != AMEDIA_OK || !reader_) {
        NF_LOGE("AndroidMediaCodec", "AImageReader_newWithUsage failed: %d", status);
        shutdown();
        return false;
    }

    AImageReader_ImageListener image_listener{};
    image_listener.context = this;
    image_listener.onImageAvailable = &AndroidMediaCodec::_on_image_available;
    status = AImageReader_setImageListener(reader_, &image_listener);
    if (status != AMEDIA_OK) {
        NF_LOGE("AndroidMediaCodec", "AImageReader_setImageListener failed: %d", status);
        shutdown();
        return false;
    }

    AImageReader_BufferRemovedListener buffer_listener{};
    buffer_listener.context = this;
    buffer_listener.onBufferRemoved = &AndroidMediaCodec::_on_buffer_removed;
    status = AImageReader_setBufferRemovedListener(reader_, &buffer_listener);
    if (status == AMEDIA_OK) {
        buffer_cache_supported_.store(true);
        NF_LOG("AndroidMediaCodec", "AHardwareBuffer import cache enabled (%s keys)",
               get_hardware_buffer_id_fn() ? "stable ID" : "opaque handle");
    } else {
        // Decoding remains available with the original per-frame import path.
        NF_LOGE("AndroidMediaCodec", "AHardwareBuffer import cache disabled; buffer listener failed: %d", status);
    }

    status = AImageReader_getWindow(reader_, &window_);
    if (status != AMEDIA_OK || !window_) {
        NF_LOGE("AndroidMediaCodec", "AImageReader_getWindow failed: %d", status);
        shutdown();
        return false;
    }

    codec_ = AMediaCodec_createDecoderByType(mime);
    if (!codec_) {
        NF_LOGE("AndroidMediaCodec", "AMediaCodec_createDecoderByType failed for %s", mime);
        shutdown();
        return false;
    }

    AMediaCodecOnAsyncNotifyCallback callbacks{};
    callbacks.onAsyncInputAvailable = &AndroidMediaCodec::_on_async_input_available;
    callbacks.onAsyncOutputAvailable = &AndroidMediaCodec::_on_async_output_available;
    callbacks.onAsyncFormatChanged = &AndroidMediaCodec::_on_async_format_changed;
    callbacks.onAsyncError = &AndroidMediaCodec::_on_async_error;
    status = AMediaCodec_setAsyncNotifyCallback(codec_, callbacks, this);
    if (status != AMEDIA_OK) {
        NF_LOGE("AndroidMediaCodec", "AMediaCodec_setAsyncNotifyCallback failed: %d", status);
        shutdown();
        return false;
    }

    AMediaFormat *format = AMediaFormat_new();
    AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, width);
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, height);
    // This is a max COMPRESSED input buffer size, not a raw frame size - width*height
    // (1 byte/pixel) is a tight budget for a single frame, and codec-agnostic code
    // like this doesn't account for H264 needing more bits than HEVC to hit the same
    // quality at the same bitrate, so a large H264 keyframe is more likely to exceed
    // it than an equivalent HEVC one at the identical resolution. feed_packet() below
    // silently drops (returns FeedResult::ERROR for) any packet too big for the
    // buffer AMediaCodec_getInputBuffer() actually hands back, with no retry/recovery
    // - repeatedly losing keyframes this way would look exactly like the codec-specific
    // stalls seen testing H264 at resolutions where HEVC (smaller compressed frames at
    // the same target bitrate) was fine. Untested hypothesis as of 2026-08-07; widen the
    // budget well past a bare per-pixel guess and confirm live whether this was the
    // real cause before assuming the earlier "H264 axis limit" conclusion was right.
    AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_MAX_INPUT_SIZE, width * height * 3);

    status = AMediaCodec_configure(codec_, format, window_, nullptr, 0);
    AMediaFormat_delete(format);
    if (status != AMEDIA_OK) {
        NF_LOGE("AndroidMediaCodec", "AMediaCodec_configure failed: %d", status);
        shutdown();
        return false;
    }

    // Input callbacks may be delivered as AMediaCodec_start() completes.
    started_.store(true);
    status = AMediaCodec_start(codec_);
    if (status != AMEDIA_OK) {
        started_.store(false);
        NF_LOGE("AndroidMediaCodec", "AMediaCodec_start failed: %d", status);
        shutdown();
        return false;
    }

    NF_LOG("AndroidMediaCodec", "Initialized async codec: %dx%d mime=%s", width, height, mime);
    return true;
}

void AndroidMediaCodec::shutdown() {
    const bool was_started = started_.exchange(false);
    buffer_cache_supported_.store(false);
    {
        std::lock_guard<std::mutex> lock(event_mutex_);
        stopping_ = true;
    }
    event_cv_.notify_all();
    _notify_event();

    // Unregister native callbacks before destroying their context. The NDK
    // guarantees codec callbacks are not delivered after unregistration.
    if (codec_) {
        AMediaCodecOnAsyncNotifyCallback callbacks{};
        AMediaCodec_setAsyncNotifyCallback(codec_, callbacks, nullptr);
    }
    if (reader_) {
        AImageReader_setImageListener(reader_, nullptr);
        AImageReader_setBufferRemovedListener(reader_, nullptr);
    }

    // Wait for a callback that entered immediately before unregistration.
    {
        std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    }

    if (codec_) {
        if (was_started) {
            AMediaCodec_stop(codec_);
        }
        AMediaCodec_delete(codec_);
        codec_ = nullptr;
    }

    // AImageReader owns the ANativeWindow returned by getWindow().
    window_ = nullptr;
    if (reader_) {
        AImageReader_delete(reader_);
        reader_ = nullptr;
    }

    {
        std::lock_guard<std::mutex> lock(event_mutex_);
        available_input_indices_.clear();
        available_output_events_.clear();
        pending_output_ = OutputEvent{};
        pending_output_valid_ = false;
        event_notifier_ = {};
    }
    {
        std::lock_guard<std::mutex> lock(removed_buffers_mutex_);
        removed_buffer_ids_.clear();
    }
    eos_.store(false);
}

void AndroidMediaCodec::_notify_event() {
    EventNotifier notifier;
    {
        std::lock_guard<std::mutex> lock(event_mutex_);
        notifier = event_notifier_;
    }
    event_cv_.notify_all();
    if (notifier) notifier();
}

void AndroidMediaCodec::_on_async_input_available(AMediaCodec *, void *userdata,
                                                   int32_t index) {
    auto *self = static_cast<AndroidMediaCodec *>(userdata);
    if (!self) return;

    std::lock_guard<std::mutex> callback_lock(self->callback_mutex_);
    if (!self->started_.load()) return;
    {
        std::lock_guard<std::mutex> lock(self->event_mutex_);
        if (self->stopping_) return;
        self->available_input_indices_.push_back((size_t)index);
    }
    self->_notify_event();
}

void AndroidMediaCodec::_on_async_output_available(AMediaCodec *, void *userdata,
                                                    int32_t index,
                                                    AMediaCodecBufferInfo *info) {
    auto *self = static_cast<AndroidMediaCodec *>(userdata);
    if (!self || !info) return;

    std::lock_guard<std::mutex> callback_lock(self->callback_mutex_);
    if (!self->started_.load()) return;
    {
        std::lock_guard<std::mutex> lock(self->event_mutex_);
        if (self->stopping_) return;

        OutputEvent event;
        event.index = (size_t)index;
        event.info = *info;
        event.width = self->width_.load();
        event.height = self->height_.load();
        self->available_output_events_.push_back(event);
    }
    self->_notify_event();
}

void AndroidMediaCodec::_on_async_format_changed(AMediaCodec *, void *userdata,
                                                  AMediaFormat *format) {
    auto *self = static_cast<AndroidMediaCodec *>(userdata);
    if (!self || !format) return;

    int32_t width = 0;
    int32_t height = 0;
    std::lock_guard<std::mutex> callback_lock(self->callback_mutex_);
    if (!self->started_.load()) return;
    AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_WIDTH, &width);
    AMediaFormat_getInt32(format, AMEDIAFORMAT_KEY_HEIGHT, &height);
    if (width > 0) self->width_.store(width);
    if (height > 0) self->height_.store(height);
    NF_LOG("AndroidMediaCodec", "Output format changed: %dx%d",
           self->width_.load(), self->height_.load());
    self->_notify_event();
}

void AndroidMediaCodec::_on_async_error(AMediaCodec *, void *userdata,
                                         media_status_t error,
                                         int32_t action_code,
                                         const char *detail) {
    auto *self = static_cast<AndroidMediaCodec *>(userdata);
    if (!self) return;

    std::lock_guard<std::mutex> callback_lock(self->callback_mutex_);
    {
        std::lock_guard<std::mutex> lock(self->event_mutex_);
        self->async_error_ = error;
    }
    NF_LOGE("AndroidMediaCodec", "Async codec error=%d action=%d detail=%s",
            error, action_code, detail ? detail : "");
    self->_notify_event();
}

void AndroidMediaCodec::_on_image_available(void *context, AImageReader *) {
    auto *self = static_cast<AndroidMediaCodec *>(context);
    if (!self) return;

    std::lock_guard<std::mutex> callback_lock(self->callback_mutex_);
    if (!self->started_.load()) return;
    {
        std::lock_guard<std::mutex> lock(self->event_mutex_);
        if (self->stopping_) return;
        ++self->image_event_generation_;
    }
    self->_notify_event();
}

bool AndroidMediaCodec::get_buffer_id(AHardwareBuffer *buffer, uint64_t &out_id) const {
    return buffer_cache_supported_.load() && query_hardware_buffer_id(buffer, out_id);
}

void AndroidMediaCodec::take_removed_buffer_ids(std::vector<uint64_t> &out_ids) {
    std::lock_guard<std::mutex> lock(removed_buffers_mutex_);
    out_ids.swap(removed_buffer_ids_);
}

void AndroidMediaCodec::_on_buffer_removed(void *context, AImageReader *,
                                            AHardwareBuffer *buffer) {
    auto *self = static_cast<AndroidMediaCodec *>(context);
    if (!self) return;

    std::lock_guard<std::mutex> callback_lock(self->callback_mutex_);
    if (!self->buffer_cache_supported_.load()) return;

    uint64_t buffer_id = 0;
    if (!query_hardware_buffer_id(buffer, buffer_id)) {
        // API 26-30 have removal callbacks but no documented stable ID API.
        // Retained imported memory keeps this opaque handle alive, so use the
        // same best-effort identity as the decode path on those releases.
        buffer_id = (uint64_t)buffer;
    }

    std::lock_guard<std::mutex> lock(self->removed_buffers_mutex_);
    self->removed_buffer_ids_.push_back(buffer_id);
}

AndroidMediaCodec::FeedResult AndroidMediaCodec::feed_packet(
        const uint8_t *data, size_t size, int64_t pts) {
    if (!data || size == 0 || !started_.load() || !codec_) {
        return FeedResult::ERROR;
    }

    size_t index = 0;
    {
        std::lock_guard<std::mutex> lock(event_mutex_);
        if (stopping_ || async_error_ != AMEDIA_OK || !started_.load()) {
            return FeedResult::ERROR;
        }
        if (available_input_indices_.empty()) {
            return FeedResult::BACKPRESSURE;
        }
        index = available_input_indices_.front();
        available_input_indices_.pop_front();
    }

    size_t buffer_size = 0;
    uint8_t *buffer = AMediaCodec_getInputBuffer(codec_, index, &buffer_size);
    if (!buffer || buffer_size < size) {
        static int fail_count = 0;
        if (++fail_count <= 3) {
            NF_LOGE("AndroidMediaCodec", "getInputBuffer failed: buf=%p size=%zu needed=%zu",
                    (void *)buffer, buffer_size, size);
        }
        // Return the callback-owned index to the codec instead of stranding it.
        media_status_t return_status = AMediaCodec_queueInputBuffer(
            codec_, index, 0, 0, (uint64_t)pts, 0);
        if (return_status != AMEDIA_OK) {
            NF_LOGE("AndroidMediaCodec", "Failed to return unusable input buffer: %d",
                    return_status);
        }
        return FeedResult::ERROR;
    }

    memcpy(buffer, data, size);
    media_status_t status = AMediaCodec_queueInputBuffer(
        codec_, index, 0, size, (uint64_t)pts, 0);
    if (status != AMEDIA_OK) {
        static int fail_count = 0;
        if (++fail_count <= 3) {
            NF_LOGE("AndroidMediaCodec", "queueInputBuffer failed: %d", status);
        }
        return FeedResult::ERROR;
    }
    return FeedResult::QUEUED;
}

bool AndroidMediaCodec::dequeue_frame(NativeDecodedFrame &out_frame,
                                       int64_t timeout_us) {
    if (!started_.load() || !codec_ || !reader_) return false;

    const auto timeout = std::chrono::microseconds(timeout_us > 0 ? timeout_us : 0);
    const auto deadline = std::chrono::steady_clock::now() + timeout;

    {
        std::unique_lock<std::mutex> lock(event_mutex_);
        if (!pending_output_valid_) {
            auto ready = [this] {
                return !available_output_events_.empty() || stopping_ ||
                       async_error_ != AMEDIA_OK || !started_.load();
            };
            if (!ready()) {
                if (timeout_us <= 0 || !event_cv_.wait_until(lock, deadline, ready)) {
                    return false;
                }
            }
            if (stopping_ || async_error_ != AMEDIA_OK || !started_.load() ||
                available_output_events_.empty()) {
                return false;
            }
            pending_output_ = available_output_events_.front();
            available_output_events_.pop_front();
            pending_output_valid_ = true;
        }
    }

    if (pending_output_.info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM) {
        media_status_t status = AMediaCodec_releaseOutputBuffer(
            codec_, pending_output_.index, false);
        if (status != AMEDIA_OK) {
            NF_LOGE("AndroidMediaCodec", "release EOS output failed: %d", status);
        }
        {
            std::lock_guard<std::mutex> lock(event_mutex_);
            pending_output_ = OutputEvent{};
            pending_output_valid_ = false;
        }
        eos_.store(true);
        return false;
    }

    if (!pending_output_.rendered) {
        media_status_t status = AMediaCodec_releaseOutputBuffer(
            codec_, pending_output_.index, true);
        if (status != AMEDIA_OK) {
            NF_LOGE("AndroidMediaCodec", "releaseOutputBuffer failed: %d", status);
            std::lock_guard<std::mutex> lock(event_mutex_);
            pending_output_ = OutputEvent{};
            pending_output_valid_ = false;
            return false;
        }
        pending_output_.rendered = true;
    }

    AImage *image = nullptr;
    while (started_.load()) {
        uint64_t observed_generation = 0;
        {
            std::lock_guard<std::mutex> lock(event_mutex_);
            observed_generation = image_event_generation_;
        }

        media_status_t status = AImageReader_acquireLatestImage(reader_, &image);
        if (status == AMEDIA_OK && image) break;
        if (status != AMEDIA_IMGREADER_NO_BUFFER_AVAILABLE) {
            static int image_fail_count = 0;
            if (++image_fail_count <= 3) {
                NF_LOGE("AndroidMediaCodec", "acquireLatestImage failed: %d", status);
            }
            return false;
        }

        if (timeout_us <= 0) return false;
        std::unique_lock<std::mutex> lock(event_mutex_);
        bool signaled = event_cv_.wait_until(lock, deadline, [this, observed_generation] {
            return image_event_generation_ != observed_generation || stopping_ ||
                   async_error_ != AMEDIA_OK || !started_.load();
        });
        if (!signaled || stopping_ || async_error_ != AMEDIA_OK || !started_.load()) {
            return false;
        }
    }

    if (!image) return false;

    AHardwareBuffer *buffer = nullptr;
    media_status_t status = AImage_getHardwareBuffer(image, &buffer);
    if (status != AMEDIA_OK || !buffer) {
        static int ahb_fail_count = 0;
        if (++ahb_fail_count <= 3) {
            NF_LOGE("AndroidMediaCodec", "AImage_getHardwareBuffer failed: %d", status);
        }
        AImage_delete(image);
        std::lock_guard<std::mutex> lock(event_mutex_);
        pending_output_ = OutputEvent{};
        pending_output_valid_ = false;
        return false;
    }

    AHardwareBuffer_acquire(buffer);
    out_frame.buffer = buffer;
    out_frame.pts = pending_output_.info.presentationTimeUs;
    out_frame.width = pending_output_.width;
    out_frame.height = pending_output_.height;
    out_frame.image = image;

    {
        std::lock_guard<std::mutex> lock(event_mutex_);
        pending_output_ = OutputEvent{};
        pending_output_valid_ = false;
    }

    static int frame_count = 0;
    if (++frame_count <= 5 || frame_count % 60 == 0) {
        NF_LOG("AndroidMediaCodec", "Frame ready: %dx%d pts=%lld buf=%p",
               out_frame.width, out_frame.height, (long long)out_frame.pts,
               (void *)buffer);
    }
    return true;
}

void AndroidMediaCodec::_release_frame_resources(NativeDecodedFrame &frame) {
    if (frame.image) {
        AImage_delete(frame.image);
        frame.image = nullptr;
    }
    if (frame.buffer) {
        AHardwareBuffer_release(frame.buffer);
        frame.buffer = nullptr;
    }
}

void AndroidMediaCodec::release_frame(NativeDecodedFrame &frame) {
    _release_frame_resources(frame);
}

} // namespace godot

#endif // __ANDROID__
