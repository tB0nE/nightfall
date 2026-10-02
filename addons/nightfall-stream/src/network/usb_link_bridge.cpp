#include "usb_link_bridge.h"
#include "nf_log.h"

#ifdef __ANDROID__
#include <jni.h>
#include <android/log.h>

// Same JNI access pattern as depth_bridge.cpp - see that file's own comment
// for why (linker namespace isolation keeps a dlsym-derived JavaVM* null on
// this device/NDK combo; GodotApp.java's static initializer stashes a real
// one via initializeMoonlightJNI() before Godot even starts).
extern JavaVM *nightfall_get_jvm();

static JNIEnv *get_jni_env() {
    JavaVM *vm = nightfall_get_jvm();
    if (!vm) {
        __android_log_print(ANDROID_LOG_ERROR, "UsbLinkBridge", "get_jni_env: no JavaVM (initializeMoonlightJNI not called yet?)");
        return nullptr;
    }
    JNIEnv *env = nullptr;
    jint res = vm->GetEnv((void **)&env, JNI_VERSION_1_6);
    if (res == JNI_EDETACHED) {
        res = vm->AttachCurrentThread(&env, nullptr);
        if (res != JNI_OK) {
            __android_log_print(ANDROID_LOG_ERROR, "UsbLinkBridge", "get_jni_env: AttachCurrentThread failed result=%d", res);
            return nullptr;
        }
    } else if (res != JNI_OK) {
        __android_log_print(ANDROID_LOG_ERROR, "UsbLinkBridge", "get_jni_env: GetEnv failed result=%d", res);
        return nullptr;
    }
    return env;
}

// Shared boilerplate for every static GodotApp method call below: resolve
// the class, look up the method, clear any pending exception on failure so
// a missing method doesn't leave the JNIEnv unusable for the next call.
static bool find_static_method(JNIEnv *env, const char *name, const char *sig, jclass *out_class, jmethodID *out_method) {
    jclass app_class = env->FindClass("com/godot/game/GodotApp");
    if (!app_class) {
        __android_log_print(ANDROID_LOG_ERROR, "UsbLinkBridge", "%s: FindClass failed", name);
        env->ExceptionClear();
        return false;
    }
    jmethodID method = env->GetStaticMethodID(app_class, name, sig);
    if (!method) {
        __android_log_print(ANDROID_LOG_ERROR, "UsbLinkBridge", "%s: GetStaticMethodID failed", name);
        env->ExceptionClear();
        env->DeleteLocalRef(app_class);
        return false;
    }
    *out_class = app_class;
    *out_method = method;
    return true;
}

// A Java exception left pending makes the next JNI call on this thread abort
// the whole process (seen as a crash inside an unrelated bridge), so every
// call clears its own.
static bool clear_exception(JNIEnv *env, const char *name) {
    if (!env->ExceptionCheck()) return false;
    __android_log_print(ANDROID_LOG_ERROR, "UsbLinkBridge", "%s: Java exception", name);
    env->ExceptionDescribe();
    env->ExceptionClear();
    return true;
}
#endif

using namespace godot;

UsbLinkBridge::UsbLinkBridge() {}
UsbLinkBridge::~UsbLinkBridge() {}

bool UsbLinkBridge::is_supported() {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return false;
    jclass app_class;
    jmethodID method;
    if (!find_static_method(env, "isUsbLinkSupported", "()Z", &app_class, &method)) return false;
    jboolean result = env->CallStaticBooleanMethod(app_class, method);
    env->DeleteLocalRef(app_class);
    if (clear_exception(env, "isUsbLinkSupported")) return false;
    return result;
#else
    return false;
#endif
}

bool UsbLinkBridge::start() {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return false;
    jclass app_class;
    jmethodID method;
    if (!find_static_method(env, "startUsbLink", "()Z", &app_class, &method)) return false;
    jboolean result = env->CallStaticBooleanMethod(app_class, method);
    env->DeleteLocalRef(app_class);
    if (clear_exception(env, "startUsbLink")) return false;
    return result;
#else
    return false;
#endif
}

