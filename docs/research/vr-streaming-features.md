# VR Streaming / Remote Desktop Feature Research

Non-VR-app-running features across Bigscreen VR, ALVR, Moonlight, Meta Quest Link/Air Link, Virtual Desktop, and Immersed.

---

## 1. Display Settings

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| Resolution presets (low/medium/high/custom) | - | X | X | X | X | - |
| Custom render resolution scale (%) | - | X | X | X | X | - |
| Refresh rate selection (72/80/90/120 Hz) | - | X | X | X | X | - |
| Codec selection (H.264/HEVC/AV1) | - | X | X | X | - | - |
| Bitrate control (constant/adaptive) | - | X | X | X | X | - |
| Encoder preset selection (speed/quality) | - | X | X | - | - | - |
| Software encoding option (x264) | - | X | - | - | - | - |
| Fixed Foveated Rendering (FFR) | - | X | - | X | - | - |
| FFR strength/center size/center offset | - | X | - | - | - | - |
| FFR methods (warp vs slices) | - | X | - | - | - | - |
| HDR streaming | - | - | X | X | X | - |
| YUV 4:4:4 color support | - | - | X | - | - | - |
| Sharpening filter | - | X | - | - | X | - |
| Brightness/contrast/gamma sliders | - | X | - | - | X | - |
| Color correction (brightness, contrast, saturation) | - | X | - | - | X | - |
| Render resolution per-eye | - | X | - | X | X | - |
| Maximum decode resolution (4K, 5K) | - | X | X | X | X | - |
| Variable rate encoding (match content updates) | - | - | X (via Sunshine) | - | - | - |
| Frame buffering control | - | X | - | - | - | - |
| Color space selection | - | X | - | X | - | - |
| Display sleep/wake control | - | - | X | - | - | - |
| V-Sync toggle | - | - | X | - | - | - |

---

## 2. Backgrounds / Virtual Environments

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| Void/black environment | X | X | - | X | X | - |
| Custom image/video backgrounds | X | - | - | - | X | - |
| Pre-built scenic environments | X | - | - | - | X | X |
| Passthrough (camera-based) | X | - | - | X | X | X |
| Environment brightness/ambient light | X | - | - | X | X | X |
| Skybox/environment import | X | - | - | - | X | - |
| Home theater/cinema environments | X | - | - | - | X | - |
| Outdoor/nature environments | X | - | - | - | X | X |
| Office/workspace environments | - | - | - | - | X | X |
| Background blur (passthrough) | - | - | - | X | - | - |
| Background audio/ambient sound | - | - | - | - | X | X |

---

## 3. Screen / Monitor Configuration

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| Multi-monitor support | X | - | X | X | X | X |
| Up to 5 virtual monitors | - | - | - | - | - | X |
| Screen size adjustment | X | - | - | X | X | X |
| Screen curvature | X | - | - | X | X | X |
| Screen distance adjustment | X | - | - | X | X | X |
| Screen position (height/angle) | X | - | - | - | X | X |
| Screen orientation (portrait/landscape) | - | - | - | - | X | X |
| Floating vs fixed screen | X | - | - | - | X | - |
| Subscreen/secondary display offset | X | - | - | - | - | - |
| Side-by-side vs surround layout | X | - | - | X | X | X |
| Giant screen (IMAX-style) mode | X | - | - | - | X | - |

---

## 4. Controls / Input

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| Laser pointer (controller-based) | X | - | - | X | X | X |
| Hand tracking input | - | X | - | X | - | - |
| Hand tracking gesture bindings | - | X | - | - | - | - |
| Gesture toggle (Only Touch mode) | - | X | - | - | - | - |
| Pinch gestures (trigger/grip/menu) | - | X | - | - | - | - |
| Virtual joystick via hand curl | - | X | - | - | - | - |
| Keyboard pass-through | X | - | X | X | X | X |
| Mouse pass-through | X | - | X | X | X | X |
| Gamepad support (Xbox/PS/etc.) | - | - | X | - | - | - |
| Force feedback / haptics | - | - | X | - | - | - |
| Motion controls (gyro/accel) | - | - | X | - | - | - |
| Up to 16 simultaneous controllers | - | - | X | - | - | - |
| System shortcut pass-through (Alt+Tab etc.) | - | - | X | - | - | - |
| Pointer capture mode (for games) | - | - | X | - | - | - |
| Direct mouse control mode (remote desktop) | - | - | X | - | X | X |
| Touchscreen support (trackpad/direct modes) | - | - | X | - | - | - |
| Multitouch (10-point) | - | - | X | - | - | - |
| Clipboard text passthrough (Ctrl+Alt+Shift+V) | - | - | X | - | - | - |
| Mouse emulation via gamepad (Start hold) | - | - | X | - | - | - |
| On-screen virtual keyboard | X | - | - | X | X | X |
| USB device passthrough (VirtualHere) | - | - | X | - | - | - |

