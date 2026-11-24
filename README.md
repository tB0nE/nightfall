<div align="center">

<img src="src/assets/nightfall_icon_v1.png" width="174" alt="Nightfall" />

# Nightfall

**An open-source VR streaming suite for Meta Quest and Steam Frame.**

Stream your PC desktop and games to screens you place anywhere in VR, in
stereoscopic 3D, beside your real room with passthrough, and play PC VR games
through Nightfall Meteor. Development focuses on Linux, with Meteor also
available for Windows and macOS.

[![Stars](https://img.shields.io/github/stars/tB0nE/nightfall?style=for-the-badge&color=7c73ff&labelColor=1a1a2e)](https://github.com/tB0nE/nightfall/stargazers)
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue?style=for-the-badge&color=4c5265&labelColor=1a1a2e)](LICENSE)
[![Release](https://img.shields.io/github/v/release/tB0nE/nightfall?style=for-the-badge&color=4ade80&labelColor=1a1a2e&label=latest)](https://github.com/tB0nE/nightfall/releases/latest)

[Features](#features) · [What runs where](#what-runs-where) · [Getting started](#getting-started) · [Game compatibility](docs/guides/game-compatibility.md) · [Controls](#controls) · [Documentation](docs/README.md) · [Building](#building) · [Donate](#donate) · [License](#license)

</div>

---

## Latest release

[**v0.9.1**](https://github.com/tB0nE/nightfall/releases/tag/v0.9.1)
includes unified screen tabs, cylinder and sphere screen grids, expanded
display controls, PC VR on Windows through SteamVR, and an experimental Steam
Frame client. Install matching Nightfall and Meteor versions.

## Features

- **PCVR** - launch PC VR games from the headset through Nightfall Meteor
  (SteamVR on Windows, Monado/xrizer on Linux) and return to your desktop when
  you finish. The wristwatch keeps your desktop within reach during a VR
  session.
- **Screens and tabs** - combine physical monitors, virtual monitors and
  browsers across up to four visible screens. Drag tabs between screens or out
  into a screen of their own. Each screen can be placed, curved and resized;
  desktop tabs can have their own resolution, subject to the codec's combined
  resolution budget.
- **Browser and Web Apps** - open web pages and web apps without a PC, with
  tabs, bookmarks, history and optional ad blocking. Streaming-service support
  depends on the service's browser and DRM requirements.
- **Crop and colour-key passthrough** - crop the primary screen manually or
  detect black bars automatically. Remove a chosen background colour so your
  real room shows through, with optional host wallpaper changes via Meteor.
  See [screen display options](docs/guides/screen-display-options.md).
- **Text clipboard sharing** - explicitly copy and paste between browser and
  desktop tabs using the virtual keyboard or keyboard shortcuts. See the
  [clipboard instructions and limitations](docs/guides/controls.md#clipboard).
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
- **Experimental Steam Frame client** - a native Linux ARM64 preview using
  Meteor for AI depth. This package has no local depth inference or Android
  browser. See [setup and limitations](docs/guides/steam-frame.md).
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
- Steam Frame hardware testing and broader client support
- Refine screen management, layout persistence and browser text selection
- Improve hand tracking

## What runs where

Nightfall runs on Quest, with an experimental Steam Frame package available.
Meteor is the optional PC companion.

**Without Meteor:** connect to a compatible GameStream host for desktop/game
streaming. On Quest, the standalone browser and on-headset AI 3D also work
without Meteor.

**With Meteor:** add PCVR, managed multi-monitor streaming, host-generated depth
maps and microphone passthrough. Meteor can use its built-in host or work with
an existing compatible host; available display-management features depend on
that host.

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
5. The stream starts automatically. Open the **Screens** tab to add your other
   monitors or virtual ones, and **VR Apps** to launch PC VR games

Use the same version of Nightfall and Meteor; releases share version numbers.

For PCVR test results, game-specific launch settings and motion-controller mod
requirements, see the [game compatibility guide](docs/guides/game-compatibility.md).

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

You can also run Meteor alongside an existing host for its additional features.
The built-in Meteor-Vibepollo host is recommended for integrated pairing and
virtual-display management; regular GameStream streaming remains independent
of Meteor.

### Support logs

Open **Settings** (the gear) and press **Save Log**. Nightfall saves a
timestamped report to `Download/Nightfall` on the headset. The report includes
the current and previous app sessions so it can be exported after reopening
Nightfall following a crash. Review it before sharing: host names and network
addresses may be included.

## Controls

Default Quest shortcuts (right primary controller):

| Input | Action |
|---|---|
| Trigger | Left-click / interact |
| Grip | Right-click; drag to scroll instead when Grip Scroll is enabled |
| Right thumbstick Y | Scroll |
| B | Toggle menu |
| A | Toggle keyboard |
| Right thumbstick click | Toggle SBS off/on using the last selected Stretch or Crop mode |
| Both thumbstick clicks | Toggle controller mapping |
| Grab bar / corner handles | Move / resize the screen |

The [controls guide](docs/guides/controls.md) covers gamepad layouts, alternate
mappings, clipboard sharing, browser input, the keyboard and PCVR controls.

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

## AI-assisted development

I use AI coding tools to help with code, documentation and research. Like other
software, these contributions can contain mistakes. Reproducible bug reports
and community reviews help improve Nightfall; please include a diagnostic log
when reporting a problem.

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
