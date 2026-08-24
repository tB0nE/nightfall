#include "depth_bridge.h"
#include "nf_log.h"

#ifdef NIGHTFALL_PLATFORM_LINUX
#include "midas_depth_engine.h"

#include <cstdint>
#include <cstring>
#include <vector>

#include <godot_cpp/classes/os.hpp>

// Loose files next to the running executable, NOT through Godot's res:///PCK
// - build.sh's Linux PCK export (--export-pack, using the Android preset as
// a headless-export workaround) never includes android/src/main/assets/, so
// fighting the resource/import pipeline for two ~17MB binary blobs isn't
// worth it. Mirrors the exact pattern already used for the GDExtension .so
// itself and the Meta OpenXR vendor plugin AAR - see build.sh's AppImage-
// assembly section for where "depth_models/" actually gets populated.
static std::string nightfall_resolve_model_dir() {
    godot::String exe_path = godot::OS::get_singleton()->get_executable_path();
    godot::String dir = exe_path.get_base_dir();
    return std::string((dir + "/depth_models").utf8().get_data());
}
#endif

#ifdef __ANDROID__
#include <jni.h>
#include <android/log.h>

// dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs") (the old approach here) fails
// on this device/NDK combo - modern Android's linker namespace isolation
// keeps libnativehelper/libart symbols out of a GDExtension .so's default
// symbol view, so every submit_depth_frame/get_depth_map/set_depth_model
// call was silently getting a null JNIEnv and no-op'ing, for the whole
// depth pipeline's lifetime. ffmpeg_decoder.cpp already solved this properly
// for MediaCodec access: GodotApp.java's static initializer calls
// initializeMoonlightJNI() before Godot even starts, which stashes a real
// JavaVM* via env->GetJavaVM() - reuse that instead of re-deriving one.
extern JavaVM *nightfall_get_jvm();

static JNIEnv *get_jni_env() {
    JavaVM *vm = nightfall_get_jvm();
    if (!vm) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "get_jni_env: no JavaVM (initializeMoonlightJNI not called yet?)");
        return nullptr;
    }
    JNIEnv *env = nullptr;
    jint res = vm->GetEnv((void **)&env, JNI_VERSION_1_6);
    if (res == JNI_EDETACHED) {
        res = vm->AttachCurrentThread(&env, nullptr);
        if (res != JNI_OK) {
            __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "get_jni_env: AttachCurrentThread failed result=%d", res);
            return nullptr;
        }
    } else if (res != JNI_OK) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "get_jni_env: GetEnv failed result=%d", res);
        return nullptr;
    }
    return env;
}
#endif

using namespace godot;

DepthBridge::DepthBridge() {}
DepthBridge::~DepthBridge() {}

#ifdef NIGHTFALL_PLATFORM_LINUX
void DepthBridge::ensure_midas_engine() {
    if (midas_engine_) return;
    midas_engine_ = std::make_unique<MidasDepthEngine>();
    midas_engine_->initialize(nightfall_resolve_model_dir());
}
#endif

void DepthBridge::submit_depth_frame(const PackedByteArray &frame_data, int width, int height) {
#ifdef NIGHTFALL_PLATFORM_LINUX
    ensure_midas_engine();
    if (midas_engine_) {
        midas_engine_->submit_frame(frame_data.ptr(), (size_t)frame_data.size(), width, height);
    }
#elif defined(__ANDROID__)
    JNIEnv *env = get_jni_env();
    if (!env) return;

    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) return;

    jmethodID method = env->GetStaticMethodID(app_class, "submitDepthFrame", "([BII)V");
    if (!method) {
        env->DeleteLocalRef(app_class);
        return;
    }

    jbyteArray input_array = env->NewByteArray(frame_data.size());
    env->SetByteArrayRegion(input_array, 0, frame_data.size(), reinterpret_cast<const jbyte *>(frame_data.ptr()));
    env->CallStaticVoidMethod(app_class, method, input_array, width, height);
    env->DeleteLocalRef(input_array);
    env->DeleteLocalRef(app_class);
#endif
}

PackedByteArray DepthBridge::get_depth_map() {
    PackedByteArray empty;
#ifdef NIGHTFALL_PLATFORM_LINUX
    if (!midas_engine_) return empty;
    std::vector<uint8_t> depth = midas_engine_->get_latest_depth();
    if (depth.empty()) return empty;
    PackedByteArray depth_data;
    depth_data.resize(depth.size());
    memcpy(depth_data.ptrw(), depth.data(), depth.size());
    return depth_data;
#elif defined(__ANDROID__)
    JNIEnv *env = get_jni_env();
    if (!env) return empty;

    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) return empty;

    jmethodID method = env->GetStaticMethodID(app_class, "getLatestDepthMap", "()[B");
    if (!method) {
        env->DeleteLocalRef(app_class);
        return empty;
    }

    jbyteArray result_array = (jbyteArray)env->CallStaticObjectMethod(app_class, method);

    PackedByteArray depth_data;
    if (result_array) {
        jsize len = env->GetArrayLength(result_array);
        if (len > 0) {
            depth_data.resize(len);
            jbyte *bytes = env->GetByteArrayElements(result_array, nullptr);
            memcpy(depth_data.ptrw(), bytes, len);
            env->ReleaseByteArrayElements(result_array, bytes, JNI_ABORT);
        }
        env->DeleteLocalRef(result_array);
    }

    env->DeleteLocalRef(app_class);
    return depth_data;
#else
    return empty;
#endif
}

void DepthBridge::set_depth_model(int model_index) {
    configure_depth(model_index, DEPTH_BACKEND_CPU);
}

