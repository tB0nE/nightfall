# Quest compatibility browser — checkpoint, 2026-11-02

Branch: `codex/quest-linux-browser-spike`.

## Outcome and scope

Netflix playback, audio and Nightfall AI 3D have worked on the Quest using
an ARM64 Linux Chrome environment. This is a development proof of concept,
not a user-friendly or release-ready feature. Pause further acceleration
experiments here; preserve the working baseline and the diagnostic work.

The user also tested Amazon Prime playback successfully in Nightfall's
**normal WebView browser**. That is a user-observed result for their test,
not a guarantee of every title, resolution, account or firmware combination.
Do not route Prime, or all video services, into Linux by default. Keep the
normal browser as the preferred path; compatibility mode is an explicit
exception for sites that need it.

## What is installed

- Nightfall's release-optimized DEV APK contains compatibility-tab integration.
- A separate `app.nightfall.browserlab` APK owns the Linux runtime and bridges.
- Linux userspace, official ARM64 Chrome and dependencies are separately
  prepared and copied over ADB into the companion's private files directory.
- Neither the main APK nor the companion APK bundles the complete Linux image.
  No finished end-user downloader/installer exists.
- PRoot runs Linux userspace on Android's kernel; this is not a hardware VM.
- The prototype expects the companion runtime to be started beforehand.
  Opening a compatibility tab attaches its Surface, input and audio.
- Only one compatibility tab is supported globally. Normal tabs remain WebView.
- Closing/hiding detaches presentation, suspends audio and attempts to pause
  media. It does not guarantee Chrome and Linux processes are terminated.
  Preserve the existing browser profile and sign-ins when resuming development.

## Current working path

```text
Chrome software rendering and software video decoding
  -> stock Xvfb memory framebuffer
  -> CPU bitmap copy
  -> Android hardware Canvas drawing/scaling onto a Surface
  -> Nightfall GPU VR presentation and optional GPU AI depth inference
```

Linux GPU mode is disabled. The MediaCodec hardware decoder bridge starts
only in the experimental GPU mode, so **hardware video decoding is not active
in the restored software baseline**. Android presentation remains accelerated.

## Validation and limits

- User previously confirmed Netflix playback, audio and AI 3D working.
- Latest short generated-content baseline: 1920x1080 source/output,
  814 posts over 11.40 seconds, 71.42 presented frames/s against a 72 Hz target,
  247 changed samples, mean CPU copy 1.18 ms and Canvas draw/post 2.35 ms.
- No GPU hangs detected during that baseline. Artifact (ignored local cache):
  `.build-cache/browser-quest-linux/gpu-nightfall-20261102T210458Z.json`.
- Presentation rate is not unique decoded video FPS. Canvas resolution is not
  proof of Netflix playback resolution. This was not a long-session Netflix
  stability or manual touch-quality test.
- Local experiment regression suite: 32 tests passed at this checkpoint.

## Experimental GPU path and blocker

The retained experiments add Mesa/KGSL Linux GPU rendering, a MediaCodec/VA
hardware decoder bridge, and GPU buffer/fence sharing into Android.
Short isolated tests succeeded, but shader drawing while Nightfall's XR
session is active can hang the GPU and freeze the headset's system display.
A tiny arithmetic-only triangle reproduces the problem without Chrome,
Xvfb, video, AI 3D or shared frame buffers. No driver fix is established.
Do not enable this path for normal use or interpret successful isolated
hardware decode tests as stable XR playback.

Some earlier launch failures were wrongly attributed to Horizon because a
test parsed only the last resumed activity across multiple displays. That
reporting bug is fixed. Actual Guardian interruptions also occurred; the
two observations must not be conflated.

## Outstanding before a usable feature

1. Resolve GPU/XR coexistence, or establish an acceptable software baseline.
   Investigating hardware decode independently of Linux GPU compositing is
   a possible direction, not a verified working configuration.
2. Automatic runtime install/update and startup on first use; decide whether
   this remains a companion or can meet the main app's target-SDK requirements.
3. Clear idle/shutdown behavior, bounded background resource use and reliable
   tab close/reopen, standby, input, scrolling and audio recovery.
4. Production security: Chrome sandboxing remains unresolved in this lab;
   PRoot is not a security boundary. Replace/harden local debug/control IPC.
5. Real playback-quality measurements, long-session stability and power/thermal
   testing. Keep decoded FPS, presentation FPS and service playback resolution
   separate in reports.
6. Packaging, distribution/licensing review and clean-install testing before
   offering this as an end-user feature.

## Resume safely

Read this checkpoint, the detailed handoff and the GPU audit first. Do not
start another broad Chrome GPU test before addressing the minimal reproducer.
Use generated content for graphics diagnostics; do not extract browser
profiles, credentials, CDM data or protected media.

Use bounded tests with the device watchdog and independent kernel hang
monitor. Stop test processes and clear test leases/awake overrides afterward;
the user frequently leaves the desk and prior tests drained the battery.
Preserve app data and pairings. Avoid host gamescope/Vulkan UI tests here:
previous host graphics tests reset the desktop.

References:
- [Detailed history](QUEST_LINUX_BROWSER_HANDOFF_2026-10-31.md)
- [Integration plan](../plans/active/quest-linux-browser-integration.md)
- [GPU audit](../plans/active/quest-linux-gpu-xr-audit-2026-11-02.md)
- [Minimal reproducer](../plans/active/quest-linux-minimal-triangle-reproducer.md)
- [Experiment tools](../../tools/experiments/browser-quest-linux/README.md)
