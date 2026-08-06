#include "ffmpeg_decoder.h"
#include <Limelight.h>
#include <godot_cpp/classes/os.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include "nf_log.h"

#ifdef __ANDROID__
#include <dlfcn.h>
#include <jni.h>
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
extern "C" {
#include <libavcodec/jni.h>
#include <libavcodec/mediacodec.h>
}

static JavaVM *g_jvm = nullptr;
static jclass g_godot_app_class = nullptr;

extern "C" JNIEXPORT void JNICALL Java_com_godot_game_GodotApp_initializeMoonlightJNI(JNIEnv *env, jclass clazz) {
    if (env->GetJavaVM(&g_jvm) == 0) {
        av_jni_set_java_vm(g_jvm, nullptr);
    }
    // clazz here IS GodotApp - cache it as a global ref for later lookup-free use.
    // FindClass("com/godot/game/GodotApp") does NOT reliably work when called later
    // from a thread the JVM didn't create (e.g. Godot's own native engine thread,
    // as opposed to this call which arrives FROM Java on a proper JVM thread) - it
    // can't see the app's classloader from there and hangs/misbehaves rather than
    // cleanly failing. Caching the already-resolved class as a global ref sidesteps
    // needing FindClass again from that risky context.
    g_godot_app_class = (jclass)env->NewGlobalRef(clazz);
}

// Exposes the JavaVM captured above (from GodotApp's static initializer, the
// earliest reliable point in the app's lifecycle) to other translation units
// that need JNI without redoing this bootstrapping - see nightfall_stream.cpp's
// get_codec_capabilities_info(), which needs a working JNIEnv before OpenXR
// init even runs, too early for JNI_GetCreatedJavaVMs-via-dlsym to reliably
// resolve.
JavaVM *nightfall_get_jvm() {
    return g_jvm;
}

jclass nightfall_get_godot_app_class() {
    return g_godot_app_class;
}

extern "C" JNIEXPORT void JNICALL Java_com_godot_game_GodotApp_setAndroidContext(JNIEnv *env, jclass clazz, jobject context) {
    if (context) {
        jobject global_ref = env->NewGlobalRef(context);
        if (global_ref) {
            av_jni_set_android_app_ctx(global_ref, nullptr);
        }
    }
}

// Extract AHardwareBuffer from a MediaCodec output frame.
// Requires access to FFmpeg internal MediaCodecDecContext (mediacodec_internal.h).
// Returns nullptr if the output buffer is not backed by an AHardwareBuffer
// (e.g., it's a ByteBuffer or the codec wasn't configured with AHB output).
AHardwareBuffer *mediacodec_get_ahb(jobject media_codec_obj, ssize_t buffer_index) {
    if (!g_jvm || !media_codec_obj || buffer_index < 0) return nullptr;

    JNIEnv *env = nullptr;
    bool attached = false;
    jint res = g_jvm->GetEnv((void **)&env, JNI_VERSION_1_6);
    if (res == JNI_EDETACHED) {
        res = g_jvm->AttachCurrentThread(&env, nullptr);
        if (res != JNI_OK) return nullptr;
        attached = true;
    } else if (res != JNI_OK) {
        return nullptr;
    }

    AHardwareBuffer *ahb = nullptr;

    jclass cls_mediacodec = env->GetObjectClass(media_codec_obj);
    jmethodID mid_getOutputImage = env->GetMethodID(cls_mediacodec, "getOutputImage", "(I)Landroid/media/Image;");
    if (mid_getOutputImage) {
        jobject image = env->CallObjectMethod(media_codec_obj, mid_getOutputImage, (jint)buffer_index);
        if (image && !env->ExceptionCheck()) {
            jclass cls_image = env->GetObjectClass(image);
            jmethodID mid_getHardwareBuffer = env->GetMethodID(cls_image, "getHardwareBuffer", "()Landroid/hardware/HardwareBuffer;");
            if (mid_getHardwareBuffer) {
                jobject hb = env->CallObjectMethod(image, mid_getHardwareBuffer);
                if (hb && !env->ExceptionCheck()) {
                    ahb = AHardwareBuffer_fromHardwareBuffer(env, hb);
                    // Keep the Java HardwareBuffer ref alive. The AHardwareBuffer is
                    // only valid while the Java object exists. We return the AHB and
                    // keep the JNI reference; the caller must release it after the
                    // Vulkan external memory import completes.
                    // Don't close the Image either - that would release the buffer.
                }
                if (!ahb && hb) env->DeleteLocalRef(hb);
            }
            env->DeleteLocalRef(cls_image);
            if (!ahb && image) {
                env->CallVoidMethod(image, env->GetMethodID(cls_image, "close", "()V"));
                env->DeleteLocalRef(image);
            }
        } else if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
    }
    env->DeleteLocalRef(cls_mediacodec);

    if (attached) {
        g_jvm->DetachCurrentThread();
    }
    return ahb;
}

