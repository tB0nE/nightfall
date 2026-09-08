# Microphone Passthrough: Implementation Plan

> Status: Active proposal

## Overview

Add Apollo-specific microphone passthrough to Nightfall, allowing Quest microphone audio to be transmitted to the host PC during streaming. Only Apollo servers support this feature.

## Architecture

```
┌─────────────────────────────────────────┐
│              Godot (GDScript)           │
│                                         │
│  main.gd                                │
│   ├── microphone_enabled (bool)         │
│   ├── _microphone_supported (bool)      │
│   ├── _ui_mic_btn (Button)              │
│                                         │
│  settings_controller.gd                 │
│   └── toggle_microphone()               │
│                                         │
│  state_manager.gd                       │
│   └── save/load microphone_enabled      │
│                                         │
│  stream_manager.gd                      │
│   └── detect Apollo from app_version    │
└──────────────┬──────────────────────────┘
               │ stream_config["enable_microphone"]
               ▼
┌─────────────────────────────────────────┐
│        GDNative (C++ GDExtension)       │
│                                         │
│  nightfall_stream.h/cpp                 │
│   └── enable_microphone getter/setter   │
│                                         │
│  stream_connection.h/cpp                │
│   └── pass enableMic to LiStartConnection
│                                         │
│  microphone_manager.h/cpp [NEW]         │
│   ├── Init/Start/Stop capture           │
│   ├── Opus encoder worker thread        │
│   └── Calls LiSendMicrophoneOpusDataEx  │
└──────────────┬──────────────────────────┘
               │ enableMic in STREAM_CONFIGURATION
               ▼
┌─────────────────────────────────────────┐
│      moonlight-common-c (C library)     │
│                                         │
│  Fork from logabell/moonlight-common-c  │
│  branch: codex/mic-common-c             │
│                                         │
│  Changes:                               │
│   - enableMic field                     │
│   - ENCFLG_MICROPHONE (0x04)            │
│   - RTSP mic SDP negotiation            │
│   - MicrophoneStream.c (UDP send)       │
│   - LiSendMicrophoneOpusDataEx()        │
└─────────────────────────────────────────┘
```

## Phase 1: moonlight-common-c Patch

**Goal**: Enable moonlight-common-c to negotiate and send microphone streams.

### Option A: Use logabell's fork (preferred)
- Update `vcpkg-overlay/moonlight-common-c/portfile.cmake`
- Change REPO to `logabell/moonlight-common-c`
- Change REF to `codex/mic-common-c` branch commit hash
- Ensure our custom patches (`0001-add-install-rules.patch`, `0002-fix-clang-multiversioning-headers.patch`) still apply

### Option B: Manual patches
- Create new patches from logabell's changes
- Apply them via vcpkg_apply_patches

### API additions from microphone-common-c:
```c
// New in STREAM_CONFIGURATION
int enableMic;

// Encryption flag
#define ENCFLG_MICROPHONE 0x04

// New functions
int LiSendMicrophoneOpusDataEx(const unsigned char* opusData, int opusLength, uint32_t frameDurationSamples);
bool LiIsMicrophoneStreamActive(void);
bool LiIsMicrophoneEncryptionEnabled(void);
```

**Files affected**: `vcpkg-overlay/moonlight-common-c/portfile.cmake`

---

## Phase 2: GDNative Bridge Extensions

**Goal**: Expose microphone support through the C++ GDExtension layer.

### 2a: Enable microphone passthrough in stream configuration

**`stream_connection.cpp`** — In `start()`, read `enable_microphone` from `stream_config` dict:
```cpp
if (stream_config.has("enable_microphone")) {
    stream_config_.enableMic = (bool)stream_config["enable_microphone"];
}
if (stream_config_.enableMic) {
    stream_config_.encryptionFlags |= ENCFLG_MICROPHONE;
}
```

### 2b: New file — `src/audio/microphone_manager.h/cpp`

Microphone capture + Opus encoding thread.

```cpp
class MicrophoneManager : public RefCounted {
    GDCLASS(MicrophoneManager, RefCounted);
public:
    bool start_microphone(const String &device_id);
    void stop_microphone();
    bool is_active() const;
    bool is_host_supported() const;  // Did RTSP negotiate mic?
};
```

**Android**:
- Use AAudio or OpenSL ES for low-latency capture
- 48kHz mono PCM16 → Opus encode (24 kbps, 20ms frame)
- Call `LiSendMicrophoneOpusDataEx()` from encoder thread

**Linux/Desktop**:
- Use PipeWire audio capture
- Same Opus encoding pipeline

### 2c: Expose to Godot

