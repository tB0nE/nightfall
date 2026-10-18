# Meteor XR: pinned ALVR integration audit

> Retired 2026-10-18. Current direction: [managed Monado runtime](../plans/active/meteor-xr-monado-spike.md).
> Our host driver was unregistered and both compositor files restored; see
> [the new integration report](meteor-xr-monado-integration.md). This audit is historical.

Date: 2026-10-17. Branch: `feat/meteor-xr-streaming`.
Status: synthetic projection confirmed on Quest 3; optional decoder/tracking bridge
implemented and compiling. **No remote XR stream has yet been confirmed.**

## Reproducible inputs

- Official ALVR release: `v20.14.1`.
- Source revision: `a9f6542fa507a841f40ab4f3fcb531427cd02550`.
- OpenVR header submodule: `4c85abcb7f7f1f02adaf3812018c99fc593bc341`.
- Rust toolchain found locally: 1.92.0; Android target `aarch64-linux-android`.
- Android NDK: Nightfall's pinned 29.0.14206865; Android API 28.
- Probe tools: cargo-ndk 4.1.2 and cbindgen 0.28.0, installed into the ignored
  cache rather than replacing global tools.
- Build: release, locked upstream Cargo dependencies, no default client-core
  features (matching the upstream packaging path that omits its explicit shared
  C++ runtime link). Inspect actual ELF dependencies before APK integration.

Run from the repository root:

```bash
bash tools/build_support/probe_alvr_client.sh --check
bash tools/build_support/probe_alvr_client.sh --build
```

Artifacts, generated header, licence and SHA-256s are staged under
`.build-cache/meteor-xr/artifacts/20.14.1/android-arm64/`. The script verifies
required C symbols and compiles `test/alvr_client_abi_probe.cpp` with the Android
compiler. It does not package/install an APK, start/register a driver or change
the active OpenXR runtime. Completion evidence is added below after execution.

## Source findings

All ALVR paths below are relative to the pinned checkout, not master. The
generated C header must come from that exact version; master has changed its
capabilities and frame metadata structures.

### Graphics ownership: do not directly call the optional renderer yet

`alvr/client_core/src/c_api.rs` stores graphics/stream renderers in thread-local
storage. `alvr_initialize_opengl()` calls `GraphicsContext::new_gl()`.
`alvr/graphics/src/lib.rs` creates a wgpu GLES instance/device and makes its
own EGL context current on a pbuffer. There is no demonstrated sharing with
Godot's GLES context. A matching GL API alone does not establish texture sharing.

The pinned API's `AlvrStreamConfig` accepts raw GL swapchain texture IDs. Those
IDs cannot be assumed meaningful in an unrelated context. Avoid silently
leaving Godot on ALVR's context, and do not ship a second OpenXR application.

Recommended first bridge: use the ALVR connection/decoder APIs, import returned
Android hardware buffers into Nightfall-owned GL resources, render into its
own OpenXR eye swapchains, and restore any modified GL state. Validate import
formats, fences, color range/orientation and latency before choosing this route.
This still needs hardware validation; it is not a performance guarantee.

### Decoded-frame ownership

`alvr_get_frame()` in `client_core/src/c_api.rs` returns a timestamp and an
`AHardwareBuffer` pointer. `video_decoder/android.rs::dequeue_frame()` keeps the
image at the front of the queue marked `in_use`; the next dequeue may pop it.
There is no independent release-frame function in this pinned C interface.

Therefore the adapter must not keep a borrowed pointer past the next dequeue
or decoder teardown. Import/copy within that lifetime, retain buffers through
Android's explicit ownership APIs only when appropriate, and fence GPU use.
Owning a buffer reference alone does not prove the decoder cannot reuse pixels;
the queue/reuse contract and GPU completion need testing together.

### Tracking, timestamps and reprojection

- Feed two eye poses/FOVs using `alvr_send_view_params`, device motion using
  `alvr_send_tracking`, and controller buttons using `alvr_send_button`.
- ALVR's OpenXR client derives timestamps from the XR runtime's clock, expressed
  as nanosecond durations. Do not substitute Godot wall time or frame counters.
- `alvr_report_compositor_start(decoded_timestamp, out_views)` retrieves the
  views associated with the decoded frame. Projection metadata must describe
  the pose/FOV actually used to render the submitted image, not blindly the
  latest headset pose. Any client-side warp changes that relationship.
- The stock client's render loop may poll/sleep waiting for a decoder frame.
  Do not copy that blocking loop into Godot's layer-collection callback.
