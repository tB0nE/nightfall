// In-process FFmpeg adapter. Public AV* layouts stay behind this C ABI.
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}
#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace {
void *open_library(const std::string &name) {
#ifdef _WIN32
    return reinterpret_cast<void *>(LoadLibraryA(name.c_str()));
#else
    return dlopen(name.c_str(), RTLD_NOW | RTLD_LOCAL);
#endif
}
void close_library(void *lib) {
    if (!lib) return;
#ifdef _WIN32
    FreeLibrary(static_cast<HMODULE>(lib));
#else
    dlclose(lib);
#endif
}
template<class T> T symbol(void *lib, const char *name) {
#ifdef _WIN32
    auto address = GetProcAddress(static_cast<HMODULE>(lib), name);
#else
    auto address = dlsym(lib, name);
#endif
    if (!address) throw std::runtime_error(std::string("Missing FFmpeg symbol: ") + name);
    return reinterpret_cast<T>(address);
}
void error_text(char *out, size_t size, const std::string &message) {
    if (out && size) std::snprintf(out, size, "%s", message.c_str());
}

struct Api {
    void *codec = nullptr, *util = nullptr, *scale = nullptr;
#define FUNCTION(name) decltype(&name) name##_fn = nullptr
    FUNCTION(avcodec_version); FUNCTION(avutil_version); FUNCTION(swscale_version);
    FUNCTION(avcodec_find_decoder); FUNCTION(avcodec_find_decoder_by_name);
    FUNCTION(avcodec_alloc_context3); FUNCTION(avcodec_free_context);
    FUNCTION(avcodec_open2); FUNCTION(avcodec_send_packet); FUNCTION(avcodec_receive_frame);
    FUNCTION(avcodec_get_hw_config); FUNCTION(av_packet_alloc); FUNCTION(av_packet_free);
    FUNCTION(av_new_packet); FUNCTION(av_frame_alloc); FUNCTION(av_frame_free);
    FUNCTION(av_frame_unref); FUNCTION(av_frame_apply_cropping);
    FUNCTION(av_hwdevice_ctx_create); FUNCTION(av_hwframe_transfer_data);
    FUNCTION(av_buffer_ref); FUNCTION(av_buffer_unref); FUNCTION(av_strerror);
    FUNCTION(av_pix_fmt_desc_get);
    FUNCTION(sws_getContext); FUNCTION(sws_scale); FUNCTION(sws_freeContext);
#undef FUNCTION
    ~Api() { close_library(scale); close_library(codec); close_library(util); }
    std::string failure(const char *what, int code) {
        char text[AV_ERROR_MAX_STRING_SIZE]{};
        av_strerror_fn(code, text, sizeof(text));
        return std::string(what) + ": " + text;
    }
};

struct Decoder {
    Api *api;
    AVCodecContext *context = nullptr;
    AVFrame *frame = nullptr, *download = nullptr;
    AVBufferRef *hardware = nullptr;
    AVPixelFormat hardware_format = AV_PIX_FMT_NONE;
    SwsContext *scaler = nullptr;
    int last_w = 0, last_h = 0, last_format = -1;
    std::vector<uint8_t> nv12;
    explicit Decoder(Api *value): api(value) {}
    ~Decoder() {
        if (scaler) api->sws_freeContext_fn(scaler);
        api->av_frame_free_fn(&frame); api->av_frame_free_fn(&download);
        api->avcodec_free_context_fn(&context); api->av_buffer_unref_fn(&hardware);
    }
    static AVPixelFormat format(AVCodecContext *ctx, const AVPixelFormat *formats) {
        auto *self = static_cast<Decoder *>(ctx->opaque);
        for (; *formats != AV_PIX_FMT_NONE; ++formats) {
            if (self->hardware_format != AV_PIX_FMT_NONE) {
                if (*formats == self->hardware_format) return *formats;
            } else {
                auto *description=self->api->av_pix_fmt_desc_get_fn(*formats);
                if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *formats;
            }
        }
        // Explicit hardware mode must not silently become software decoding.
        return AV_PIX_FMT_NONE;
    }
};
}

