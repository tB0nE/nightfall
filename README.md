<div align="center">

<img src="src/assets/nightfall_icon_v1.png" width="174" alt="Nightfall" />

# Nightfall

**VR-native game and desktop streaming for Meta Quest.**

Stream your PC desktop and games to screens you place anywhere in VR, in
stereoscopic 3D, beside your real room with passthrough, and play PC VR games
through Nightfall Meteor.

[![Stars](https://img.shields.io/github/stars/tB0nE/nightfall?style=for-the-badge&color=7c73ff&labelColor=1a1a2e)](https://github.com/tB0nE/nightfall/stargazers)
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue?style=for-the-badge&color=4c5265&labelColor=1a1a2e)](LICENSE)
[![Release](https://img.shields.io/github/v/release/tB0nE/nightfall?style=for-the-badge&color=4ade80&labelColor=1a1a2e&label=latest)](https://github.com/tB0nE/nightfall/releases/latest)

[Features](#features) · [What runs where](#what-runs-where) · [Getting started](#getting-started) · [Controls](#controls) · [Building](#building) · [Donate](#donate) · [License](#license)

</div>

---

## Features

- **PCVR** - launch PC VR games from the headset through Nightfall Meteor
  (SteamVR on Windows, Monado/xrizer on Linux) and return to your desktop when
  you finish. The wristwatch keeps your desktop within reach during a VR
  session.
- **Multiple screens** - bring your PC's monitors into VR, add up to four
  virtual monitors that exist only in the headset, and open browser screens
  beside them: up to four screens in all. Each screen can be placed, curved and
  resized on its own.
- **Browser and Web Apps** - open web pages and web apps on their own screens,
  with no PC needed.
- **AI stereoscopic 3D** - real-time depth conversion turns ordinary 2D games
  into stereoscopic 3D. On Quest, widescreen EdgePad models run on the GPU
  (or on the CPU, to leave the GPU to the stream). The models are
  [published under MIT](https://github.com/tB0nE/nightfall/releases/tag/edgepad-models-2026-10-08).
- **Nightfall Meteor** - an optional companion app for the PC (Linux, Windows
  and macOS on Apple silicon). It runs AI depth on the PC's GPU, including the
  temporal Video Depth Anything model on supported GPUs, makes the Quest's
  microphone a PC input device, and includes a built-in host with one-click
  setup and PIN approval on the desktop. Nightfall finds it automatically; the
  depth maps and audio are encrypted. See [meteor/README.md](meteor/README.md).
- **SBS support** - Stretch and Crop modes for native side-by-side content,
  with a quick toggle on the right thumbstick.
- **Flexible stream configuration** - 720p through 4K presets, including 4:3
  and 21:9, auto or manual bitrate, and stream rates from 30 to 207 FPS where
  supported by the host, headset, and OpenXR runtime.
- **Controller mapping** - PAD-HAND and PAD-ABXY gamepad layouts, plus a KBM
  mode that maps Quest controls to mouse and keyboard input.
- **VR-native display controls** - reposition, resize, curve, and recenter
  each screen, with an independently controlled bezel.
- **Virtual keyboard and trackpad** - type and control a relative mouse from a
  floating VR panel.
- **Hand tracking** - navigate and interact without controllers on supported
  Meta Quest headsets.
- **HDR streaming** - HDR10/PQ and HLG streams are tonemapped by the native
  renderer on Quest.
- **PyroWave** - a very low-latency codec for high bitrates on a fast local
  network, decoded on the Quest's GPU, with hosts that support it.
- **USB Link** - stream over the Quest's USB-C cable instead of Wi-Fi, falling
  back to Wi-Fi if it's unplugged.
- **21 languages** - the menus are translated, with a language picker on the
  welcome screen and a Settings page behind the gear.
- **Ambient lighting** - a lightweight halo around the screen with Off,
  Static, Slow, and Live modes. Static mode includes selectable colours.
- **GameStream compatibility** - connects to Sunshine, Apollo, Vibepollo,
  Polaris, and other compatible hosts, with or without Meteor.

<div align="center">
<img src="src/assets/nightfall_shot.png" width="720" alt="Nightfall running on Quest" />
</div>

## Why Nightfall

Nightfall was designed from scratch as a high-performance, highly customizable,
VR-first streaming client. It is built around configurable OpenXR screens
rather than an Android window, with local AI depth conversion, SBS rendering,
passthrough, ambient lighting and picture controls as first-class features.

Your screens live in 3D space: grab them, curve them, resize them, or place them
wherever you want.

Nightfall is useful beyond gaming too. A Windows, macOS, or Linux PC becomes a
set of large virtual monitors, and passthrough keeps your keyboard and desk
visible while you work.

### Roadmap

- Meteor PCVR on Intel GPUs
- Nightfall Meteor: wider GPU and desktop testing, and a signed Windows installer
- Environments: a cinema room and your own rooms, without affecting performance
- Improve hand tracking

## What runs where

Nightfall runs on the Quest; Nightfall Meteor is the optional companion on the PC.

| Meteor feature | Linux | Windows | macOS (Apple silicon) |
|---|---|---|---|
| Built-in host (Meteor-Vibepollo) | ✓ | ✓ | ✓ |
| AI depth on the PC | ✓ | ✓ | ✓ (EdgePad) |
| Microphone passthrough | ✓ | ✓ | ✓ |
| Virtual monitors | ✓ (KDE Plasma and GNOME on Wayland) | ✓ | ✓ |
| PCVR | ✓ (NVIDIA, AMD) | ✓ (NVIDIA, AMD) | ✗ |

AI depth uses EdgePad models on NVIDIA, AMD, Intel and Apple GPUs. The temporal
Video Depth Anything model runs on NVIDIA (TensorRT or Vulkan) and on supported
AMD GPUs (Vulkan). X11 desktops can be streamed, but virtual monitors need
Wayland.

## Getting started

### Headset (Quest)

Quest 3 and 3S are the primary development targets. Quest 2 is supported with a
lower resolution ceiling and less performance headroom, particularly when AI
3D and passthrough are enabled together.

1. Download the Android APK from the [latest release](https://github.com/tB0nE/nightfall/releases/latest)
2. Sideload it with SideQuest, ADB, or [Obtainium](https://github.com/ImranR98/Obtainium)
3. Launch Nightfall to open the welcome screen

### PC: with Nightfall Meteor (recommended)

1. Download Meteor for your PC from the [latest release](https://github.com/tB0nE/nightfall/releases/latest):
   the Linux AppImage, the Windows installer, or the macOS app
2. Run it. The Setup window installs the built-in host and, if you want them,
   PCVR and the larger AI depth models
3. In Nightfall, select your PC (it is found automatically) and press **Connect**
4. On the first connection, compare the PIN shown in the headset with the one
   in Meteor's pop-up on the PC, and approve it
5. The stream starts automatically. Open the **Monitors** tab to add your other
   monitors or virtual ones, and **VR Apps** to launch PC VR games

Use the same version of Nightfall and Meteor; releases share version numbers.

### PC: with another GameStream host

Nightfall also streams from any GameStream-compatible host on your local
network, without Meteor:

- **[Sunshine](https://github.com/LizardByte/Sunshine)** - open source GameStream host
- **[Apollo](https://github.com/ClassicOldSong/Apollo)** - Sunshine fork with virtual display and extra features
- **[Polaris](https://github.com/papi-ux/polaris)** - lightweight GameStream server for macOS and Linux
- **[Vibepollo](https://github.com/Nonary/Vibepollo) / Vibeshine** - Nonary's Sunshine forks, which add the PyroWave codec (as does Zevro's fork)

1. Install and configure the host, and open its web interface (for Sunshine,
   `https://<your-pc-ip>:47990`)
2. Create a username and password, and add your games and apps
3. In Nightfall, select the host, or press **Select Server** to enter an
   address, then press **Connect**
4. On the first connection, enter Nightfall's PIN in the host's web interface

You can run Meteor in front of one of these hosts too, for AI depth and the
microphone; its built-in host is only needed for virtual monitors and PCVR.

### Support logs

Open **Settings** (the gear) and press **Save Log**. Nightfall saves a
timestamped report to `Download/Nightfall` on the headset. The report includes
the current and previous app sessions so it can be exported after reopening
Nightfall following a crash. Review it before sharing: host names and network
addresses may be included.

## Controls

| Input | Action |
|---|---|
| **Trigger** | Left-click / interact |
| **Grip** | Right-click |
| **Right thumbstick Y** | Scroll |
| **B button** | Toggle menu |
| **A button** | Toggle keyboard |
| **Right thumbstick click** | Cycle SBS mode (Off → Stretch → Crop) |
| **Both thumbstick clicks** | Toggle controller mapper on/off |
| **Grab bars** | Drag to reposition a screen, the menu, or the keyboard. A screen's grab bar appears when you point at the screen |
| **Corner handles** | Point at the grab bar or a corner to show them; drag to resize the screen (locked aspect ratio) |
| **Grab bar buttons** | Microphone, controller mapping, keyboard, SBS, AI 3D, menu |

### Controller Modes

Toggle controller mapping with **both thumbstick clicks** or the **Mapping**
button in the Control tab. The **Device Mode** setting cycles through three
layouts:

- **PAD-HAND** - the original gamepad layout, with face-button roles divided
  between the left and right controllers.
- **PAD-ABXY** - follows the physical A/B/X/Y labels; alternate mode changes
  that hand's pair into D-pad directions.
- **KBM** - keeps pointer control active and maps controller inputs to keyboard
  and mouse actions.

For the PAD modes:

| Input | Action |
|---|---|
| **Thumbsticks** | Xbox left/right sticks |
| **Triggers** | Left/right triggers |
| **Grips** | Left/right bumpers |
| **Face buttons** | Xbox face buttons or D-pad, depending on layout and alternate mode |
| **Menu buttons** | Start / Back |

**Alternate Mode** controls how the secondary face-button mapping is engaged:
Head, Tilt, or None. **Primary Hand** can be Right, Left, or Auto.

For the default KBM profile:

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

The Control tab also provides Circle, Pointer or Hidden cursors, Off/Low/High/One
Euro cursor stabilization, Standard/Chord double-click behavior, and optional
hand tracking.

### Keyboard Trackpad

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
- Quest deployment via ADB
- Desktop builds of the app, used for development and testing

Nightfall Meteor (the PC companion) is a separate Rust project; see
[meteor/README.md](meteor/README.md) for building it, its Linux AppImage,
Windows installer and macOS app. Its built-in host is a modified
[Vibepollo](https://github.com/tB0nE/Vibepollo) built from source.

Architecture notes, active plans, research, and historical implementation
documents are indexed in [docs/README.md](docs/README.md).

Quick start (Android):

```bash
# Optimized APK
./build.sh --release

# Optimized APK and install to a connected headset
./build.sh --release --install
```

> [!WARNING]
> Quest release builds require Nightfall's patched Godot Android templates and
> matching native-XR bindings. Follow [BUILD.md](BUILD.md) before building from
> a fresh checkout. Do not compile either GDExtension manually with `clang++`.

## Donate

Nightfall is a spare-time project built to make VR game streaming feel native
instead of bolted on. If it becomes part of your setup, that alone makes my day.
Donations help keep the coffee flowing and the commits coming.

[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-Support-7c73ff?style=for-the-badge&logo=github&labelColor=1a1a2e)](https://github.com/sponsors/tB0nE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support-7c73ff?style=for-the-badge&logo=kofi&labelColor=1a1a2e)](https://ko-fi.com/tb0ne)

## License

Nightfall is licensed under the **GNU General Public License v3.0**. See [LICENSE](LICENSE) for the full text.
The EdgePad depth models are MIT-licensed, derived from
[ZipDepth](https://github.com/fabiotosi92/ZipDepth); Settings → Licences in the
app lists all third-party software and its licences.

Special thanks to the [Moonlight-Godot](https://github.com/html5syt/Moonlight-Godot) project, which served as a reference implementation, and to [Janyger](https://github.com/Janyger) for AI 3D contributions to Artemis.
Meteor's built-in host is based on [Nonary](https://github.com/Nonary)'s
[Vibepollo](https://github.com/Nonary/Vibepollo), and its Linux PCVR runtime on
[Monado](https://monado.freedesktop.org/) and [xrizer](https://github.com/Supreeeme/xrizer).
Compatible with [Apollo](https://github.com/ClassicOldSong/Apollo),
[Sunshine](https://github.com/LizardByte/Sunshine), [Vibepollo](https://github.com/Nonary/Vibepollo),
and [Polaris](https://github.com/papi-ux/polaris).