- JNI initialization requires a valid JVM and Android context before core
  initialization; decoder teardown must stop callbacks before releasing them.

### Godot/native extension insertion points

- Register the provider during `_ready()` alongside native presentation setup,
  before its first await. Godot rejects new composition providers once running.
- Current `NightfallXrRenderer::_get_composition_layer_count()` is the reliable
  render hook; `_on_pre_render()` is intentionally empty because registration
  as a composition provider is not registration for general extension callbacks.
- Return one persistent `XrCompositionLayerProjection` with two views rather
  than the existing video-screen quads/cylinders.
- Godot alone calls `xrWaitFrame`, `xrBeginFrame`, `xrEndFrame`. Its public
  predicted-time getter reads main-thread frame state; submission uses the
  render-thread snapshot. Confirm/expose the correct render-frame snapshot
  (time, should-render, reference space) before using it for projection output.
- Block normal native-screen eligibility while exclusive mode is preparing,
  connecting, running or stopping. Otherwise the regular process loop can
  reactivate a desktop provider during teardown.

## Lifecycle scaffold and next device gate

`PCVRSession` is a pure, generation-tagged policy. Its commands are deliberately
not wired to an unavailable backend. Preparation must be acknowledged before
connection; teardown must be acknowledged before welcome. Exit/error cannot
reopen previous browser/desktop content. Tests cover cancellation and stale
callbacks across retries.

Next device gate: synthetic left/right test images through an exclusive native
projection provider, using one unchanged Godot session/frame loop, with a local
exit path. Then test the decoder-buffer bridge and stock matching ALVR host.
Only after that should Meteor advertise usable PCVR or automatic switching.

## Verification record

- Local read-only preflight found SteamVR and the Android target/toolchain.
- No host driver registration, runtime selection, headset installation or
  launch was performed as part of dependency probing.
- Android arm64 release build passed. Generated C header, required exported
  symbols and the Android C++ ABI/layout probe passed. A cached second run
  produced the same original-library/header hashes (not a clean-room build).
- Original optimized library with debug symbols: 79,298,488 bytes. Debug-symbol
  stripped candidate: 11,200,800 bytes. Neither is bundled in Nightfall yet.
- ELF dependencies: liblog, libandroid, libmediandk, libaaudio, libdl, libm and
  libc. No libc++_shared dependency was present in this build.
- SHA-256, original library:
  `2ca6f1ce0dfb61b9489f9afd97b2c2c787ae43c762565bf245c3a37724eee865`.
- SHA-256, stripped library:
  `e0704dd9e5569cd58736ce7c4f1abedb13530dc7eede346a312cf361fb57efd8`.
- SHA-256, generated C header:
  `4badc6064782657f3faa9511c65b931b3aa2b501ef12d407344892ca90acecf9`.
- Full GDScript suite (including lifecycle), Godot project parse, shell syntax
  and repository-local Markdown-link checks passed. The lifecycle remains an
  isolated policy, not a connected/rendering backend.
- Quest 3 was detected over ADB. No visual, motion, audio, encoder or latency
  baseline has been measured; no synthetic projection or remote frame has
  been displayed. No APK was built or deployed for this dependency-only step.

## Decoder bridge follow-up — 2026-10-17

The user confirmed the synthetic tracked projection succeeds on Quest 3. It
remains available separately. The next experimental path is implemented behind
`NIGHTFALL_PCVR_ALVR=ON` on optimized DEV builds only:

- A worker owns ALVR core initialization, discovery/events and decoder teardown.
- The JVM and Android context are passed explicitly from GodotApp. The follow-up
  below corrects this to an Activity held until core shutdown because upstream
  can call `requestPermissions()`. Core initialization remains on explicit entry.
- A clock-only extension wrapper registers during native module initialization
  so `XR_KHR_convert_timespec_time` is requested before instance creation.
  Tracking converts CLOCK_MONOTONIC explicitly to XrTime and sends head pose,
  valid velocities and local eye poses/FOVs. No separate action sync or frame loop.
- Decoder hardware buffers are sampled through EGLImage/external OES into the
  existing double-wide projection swapchain. No ALVR graphics context is created.
- The next decoder dequeue waits for a nonblocking GPU fence to signal; a stop
  drains the borrowed image and projection before allowing worker/core teardown.
- Projection poses/FOVs come from the decoded frame's compositor metadata, with
  finite/unit-quaternion/frustum validation. Head tracking is not substituted
  for the old frame's image poses.