void UsbLinkBridge::stop() {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return;
    jclass app_class;
    jmethodID method;
    if (!find_static_method(env, "stopUsbLink", "()V", &app_class, &method)) return;
    env->CallStaticVoidMethod(app_class, method);
    env->DeleteLocalRef(app_class);
    clear_exception(env, "stopUsbLink");
#endif
}

bool UsbLinkBridge::is_up() {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return false;
    jclass app_class;
    jmethodID method;
    if (!find_static_method(env, "isUsbLinkUp", "()Z", &app_class, &method)) return false;
    jboolean result = env->CallStaticBooleanMethod(app_class, method);
    env->DeleteLocalRef(app_class);
    if (clear_exception(env, "isUsbLinkUp")) return false;
    return result;
#else
    return false;
#endif
}

PackedStringArray UsbLinkBridge::get_link_local_addresses() {
    PackedStringArray out;
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return out;
    jclass app_class;
    jmethodID method;
    if (!find_static_method(env, "getUsbLinkAddresses", "()Ljava/lang/String;", &app_class, &method)) return out;
    jstring joined = (jstring)env->CallStaticObjectMethod(app_class, method);
    env->DeleteLocalRef(app_class);
    if (clear_exception(env, "getUsbLinkAddresses")) return out;
    if (!joined) return out;
    const char *chars = env->GetStringUTFChars(joined, nullptr);
    if (chars) {
        String joined_str = String::utf8(chars);
        env->ReleaseStringUTFChars(joined, chars);
        if (!joined_str.is_empty()) {
            out = joined_str.split("|", false);
        }
    }
    env->DeleteLocalRef(joined);
#endif
    return out;
}

static String call_static_string(const char *name) {
#ifdef __ANDROID__
    JNIEnv *env = get_jni_env();
    if (!env) return String();
    jclass app_class;
    jmethodID method;
    if (!find_static_method(env, name, "()Ljava/lang/String;", &app_class, &method)) return String();
    jstring result = (jstring)env->CallStaticObjectMethod(app_class, method);
    env->DeleteLocalRef(app_class);
    if (clear_exception(env, name)) return String();
    if (!result) return String();
    String out;
    const char *chars = env->GetStringUTFChars(result, nullptr);
    if (chars) {
        out = String::utf8(chars);
        env->ReleaseStringUTFChars(result, chars);
    }
    env->DeleteLocalRef(result);
    return out;
#else
    return String();
#endif
}

String UsbLinkBridge::current_interface_name() {
    return call_static_string("getUsbLinkInterfaceName");
}

String UsbLinkBridge::get_interface_name() {
    return current_interface_name();
}

String UsbLinkBridge::zone_link_local(const String &addr) {
    if (!addr.to_lower().begins_with("fe80:") || addr.find("%") != -1) {
        return addr;
    }
    String iface = current_interface_name();
    return iface.is_empty() ? addr : addr + String("%") + iface;
}

String UsbLinkBridge::describe_link_properties() {
    return call_static_string("describeUsbLinkProperties");
}

String UsbLinkBridge::get_active_transport() {
    return call_static_string("getActiveNetworkTransport");
}

void UsbLinkBridge::_bind_methods() {
    ClassDB::bind_method(D_METHOD("is_supported"), &UsbLinkBridge::is_supported);
    ClassDB::bind_method(D_METHOD("start"), &UsbLinkBridge::start);
    ClassDB::bind_method(D_METHOD("stop"), &UsbLinkBridge::stop);
    ClassDB::bind_method(D_METHOD("is_up"), &UsbLinkBridge::is_up);
    ClassDB::bind_method(D_METHOD("get_link_local_addresses"), &UsbLinkBridge::get_link_local_addresses);
    ClassDB::bind_method(D_METHOD("get_interface_name"), &UsbLinkBridge::get_interface_name);
    ClassDB::bind_method(D_METHOD("describe_link_properties"), &UsbLinkBridge::describe_link_properties);
    ClassDB::bind_method(D_METHOD("get_active_transport"), &UsbLinkBridge::get_active_transport);
}
