#include "depth_bridge.h"
#include "nf_log.h"

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

void DepthBridge::submit_depth_frame(const PackedByteArray &frame_data, int width, int height) {
#ifdef __ANDROID__
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
#ifdef __ANDROID__
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
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "set_depth_model: no JNIEnv");
        return;
    }

    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "set_depth_model: FindClass failed");
        env->ExceptionClear();
        return;
    }

    jmethodID method = env->GetStaticMethodID(app_class, "setDepthModel", "(I)V");
    if (!method) {
        __android_log_print(ANDROID_LOG_ERROR, "DepthBridge", "set_depth_model: GetStaticMethodID failed");
        env->ExceptionClear();
        env->DeleteLocalRef(app_class);
        return;
    }

    env->CallStaticVoidMethod(app_class, method, (jint)model_index);
    env->DeleteLocalRef(app_class);
#endif
}

void DepthBridge::_bind_methods() {
    ClassDB::bind_method(D_METHOD("submit_depth_frame", "frame_data", "width", "height"), &DepthBridge::submit_depth_frame);
    ClassDB::bind_method(D_METHOD("get_depth_map"), &DepthBridge::get_depth_map);
    ClassDB::bind_method(D_METHOD("set_depth_model", "model_index"), &DepthBridge::set_depth_model);
}