---

## 5. Audio Options

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| Stream PC audio to headset | X | X | X | X | X | X |
| Microphone passthrough | X | - | X | X | X | X |
| 7.1 surround sound | - | - | X | X | - | - |
| Audio bitrate selection | - | X | - | - | - | - |
| Audio device selection on host | - | - | X | - | - | - |
| Spatial audio / 3D audio | X | - | - | X | X | - |
| Volume control | X | - | - | X | X | X |
| Mute toggle | X | - | - | X | X | - |
| Ambient environment audio | - | - | - | - | X | X |

---

## 6. Overlays & UI

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| Performance stats overlay | - | X | X | X | X | - |
| FPS counter | - | X | X | X | X | - |
| Latency graph (encode/network/decode) | - | X | X | - | X | - |
| Bitrate display | - | X | X | - | - | - |
| Frame drop counter | - | - | X | - | - | - |
| Network quality indicator | - | X | - | X | X | - |
| Battery level overlay | - | - | - | X | - | - |
| Guardian/boundary overlay | - | - | - | X | - | - |
| In-VR settings panel | X | X | - | X | X | X |
| Quick-access menu (long press) | - | - | - | X | - | - |
| Dockable toolbar | X | - | - | - | X | - |
| On-screen keyboard overlay | X | - | - | X | X | X |

---

## 7. Screenshot / Recording

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| Screenshot capture | X | - | - | X | X | - |
| Video recording | X | - | - | X | X | - |
| Casting to phone/browser | - | - | - | X | - | - |
| Livestream integration | X | - | - | - | - | - |
| Share to social | X | - | - | - | - | - |
| Capture button on controller | - | - | - | X | - | - |

---

## 8. Network & Connection

| Feature | Bigscreen | ALVR | Moonlight | Meta Quest Link | Virtual Desktop | Immersed |
|---------|-----------|------|-----------|-----------------|-----------------|----------|
| WiFi (wireless) streaming | X | X | X | X | X | X |
| USB (wired) streaming | - | X | - | X | - | - |
| TCP or UDP protocol selection | - | X | - | - | - | - |
| Internet streaming (remote) | - | - | X | - | - | - |
| UPnP automatic port forwarding | - | - | X | - | - | - |
| VPN support (ZeroTier/Tailscale) | - | - | X | - | - | - |
| Auto-discovery on LAN | - | X | X | X | X | X |
| Manual IP connection | - | X | X | - | - | - |
| Connection statistics dashboard | - | X | X | X | X | - |
| Automatic reconnection | - | X | - | X | X | - |
| Wake-on-LAN | - | - | X | - | - | - |
| End-to-end encryption | - | - | X | - | - | - |

---

## 9. Unique / Notable Features

### Bigscreen VR
- Social/multiuser rooms (watch movies with friends as avatars)
- Movie theater/cinema simulation with tiered seating
- Avatar customization
- Public and private rooms
- Voice chat with spatial audio
- Screen sharing with other users
- Bigscreen Beyond (own hardware - ultra-lightweight PCVR headset)
- Desktop mirroring in shared spaces

### ALVR
- Fully open source (Apache-2.0 license)
- Fixed Foveated Encoding (two methods: warp and slices)
- Hand tracking controller bindings (pinch/curl gesture mappings)
- Color correction pipeline (brightness, contrast, saturation, sharpening)
- Linux host support (including Flatpak)
- Monado driver (support for non-SteamVR runtimes)
- Experimental real-time video upscaling (FSR/NIS)
- Hardware encoder selection (NVENC, AMF, VideoToolbox, VAAPI)
- AMF pre-processor option
- Statistics tab with detailed latency graphs
- Custom resolution presets
- Configurable max buffering frames
- Nightly builds with bleeding-edge features

### Moonlight (GameStream/Sunshine client)
- Multi-platform (Windows, macOS, Linux, Android, iOS, ChromeOS, Steam Link, Raspberry Pi, Xbox, PS Vita, Nintendo Switch, Wii U, LG webOS TV)
- HDR10 streaming support
- YUV 4:4:4 chroma sampling
- AV1 codec support (with Sunshine + supported GPU)
- 10-point multitouch support
- Gamepad support for up to 16 players with force feedback
- Performance stats overlay (Ctrl+Alt+Shift+S)
- Fullscreen/windowed toggle (Ctrl+Alt+Shift+X)
- Remote desktop optimized mouse mode
- Clipboard passthrough
- Pointer lock to video area
- Frame pacing options (lowest latency / balanced / smoothest video)
- Hardware-accelerated video decoding
- Embedded mode for single-purpose devices
- Vulkan renderer with libplacebo
- End-to-end encryption (with Sunshine v0.22+)
- Host agnostic: works with Sunshine (open source), GeForce Experience, Wolf (Docker)
- Sunshine provides: virtual display, multi-monitor, HDR toggle, audio device selection

