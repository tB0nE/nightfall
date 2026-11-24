# Steam Frame (Linux arm64) - experimental

Nightfall runs on Valve's Steam Frame as a native SteamOS (aarch64) OpenXR app,
using the Frame's own SteamVR runtime. Desktop streaming from Sunshine works:
pairing, hardware HEVC/H.264 decoding, screens, menus, controllers.

## What was needed

| Area | Change |
|---|---|
| Build | `NIGHTFALL_LINUX_ARCH=arm64 bash docker-build-linux.sh`, run on an arm64 host (the Frame itself works, with podman). The image gets Kitware's CMake 3.31 on aarch64: vcpkg can't download its own there and Ubuntu 22.04's 3.22 is too old for godot-cpp. |
| Decoding | vcpkg's FFmpeg is built with `--disable-autodetect`, which also drops V4L2 mem2mem, so Linux builds decoded in software. The overlay port in `addons/nightfall-stream/vcpkg-overlay/ffmpeg/` adds `--enable-v4l2-m2m`; `FfmpegDecoder` tries `hevc_v4l2m2m` / `h264_v4l2m2m` first on Linux (the Frame's Qualcomm decoder; desktops without an M2M device fall through). |
| Composition | SteamVR has no `XR_KHR_composition_layer_equirect2`. `setup_background_equirect()` returned early without it and skipped the UI, cursor and ray layers, so the pointer was drawn behind every panel. |
| Input | SteamVR keeps reporting `XR_EXT_hand_tracking` joints derived from the held controllers, so Nightfall flipped to hand mode and hid the pointer. On SteamVR a tracked controller now owns the pointers. |

## Experimental cross-built preview

The archive produced by `tools/steam_frame/package.sh VERSION` includes a
release ARM64 client and the Steam launcher. Extract it on the Frame and add
`launch-from-steam.sh` to Steam. This variant disables local depth inference;
AI 3D uses Meteor. It does not include the Android WebView browser.

The complete cross-build command is
`bash tools/steam_frame/build.sh v0.9.1`. It needs Docker, the Godot
4.7 editor/export templates and the ARM64 GodotOpenXRVendors addon.

To run the stages separately on x86_64, first provide the `nightfall-linux-builder` image
from `Dockerfile.linux-build`, then build `tools/steam_frame/Dockerfile.cross`
as `nightfall-steam-frame-cross`. Mount `addons/nightfall-stream` read-only at
`/source` and a persistent `.build-cache/steam-frame-preview` at `/work`, then
run `tools/steam_frame/build-native.sh` in that container. Copy the script into
the cache first or mount it separately. `package.sh` uses the ARM64 Godot 4.7
export template and the installed GodotOpenXRVendors ARM64 library. Its
`NightfallSteamFrame` preset is separate from the normal Linux preset.

Cross-compilation and package validation do not establish runtime performance
on real Frame hardware. See the archive README for limitations and controls.

## Building and running on the Frame

1. Enable Developer Mode on the Frame (Settings -> System) for SSH.
2. Native library, on the Frame (or any arm64 Linux host with podman/docker):
   `NIGHTFALL_LINUX_ARCH=arm64 bash docker-build-linux.sh`
   -> `addons/nightfall-stream/bin/linux/libnightfall-stream.linux.template_release.arm64.so`.
   The first build compiles every vcpkg dependency (allow ~20 minutes); later
   builds are incremental.
3. PCK, on any machine with Godot 4.7: `godot --headless --export-pack NightfallLinux nightfall.pck`
   (exit status 134 after "savepack DONE" is the known Godot 4.7 shutdown abort).
4. App layout: Godot's `linux_release.arm64` export template as the binary, the
   PCK next to it with the same base name, plus
   `addons/nightfall-stream/bin/linux/<the .so>` and
   `addons/godotopenxrvendors/` (5.2.0 ships `linux/template_release/arm64`).
5. Run it from SSH with the session environment, e.g.
   `DISPLAY=:1 XDG_RUNTIME_DIR=/run/user/1000 ./nightfall`, or add it to Steam as
   a non-Steam game through the launcher below. SteamVR makes it the scene app.

## Adding Nightfall to Steam on the Frame

Added to Steam directly (the binary as a non-Steam game), Nightfall starts, and
a couple of seconds later Steam's **Now Playing** panel opens over it. Steam
treats any window from a game's launch process tree as a flat game: it mirrors
Nightfall's 2D desktop window as a `valve.steam.desktopgame.<appid>` overlay and
opens the dashboard to show it (`ShowGame/ShowOverlay` in
`~/.local/share/Steam/logs/vrwebhelper_systemui.txt`). Unsetting `SteamAppId`
doesn't help (Steam goes by the process tree) and makes SteamVR treat the app
as a new one, so its per-app settings (refresh rate, render size) are lost.

`tools/steam_frame/launch-from-steam.sh` avoids both: put it next to the
`nightfall` binary and add **the script** to Steam as the non-Steam game. It
runs Nightfall as a systemd user unit outside Steam's launch tree, passes the
Steam ids on (SteamVR keeps the `steam.app.<id>` settings), waits for Nightfall
so Steam shows it running, and stops Nightfall if Steam stops the game. The log
goes to `nightfall.log` next to the binary.

