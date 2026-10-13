#include "android_audio_backend.h"
#ifdef __ANDROID__
#include "nf_log.h"
extern JavaVM *nightfall_get_jvm();
extern jclass nightfall_get_godot_app_class();
namespace {
// Attached native worker threads must detach before exiting. JVM-owned threads
// must not be detached, including Godot's Java startup thread.
struct ThreadEnv {
    JavaVM *vm = nightfall_get_jvm();
    JNIEnv *env = nullptr;
    bool attached = false;
    ThreadEnv() {
        if (!vm) return;
        jint result = vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
        if (result == JNI_EDETACHED) {
            attached = vm->AttachCurrentThread(&env, nullptr) == JNI_OK;
            if (!attached) env = nullptr;
        } else if (result != JNI_OK) env = nullptr;
    }
    ~ThreadEnv() { if (attached) vm->DetachCurrentThread(); }
};
struct Env {
    JNIEnv *env;
    Env() {
        thread_local ThreadEnv thread;
        env = thread.env;
    }
    bool ok() {
        if (!env) return false;
        if (!env->ExceptionCheck()) return true;
        env->ExceptionDescribe(); env->ExceptionClear();
        NF_LOGE("AudioOutput", "AudioTrack JNI exception");
        return false;
    }
};
}
namespace nightfall {
void log_audio_diagnostic(const char *message) {
    Env e;
    jclass cls = nightfall_get_godot_app_class();
    if (!e.env || !cls) return;
    jmethodID method = e.env->GetStaticMethodID(cls, "logAudioDiagnostics", "(Ljava/lang/String;)V");
    if (!e.ok() || !method) return;
    jstring text = e.env->NewStringUTF(message);
    if (!e.ok() || !text) return;
    e.env->CallStaticVoidMethod(cls, method, text);
    e.ok();
    e.env->DeleteLocalRef(text);
}
bool AndroidAudioBackend::initialize(int rate, int channels, int period) {
    Env e;
    jclass cls = nightfall_get_godot_app_class();
    if (!e.env || !cls) return false;
    open_ = e.env->GetStaticMethodID(cls, "openAudioTrack", "(III)Z");
    if (!e.ok() || !open_) return false;
    write_ = e.env->GetStaticMethodID(cls, "writeAudioTrack", "([FI)Z");
    if (!e.ok() || !write_) return false;
    close_ = e.env->GetStaticMethodID(cls, "closeAudioTrack", "()V");
    if (!e.ok() || !close_) return false;
    pause_ = e.env->GetStaticMethodID(cls, "pauseAudioTrack", "()V");
    if (!e.ok() || !pause_) return false;
    resume_ = e.env->GetStaticMethodID(cls, "resumeAudioTrack", "()V");
    if (!e.ok() || !resume_) return false;
    latency_ = e.env->GetStaticMethodID(cls, "audioTrackLatency", "()I");
    if (!e.ok() || !latency_) return false;
    bool opened = e.env->CallStaticBooleanMethod(cls, open_, rate, channels, period);
    initialized_ = e.ok() && opened;
    channels_ = channels;
    return initialized_;
}
void AndroidAudioBackend::shutdown() {
    Env e;
    if (!e.env) return;
    if (initialized_) { e.env->CallStaticVoidMethod(nightfall_get_godot_app_class(), close_); e.ok(); }
    initialized_ = false;
    if (samples_) e.env->DeleteGlobalRef(samples_);
    samples_ = nullptr; capacity_ = 0;
}
bool AndroidAudioBackend::write_pcm(const float *data, size_t frames) {
    Env e;
    if (!e.env || !initialized_) return false;
    int count = static_cast<int>(frames * channels_);
    if (count > capacity_) {
        jfloatArray local = e.env->NewFloatArray(count);
        if (!e.ok() || !local) return false;
        jfloatArray global = static_cast<jfloatArray>(e.env->NewGlobalRef(local));
        e.env->DeleteLocalRef(local);
        if (!e.ok() || !global) return false;
        if (samples_) e.env->DeleteGlobalRef(samples_);
        samples_ = global; capacity_ = count;
    }
    e.env->SetFloatArrayRegion(samples_, 0, count, data);
    if (!e.ok()) return false;
    bool result = e.env->CallStaticBooleanMethod(nightfall_get_godot_app_class(), write_, samples_, static_cast<int>(frames));
    return e.ok() && result;
}
void AndroidAudioBackend::pause() { Env e; if (e.env && initialized_) { e.env->CallStaticVoidMethod(nightfall_get_godot_app_class(), pause_); e.ok(); } }
void AndroidAudioBackend::resume() { Env e; if (e.env && initialized_) { e.env->CallStaticVoidMethod(nightfall_get_godot_app_class(), resume_); e.ok(); } }
int AndroidAudioBackend::get_latency_ms() const {
    Env e;
    if (!e.env || !initialized_) return 0;
    int result = e.env->CallStaticIntMethod(nightfall_get_godot_app_class(), latency_);
    return e.ok() ? result : 0;
}
}
#endif
