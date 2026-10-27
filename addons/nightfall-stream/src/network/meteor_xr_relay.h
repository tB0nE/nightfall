#pragma once
#if defined(__linux__) || defined(__ANDROID__)
#include "meteor_xr_relay_client.h"
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
namespace godot {
class MeteorXrRelay : public RefCounted {
  GDCLASS(MeteorXrRelay, RefCounted);

public:
  bool start(const Dictionary &settings);
  void stop() { client_.stop(); }
  Dictionary get_status() const;
  String get_config_path() const;

protected:
  static void _bind_methods();

private:
  MeteorXrRelayClient client_;
};
} // namespace godot
#endif