#endif

using namespace godot;

FfmpegDecoder::FfmpegDecoder() {
    sw_frame = av_frame_alloc();
    decode_frame = av_frame_alloc();
}

FfmpegDecoder::~FfmpegDecoder() {
    cleanup();
    if (sw_frame) {
        av_frame_free(&sw_frame);
        sw_frame = nullptr;
    }
    if (decode_frame) {
        av_frame_free(&decode_frame);
        decode_frame = nullptr;
    }
}

Vector<AVHWDeviceType> FfmpegDecoder::_get_supported_hw_devices() {
    Vector<AVHWDeviceType> types;
#if defined(__ANDROID__)
#elif defined(_WIN32)
    types.push_back(AV_HWDEVICE_TYPE_VULKAN);
    types.push_back(AV_HWDEVICE_TYPE_D3D11VA);
#elif defined(__APPLE__)
    types.push_back(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);
#elif defined(__linux__)
    types.push_back(AV_HWDEVICE_TYPE_VULKAN);
    types.push_back(AV_HWDEVICE_TYPE_VAAPI);
#endif
    return types;
}

Vector<String> FfmpegDecoder::get_candidate_decoders(int codec_family) {
    Vector<String> candidates;

#if defined(__ANDROID__)
    String base_codec_name;
    if (codec_family == CODEC_FAMILY_H264) base_codec_name = "h264";
    else if (codec_family == CODEC_FAMILY_H265) base_codec_name = "hevc";
    else if (codec_family == CODEC_FAMILY_AV1) base_codec_name = "av1";

    if (!base_codec_name.is_empty()) {
        candidates.push_back(base_codec_name + "_mediacodec");
    }
#else
    if (codec_family == CODEC_FAMILY_H264) {
        candidates.push_back("h264_mediacodec");
        candidates.push_back("h264");
    } else if (codec_family == CODEC_FAMILY_H265) {
        candidates.push_back("hevc");
    } else if (codec_family == CODEC_FAMILY_AV1) {
        candidates.push_back("libdav1d");
        candidates.push_back("av1");
    }
#endif
    return candidates;
}

enum AVPixelFormat FfmpegDecoder::_get_hw_format_callback(AVCodecContext *ctx, const enum AVPixelFormat *pix_fmts) {
    FfmpegDecoder *self = static_cast<FfmpegDecoder *>(ctx->opaque);
    if (self && self->hw_pix_fmt != AV_PIX_FMT_NONE) {
        for (const enum AVPixelFormat *p = pix_fmts; *p != AV_PIX_FMT_NONE; p++) {
            if (*p == self->hw_pix_fmt)
                return *p;
        }
    }
    return avcodec_default_get_format(ctx, pix_fmts);
}

