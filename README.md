<div align="center">

<img src="src/assets/nightfall_icon_v1.png" width="174" alt="Nightfall" />

# Nightfall

**VR-first GameStream client for Meta Quest and Linux PCVR.**

Stream your PC games into a virtual living room - repositionable screens, stereoscopic 3D,
passthrough, and AI depth estimation, all built native on Godot 4.7 and OpenXR.

[![Stars](https://img.shields.io/github/stars/tB0nE/nightfall?style=for-the-badge&color=7c73ff&labelColor=1a1a2e)](https://github.com/tB0nE/nightfall/stargazers)
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue?style=for-the-badge&color=4c5265&labelColor=1a1a2e)](LICENSE)
[![Release](https://img.shields.io/github/v/release/tB0nE/nightfall?style=for-the-badge&color=4ade80&labelColor=1a1a2e&label=latest)](https://github.com/tB0nE/nightfall/releases/latest)

[Features](#features) · [Why Nightfall](#why-nightfall) · [Usage](#usage-and-requirements) · [Building](#building) · [Donate](#donate) · [License](#license)

</div>

---

## Features

- **VR-native streaming** - floating screen in 3D space with grab bars, corner resize, and curvature options
- **HEVC hardware decoding** - NDK MediaCodec pipeline for low-latency H.265 on Quest 3/3S; VAAPI HEVC decode on Linux
- **AI Stereoscopic 3D** - real-time AI depth conversion via MiDaS turns any 2D game into stereoscopic 3D, no server-side setup required (Quest only)
- **SBS support** - Stretch and Crop modes for native side-by-side 3D content; quick-toggle via right thumbstick click
- **Controller mapping** - PAD mode maps Quest controllers to an Xbox controller; KBM mode keeps the pointer for mouse aim while binding movement to WASD and actions to keyboard keys
- **Virtual keyboard with trackpad** - floating keyboard for text input, plus an integrated trackpad for relative mouse control with trigger/grip for left/right click
- **Head-angle-aware positioning** - screen, menu, and keyboard position relative to where you're looking; works standing, sitting, or lying down
- **Shader smoothing & sharpening** - Gaussian blur plus CAS adaptive sharpening on the stream
- **Flexible stream configuration** - resolution presets (720p–4K including 4:3 and 21:9), 30–120 FPS, auto or manual bitrate, auto display refresh rate matching
- **Touch-style pointer** - laser pointer with trigger-to-click, grip for right-click, thumbstick scroll; circle or arrow cursor with optional steady mode
- **Passthrough** - see your real room with the stream floating in front of you
- **Curved screen** - toggle curvature from the menu; flat, slight curve, or full wrap with optional bezel
- **Quest Touch Plus models** - real controller models instead of placeholder boxes (Quest only)
- **Hand tracking** - navigate and interact without controllers using Quest hand tracking (Quest only)
- **Linux PCVR** - AppImage release for WiVRn/Monado with passthrough, composition layers, and SBS support
- **X11 local capture** - low-latency screen capture for streaming the Linux desktop to itself without a network
- **Compatibility** - works with any GameStream-compatible server
- **Ease of use** - pair and connect in seconds; AI 3D requires no additional server-side configuration

<div align="center">
<img src="src/assets/nightfall_shot.png" width="720" alt="Nightfall running on Quest" />
</div>

## Why Nightfall

There is no native Moonlight client on the Quest. Existing options like Moonlight Android and Artemis run as flat Android apps - they work inside a 2D window, not in XR/VR space. This means you can't use Quest-native features like stereoscopic SBS rendering, AI-powered 3D depth conversion, or passthrough while streaming. You're staring at a flat panel in a flat app, same as any phone screen.

Nightfall is built from scratch as a native OpenXR application. The stream lives in 3D space - you can grab it, curve it, resize it, and place it wherever you want. AI depth estimation turns any 2D game into stereoscopic 3D in real-time, something flat clients simply cannot do because they don't have per-eye rendering access.

Beyond gaming there is potential for Nightfall to become a useful streaming client for productivity too. With compatibility as it's strength, any server - Windows, Mac, or Linux - becomes a serious desktop streaming tool. Pull up your IDE, terminal, or browser on a massive virtual screen with passthrough so you can still see your desk.

### Roadmap

- **Wide mode for SBS** - when dynamic virtual desktop creation is supported, create a double-width desktop so SBS content renders at full per-eye resolution
- **SBS auto-detection** - automatically detect side-by-side content and switch modes, then restore previous setting when SBS ends
- **Server processing layer** - a companion app running on the Sunshine server that offloads processing from the headset, similar to WiVRn's architecture; potential for significant quality and performance gains

## Usage and Requirements

### Host (PC)

Nightfall streams from any GameStream-compatible server on your local network:

- **[Sunshine](https://github.com/LizardByte/Sunshine)** - open source GameStream host (recommended)
- **[Apollo](https://github.com/ClassicOldSong/Apollo)** - Sunshine fork with virtual display and extra features
- **[Polaris](https://github.com/papi-ux/polaris)** - lightweight GameStream server for macOS and Linux

Setup:
1. Install and configure Sunshine on your PC
2. Open the Sunshine web UI at `https://<your-pc-ip>:47990`
3. Create a username and password
4. Add your games/apps to the Sunshine library

### Client (Quest)

1. Sideload Nightfall onto your Quest 3 or 3S (via SideQuest, ADB, or [Obtainium](https://github.com/ImranR98/Obtainium))
2. Launch the app - you'll see the welcome screen
3. Select a server from auto-discovered hosts, or press **Select Server** to enter an IP address manually
4. Press **Connect** to pair and start the stream
5. Enter the displayed PIN in your server's web UI
6. The stream starts automatically

### Client (Linux PCVR)

1. Download the `Nightfall-x86_64.AppImage` from the [latest release](https://github.com/tB0nE/nightfall/releases/latest)
2. Ensure [WiVRn](https://github.com/WiVRn/WiVRn) is running on your PC with your headset connected
3. Run `chmod +x Nightfall-x86_64.AppImage && ./Nightfall-x86_64.AppImage`
4. The app launches into VR via WiVRn/Monado OpenXR runtime
5. Controls and streaming work the same as Quest (AI 3D not available on Linux yet)

### Controls

| Input | Action |
|---|---|
| **Trigger** | Left-click / interact |
| **Grip** | Right-click |
| **Right thumbstick Y** | Scroll |
| **B button** | Toggle menu |
| **A button** | Toggle keyboard |
| **Right thumbstick click** | Cycle SBS mode (Off → Stretch → Crop) |
| **Both thumbstick clicks** | Toggle controller mapper on/off |
| **Grab bars** | Drag to reposition screen, menu, or keyboard |
| **Corner handles** | Resize screen (locked aspect ratio) |

#### Controller Modes

Toggle the controller mapper with **both thumbstick clicks** or the **Ctrl** button in the menu. Cycle between PAD and KBM with the **Type** button.

**PAD mode** - Quest controllers emulate an Xbox controller:
| Input | Action |
|---|---|
| **Thumbsticks** | Left/right stick |
| **Triggers** | Left/right trigger |
| **Grips** | Left/right bumper |
| **A/B/X/Y** | Face buttons (D-pad when controllers near head) |
| **Menu buttons** | Start / Back |

**KBM mode** - Mouse pointer stays active, buttons map to keyboard:
| Input | Action |
|---|---|
| **Left thumbstick** | WASD movement |
| **Left trigger** | Shift |
| **Left grip** | Ctrl |
| **A** | Space |
| **B** | R |
| **X** | E |
| **Y** | F |
| **Left menu** | Esc |
| **Right menu** | Tab |
| **Right thumbstick Y** | Scroll |

#### Keyboard Trackpad

The keyboard includes an integrated trackpad on the right side. Point at the trackpad area and **click trigger** to activate. While active:

| Input | Action |
|---|---|
| **Move controller** | Relative mouse movement |
| **Trigger** | Left-click |
| **Grip** | Right-click |
| **Thumbstick Y** | Scroll |
| **Right thumbstick click** | Exit trackpad |

## Building

See [BUILD.md](BUILD.md) for full build instructions including:

- GDExtension compilation (cmake + ninja, not manual clang++)
- vcpkg dependency setup
- Android APK export via Godot headless
- Linux binary and AppImage export
- Quest deployment via ADB

Quick start (Android):

```bash
# 1. Build the GDExtension
cd addons/nightfall-stream
cmake --preset android
ninja -C build/android

# 2. Export the APK
./build.sh --debug

# 3. Install to Quest
adb install -r Nightfall-Android-arm64-v8a-debug.apk
```

Quick start (Linux AppImage):

```bash
# 1. Build the GDExtension
cd addons/nightfall-stream
VCPKG_ROOT=~/Development/Personal/vcpkg VCPKG_DEFAULT_TRIPLET=x64-linux \
  cmake --preset linux -DCMAKE_BUILD_TYPE=Release
ninja -C build/linux-release

# 2. Export the AppImage
./build.sh --appimage
```

> [!WARNING]
> Always use cmake + ninja to build the GDExtension. Manual clang++ compilation produces `.so` files
> that depend on `libc++_shared.so`, which isn't in the APK and causes `UnsatisfiedLinkError` crashes.

## Donate

Nightfall is a spare-time project built to make VR game streaming feel native
instead of bolted on. If it becomes part of your setup, that alone makes my day.
Donations help keep the coffee flowing and the commits coming.

[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-Support-7c73ff?style=for-the-badge&logo=github&labelColor=1a1a2e)](https://github.com/sponsors/tB0nE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support-7c73ff?style=for-the-badge&logo=kofi&labelColor=1a1a2e)](https://ko-fi.com/tb0ne)

## License

Nightfall is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for the full text.

Special thanks to the [Moonlight-Godot](https://github.com/html5syt/Moonlight-Godot) project, which served as a reference implementation, and to [Janyger](https://github.com/Janyger) for AI 3D contributions to Artemis. Compatible with
[Apollo](https://github.com/ClassicOldSong/Apollo), [Sunshine](https://github.com/LizardByte/Sunshine), and [Polaris](https://github.com/papi-ux/polaris).
