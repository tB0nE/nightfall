#include "meteor_xr_relay.h"
#if defined(__linux__) || defined(__ANDROID__)
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#ifdef __ANDROID__
#include <jni.h>
extern JavaVM *nightfall_get_jvm();
#endif
using namespace godot;
bool MeteorXrRelay::start(const Dictionary &settings) {
  MeteorXrRelayClient::Config config;
  config.address = String(settings.get("address", "")).utf8().get_data();
  int64_t video = settings.get("video", 0),
          tracking = settings.get("tracking", 0);
  if (video < 1 || video > 65535 || tracking < 1 || tracking > 65535)
    return false;
  config.video = uint16_t(video);
  config.tracking = uint16_t(tracking);
  auto copy = [&](const char *name, auto &target) {
    Variant value = settings.get(name, Variant());
    if (value.get_type() != Variant::PACKED_BYTE_ARRAY)
      return false;
    PackedByteArray bytes = value;
    if (size_t(bytes.size()) != target.size())
      return false;
    std::copy_n(bytes.ptr(), target.size(), target.begin());
    return true;
  };
  if (!copy("host", config.host) || !copy("identity", config.identity) ||
      !copy("server_nonce", config.server_nonce) ||
      !copy("client_nonce", config.client_nonce) ||
      !copy("session", config.session))
    return false;
  return client_.start(config);
}
Dictionary MeteorXrRelay::get_status() const {
  Dictionary result;
  result["failed"] = client_.failed();
  result["idle"] = client_.idle();
  result["connected_lanes"] = int(client_.connected_lanes());
  return result;
}
String MeteorXrRelay::get_config_path() const {
#ifdef __ANDROID__
  JavaVM *vm = nightfall_get_jvm();
  JNIEnv *env = nullptr;
  if (!vm ||
      vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK)
    return "";
  jclass app = env->FindClass("com/godot/game/GodotApp");
  if (!app) {
    env->ExceptionClear();
    return "";
  }
  jmethodID method = env->GetStaticMethodID(app, "getXrControlConfigPath",
                                            "()Ljava/lang/String;");
  if (!method) {
    env->ExceptionClear();
    env->DeleteLocalRef(app);
    return "";
  }
  auto value = static_cast<jstring>(env->CallStaticObjectMethod(app, method));
  env->DeleteLocalRef(app);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    if (value)
      env->DeleteLocalRef(value);
    return "";
  }
  if (!value)
    return "";
  const char *text = env->GetStringUTFChars(value, nullptr);
  if (!text) {
    env->ExceptionClear();
    env->DeleteLocalRef(value);
    return "";
  }
  String out = String::utf8(text);
  env->ReleaseStringUTFChars(value, text);
  env->DeleteLocalRef(value);
  return out;
#else
  return "";
#endif
}
void MeteorXrRelay::_bind_methods() {
  ClassDB::bind_method(D_METHOD("get_config_path"),
                       &MeteorXrRelay::get_config_path);
  ClassDB::bind_method(D_METHOD("start", "settings"), &MeteorXrRelay::start);
  ClassDB::bind_method(D_METHOD("stop"), &MeteorXrRelay::stop);
  ClassDB::bind_method(D_METHOD("get_status"), &MeteorXrRelay::get_status);
}
#endif