**`nightfall_stream.h/cpp`**:
```cpp
void set_enable_microphone(bool enabled);
bool get_enable_microphone() const;
bool is_microphone_supported_by_host() const;
bool is_microphone_active() const;
```

**Files affected**:
- `src/audio/microphone_manager.h` [NEW]
- `src/audio/microphone_manager.cpp` [NEW]
- `src/video/stream_connection.h`
- `src/video/stream_connection.cpp`
- `src/nightfall_stream.h`
- `src/nightfall_stream.cpp`

---

## Phase 3: Godot UI — Settings Toggle

**Goal**: Add microphone passthrough toggle in Stream settings tab, greyed out when not supported.

### 3a: Variables in `main.gd`

```gdscript
var microphone_enabled: bool = false
var _microphone_supported: bool = false
@onready var _ui_mic_btn: Button
```

### 3b: Button creation in `ui_controller.gd`

Add to Stream tab row 2 (after Quick Start button):
```gdscript
main._ui_mic_btn = make_option_btn("Microphone", "Off")
stream_row2.add_child(main._ui_mic_btn)
main._ui_mic_btn.button_down.connect(func(): main.settings_controller.toggle_microphone())
```

### 3c: Toggle logic in `settings_controller.gd`

```gdscript
func toggle_microphone():
    if not main._microphone_supported:
        return
    main.microphone_enabled = not main.microphone_enabled
    _save_setting(main._ui_mic_btn, "On" if main.microphone_enabled else "Off")
```

### 3d: Update mic supported state from stream_manager

In `stream_manager.gd::_on_v2_launch_response()`, detect Apollo:
```gdscript
func _detect_microphone_support(app_version: String) -> bool:
    # Apollo: positive last version component
    # Sunshine: negative last version component
    # GFE: no mic support
    var parts = app_version.split(".")
    if parts.size() >= 4:
        var last = int(parts[3])
        return last >= 0  # Sunshine uses negative
    return false
```

### 3e: Save/load in `state_manager.gd`

```gdscript
# save
save.set_value("stream", "microphone_enabled", main.microphone_enabled)

# load
main.microphone_enabled = save.get_value("stream", "microphone_enabled", false)
```

**Files affected**:
- `main.gd`
- `ui_controller.gd`
- `settings_controller.gd`
- `state_manager.gd`
- `stream_manager.gd`

---

## Phase 4: Wire up at Stream Launch

**Goal**: Pass microphone setting from GDScript through GDNative to moonlight-common-c.

### 4a: `stream_manager.gd::_on_v2_launch_response()`

```gdscript
if main.microphone_enabled and main._microphone_supported:
    stream_config["enable_microphone"] = true
```

### 4b: `nightfall_stream.cpp::start_stream()`

```cpp
stream_connection_->set_enable_microphone(enable_microphone);
```

### 4c: `stream_connection.cpp::start()`

```cpp
stream_config_.enableMic = enable_microphone_;
if (enable_microphone_) {
    stream_config_.encryptionFlags |= ENCFLG_MICROPHONE;
}
```

### 4d: After `LiStartConnection()` succeeds, start MicrophoneManager

```cpp
if (enable_microphone_ && LiIsMicrophoneStreamActive()) {
    microphone_manager_->start_microphone(device_id_);
}
```

**Files affected**:
- `stream_manager.gd`
- `nightfall_stream.h/cpp`
- `stream_connection.h/cpp`
- `microphone_manager.h/cpp`

---

## Implementation Order

```
Phase 1: moonlight-common-c patch
         └── Update vcpkg portfile → rebuild
Phase 2a: GDNative stream_config change (enableMic passthrough)
Phase 3: Godot UI toggle (done independently of C library)
Phase 2b: MicrophoneManager capture + Opus encode
Phase 4: Wire everything together at stream launch
```

## Key Files Summary

| Layer | File | Role |
|-------|------|------|
| C lib | `vcpkg-overlay/moonlight-common-c/portfile.cmake` | Switch to mic-enabled fork |
| C++ | `src/video/stream_connection.cpp:1612` | Read `enable_microphone` from dict, set `stream_config_.enableMic` |
| C++ | `src/audio/microphone_manager.h/cpp` | [NEW] Capture + encode + send |
| C++ | `src/nightfall_stream.h/cpp` | Expose mic getter/setters to Godot |
| GDScript | `main.gd` | `microphone_enabled`, `_microphone_supported` vars |
| GDScript | `ui_controller.gd:413` | Mic button in Stream tab |
| GDScript | `settings_controller.gd` | `toggle_microphone()` |
| GDScript | `state_manager.gd` | Save/load mic state |
| GDScript | `stream_manager.gd:94` | Apollo detection from app_version |
| GDScript | `stream_manager.gd:121` | Pass `enable_microphone` in stream_config |