int FfmpegDecoder::_try_open_decoder(const String &codec_name, int width, int height, AVHWDeviceType hw_type, bool disable_hw) {
    String base_name = codec_name;
    int sep = codec_name.find(":");
    if (sep != -1) {
        base_name = codec_name.substr(0, sep);
    }
    if (base_name.ends_with("_lowlat")) {
        base_name = base_name.substr(0, base_name.length() - 7);
    }

    const AVCodec *codec = avcodec_find_decoder_by_name(base_name.utf8().get_data());
    if (!codec) return -1;

    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx)
        return -1;

    ctx->opaque = this;
    ctx->width = width;
    ctx->height = height;
    ctx->coded_width = width;
    ctx->coded_height = height;

    bool is_mediacodec = codec_name.find("_mediacodec") != -1;

    if (!is_mediacodec) {
        ctx->flags |= AV_CODEC_FLAG_LOW_DELAY;
        ctx->delay = 0;
        ctx->flags |= AV_CODEC_FLAG_OUTPUT_CORRUPT;
        ctx->flags2 |= AV_CODEC_FLAG2_SHOW_ALL;
        ctx->flags2 |= AV_CODEC_FLAG2_FAST;
        ctx->err_recognition = AV_EF_EXPLODE;
    }

    bool enforce_sw_pix_fmt = hw_type == AV_HWDEVICE_TYPE_NONE &&
            codec_name.find("av1") == -1 && codec_name.find("dav1d") == -1 &&
            !is_mediacodec;
    if (enforce_sw_pix_fmt) {
        ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    }

    hw_pix_fmt = AV_PIX_FMT_NONE;
    if (hw_type != AV_HWDEVICE_TYPE_NONE) {
        int err = av_hwdevice_ctx_create(&hw_device_ctx, hw_type, nullptr, nullptr, 0);
        if (err < 0) {
            avcodec_free_context(&ctx);
            return -1;
        }
        ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
        ctx->get_format = _get_hw_format_callback;

        if (hw_type == AV_HWDEVICE_TYPE_MEDIACODEC)
            hw_pix_fmt = AV_PIX_FMT_MEDIACODEC;
        else if (hw_type == AV_HWDEVICE_TYPE_VULKAN)
            hw_pix_fmt = AV_PIX_FMT_VULKAN;
        else if (hw_type == AV_HWDEVICE_TYPE_VAAPI)
            hw_pix_fmt = AV_PIX_FMT_VAAPI;
    }

    int thread_count = OS::get_singleton()->get_processor_count() - 1;
    if (thread_count < 1) thread_count = 1;

    if (hw_type != AV_HWDEVICE_TYPE_NONE) {
        ctx->thread_count = 1;
        ctx->thread_type = 0;
    } else {
        if (codec->capabilities & AV_CODEC_CAP_SLICE_THREADS) {
            ctx->thread_type = FF_THREAD_SLICE;
            ctx->thread_count = thread_count;
        } else {
            ctx->thread_count = 1;
        }
    }

    AVDictionary *opts = nullptr;
    if (is_mediacodec) {
        av_dict_set(&opts, "ndk_codec", "1", 0);
    }

    if (is_mediacodec && ctx->codec_id == AV_CODEC_ID_H264 && !ctx->extradata) {
        avcodec_free_context(&ctx);
        return -1;
    }

    String special_component;
    if (sep != -1) {
        special_component = codec_name.substr(sep + 1, codec_name.length() - (sep + 1));
    }
    if (special_component != String()) {
        av_dict_set(&opts, "mediacodec_name", special_component.utf8().get_data(), 0);
    }

    int ret = avcodec_open2(ctx, codec, &opts);
    if (opts) av_dict_free(&opts);

    if (ret < 0) {
        if (hw_device_ctx) {
            av_buffer_unref(&hw_device_ctx);
            hw_device_ctx = nullptr;
        }
        avcodec_free_context(&ctx);
        return -1;
    }

    v_codec = codec;
    v_codec_ctx = ctx;
    return 0;
}