extern "C" void *meteor_video_api(const char *directory, char *error, size_t size) {
    try {
        auto api = std::make_unique<Api>();
        auto path = [&](const char *name) { return directory && *directory ? std::string(directory) + "/" + name : name; };
#ifdef _WIN32
        api->util = open_library(path("avutil-60.dll"));
        api->codec = open_library(path("avcodec-62.dll"));
        api->scale = open_library(path("swscale-9.dll"));
#else
        api->util = open_library(path("libavutil.so.60"));
        api->codec = open_library(path("libavcodec.so.62"));
        api->scale = open_library(path("libswscale.so.9"));
#endif
        if (!api->codec || !api->util || !api->scale)
            throw std::runtime_error("FFmpeg 8 runtime required: avcodec 62, avutil 60, swscale 9");
#define LOAD(lib, name) api->name##_fn = symbol<decltype(&name)>(api->lib, #name)
        LOAD(codec, avcodec_version); LOAD(util, avutil_version); LOAD(scale, swscale_version);
        if ((api->avcodec_version_fn() >> 16) != 62 || (api->avutil_version_fn() >> 16) != 60 || (api->swscale_version_fn() >> 16) != 9)
            throw std::runtime_error("Unsupported FFmpeg runtime ABI");
        LOAD(codec, avcodec_find_decoder); LOAD(codec, avcodec_find_decoder_by_name);
        LOAD(codec, avcodec_alloc_context3); LOAD(codec, avcodec_free_context);
        LOAD(codec, avcodec_open2); LOAD(codec, avcodec_send_packet); LOAD(codec, avcodec_receive_frame);
        LOAD(codec, avcodec_get_hw_config); LOAD(codec, av_packet_alloc); LOAD(codec, av_packet_free); LOAD(codec, av_new_packet);
        LOAD(util, av_frame_alloc); LOAD(util, av_frame_free); LOAD(util, av_frame_unref); LOAD(util, av_frame_apply_cropping);
        LOAD(util, av_hwdevice_ctx_create); LOAD(util, av_hwframe_transfer_data);
        LOAD(util, av_buffer_ref); LOAD(util, av_buffer_unref); LOAD(util, av_strerror);
        LOAD(util, av_pix_fmt_desc_get);
        LOAD(scale, sws_getContext); LOAD(scale, sws_scale); LOAD(scale, sws_freeContext);
#undef LOAD
        return api.release();
    } catch (const std::exception &e) { error_text(error, size, e.what()); return nullptr; }
}

extern "C" void *meteor_video_create(void *runtime, int codec_id, bool vaapi, const char *device, char *error, size_t size) {
    try {
        auto *api = static_cast<Api *>(runtime);
        auto self = std::make_unique<Decoder>(api);
        AVCodecID id = codec_id == 0 ? AV_CODEC_ID_H264 : codec_id == 1 ? AV_CODEC_ID_HEVC : AV_CODEC_ID_AV1;
        const AVCodec *codec = id == AV_CODEC_ID_AV1 ? api->avcodec_find_decoder_by_name_fn(vaapi ? "av1" : "libdav1d") : nullptr;
        if (!codec) codec = api->avcodec_find_decoder_fn(id);
        if (!codec) throw std::runtime_error("FFmpeg decoder not available for this codec");
        self->context = api->avcodec_alloc_context3_fn(codec);
        self->frame = api->av_frame_alloc_fn(); self->download = api->av_frame_alloc_fn();
        if (!self->context || !self->frame || !self->download) throw std::bad_alloc();
        self->context->thread_count = 4;
        self->context->thread_type = FF_THREAD_SLICE; // No frame-thread lookahead.
        self->context->max_pixels = 8192LL * 8192LL;
        self->context->opaque = self.get(); self->context->get_format = Decoder::format;
        if (vaapi) {
            for (int i = 0; const auto *config = api->avcodec_get_hw_config_fn(codec, i); ++i)
                if (config->device_type == AV_HWDEVICE_TYPE_VAAPI && (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX))
                    self->hardware_format = config->pix_fmt;
            if (self->hardware_format == AV_PIX_FMT_NONE) throw std::runtime_error("Codec has no VAAPI decode path");
            int rc = api->av_hwdevice_ctx_create_fn(&self->hardware, AV_HWDEVICE_TYPE_VAAPI, device && *device ? device : nullptr, nullptr, 0);
            if (rc < 0) throw std::runtime_error(api->failure("VAAPI device", rc));
            self->context->hw_device_ctx = api->av_buffer_ref_fn(self->hardware);
        }
        int rc = api->avcodec_open2_fn(self->context, codec, nullptr);
        if (rc < 0) throw std::runtime_error(api->failure("Open decoder", rc));
        return self.release();
    } catch (const std::exception &e) { error_text(error, size, e.what()); return nullptr; }
}