`NIGHTFALL_ALLOW_MISSING_MODELS=1` lets `build.sh --linux` finish without the
on-device depth models (they are not in the repository); AI 3D then needs Meteor.

## Notes

- **Refresh rate**: SteamVR on the Frame runs every app at 72 Hz unless the app
  ships a `vrpreferences.json` (`{"steam_frame": {"preferMinRefreshRate": 120}}`)
  or the user sets SteamVR Settings -> Video -> Per-Application Video Settings ->
  Frame Limit / Refresh Rate Override. That per-app value is what
  `xrEnumerateDisplayRefreshRatesFB` reports, so Nightfall's own choice follows it.
- The decoder has no AV1 (H.264, HEVC, VP9 only).
- SteamVR offers `XR_VALVE_frame_controller_interaction`; the action map includes
  its dedicated Frame profile, including View/Menu and physical bumpers.
- Headset screenshots: OpenVR `IVRScreenshots::TakeStereoScreenshot` from any
  background OpenVR app captures the composited view, layers included.

## Local AI 3D performance

The Frame's GPU (Adreno 750, Mesa Turnip) draws Nightfall's frames, runs the
SteamVR compositor and runs on-device depth. What was measured on it (90 Hz,
2560x1080 at 90 fps, EdgePad-512, GPU work read from `drm-cycles-gpu` in
`/proc/<pid>/fdinfo`, depth from `[DEPTH-PERF]`, video from `[STATS]`):

| Setup | EdgePad-512 maps/s | Notes |
| --- | --- | --- |
| Forward+ (with async capture and low priority) | ~11-15 | |
| `--rendering-method mobile` | ~15-16 | Nightfall's own GPU work -58% against Forward+ |
| + projectionless (patched engine) | ~17-21 | A/B in one session: 15-16 -> 17-21; Nightfall's GPU work -22% |

- **Async capture** (`texture_get_data_async`): `get_image()` on the depth
  viewport stalled the renderer ~8 ms (256x256) / ~17 ms (384x384) per capture;
  now ~1 ms of CPU work, no stall.
- **Low-priority ncnn queue**: with ZipDepth-384 the headset ran 73-82 fps and
  showed 67-69 video fps at 90 Hz, even at a 12 Hz cap; at low priority 90 fps
  and 88-89 video fps, lost/late frames 8.4 -> 1.3 per minute. Depth then gets
  the GPU's spare time (~15 maps/s for ZipDepth-384 at 90 Hz).

- **Renderer**: on this GPU the Mobile renderer costs well under half of
  Forward+ for the same picture. Start the app with `--rendering-method mobile`
  on the Frame (or give Linux arm64 a project-setting override).
- **Projectionless** needs the patched engine (`patches/godot-4.7-projectionless*.patch`)
  built as a Linux arm64 template; Godot's buildroot aarch64 SDK cross-builds it on
  an x86 PC in a few minutes. Without the patch nothing changes.
- **Where the rest goes**: the two eye composition viewports are about half of
  Nightfall's remaining GPU work, and their cost scales with pixel count, not
  with the warp's Newton steps (2 vs 0: no measurable change) or the bezel fill.
  Godot already renders them straight into the layer swapchains on Vulkan, so a
  native Vulkan renderer like the Android GLES one would mostly save fixed
  per-pass overhead (~1 map/s here). Fewer pixels or frames are the real
  levers: Settings > Display > Screen Res (Auto renders each screen at the size
  it covers in the headset; Auto 2 looked identical to Full, stronger steps
  save more on small or distant screens but soften text), or 72 Hz: EdgePad-512 measured ~20 maps/s at 72 Hz
  with Forward+, before the Mobile renderer and projectionless.
- **Model costs** on the Frame's GPU at normal priority: ZipDepth-256 ~11 ms,
  ZipDepth-384 ~16-19 ms per map. With the low priority they take longer in
  wall time (EdgePad-512 ~37-56 ms) but don't delay frames.
- **SteamVR layer order**: the screen-controls cylinder 3 mm *behind* the screen
  cylinder (radius + 3 mm) was hidden whenever the screen was pulled closer,
  despite its higher sort order; in front (radius - 3 mm) it is always shown.

## Not done yet

- Frame hardware acceptance of the cross-built archive and packaging.
- A refresh-rate preference file (`vrpreferences.json`), if a higher default is desired.
- Many settings use `OS.get_name() == "Android"` to mean "standalone headset"
  (Screens tab, HDR, Save Log, headset depth options); they are hidden on the Frame.
- Hand/controller ownership via `XR_EXT_hand_tracking_data_source` instead of the
  SteamVR check.
- Only advertise codecs the hardware decodes (AV1 would fall back to software).
- AI 3D tab -> GPU Priority on Linux: the ncnn queue priority is fixed when its
  Vulkan device is created (low, the Android "Stream" default); switching it at
  run time needs the ncnn GPU instance re-created.
- A model that never produces depth (e.g. a CPU `.tflite` that isn't installed)
  still reports `status='ok'` with 0 updates/s.
