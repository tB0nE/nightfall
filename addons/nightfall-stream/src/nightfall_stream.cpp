#include "nightfall_stream.h"
#include "video/stream_connection.h"
#include "video/ffmpeg_decoder.h"
#include "video/texture_uploader.h"
#include "video/pipewire_capture.h"
#include "video/dmabuf_importer.h"
#include "video/x11_capture.h"
#include "audio/audio_renderer.h"
#include "audio/pipewire_audio.h"
#include "input/input_bridge.h"
#include "config/computer_manager.h"
#include "config/config_manager.h"
#include "network/http_requester.h"

#include <godot_cpp/classes/timer.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include "nf_log.h"

#ifdef __ANDROID__
#include <dlfcn.h>
#include <jni.h>
#endif

using namespace godot;

#ifdef NIGHTFALL_HAS_X11
static bool is_wayland() {
    const char *xdg = getenv("XDG_SESSION_TYPE");
    if (xdg && strcmp(xdg, "wayland") == 0) return true;
    const char *wl = getenv("WAYLAND_DISPLAY");
    if (wl && wl[0]) return true;
    return false;
}
#endif

NightfallStream::NightfallStream() {}

NightfallStream::~NightfallStream() {
    stop_stream();
    if (http_requester_) {
        memdelete(http_requester_);
        http_requester_ = nullptr;
    }
}

void NightfallStream::_ready() {
    set_process(true);
    config_manager_.instantiate();
    computer_manager_.instantiate();
    computer_manager_->set_config_manager(config_manager_.ptr());

    http_requester_ = memnew(HttpRequester);
    computer_manager_->set_http_requester(http_requester_);

    stream_connection_ = memnew(StreamConnection);
    add_child(stream_connection_);

    computer_manager_->set_parent_node(this);

    stream_connection_->connect("stream_started", callable_mp(this, &NightfallStream::_on_stream_started));
    stream_connection_->connect("stream_terminated", callable_mp(this, &NightfallStream::_on_stream_terminated));
    stream_connection_->connect("stage_starting", callable_mp(this, &NightfallStream::_on_stage_starting));
    stream_connection_->connect("stage_complete", callable_mp(this, &NightfallStream::_on_stage_complete));
    stream_connection_->connect("stage_failed", callable_mp(this, &NightfallStream::_on_stage_failed));
    stream_connection_->connect("connection_status_update", callable_mp(this, &NightfallStream::_on_connection_status_update));
    stream_connection_->connect("log_message", callable_mp(this, &NightfallStream::_on_log_message));
    stream_connection_->connect("h264_hw_upgraded", callable_mp(this, &NightfallStream::_on_h264_hw_upgraded));
    stream_connection_->connect("controller_rumble", callable_mp(this, &NightfallStream::_on_controller_rumble));
    stream_connection_->connect("controller_trigger_rumble", callable_mp(this, &NightfallStream::_on_controller_trigger_rumble));
}

void NightfallStream::_process(double /*delta*/) {
    if (pipewire_capture_ && dmabuf_importer_ && pipewire_capture_->has_new_frame()) {
        PipeWireCapture::FrameData frame;
        if (pipewire_capture_->get_latest_frame(frame)) {
            dmabuf_importer_->import_frame(frame);
            pipewire_capture_->release_frame(frame.spa_buf_ptr);
        }
    }
    if (x11_capture_ && x11_capture_->has_new_frame()) {
        X11Capture::FrameData frame;
        if (x11_capture_->get_latest_frame(frame) && frame.data) {
            Ref<TextureUploader> uploader = get_texture_uploader();
            if (uploader.is_valid()) {
                static uint32_t last_w = 0, last_h = 0;
                if (last_w != frame.width || last_h != frame.height) {
                    last_w = frame.width;
                    last_h = frame.height;
                    uploader->setup_bgra(frame.width, frame.height);
                }
                // Convert X11 BGRA (B,G,R,X) to RGBA (R,G,B,A) in CPU.
                // Eliminates shader swizzle dependency entirely.
                uint32_t data_size = frame.width * frame.height * 4;
                std::vector<uint8_t> rgba(data_size);
                for (uint32_t y = 0; y < frame.height; y++) {
                    const uint8_t *src = frame.data + y * frame.stride;
                    uint8_t *dst = rgba.data() + y * frame.width * 4;
                    for (uint32_t x = 0; x < frame.width; x++) {
                        dst[x*4 + 0] = src[x*4 + 2]; // R from byte 2 (red)
                        dst[x*4 + 1] = src[x*4 + 1]; // G from byte 1 (green)
                        dst[x*4 + 2] = src[x*4 + 0]; // B from byte 0 (blue)
                        dst[x*4 + 3] = 0xFF;          // A = 255
                    }
                }
                uploader->update_from_raw_bgra(frame.width, frame.height, rgba.data(), data_size);
            }
            x11_capture_->release_frame();
        }
    }
}