int FfmpegDecoder::probe_video_format(int codec_preference, bool disable_hw) {
    if (codec_preference == CODEC_FAMILY_RAW) {
        return VIDEO_FORMAT_MASK_RAW;
    }

    int supported_mask = 0;
    int test_w = 1280;
    int test_h = 720;

    Vector<AVHWDeviceType> hw_devices;
    if (!disable_hw) {
        hw_devices = _get_supported_hw_devices();
    }
    hw_devices.push_back(AV_HWDEVICE_TYPE_NONE);

    auto test_family = [&](int family) -> bool {
        Vector<String> candidates = get_candidate_decoders(family);
        for (int i = 0; i < candidates.size(); i++) {
            if (disable_hw && candidates[i].find("_mediacodec") != -1) continue;
            for (int j = 0; j < hw_devices.size(); j++) {
                if (_try_open_decoder(candidates[i], test_w, test_h, hw_devices[j], disable_hw) == 0) {
                    cleanup();
                    return true;
                }
            }
        }
        return false;
    };

    bool h264_ok = (codec_preference == CODEC_FAMILY_AUTO || codec_preference == CODEC_FAMILY_H264) && test_family(CODEC_FAMILY_H264);
    bool hevc_ok = (codec_preference == CODEC_FAMILY_AUTO || codec_preference == CODEC_FAMILY_H265) && test_family(CODEC_FAMILY_H265);
    bool av1_ok = (codec_preference == CODEC_FAMILY_AUTO || codec_preference == CODEC_FAMILY_AV1) && test_family(CODEC_FAMILY_AV1);

    if (codec_preference == CODEC_FAMILY_AV1 && av1_ok)
        supported_mask |= VIDEO_FORMAT_AV1_MAIN8;
    else if (codec_preference == CODEC_FAMILY_H265 && hevc_ok)
        supported_mask |= VIDEO_FORMAT_H265;
    else if (codec_preference == CODEC_FAMILY_H264 && h264_ok)
        supported_mask |= VIDEO_FORMAT_H264;

    if (codec_preference == CODEC_FAMILY_AUTO) {
        if (h264_ok) supported_mask |= VIDEO_FORMAT_H264;
        if (hevc_ok) supported_mask |= VIDEO_FORMAT_H265;
        if (av1_ok) supported_mask |= VIDEO_FORMAT_AV1_MAIN8;
    }
    if (supported_mask == 0)
        supported_mask = VIDEO_FORMAT_H264;

    return supported_mask;
}

int FfmpegDecoder::setup(int video_format, int width, int height, bool disable_hw) {
    cleanup();

    if (video_format & VIDEO_FORMAT_MASK_RAW) {
        is_raw_decode_active = true;
        video_width = width;
        video_height = height;
        return 0;
    }

    int family = -1;
    if (video_format & VIDEO_FORMAT_MASK_H264) family = CODEC_FAMILY_H264;
    else if (video_format & VIDEO_FORMAT_MASK_H265) family = CODEC_FAMILY_H265;
    else if (video_format & VIDEO_FORMAT_MASK_AV1) family = CODEC_FAMILY_AV1;
    if (family == -1) return -1;

    Vector<String> candidates = get_candidate_decoders(family);
    Vector<AVHWDeviceType> hw_devices;
    if (!disable_hw) hw_devices = _get_supported_hw_devices();
    hw_devices.push_back(AV_HWDEVICE_TYPE_NONE);

    bool opened = false;
    String opened_name;
    String opened_hw = "Software";

    for (int i = 0; i < candidates.size(); i++) {
        if (disable_hw && candidates[i].find("_mediacodec") != -1) continue;
        for (int j = 0; j < hw_devices.size(); j++) {
            if (_try_open_decoder(candidates[i], width, height, hw_devices[j], disable_hw) == 0) {
                opened_name = candidates[i];
                if (hw_devices[j] != AV_HWDEVICE_TYPE_NONE)
                    opened_hw = String(av_hwdevice_get_type_name(hw_devices[j]));
                else if (candidates[i].find("_mediacodec") != -1)
                    opened_hw = "MediaCodec (Buffer)";
                opened = true;
                break;
            }
        }
        if (opened) break;
    }

    if (!opened) {
        NF_LOGE("FfmpegDecoder", "No usable decoder found!");
        return -1;
    }

    video_width = width;
    video_height = height;
    is_hw_decode_active = (opened_name.find("_mediacodec") != -1) || (hw_device_ctx != nullptr);

    return 0;
}