void DepthBridge::configure_depth(int model_index, int requested_backend) {
    selected_model_index_ = model_index;
    requested_backend_ = requested_backend >= DEPTH_BACKEND_AUTO && requested_backend <= DEPTH_BACKEND_GPU
            ? requested_backend : DEPTH_BACKEND_AUTO;
#ifdef NIGHTFALL_PLATFORM_LINUX
    ensure_midas_engine();
    if (midas_engine_) {
        midas_engine_->set_active_model(model_index);
    }
    effective_backend_ = DEPTH_BACKEND_CPU;
    backend_status_ = requested_backend_ == DEPTH_BACKEND_GPU
            ? "GPU depth is unavailable on Linux; using CPU" : "";
#elif defined(__ANDROID__)
    JNIEnv *env = get_jni_env();
    if (!env) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "configure_depth: no JNIEnv");
        effective_backend_ = DEPTH_BACKEND_CPU;
        backend_status_ = "Android depth runtime unavailable; using CPU";
        return;
    }

    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "configure_depth: FindClass failed");
        env->ExceptionClear();
        effective_backend_ = DEPTH_BACKEND_CPU;
        backend_status_ = "Android depth runtime unavailable; using CPU";
        return;
    }

    jmethodID method = env->GetStaticMethodID(app_class, "configureDepth", "(II)V");
    if (!method) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "configure_depth: GetStaticMethodID failed");
        env->ExceptionClear();
        env->DeleteLocalRef(app_class);
        effective_backend_ = DEPTH_BACKEND_CPU;
        backend_status_ = "Android depth runtime unavailable; using CPU";
        return;
    }

    env->CallStaticVoidMethod(app_class, method, (jint)model_index, (jint)requested_backend_);
    env->DeleteLocalRef(app_class);
#else
    effective_backend_ = DEPTH_BACKEND_CPU;
    backend_status_ = requested_backend_ == DEPTH_BACKEND_GPU
            ? "GPU depth is unavailable on this platform; using CPU" : "";
#endif
}

int DepthBridge::get_depth_backend_capabilities(int model_index) {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return DEPTH_BACKEND_CAP_CPU;
    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) {
        env->ExceptionClear();
        return DEPTH_BACKEND_CAP_CPU;
    }
    jmethodID method = env->GetStaticMethodID(app_class, "getDepthBackendCapabilities", "(I)I");
    if (!method) {
        env->ExceptionClear();
        env->DeleteLocalRef(app_class);
        return DEPTH_BACKEND_CAP_CPU;
    }
    jint capabilities = env->CallStaticIntMethod(app_class, method, (jint)model_index);
    env->DeleteLocalRef(app_class);
    return (int)capabilities;
#else
    (void)model_index;
    return DEPTH_BACKEND_CAP_CPU;
#endif
}

int DepthBridge::get_effective_depth_backend() {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return effective_backend_;
    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) {
        env->ExceptionClear();
        return effective_backend_;
    }
    jmethodID method = env->GetStaticMethodID(app_class, "getEffectiveDepthBackend", "()I");
    if (!method) {
        env->ExceptionClear();
        env->DeleteLocalRef(app_class);
        return effective_backend_;
    }
    effective_backend_ = (int)env->CallStaticIntMethod(app_class, method);
    env->DeleteLocalRef(app_class);
#endif
    return effective_backend_;
}

String DepthBridge::get_depth_backend_status() {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return backend_status_;
    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) {
        env->ExceptionClear();
        return backend_status_;
    }
    jmethodID method = env->GetStaticMethodID(app_class, "getDepthBackendStatus", "()Ljava/lang/String;");
    if (!method) {
        env->ExceptionClear();
        env->DeleteLocalRef(app_class);
        return backend_status_;
    }
    jstring status = (jstring)env->CallStaticObjectMethod(app_class, method);
    if (status) {
        const char *chars = env->GetStringUTFChars(status, nullptr);
        if (chars) {
            backend_status_ = String::utf8(chars);
            env->ReleaseStringUTFChars(status, chars);
        }
        env->DeleteLocalRef(status);
    }
    env->DeleteLocalRef(app_class);
#endif
    return backend_status_;
}

int DepthBridge::get_depth_model_size() {
#ifdef NIGHTFALL_PLATFORM_LINUX
    if (!midas_engine_) return 256;
    return midas_engine_->get_model_size();
#elif defined(__ANDROID__)
    JNIEnv *env = get_jni_env();
    if (!env) return 256;

    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) return 256;

    jmethodID method = env->GetStaticMethodID(app_class, "getDepthModelSize", "()I");
    if (!method) {
        env->DeleteLocalRef(app_class);
        return 256;
    }

    jint size = env->CallStaticIntMethod(app_class, method);
    env->DeleteLocalRef(app_class);
    return (int)size;
#else
    return 256;
#endif
}

void DepthBridge::_bind_methods() {
    ClassDB::bind_method(D_METHOD("submit_depth_frame", "frame_data", "width", "height"), &DepthBridge::submit_depth_frame);
    ClassDB::bind_method(D_METHOD("get_depth_map"), &DepthBridge::get_depth_map);
    ClassDB::bind_method(D_METHOD("set_depth_model", "model_index"), &DepthBridge::set_depth_model);
    ClassDB::bind_method(D_METHOD("configure_depth", "model_index", "requested_backend"), &DepthBridge::configure_depth);
    ClassDB::bind_method(D_METHOD("get_depth_backend_capabilities", "model_index"), &DepthBridge::get_depth_backend_capabilities);
    ClassDB::bind_method(D_METHOD("get_effective_depth_backend"), &DepthBridge::get_effective_depth_backend);
    ClassDB::bind_method(D_METHOD("get_depth_backend_status"), &DepthBridge::get_depth_backend_status);
    ClassDB::bind_method(D_METHOD("get_depth_model_size"), &DepthBridge::get_depth_model_size);
}