void NightfallStream::set_restore_token(const String &token) {
    restore_token_ = token;
}

String NightfallStream::get_restore_token() const {
    return restore_token_;
}

String NightfallStream::get_version() const {
    return "2.0.0-alpha";
}

int NightfallStream::get_state() const {
    return (int)state_;
}

void NightfallStream::start_stream(const String &host, const Dictionary &server_info, const Dictionary &stream_config, bool disable_hw) {
    NF_LOG("NightfallStream", "start_stream: host=%s server_info_keys=%d stream_config_keys=%d state=%d stream_conn=%p",
        host.utf8().get_data(), (int)server_info.size(), (int)stream_config.size(), (int)state_, (void*)stream_connection_);
    if (state_ == STATE_CONNECTING || state_ == STATE_CONNECTED) {
        stop_stream();
    }

    last_host_ = host;
    last_server_info_ = server_info.duplicate();
    last_stream_config_ = stream_config.duplicate();
    last_disable_hw_ = disable_hw;

    state_ = STATE_CONNECTING;
    _reset_reconnect();
    emit_signal("state_changed", (int)state_);

    // Set local_capture_mode so _cb_submit_decode_unit skips Sunshine frames
    // (avoiding texture corruption from YUV/BGRA conflict).
    // _cb_decoder_setup still runs normally to create the uploader's ShaderMaterial.
    stream_connection_->set_local_capture_mode(local_capture_mode_);
    stream_connection_->start(host, server_info, stream_config, disable_hw);

    if (local_capture_mode_) {
        // Ensure shader material exists on main thread so _setup_v2_yuv_rect()
        // can access it immediately when the stream starts.
        Ref<TextureUploader> uploader = get_texture_uploader();
        if (uploader.is_valid()) {
            uploader->ensure_shader_material();
        }

        // Mute Sunshine audio - audio is already on the machine
        Ref<AudioRenderer> audio = get_audio_renderer();
        if (audio.is_valid()) {
            audio->set_muted(true);
            NF_LOG("NightfallStream", "Audio muted (local capture mode)");
        }
#ifdef NIGHTFALL_HAS_X11
        if (!is_wayland()) {
            NF_LOG("NightfallStream", "Starting X11 SHM capture for local mode (X11 detected)");
            x11_capture_ = new X11Capture();
            if (!x11_capture_->start()) {
                NF_LOGE("NightfallStream", "X11 capture failed to start");
                delete x11_capture_;
                x11_capture_ = nullptr;
            }
        } else
#endif
        {
            NF_LOG("NightfallStream", "Starting PipeWire capture for local mode (Wayland detected)");
            pipewire_capture_ = new PipeWireCapture();
            dmabuf_importer_ = new DmaBufImporter(get_texture_uploader());
            pipewire_capture_->start(restore_token_.utf8().get_data());

            pipewire_audio_ = new PipeWireAudio(get_audio_renderer().ptr());
            pipewire_audio_->start();
        }
    }
}