- Empty/unsupported configurations fail closed. First-frame timeout is 30s;
  local exit and 45s deadman remain. No automatic reconnect/content restoration.

Not validated: host trust/discovery, live decoding/import, image orientation,
gamma/range, real motion-to-photon timing, remote disconnect and repeated remote
entry. Host/driver/runtime registration has not been changed. The fixed output
is 1024x1024 per eye; advertised rate is 72 Hz but Nightfall's runtime rate is
not yet forced to match. Queue latency reporting is a placeholder zero, not a
measurement. Godot still owns final display time; exposing its exact render-frame
snapshot remains necessary for accurate accounting. ALVR's built-in audio follows
host settings: disable game audio/microphone for the first test. Controller
forwarding is not implemented.

Important upstream limitation: the pinned `alvr_create_decoder` implementation
unwraps codec creation failures. A codec setup failure can abort the process
rather than return an error. Restrict this bridge to development and harden that
API before considering public distribution.

Verification: both optional-bridge ON and OFF Android release configurations
compile. The enabled APK packages the core and MIT notice, installs in-place,
and has `DT_NEEDED=libalvr_client_core.so` (no host path). GDScript suite/parse,
standalone native view-metadata tests, shell syntax and Markdown links pass.
The full native runner could not run on this host because FFmpeg development
packages are unavailable; its new standalone metadata test was compiled/run
directly with the host C++ compiler. On-device startup/remote operation has not
yet been confirmed for this bridge APK; the headset was not actively rendering
during the log check. SteamVR's existing external-driver list has no ALVR entry;
other registered drivers and runtime paths were left untouched.

## Linux host preparation — 2026-10-18

- Downloaded the official `v20.14.1/alvr_streamer_linux.tar.gz`, verified against
  GitHub's release-asset SHA-256:
  `be82b4a7a3cb3607dd5c307cf2b0a1b524d1ecbba586d657a458117a8a63bc09`.
- Extracted into `.build-cache/meteor-xr/host/20.14.1/alvr_streamer_linux/`.
  This directory is currently the registered driver location: do not delete it
  before unregistering that driver.
- Backed up `~/.config/openvr/openvrpaths.vrpath` and the existing matching
  `~/.config/alvr/session.json` into
  `.build-cache/meteor-xr/host/20.14.1/backups/pre-registration-20261018/`.
- Added only this host's `lib64/alvr` using SteamVR's `vrpathreg adddriver`.
  Standable remains registered. The SteamVR/xrizer runtime paths were unchanged.
