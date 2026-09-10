<div align="center">

<img src="src/assets/nightfall_icon_v1.png" width="174" alt="Nightfall" />

# Nightfall

**Native OpenXR GameStream client for Meta Quest and Linux PCVR.**

Stream your PC games and desktop to a configurable screen in VR, with
stereoscopic 3D, passthrough, ambient lighting, and real-time AI depth.

[![Stars](https://img.shields.io/github/stars/tB0nE/nightfall?style=for-the-badge&color=7c73ff&labelColor=1a1a2e)](https://github.com/tB0nE/nightfall/stargazers)
[![License: GPL v3](https://img.shields.io/badge/License-GPL%20v3-blue?style=for-the-badge&color=4c5265&labelColor=1a1a2e)](LICENSE)
[![Release](https://img.shields.io/github/v/release/tB0nE/nightfall?style=for-the-badge&color=4ade80&labelColor=1a1a2e&label=latest)](https://github.com/tB0nE/nightfall/releases/latest)

[Features](#features) · [Why Nightfall](#why-nightfall) · [Usage](#usage-and-requirements) · [Building](#building) · [Donate](#donate) · [License](#license)

</div>

---

## Features

- **AI stereoscopic 3D** - real-time depth conversion turns ordinary 2D games
  into stereoscopic 3D without server-side processing. Android uses the fast,
  mobile-optimized ZipDepth-384 GPU model; Linux retains its native selectable
  depth models.
- **SBS support** - Stretch and Crop modes for native side-by-side content,
  with a quick toggle on the right thumbstick.
- **Flexible stream configuration** - 720p through 4K presets, including 4:3
  and 21:9, auto or manual bitrate, and stream rates from 30 to 207 FPS where
  supported by the host, headset, and OpenXR runtime.
- **Controller mapping** - PAD-HAND and PAD-ABXY gamepad layouts, plus a KBM
  mode that maps Quest controls to mouse and keyboard input.
- **VR-native display controls** - reposition, resize, curve, and recenter the
  screen, with an independently controlled bezel.
- **Virtual keyboard and trackpad** - type and control a relative mouse from a
  floating VR panel.
- **Hand tracking** - navigate and interact without controllers on supported
  Meta Quest headsets.
- **HDR streaming** - HDR10/PQ and HLG streams are tonemapped by the native
  renderer on Quest.
- **Ambient lighting** - a lightweight halo around the screen with Off,
  Static, Slow, and Live modes. Static mode includes selectable colours.
- **Linux PCVR** - WiVRn/Monado support with composition layers, SBS, native AI
  depth, and same-machine local capture through PipeWire/Wayland or X11.
- **GameStream compatibility** - connects to Sunshine, Apollo, Polaris, and
  other compatible hosts.

<div align="center">
<img src="src/assets/nightfall_shot.png" width="720" alt="Nightfall running on Quest" />
</div>

## Why Nightfall

Nightfall was designed from scratch as a high-performance, highly customizable,
VR-first GameStream client. It is built around a configurable OpenXR display
rather than an Android window, with local AI depth conversion, SBS rendering,
passthrough, ambient lighting, picture controls, and Linux PCVR support as
first-class features.

The stream lives in 3D space: grab it, curve it, resize it, or place it wherever
you want.

Nightfall is useful beyond gaming too. With compatibility as its strength, a
Windows, macOS, or Linux host can become a large virtual desktop. Passthrough
keeps your keyboard and desk visible while you work.

### Roadmap

- Port the Android optimizations to the Linux version
- Multiple monitors (70% complete)
- An improved version of ZipDepth optimized for sharper edges and widescreen ratios
- Safely reintroduce 3D objects and environments without affecting performance
- Resolve Vibepollo pairing issues
- Improve hand tracking

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

Quest 3 and 3S are the primary development targets. Quest 2 is supported with a
lower resolution ceiling and less performance headroom, particularly when AI
3D and passthrough are enabled together.

1. Download the Android APK from the [latest release](https://github.com/tB0nE/nightfall/releases/latest)
2. Sideload it with SideQuest, ADB, or [Obtainium](https://github.com/ImranR98/Obtainium)
3. Launch Nightfall to open the welcome screen
4. Select an automatically discovered server, or press **Select Server** to enter an address manually
5. Press **Connect**
6. If this is the first connection, enter Nightfall's displayed PIN in the host's web interface
7. The stream starts automatically after pairing

For support logs, press the **↓** button beside **Stats**. Nightfall saves a
timestamped report to `Download/Nightfall` on the headset. The report includes
the current and previous app sessions so it can be exported after reopening
Nightfall following a crash. Review it before sharing: host names and network
addresses may be included.

### Client (Linux PCVR)

The Linux client is supported in source, but **v0.7.8 does not include a Linux
binary**. The application changed substantially during the native-renderer
performance work and the Linux release needs another validation pass before a
new AppImage is published.

To build the current Linux client:

1. Install and start [WiVRn](https://github.com/WiVRn/WiVRn) or another compatible Monado OpenXR setup
2. Follow the Linux prerequisites in [BUILD.md](BUILD.md)
3. Run `./build.sh --appimage`
4. Start the generated `Nightfall-x86_64.AppImage`

Linux supports the normal streaming controls, SBS, passthrough when exposed by
the runtime, and native CPU AI-depth models. It does not use Android's
ZipDepth/GPU or native GLES renderer paths.

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

The Control tab also provides Circle/Pointer cursor selection, Off/Low/High/One
Euro cursor stabilization, Standard/Chord double-click behavior, and optional
hand tracking.

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

Architecture notes, active plans, research, and historical implementation
documents are indexed in [docs/README.md](docs/README.md).

Quick start (Android):

```bash
# Optimized APK
./build.sh --release

# Optimized APK and install to a connected headset
./build.sh --release --install
```

Quick start (Linux AppImage):

```bash
./build.sh --appimage
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

Special thanks to the [Moonlight-Godot](https://github.com/html5syt/Moonlight-Godot) project, which served as a reference implementation, and to [Janyger](https://github.com/Janyger) for AI 3D contributions to Artemis. Compatible with
[Apollo](https://github.com/ClassicOldSong/Apollo), [Sunshine](https://github.com/LizardByte/Sunshine), and [Polaris](https://github.com/papi-ux/polaris).