void NightfallStream::stop_stream() {
    if (state_ == STATE_IDLE) return;

    // Unmute audio
    Ref<AudioRenderer> audio = get_audio_renderer();
    if (audio.is_valid()) audio->set_muted(false);

    if (x11_capture_) {
        x11_capture_->stop();
        delete x11_capture_;
        x11_capture_ = nullptr;
    }
    if (pipewire_audio_) {
        pipewire_audio_->stop();
        delete pipewire_audio_;
        pipewire_audio_ = nullptr;
    }
    if (pipewire_capture_) {
        pipewire_capture_->stop();
        std::string tok = pipewire_capture_->get_restore_token();
        if (!tok.empty()) {
            restore_token_ = String(tok.c_str());
            emit_signal("restore_token_updated", restore_token_);
        }
        delete pipewire_capture_;
        pipewire_capture_ = nullptr;
    }
    if (dmabuf_importer_) {
        delete dmabuf_importer_;
        dmabuf_importer_ = nullptr;
    }

    StreamState prev_state = state_;
    state_ = STATE_STOPPING;
    _reset_reconnect();
    emit_signal("state_changed", (int)state_);

    stream_connection_->stop();

    state_ = STATE_IDLE;
    emit_signal("state_changed", (int)state_);
    if (prev_state == STATE_CONNECTED || prev_state == STATE_RECONNECTING) {
        emit_signal("stream_terminated", 0, "Disconnected");
    }
}

int NightfallStream::probe_video_format(int codec_preference, bool disable_hw) {
    if (!stream_connection_) return 1;
    return stream_connection_->probe_video_format(codec_preference, disable_hw);
}

Dictionary NightfallStream::probe_all_video_formats() {
    if (!stream_connection_) {
        Dictionary result;
        result["h264"] = true;
        result["hevc"] = false;
        result["av1"] = false;
        result["raw"] = true;
        return result;
    }
    return stream_connection_->probe_all_video_formats();
}

int NightfallStream::get_server_codec_mode_support() const {
    if (!stream_connection_) return 0;
    return stream_connection_->get_server_codec_mode_support();
}

void NightfallStream::set_auto_reconnect(bool enabled) {
    auto_reconnect_ = enabled;
}

bool NightfallStream::get_auto_reconnect() const {
    return auto_reconnect_;
}

void NightfallStream::set_max_reconnect_attempts(int attempts) {
    max_reconnect_attempts_ = attempts;
}

int NightfallStream::get_max_reconnect_attempts() const {
    return max_reconnect_attempts_;
}

void NightfallStream::set_reconnect_delay_ms(int ms) {
    reconnect_delay_ms_ = ms;
}

int NightfallStream::get_reconnect_delay_ms() const {
    return reconnect_delay_ms_;
}

void NightfallStream::set_local_capture_mode(bool enabled) {
    local_capture_mode_ = enabled;
}

bool NightfallStream::get_local_capture_mode() const {
    return local_capture_mode_;
}

Ref<FfmpegDecoder> NightfallStream::get_decoder() const {
    if (stream_connection_) return stream_connection_->get_decoder();
    return nullptr;
}

Ref<TextureUploader> NightfallStream::get_texture_uploader() const {
    if (stream_connection_) return stream_connection_->get_texture_uploader();
    return nullptr;
}

Ref<ShaderMaterial> NightfallStream::get_shader_material() const {
    if (stream_connection_) return stream_connection_->get_shader_material();
    return nullptr;
}

Ref<AudioRenderer> NightfallStream::get_audio_renderer() const {
    if (stream_connection_) return stream_connection_->get_audio_renderer();
    return nullptr;
}

Ref<InputBridge> NightfallStream::get_input_bridge() const {
    if (stream_connection_) return stream_connection_->get_input_bridge();
    return nullptr;
}

Ref<DepthBridge> NightfallStream::get_depth_bridge() const {
    if (stream_connection_) return stream_connection_->get_depth_bridge();
    return nullptr;
}

int NightfallStream::get_frames_dropped() const {
    if (stream_connection_) return stream_connection_->get_frames_dropped();
    return 0;
}

int NightfallStream::get_frames_decoded() const {
    if (stream_connection_) return stream_connection_->get_frames_decoded();
    return 0;
}

int NightfallStream::get_decode_queue_size() const {
    if (stream_connection_) return stream_connection_->get_decode_queue_size();
    return 0;
}

int NightfallStream::get_last_frame_latency_us() const {
    if (stream_connection_) return stream_connection_->get_last_frame_latency_us();
    return 0;
}

bool NightfallStream::is_display_ready() const {
    if (stream_connection_) return stream_connection_->is_display_ready();
    return false;
}