extern "C" int meteor_video_send(void *handle, const uint8_t *bytes, size_t length, int64_t id, char *error, size_t size) {
    auto *self = static_cast<Decoder *>(handle); auto *api = self->api;
    if (length > 32 * 1024 * 1024) { error_text(error, size, "Video packet exceeds 32 MiB"); return -1; }
    AVPacket *packet = nullptr;
    if (bytes) {
        packet = api->av_packet_alloc_fn();
        if (!packet) { error_text(error, size, "Packet allocation failed"); return -1; }
        int rc = api->av_new_packet_fn(packet, static_cast<int>(length));
        if (rc < 0) { api->av_packet_free_fn(&packet); error_text(error, size, api->failure("Packet allocation", rc)); return -1; }
        std::memcpy(packet->data, bytes, length); packet->pts = id;
    }
    int rc = api->avcodec_send_packet_fn(self->context, packet);
    api->av_packet_free_fn(&packet);
    if (rc == AVERROR(EAGAIN)) return 0;
    if (rc < 0) { error_text(error, size, api->failure("Decode packet", rc)); return -1; }
    return 1;
}

struct MeteorVideoFrame { const uint8_t *data; size_t length; int64_t id; uint32_t width, height, matrix, full_range; };
extern "C" int meteor_video_receive(void *handle, bool pixels, MeteorVideoFrame *out, char *error, size_t size) {
    auto *self = static_cast<Decoder *>(handle); auto *api = self->api;
    try {
        api->av_frame_unref_fn(self->frame); api->av_frame_unref_fn(self->download);
        int rc = api->avcodec_receive_frame_fn(self->context, self->frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) return 0;
        if (rc < 0) throw std::runtime_error(api->failure("Receive decoded frame", rc));
        AVFrame *frame = self->frame;
        if (!pixels) { *out={nullptr,0,frame->pts,0,0,0,0}; return 1; }
        if (self->hardware_format != AV_PIX_FMT_NONE) {
            if (frame->format != self->hardware_format) throw std::runtime_error("VAAPI decoder returned a software surface");
            rc = api->av_hwframe_transfer_data_fn(self->download, frame, 0);
            if (rc < 0) throw std::runtime_error(api->failure("VAAPI surface download", rc));
            self->download->crop_left=frame->crop_left; self->download->crop_right=frame->crop_right;
            self->download->crop_top=frame->crop_top; self->download->crop_bottom=frame->crop_bottom;
            frame = self->download;
        }
        rc = api->av_frame_apply_cropping_fn(frame, 0);
        if (rc < 0) throw std::runtime_error(api->failure("Crop decoded frame", rc));
        int w = frame->width, h = frame->height;
        if (w < 2 || h < 2 || w > 8192 || h > 8192 || w % 2 || h % 2) throw std::runtime_error("Unsupported decoded dimensions");
        self->nv12.resize(static_cast<size_t>(w) * h * 3 / 2);
        if (frame->format == AV_PIX_FMT_NV12) {
            for (int y = 0; y < h; ++y) std::memcpy(self->nv12.data()+y*w, frame->data[0]+y*frame->linesize[0],w);
            for (int y = 0; y < h/2; ++y) std::memcpy(self->nv12.data()+w*h+y*w, frame->data[1]+y*frame->linesize[1],w);
        } else {
            if (!self->scaler || self->last_w!=w || self->last_h!=h || self->last_format!=frame->format) {
                if (self->scaler) api->sws_freeContext_fn(self->scaler);
                self->scaler=api->sws_getContext_fn(w,h,static_cast<AVPixelFormat>(frame->format),w,h,AV_PIX_FMT_NV12,SWS_POINT,nullptr,nullptr,nullptr);
                self->last_w=w; self->last_h=h; self->last_format=frame->format;
            }
            if (!self->scaler) throw std::runtime_error("Cannot convert decoded format to NV12");
            uint8_t *planes[4]={self->nv12.data(),self->nv12.data()+w*h,nullptr,nullptr}; int strides[4]={w,w,0,0};
            if (api->sws_scale_fn(self->scaler,frame->data,frame->linesize,0,h,planes,strides)!=h) throw std::runtime_error("Incomplete NV12 conversion");
        }
        auto *original=self->frame;
        *out={self->nv12.data(),self->nv12.size(),original->pts,static_cast<uint32_t>(w),static_cast<uint32_t>(h),static_cast<uint32_t>(original->colorspace),original->color_range==AVCOL_RANGE_JPEG ? 1u:0u};
        return 1;
    } catch (const std::exception &e) { error_text(error,size,e.what()); return -1; }
}
extern "C" void meteor_video_destroy(void *handle) { delete static_cast<Decoder *>(handle); }
