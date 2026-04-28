# Nightfall

A Godot 4 XR Moonlight streaming client for Meta Quest 3 with HEVC hardware decoding and stereoscopic 3D support.

## Project Status
- [x] GDExtension compilation and loading
- [x] Moonlight pairing and streaming
- [x] OpenXR integration (Quest 3)
- [x] HEVC hardware decoding via NDK MediaCodec
- [x] Stereo SBS shader (2D / SBS Stretch / SBS Crop modes)
- [x] SBS auto-detection
- [x] XR pointer interaction with grab bars
- [x] Gamepad/controller passthrough
- [x] Mouse/keyboard passthrough with stream capture mode
- [x] Numpad UI for IP entry and pairing

## How to Run (Desktop)

```bash
"/var/home/tyrone/.local/share/Steam/steamapps/common/Godot Engine/godot.x11.opt.tools.64" --xr-mode on --path .
```

## How to Build (Quest)

See [BUILD.md](BUILD.md) for full build instructions including GDExtension compilation, APK export, and Quest deployment.

## Pairing

1. Launch the app on Quest
2. Enter your Sunshine host IP using the numpad
3. Press **Pair & Start Stream**
4. Enter the displayed PIN in the Sunshine web UI
5. The stream starts automatically after pairing

The last used IP is saved and restored on next launch.

## Controls

### XR (Quest Headset)
- **Hand raycasts** point at the stream screen and UI panel
- **Trigger** clicks on UI elements or captures mouse to stream
- **Grab bars** (green on hover, blue when grabbed) let you reposition screens
- **Ctrl+Alt+Shift** releases captured mouse back to pointer mode
- **B button** switches to Stream mode, **A button** to Env mode

### Desktop
- **Mouse** aims at screens (non-XR mode uses camera rotation)
- **Left click** interacts with UI or captures mouse to stream
- **Ctrl+Alt+Esc** releases captured mouse
- **Tab** toggles between Stream and Env modes
- **WASD** moves the XR origin in Env mode

### Gamepad
- All gamepad inputs (buttons, sticks, triggers) are forwarded to the remote host during streaming
- Multi-controller support with Xbox button mapping

## SBS Stereo Modes

- **2D**: Standard display
- **SBS Stretch**: Side-by-side content stretched to full screen
- **SBS Crop**: Side-by-side content with letterbox bars cropped

Toggle modes with the **SBS Mode** button. Enable **Auto-Detect** to automatically switch based on content analysis.

## Shader

`src/stereo_screen.gdshader` handles YUV→RGB conversion and SBS stereo splitting based on `VIEW_INDEX` (Multiview). This enables true stereoscopic 3D for games using ReShade/SuperDepth3D.