// One-off diagnostic: queries the real on-device H.264/HEVC hardware decoder
// limits via MediaCodecInfo.CodecCapabilities.VideoCapabilities (see
// GodotApp.getCodecCapabilitiesInfo()), rather than inferring them from trial
// and error. Not on any hot path - call once from GDScript and read the result
// from logcat/the returned string.
// Pre-existing Linux-build bug (found 2026-08-20 while adding native AI-3D
// depth on Linux, unrelated to that work) - JavaVM/jclass were declared here
// unconditionally, with only the FUNCTION BODY below guarded by
// #ifdef __ANDROID__. On Android something else transitively pulls in
// <jni.h> before this point so it happened to compile; on Linux nothing ever
// defines those types at all, failing the whole target's build outright.
#ifdef __ANDROID__
extern JavaVM *nightfall_get_jvm();
extern jclass nightfall_get_godot_app_class();
#endif

String NightfallStream::get_codec_capabilities_info() const {
#ifdef __ANDROID__
    JavaVM *vm = nightfall_get_jvm();
    if (!vm) return "ERROR: no JavaVM (initializeMoonlightJNI not called yet?)";

    JNIEnv *env = nullptr;
    jint res = vm->GetEnv((void **)&env, JNI_VERSION_1_6);
    if (res == JNI_EDETACHED) {
        if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK || !env) {
            return "ERROR: AttachCurrentThread failed";
        }
    } else if (res != JNI_OK || !env) {
        return "ERROR: GetEnv failed";
    }

    // Use the class reference cached at Java-static-init time (see
    // initializeMoonlightJNI in ffmpeg_decoder.cpp) instead of calling
    // FindClass("com/godot/game/GodotApp") here - this runs on whatever thread
    // GDScript happens to be on (Godot's own native engine thread, not one the
    // JVM created), and FindClass from that context can't see the app's
    // classloader; it doesn't fail cleanly, it hangs the whole app.
    jclass app_class = nightfall_get_godot_app_class();
    if (!app_class) return "ERROR: GodotApp class not cached (initializeMoonlightJNI not called yet?)";

    jmethodID method = env->GetStaticMethodID(app_class, "getCodecCapabilitiesInfo", "()Ljava/lang/String;");
    if (!method) {
        return "ERROR: getCodecCapabilitiesInfo method not found";
    }

    jstring result_jstr = (jstring)env->CallStaticObjectMethod(app_class, method);
    String result = "ERROR: null result";
    if (result_jstr) {
        const char *chars = env->GetStringUTFChars(result_jstr, nullptr);
        if (chars) {
            result = String(chars);
            env->ReleaseStringUTFChars(result_jstr, chars);
        }
        env->DeleteLocalRef(result_jstr);
    }
    // app_class is the cached global ref (see above) - not ours to delete.
    return result;
#else
    return "Not supported on this platform";
#endif
}

String NightfallStream::get_decoder_name() const {
    if (stream_connection_) return stream_connection_->get_decoder_name();
    return "";
}

int NightfallStream::get_video_width() const {
    if (stream_connection_) return stream_connection_->get_video_width();
    return 0;
}

int NightfallStream::get_video_height() const {
    if (stream_connection_) return stream_connection_->get_video_height();
    return 0;
}

bool NightfallStream::is_hw_decode() const {
    if (stream_connection_) return stream_connection_->is_hw_decode();
    return false;
}

String NightfallStream::get_error_string(int error_code) {
    return StreamConnection::get_error_string(error_code);
}

Object *NightfallStream::get_computer_manager() const {
    return computer_manager_.ptr();
}

Object *NightfallStream::get_config_manager() const {
    return config_manager_.ptr();
}

Object *NightfallStream::get_stream_connection() const {
    return stream_connection_;
}

void NightfallStream::_on_pair_completed(bool success, const String &msg) {
    NF_LOG("NightfallStream", "_on_pair_completed: success=%d msg=%s", success, msg.utf8().get_data());
    emit_signal("pair_completed", success, msg);
}

void NightfallStream::_on_stream_started() {
    NF_LOG("NightfallStream", "_on_stream_started");
    state_ = STATE_CONNECTED;
    _reset_reconnect();
    emit_signal("state_changed", (int)state_);
    emit_signal("stream_started");
}