void FfmpegDecoder::cleanup() {
    if (hw_device_ctx) {
        av_buffer_unref(&hw_device_ctx);
        hw_device_ctx = nullptr;
    }
    hw_pix_fmt = AV_PIX_FMT_NONE;
    if (v_codec_ctx) {
        avcodec_free_context(&v_codec_ctx);
        v_codec_ctx = nullptr;
    }
    v_codec = nullptr;
    is_hw_decode_active = false;
    is_raw_decode_active = false;
}

AVFrame *FfmpegDecoder::get_sw_frame() {
    return sw_frame;
}

String FfmpegDecoder::get_decoder_name() const {
    if (v_codec) return String(v_codec->name);
    return "";
}

bool FfmpegDecoder::is_hw_decode() const {
    return is_hw_decode_active;
}

bool FfmpegDecoder::is_raw_decode() const {
    return is_raw_decode_active;
}

int FfmpegDecoder::get_video_width() const { return video_width; }
int FfmpegDecoder::get_video_height() const { return video_height; }

int FfmpegDecoder::upgrade_to_mediacodec(const uint8_t *extradata, int extradata_size) {
    if (!v_codec_ctx || v_codec_ctx->codec_id != AV_CODEC_ID_H264) return -1;
    if (is_hw_decode_active) return -1;

    int w = v_codec_ctx->width;
    int h = v_codec_ctx->height;

    avcodec_free_context(&v_codec_ctx);
    v_codec = nullptr;

    const AVCodec *codec = avcodec_find_decoder_by_name("h264_mediacodec");
    if (!codec) return -1;

    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return -1;

    ctx->opaque = this;
    ctx->width = w;
    ctx->height = h;
    ctx->coded_width = w;
    ctx->coded_height = h;

    ctx->extradata = (uint8_t *)av_mallocz(extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!ctx->extradata) {
        avcodec_free_context(&ctx);
        return -1;
    }
    memcpy(ctx->extradata, extradata, extradata_size);
    ctx->extradata_size = extradata_size;

    ctx->thread_count = 1;
    ctx->thread_type = 0;

    AVDictionary *opts = nullptr;
    av_dict_set(&opts, "ndk_codec", "1", 0);

    int ret = avcodec_open2(ctx, codec, &opts);
    if (opts) av_dict_free(&opts);

    if (ret < 0) {
        char err_buf[128] = {0};
        av_strerror(ret, err_buf, sizeof(err_buf));
        NF_LOGE("FfmpegDecoder", "upgrade_to_mediacodec: avcodec_open2 failed (%d: %s)", ret, err_buf);
        avcodec_free_context(&ctx);
        return -1;
    }

    v_codec = codec;
    v_codec_ctx = ctx;
    is_hw_decode_active = true;

    NF_LOG("FfmpegDecoder", "upgrade_to_mediacodec: %s %dx%d", codec->name, w, h);
    return 0;
}

void FfmpegDecoder::_bind_methods() {
    ClassDB::bind_method(D_METHOD("probe_video_format", "codec_preference", "disable_hw"), &FfmpegDecoder::probe_video_format);
    ClassDB::bind_method(D_METHOD("setup", "video_format", "width", "height", "disable_hw"), &FfmpegDecoder::setup);
    ClassDB::bind_method(D_METHOD("cleanup"), &FfmpegDecoder::cleanup);
    ClassDB::bind_method(D_METHOD("get_decoder_name"), &FfmpegDecoder::get_decoder_name);
    ClassDB::bind_method(D_METHOD("is_hw_decode"), &FfmpegDecoder::is_hw_decode);
    ClassDB::bind_method(D_METHOD("is_raw_decode"), &FfmpegDecoder::is_raw_decode);
    ClassDB::bind_method(D_METHOD("get_video_width"), &FfmpegDecoder::get_video_width);
    ClassDB::bind_method(D_METHOD("get_video_height"), &FfmpegDecoder::get_video_height);
}