- Existing ALVR settings now disable game audio, microphone and foveated
  encoding, and select Scale=1 resolution (use client's advertised eye size).
  Dashboard auto-start/stop of SteamVR remains disabled. No firewall changes.
- Launched the matching dashboard. Host RTX 3090 / NVIDIA 615.71.09 detected.
  No live client trust, SteamVR Home image or encoding test yet.

Pending before ALVR's normal Linux launch: its launcher replaces `vrcompositor`
with a symlink to its capture wrapper and saves the current executable as
`vrcompositor.real`. Both files already exist as regular files here, with different
versions. Neither was modified. Back up both before allowing launcher setup;
otherwise its rename could overwrite the old `.real` backup. The wrapper enables
ALVR's Vulkan capture layer and, on Wayland, its DRM lease shim; it is separate
from switching the active OpenXR runtime. Firewall/ports also remain untested.

To undo only registration (preserving other drivers/runtime paths), use:

```bash
~/.local/share/Steam/steamapps/common/SteamVR/bin/linux64/vrpathreg removedriver \
  /var/home/tyrone/Development/Personal/moonlight-quest/.build-cache/meteor-xr/host/20.14.1/alvr_streamer_linux/lib64/alvr
```

Close ALVR before restoring its settings from the backup. Do not blindly restore
the complete OpenVR backup later if other applications have since added drivers.

Platform status: upstream v20.14.1 supports Windows 10/11 and Linux (Linux beta).
The headset core/projection bridge is host-independent, but Nightfall remote video
has not yet been verified on either OS. Meteor orchestration/packaging is still
pending separately for both. Windows does not need this Linux compositor wrapper.

## Linux wrapper enabled — 2026-10-18

After explicit approval, both existing compositor files were copied into
`.build-cache/meteor-xr/host/20.14.1/backups/compositor-20261018/` before changes:

- `vrcompositor`: `ebdffa9a8309d9596201cb385ceded35b71a1f16fb8f123fc0196c245cb8186c`.
- Old `vrcompositor.real`: `cc0c862b5219f00f97c0d68f64c7c9b731ab5ddfcf756bc369786c2477aa0c21`.

The current executable was moved to `vrcompositor.real`; `vrcompositor` is now a
symlink to the pinned host's `libexec/alvr/vrcompositor-wrapper`. The previous
`.real` is recoverable from the backup. No executable was patched and no active
OpenXR runtime was changed. Keep the registered host cache until the wrapper and
driver are removed/restored.

SteamVR was launched through Steam. Fresh logs confirm `driver_alvr_server.so`
loaded and became the active SteamVR HMD, and the compositor reached **Startup
Complete** on the RTX 3090. The local API with `X-ALVR: true` reports `20.14.1`,
and the dashboard reports **Server connected**. This is host startup evidence,
not a successful headset stream or proof of encoder/capture compatibility.
SteamVR is waiting/searching for the headset. Existing Standable registration
is preserved but SteamVR reports its Linux library is absent (unrelated).

Next manual gate: enter Nightfall's **DEV: ALVR PCVR stream**, identify/trust that
specific client in the dashboard, retry entry if its 30-second first-frame timeout
expires, and verify the first decoded projection, head motion and B/Y exit.
Do not bulk-trust other clients. Controller forwarding and audio remain outside
this first video gate. To restore the compositor, first stop SteamVR, preserve or
remove only the installed wrapper symlink, then copy both backed-up files to
their original names; do not restore the older `.real` as the main executable.

## Clock registration correction — 2026-10-18

The first remote-button attempt was blocked: the initial clock-only wrapper was
registered at SCENE level, but Godot's OpenXR module creates the instance at
SERVERS level. Fresh device logs showed **Cannot register OpenXR extension
wrappers after the OpenXR instance has been created**, then `remote_clock=false`.
The rejection was sent to the hidden menu status bar rather than welcome.

ALVR-enabled builds now register their native classes/wrapper at CORE (the
required OpenXR base classes are themselves registered at CORE). Ordinary builds
retain SCENE initialization. Rejections update welcome's own status label and
persist in session logs; remote HUD/status changes are also persisted. The
optimized DEV APK was rebuilt and installed. At 08:40:43 device logs confirmed
CORE registration before instance creation; at 08:40:45 they reported
`provider registered=true remote_clock=true`. Full GDScript tests and parse pass,
including a welcome-status regression test. Actual connection/decoded frames
still need testing.

## Initialization crash correction — 2026-10-18

The remote-button attempt at 09:35:02 aborted in `alvr_initialize`, before decoding.
Symbolizing the pinned unstripped core resolved the stack to
`alvr_system_info::android::set_wifi_lock::set_lock` (`android.rs:148`), its
unchecked `WifiLock.acquire()` result. Nightfall's export had both WAKE_LOCK and
ACCESS_WIFI_STATE disabled; the upstream client's manifest explicitly requires
them. The original Java exception text was no longer present in the live log.

The optional ALVR DEV export now enables these two normal permissions for that
export only. Java preflight checks them and acquires/releases a low-latency lock
under exception handling before Rust can unwrap an error. Upstream also expects
an Activity for its optional microphone permission request, not an Application:
the bridge now holds the Activity through core shutdown, then releases its global
reference. No microphone streaming was enabled on the host. A new optimized DEV
APK was installed; the installed package permissions are checked separately.

SteamVR's small status window corresponds to **303 / Searching / NotReady** in
the host logs. The compositor logs confirm the ALVR capture layer and successful
startup; no remote client connection had succeeded. Normal window resizing was
attempted but the status window retained its fixed geometry. No DPI/runtime or
Steam launch-option changes were made for that UI issue.

## Sources (pinned upstream and release)

- [Pinned ALVR C API](https://github.com/alvr-org/ALVR/blob/a9f6542fa507a841f40ab4f3fcb531427cd02550/alvr/client_core/src/c_api.rs)
- [Pinned GLES context implementation](https://github.com/alvr-org/ALVR/blob/a9f6542fa507a841f40ab4f3fcb531427cd02550/alvr/graphics/src/lib.rs)
- [Pinned Android decoder](https://github.com/alvr-org/ALVR/blob/a9f6542fa507a841f40ab4f3fcb531427cd02550/alvr/client_core/src/video_decoder/android.rs)
- [Pinned OpenXR stream client](https://github.com/alvr-org/ALVR/blob/a9f6542fa507a841f40ab4f3fcb531427cd02550/alvr/client_openxr/src/stream.rs)