void NightfallStream::_on_stream_terminated(int error_code, const String &error_message) {
    if (state_ == STATE_STOPPING) return;

    state_ = STATE_DISCONNECTED;
    emit_signal("state_changed", (int)state_);
    emit_signal("stream_terminated", error_code, error_message);

    if (error_code == 0) return;

    if (auto_reconnect_ && reconnect_attempts_ < max_reconnect_attempts_) {
        state_ = STATE_RECONNECTING;
        emit_signal("state_changed", (int)state_);
        emit_signal("reconnect_attempt", reconnect_attempts_ + 1, max_reconnect_attempts_);
        _attempt_reconnect();
    } else if (reconnect_attempts_ >= max_reconnect_attempts_) {
        emit_signal("reconnect_failed");
    }
}

void NightfallStream::_on_stage_starting(const String &stage_name) {
    current_stage_ = stage_name;
    emit_signal("stage_starting", stage_name);
}

void NightfallStream::_on_stage_complete(const String &stage_name) {
    emit_signal("stage_complete", stage_name);
}

void NightfallStream::_on_stage_failed(const String &stage_name, int error_code) {
    emit_signal("stage_failed", stage_name, error_code);

    if (auto_reconnect_ && reconnect_attempts_ < max_reconnect_attempts_) {
        state_ = STATE_RECONNECTING;
        emit_signal("state_changed", (int)state_);
        emit_signal("reconnect_attempt", reconnect_attempts_ + 1, max_reconnect_attempts_);
        _attempt_reconnect();
    } else if (reconnect_attempts_ >= max_reconnect_attempts_) {
        emit_signal("reconnect_failed");
    }
}

void NightfallStream::_on_connection_status_update(int status) {
    emit_signal("connection_status_update", status);
}

void NightfallStream::_on_log_message(const String &message) {
    emit_signal("log_message", message);
}

void NightfallStream::_on_h264_hw_upgraded() {
    emit_signal("h264_hw_upgraded");
}

void NightfallStream::_on_controller_rumble(int controller, int low_freq, int high_freq) {
    emit_signal("controller_rumble", controller, low_freq, high_freq);
}

void NightfallStream::_on_controller_trigger_rumble(int controller, int left_motor, int right_motor) {
    emit_signal("controller_trigger_rumble", controller, left_motor, right_motor);
}

void NightfallStream::_attempt_reconnect() {
    reconnect_attempts_++;

    int delay = reconnect_delay_ms_;
    for (int i = 1; i < reconnect_attempts_; i++) {
        delay *= 2;
        if (delay > 30000) { delay = 30000; break; }
    }

    NF_LOG("NightfallStream", "Reconnect attempt %d/%d in %dms", reconnect_attempts_, max_reconnect_attempts_, delay);

    call_deferred("emit_signal", "reconnect_scheduled", reconnect_attempts_, max_reconnect_attempts_, delay);

    if (reconnect_timer_) {
        reconnect_timer_->stop();
        reconnect_timer_->queue_free();
        reconnect_timer_ = nullptr;
    }
    reconnect_timer_ = memnew(Timer);
    reconnect_timer_->set_wait_time((double)delay / 1000.0);
    reconnect_timer_->set_one_shot(true);
    add_child(reconnect_timer_);
    reconnect_timer_->connect("timeout", callable_mp(this, &NightfallStream::_on_reconnect_timeout));
    reconnect_timer_->start();
}

void NightfallStream::_on_reconnect_timeout() {
    if (reconnect_timer_) {
        reconnect_timer_->queue_free();
        reconnect_timer_ = nullptr;
    }
    _do_reconnect();
}

void NightfallStream::_do_reconnect() {
    if (state_ != STATE_RECONNECTING) return;
    NF_LOG("NightfallStream", "_do_reconnect: last_host_=%s last_server_info_keys=%d last_stream_config_keys=%d",
        last_host_.utf8().get_data(), (int)last_server_info_.size(), (int)last_stream_config_.size());
    start_stream(last_host_, last_server_info_, last_stream_config_, last_disable_hw_);
}