### Meta Quest Link / Air Link
- Official Oculus/Meta integration (free, built-in)
- Oculus Dash overlay (persistent 2D panel system in VR)
- Guardian boundary system
- Passthrough camera view
- Physical keyboard tracking (Quest 3+)
- Hand tracking support
- USB-C wired and WiFi wireless modes
- Automatic bitrate adjustment
- Fixed Foveated Rendering
- 120 Hz support (Quest 2+)
- In-headset settings (no PC app needed)
- Quest Pro face/eye tracking passthrough
- Debug tool (Oculus Debug Tool) for advanced settings:
  - Render resolution override
  - Encode bitrate override
  - FFR level (0-4)
  - Link sharpening feature
  - Distortion curve override
  - Switch to lower codecs
- Snap turn / smooth turn options
- Boundary visibility toggle
- Auto-wake headset

### Virtual Desktop (paid app by Guy Godin)
- Custom environments (void, space, theater, outdoors)
- Environment brightness slider
- Screen brightness/contrast/saturation controls
- Sweetspot (sharpening filter)
- Multiple screen layouts (single, side-by-side, curved surround)
- Screen size/distance/curvature/height adjustment
- Portrait mode for screens
- Godrays filter (reduces lens artifact visibility)
- Multi-monitor support (up to monitors connected to PC)
- Vive/Index controller support via Quest controllers
- Hand tracking to controller emulation
- Mic passthrough
- Audio streaming with spatial audio
- HDR support
- 120 Hz streaming
- Performance stats overlay
- In-VR settings menu
- Screenshot/video recording
- Ambient audio in environments
- Automatic reconnection
- NVENC/AMF encoder selection

### Immersed
- Up to 5 virtual monitors (3 free, 2 paid)
- Remote collaboration / telepresence (4+ people in same room)
- Multi-screen sharing with other users
- Remote whiteboarding
- Public and private workspaces
- Portrait/landscape orientation per monitor
- Curved screen option
- Environment selection (nature scenes, offices)
- Ambient music/sound
- Camera passthrough
- Mac, Windows, Linux support
- Apple Vision Pro and Visor headset support
- Focus/productivity-oriented (no games)
- Low-latency wireless streaming
- Keyboard passthrough/visibility in passthrough
- No subscription required
- Team chat features
- Virtual office spaces

---

## 10. Feature Matrix Summary by Category

### Most Complete Apps Per Category

- **Display Settings**: ALVR (most granular codec/resolution/FFR controls)
- **Backgrounds/Environments**: Bigscreen (cinemas, custom images, social spaces)
- **Screen Configuration**: Immersed (up to 5 monitors, orientation, layout)
- **Input/Controls**: Moonlight (gamepad, multitouch, keyboard shortcuts, clipboard)
- **Audio**: Moonlight (7.1 surround, multi-platform audio)
- **Overlays/UI**: ALVR + Moonlight (detailed latency/stats)
- **Network**: Moonlight (internet streaming, VPN, encryption, Wake-on-LAN)
- **Social/Collaboration**: Bigscreen + Immersed
- **Open Source**: ALVR + Moonlight
- **Productivity**: Immersed (5 monitors, whiteboarding, telepresence)

---

## 11. Feature Ideas for Moonlight Quest (This Project)

Features from the above research that are most relevant for a VR remote desktop client:

### High Priority (common across most apps)
1. Resolution presets and custom scale slider
2. Bitrate slider (adaptive + manual)
3. Codec selection (H.264, HEVC, AV1)
4. Refresh rate selection
5. Void/black environment + passthrough
6. Performance stats overlay (FPS, latency, bitrate, frame drops)
7. Screen size/distance/curvature controls
8. Multi-monitor support
9. Keyboard/mouse/gamepad passthrough
10. Audio streaming with volume control
11. Auto-discovery + manual IP connection

### Medium Priority (differentiating features)
1. Color correction (brightness, contrast, saturation, sharpening)
2. Fixed Foveated Rendering
3. Pre-built scenic environments with ambient audio
4. Hand tracking gesture bindings for controller emulation
5. Screenshot/recording capture
6. Portrait/landscape screen orientation
7. In-VR settings panel with dockable toolbar
8. Connection statistics dashboard with latency graphs
9. USB wired + WiFi wireless modes

### Lower Priority / Nice-to-Have
1. Social features (shared rooms, avatars)
2. Remote whiteboarding/collaboration
3. Internet streaming with VPN/encryption
4. Wake-on-LAN
5. Environment import (custom skyboxes)
6. Ambient environment audio
7. End-to-end encryption
8. Multi-user telepresence
9. Background blur in passthrough
10. Debug/advanced settings panel