void NightfallStream::_reset_reconnect() {
    reconnect_attempts_ = 0;
    if (reconnect_timer_) {
        reconnect_timer_->stop();
        reconnect_timer_->queue_free();
        reconnect_timer_ = nullptr;
    }
}

void NightfallStream::_bind_methods() {
    BIND_ENUM_CONSTANT(STATE_IDLE);
    BIND_ENUM_CONSTANT(STATE_CONNECTING);
    BIND_ENUM_CONSTANT(STATE_CONNECTED);
    BIND_ENUM_CONSTANT(STATE_DISCONNECTED);
    BIND_ENUM_CONSTANT(STATE_RECONNECTING);
    BIND_ENUM_CONSTANT(STATE_STOPPING);

    ClassDB::bind_method(D_METHOD("get_version"), &NightfallStream::get_version);
    ClassDB::bind_method(D_METHOD("get_state"), &NightfallStream::get_state);

    ClassDB::bind_method(D_METHOD("start_stream", "host", "server_info", "stream_config", "disable_hw"), &NightfallStream::start_stream, DEFVAL(false));
    ClassDB::bind_method(D_METHOD("stop_stream"), &NightfallStream::stop_stream);
    ClassDB::bind_method(D_METHOD("probe_video_format", "codec_preference", "disable_hw"), &NightfallStream::probe_video_format);
    ClassDB::bind_method(D_METHOD("probe_all_video_formats"), &NightfallStream::probe_all_video_formats);
    ClassDB::bind_method(D_METHOD("get_server_codec_mode_support"), &NightfallStream::get_server_codec_mode_support);

    ClassDB::bind_method(D_METHOD("set_auto_reconnect", "enabled"), &NightfallStream::set_auto_reconnect);
    ClassDB::bind_method(D_METHOD("get_auto_reconnect"), &NightfallStream::get_auto_reconnect);
    ClassDB::bind_method(D_METHOD("set_max_reconnect_attempts", "attempts"), &NightfallStream::set_max_reconnect_attempts);
    ClassDB::bind_method(D_METHOD("get_max_reconnect_attempts"), &NightfallStream::get_max_reconnect_attempts);
    ClassDB::bind_method(D_METHOD("set_reconnect_delay_ms", "ms"), &NightfallStream::set_reconnect_delay_ms);
    ClassDB::bind_method(D_METHOD("get_reconnect_delay_ms"), &NightfallStream::get_reconnect_delay_ms);
    ClassDB::bind_method(D_METHOD("set_local_capture_mode", "enabled"), &NightfallStream::set_local_capture_mode);
    ClassDB::bind_method(D_METHOD("get_local_capture_mode"), &NightfallStream::get_local_capture_mode);
    ClassDB::bind_method(D_METHOD("set_restore_token", "token"), &NightfallStream::set_restore_token);
    ClassDB::bind_method(D_METHOD("get_restore_token"), &NightfallStream::get_restore_token);

    ClassDB::bind_method(D_METHOD("get_decoder"), &NightfallStream::get_decoder);
    ClassDB::bind_method(D_METHOD("get_texture_uploader"), &NightfallStream::get_texture_uploader);
    ClassDB::bind_method(D_METHOD("get_shader_material"), &NightfallStream::get_shader_material);
    ClassDB::bind_method(D_METHOD("get_audio_renderer"), &NightfallStream::get_audio_renderer);
    ClassDB::bind_method(D_METHOD("get_input_bridge"), &NightfallStream::get_input_bridge);
    ClassDB::bind_method(D_METHOD("get_depth_bridge"), &NightfallStream::get_depth_bridge);
    ClassDB::bind_method(D_METHOD("get_frames_dropped"), &NightfallStream::get_frames_dropped);
    ClassDB::bind_method(D_METHOD("get_frames_decoded"), &NightfallStream::get_frames_decoded);
    ClassDB::bind_method(D_METHOD("get_decode_queue_size"), &NightfallStream::get_decode_queue_size);
    ClassDB::bind_method(D_METHOD("get_last_frame_latency_us"), &NightfallStream::get_last_frame_latency_us);
    ClassDB::bind_method(D_METHOD("is_display_ready"), &NightfallStream::is_display_ready);
    ClassDB::bind_method(D_METHOD("get_codec_capabilities_info"), &NightfallStream::get_codec_capabilities_info);
    ClassDB::bind_method(D_METHOD("get_decoder_name"), &NightfallStream::get_decoder_name);
    ClassDB::bind_method(D_METHOD("get_video_width"), &NightfallStream::get_video_width);
    ClassDB::bind_method(D_METHOD("get_video_height"), &NightfallStream::get_video_height);
    ClassDB::bind_method(D_METHOD("is_hw_decode"), &NightfallStream::is_hw_decode);
    ClassDB::bind_static_method("NightfallStream", D_METHOD("get_error_string", "error_code"), &NightfallStream::get_error_string);
    ClassDB::bind_method(D_METHOD("get_computer_manager"), &NightfallStream::get_computer_manager);
    ClassDB::bind_method(D_METHOD("get_config_manager"), &NightfallStream::get_config_manager);
    ClassDB::bind_method(D_METHOD("get_stream_connection"), &NightfallStream::get_stream_connection);
    ClassDB::bind_method(D_METHOD("_on_pair_completed", "success", "message"), &NightfallStream::_on_pair_completed);
    ClassDB::bind_method(D_METHOD("_on_log_message", "message"), &NightfallStream::_on_log_message);
    ClassDB::bind_method(D_METHOD("_on_h264_hw_upgraded"), &NightfallStream::_on_h264_hw_upgraded);

    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "auto_reconnect"), "set_auto_reconnect", "get_auto_reconnect");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "max_reconnect_attempts"), "set_max_reconnect_attempts", "get_max_reconnect_attempts");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "reconnect_delay_ms"), "set_reconnect_delay_ms", "get_reconnect_delay_ms");
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "local_capture_mode"), "set_local_capture_mode", "get_local_capture_mode");
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "restore_token"), "set_restore_token", "get_restore_token");

    ADD_SIGNAL(MethodInfo("state_changed", PropertyInfo(Variant::INT, "state")));
    ADD_SIGNAL(MethodInfo("stream_started"));
    ADD_SIGNAL(MethodInfo("stream_terminated", PropertyInfo(Variant::INT, "error_code"), PropertyInfo(Variant::STRING, "error_message")));
    ADD_SIGNAL(MethodInfo("restore_token_updated", PropertyInfo(Variant::STRING, "token")));
    ADD_SIGNAL(MethodInfo("stage_starting", PropertyInfo(Variant::STRING, "stage_name")));
    ADD_SIGNAL(MethodInfo("stage_complete", PropertyInfo(Variant::STRING, "stage_name")));
    ADD_SIGNAL(MethodInfo("stage_failed", PropertyInfo(Variant::STRING, "stage_name"), PropertyInfo(Variant::INT, "error_code")));
    ADD_SIGNAL(MethodInfo("connection_status_update", PropertyInfo(Variant::INT, "status")));
    ADD_SIGNAL(MethodInfo("reconnect_scheduled", PropertyInfo(Variant::INT, "attempt"), PropertyInfo(Variant::INT, "max_attempts"), PropertyInfo(Variant::INT, "delay_ms")));
    ADD_SIGNAL(MethodInfo("reconnect_attempt", PropertyInfo(Variant::INT, "attempt"), PropertyInfo(Variant::INT, "max_attempts")));
    ADD_SIGNAL(MethodInfo("reconnect_failed"));
    ADD_SIGNAL(MethodInfo("pair_completed", PropertyInfo(Variant::BOOL, "success"), PropertyInfo(Variant::STRING, "message")));
    ADD_SIGNAL(MethodInfo("log_message", PropertyInfo(Variant::STRING, "message")));
    ADD_SIGNAL(MethodInfo("h264_hw_upgraded"));
    ADD_SIGNAL(MethodInfo("controller_rumble", PropertyInfo(Variant::INT, "controller"), PropertyInfo(Variant::INT, "low_freq"), PropertyInfo(Variant::INT, "high_freq")));
    ADD_SIGNAL(MethodInfo("controller_trigger_rumble", PropertyInfo(Variant::INT, "controller"), PropertyInfo(Variant::INT, "left_motor"), PropertyInfo(Variant::INT, "right_motor")));
}
