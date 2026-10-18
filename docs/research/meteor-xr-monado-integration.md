# Meteor XR: Monado runtime integration spike

2026-10-18, `feat/meteor-xr-streaming`.
Plan: [managed runtime spike](../plans/active/meteor-xr-monado-spike.md).

**Current status:** user-confirmed tracked USB scene, 120 hardware-encoded/decoded
frames and clean teardown. See the [session checkpoint](meteor-xr-session-checkpoint.md)
for the complete progression and current limits. Earlier sections below describe
the milestones as they stood when first implemented, not today's remaining work.

## Decision and product boundary

Replace the ALVR/SteamVR-first host architecture with a Meteor-managed
Monado-based runtime/service, using WiVRn as the primary streaming reference.
Linux is the immediate test; Windows remains a required architecture gate.
One user-facing host/client experience may include several managed binaries.
The initial runtime test alone did not establish remote video; the later USB
tracked-scene proof is recorded in the checkpoint above.

## Source pins and licensing findings

- Official Monado: `eab5ff028a10db03200f6f3927a97bb6bb5d27ea`, fetched from
  `https://gitlab.freedesktop.org/monado/monado.git`.
- WiVRn reference: `f0fa8613aff2387636cabfaed115103c5e275a1d`, fetched from
  `https://github.com/WiVRn/WiVRn.git`.
- WiVRn itself pins Monado `8b259763fdd23c46592fd4cdd30b4eea997d4b70` in
  `monado-rev` and applies `patches/monado/`. Our independent upstream pin is not
  assumed ABI-compatible with that patch set. Do not transplant patches blindly.
- Monado's root LICENSE and key target sources use BSL-1.0. Modification and
  redistribution are permitted under its conditions; audit per-file/dependency
  licences before shipping. This checkout is a baseline, not a published fork.
- WiVRn's `server/target_instance_wivrn.cpp` is GPLv3-or-later. No WiVRn source
  was copied into this first probe. Track reused code/patch provenance later.

## Tested implementation

`probe_monado_runtime.sh` verifies source revisions and builds a release Monado
service and OpenXR runtime in an Ubuntu 24.04 Docker image. Dependencies are
installed inside the image only. Physical drivers are disabled; the simulated
HMD and testing null compositor are selected. SDL/OpenGL are disabled for this
minimal configuration, not a statement about production graphics support.

The test container has no network or host GPU/device passthrough. It uses Mesa
lavapipe explicitly and an isolated `/out/run` service socket. `XR_RUNTIME_JSON`
points only the test process at the generated runtime manifest. No global/user
OpenXR runtime registration, systemd service, Steam launch option or firewall is
changed. Runtime build paths in the manifest are container-local (`/out/build`).
Do not run that manifest on the host and expect those paths to resolve.

The authored `test/monado_runtime_probe.cpp` exercises:

1. OpenXR loader discovery and runtime identification.
2. Simulated HMD discovery through the separate service's IPC interface.
3. Vulkan graphics requirements and instance/device creation via enable2.
4. An offscreen graphics-bound session reaching READY and beginning.
5. Five wait/begin/locate-two-views/end cycles with positive predicted times and
   valid orientation state. The initial lifecycle probe submitted zero layers;
   the stereo extension now submits one projection layer with two eye swapchains.
6. Request-exit, STOPPING, end-session and explicit resource destruction.

Two consecutive successful runs identified `Monado(XRT) by Collabora et al 'eab5ff0'`
and each completed all five frame cycles. The service exited cleanly and its
isolated socket directory was empty after the repeat. This establishes runtime/IPC/frame lifecycle,
not rendering, encoding, wireless performance, remote tracking or compatibility.
The null compositor uses synthetic timing; these are not latency/FPS benchmarks.

### Stereo swapchain extension

`test/monado_stereo_images.h` now creates two 256×256 RGBA8 UNORM swapchains,
acquires/waits each image, uploads a diagnostic pattern using Vulkan, reads it back and verifies
every RGBA pixel before releasing it. Left is red with an X step, right blue with
a Y step; a changing green
channel identifies each of the five frames. Explicit image/buffer barriers and a
diagnostic queue-idle wait precede CPU verification. Images are returned in
COLOR_ATTACHMENT_OPTIMAL before OpenXR release. The finite swapchain wait treats
XR_TIMEOUT_EXPIRED as failure, not permission to use the image.

The test copies located eye poses/FOVs into a stereo projection layer and submits
it to the separate Monado service. Final-frame app-side artifacts are
`eye-left.ppm` and `eye-right.ppm` in the cache output directory. The build and
test passed on software Vulkan (`/tmp/nightfall-monado-stereo-build.log` and
`/tmp/nightfall-monado-stereo-test.log`).

The initial extension proved only app-side pixels. The subsequent capture hook
below adds server-side consumption. CPU readback and queue-idle remain diagnostic
only, not the production encode path.

### Server-side capture hook

`test/monado_capture_hook.patch` includes the authored
`test/monado_server_capture.h` at the null compositor's layer-commit boundary.
The pinned input checkout remains clean. The build copies it into
`capture-source/`, applies the small recorded patch and builds `capture-build/`.
No WiVRn implementation was copied.

The hook accepts exactly one stereo projection with separate full-rect 256×256
RGBA8 UNORM swapchains. Other content fails explicitly. It accesses each submitted
`comp_swapchain` image using the submitted image index, acquires external Vulkan
ownership from SHADER_READ_ONLY_OPTIMAL, copies to coherent host memory, then
restores layout and external ownership before returning. Queue operations use
Monado's queue mutex. Image references remain held by the compositor while the
synchronous readback runs.

This diagnostic relies on Monado's multi-compositor synchronization handling:
`comp_multi_compositor.c` imports/waits client fences before scheduling layers;
`comp_multi_system.c` commits them to the native compositor with an invalid sync
handle. The hook rejects a pending handle instead of silently ignoring it. This
is not yet proof of hardware fence behavior: all runs use software Vulkan.

The hook checks opaque alpha and the asymmetric per-eye patterns, saves
`server-eye-left.ppm` and `server-eye-right.ppm`, and logs frame/timestamp metadata.
A file acknowledgment written after both final-frame captures keeps the test
app alive until consumption completes (originally two seconds, now bounded at
ten seconds to cover diagnostic GPU encoder initialization). This is test
coordination, not a proposed network protocol. Without it, an initial test caught
teardown before the asynchronous compositor consumed the last submission.

The test removes only its known generated images/acknowledgment before startup
of the app, then uses `cmp` to check both server images against the app's final
readbacks. Two consecutive runs passed, with clean service shutdown. See
`/tmp/nightfall-monado-capture-build.log`, `...-test.log` and `...-repeat.log`.
Intermediate app frames may be skipped by compositor pacing; five submitted
frames do not imply five presented frames. Final-frame matching is required.

This establishes raw stereo image delivery across IPC into the service, including
eye identity and spatial pattern preservation. It is not a general compositor,
pose/FOV alignment proof, alpha blending/color-space test, encoder, remote
tracking or headset stream. The next step is GPU-local output/encoder ownership
and an actual render/encode path, retaining an asymmetric correctness sample.

### Useful bring-up corrections

- A background service must set `XRT_NO_STDIN=1`; otherwise Monado tries to
  register stdin with epoll and fails in a non-interactive container.
- The container's software ICD is `lvp_icd.json`; the script also recognizes the
  older `lvp_icd.x86_64.json` name and fails if neither exists.
- A true `XR_MND_headless` session does not exercise Monado's compositor frame
  accounting. It cannot serve as proof of wait/begin/end pacing. The probe was
  changed to a Vulkan-bound session against the null compositor instead.
- Disabling optional graphics support requires clearing dependent cached GLX/SDL
  flags too. No upstream source patch was needed for this minimal build.

Build/test logs and generated binaries:
`.build-cache/meteor-xr/monado-linux-spike/` (`service.log`, `probe.log`,
`runtime-probe`, `capture-build/`, `capture-source/`, eye PPMs). Source-pinned, not a bit-reproducible image: distribution
packages/base-image updates are not locked yet.

## Integration seams to study next

### Loopback transport checkpoint

The next-stage [transport probe](meteor-xr-transport-probe.md) first forwarded the
live encoder spool to an isolated Rust receiver; it now uses a native owned-packet
callback by default. Payloads/poses/FOVs/times reach the receiver without spool
reads and outside Monado's GPU queue lock. 32/120-frame runs passed payload hash,
metadata and decoded-marker checks; old spool mode remains for regression.
It does not connect to the headset. Normal Meteor discovery/server is unchanged,
and the diagnostic receiver binds loopback only without encryption.

### Persistent encoder and changing-frame sequence (2026-10-18)

The shared diagnostic bridge now keeps its Vulkan packed image/allocation,
CUDA context/imported array, NVENC session/registered input/bitstream buffer and
command pool alive across submissions. A dedicated worker owns the CUDA context
for its full lifetime. The input channel permits one active frame; submission
waits for completion, so no unbounded queue or premature swapchain reuse exists.
Borrowed source image references remain valid throughout that wait. NVENC input
is mapped/unmapped for each frame; the packed image is reacquired from external
GENERAL ownership before the next GPU copy. No service-side pixel readback.

The compositor keeps the module loaded, ignores repeated presentation of an
already encoded display timestamp, and rejects backwards timestamps. Metadata
is appended as JSONL with frame ID, monotonic display time, views and exact
encoded byte offset/length. Each encoded output timestamp is checked against
the input ID. `null_compositor_end_session` and the final destroy fallback both
join/drain the worker before the runtime destroys its Vulkan device; cleanup is
idempotent. Logs identify one initialization, drain count and completed resource
release.

The OpenXR app emits changing green markers `(frame * 73) % 256`, preserving the
spatial red/blue steps. It waits for each display timestamp's acknowledgment
before submitting the next frame. This deliberate stop-and-wait proof ensures
we validate every frame rather than letting synthetic compositor pacing drop
intermediates. It does not represent real-time network or encoder throughput.
The runner verifies all metadata/timestamp orders, contiguous positive bitstream
ranges covering the whole file, decoded frame count and every frame's marker.
Markers are spaced enough that the lossy decoder tolerance rejects an adjacent
stale frame. Offline tests also reject duplicated/reversed frame sequences.

Passed on the RTX 3090:

- 32 changing frames with one encoder/surface and clean normal exit.
- 120 changing frames with the same resources and ordered matching output.
- Deliberately killing only the test app after five encoded frames; valid
  partial bitstream/metadata, encoder drain and cleanup during service shutdown.

Evidence: `/tmp/nightfall-monado-continuous-test.log`,
`/tmp/nightfall-monado-continuous-120.log`,
`/tmp/nightfall-monado-continuous-disconnect.log`. Current artifacts overwrite the
previous run in `.build-cache/meteor-xr/monado-nvenc-spike/`.

Still diagnostic: one synchronous surface, queue-idle and blocking bitstream
waits, small SDR frames, fail-fast errors rather than recoverable encoder faults,
and no network or remote tracking. Avoid promising product streaming from this.
Before production, extract the spike's compile-time branches into a maintainable
encoder component, add asynchronous synchronization, negotiated dimensions/rate,
bounded low-latency drop policy, transport, and headset decoding/presentation.

### Actual Monado swapchain encoding (2026-10-18)

`probe_monado_nvenc.sh` compiles the same authored interop source as a shared
diagnostic bridge (`METEOR_MONADO_BRIDGE`). The null-compositor hook loads it only
when `METEOR_NVENC_BRIDGE` is explicitly set. Ordinary software capture tests do
not load CUDA or NVENC. The pinned input checkout stays unchanged.

The hook validates the same narrow full-rect stereo layout as before, selects
each submitted swapchain image by its actual index, and passes borrowed Vulkan
handles into the bridge. The bridge acquires the images from external ownership,
GPU-copies left and right into a single dedicated 512×256 exportable image, then
restores source layout/ownership. It uses Monado's queue mutex and a diagnostic
queue-idle wait. CUDA imports the packed image and NVENC encodes a single IDR.
No CPU upload or image readback occurs in this service-side branch. Only the
encoded bitstream is read by the CPU. The OpenXR test app still performs its own
diagnostic readback to validate what it submitted.

The app submits only its known final frame in this mode to avoid confusing
compositor frame dropping with encoder validation. The hook records compositor
frame ID, monotonic display timestamp and both submitted poses/FOVs in
`monado-stereo.json`. NVENC receives the frame ID as its input timestamp and its
output timestamp is checked before writing the bitstream. Acknowledgment follows
encoder completion/resource teardown and metadata output, before the app exits.

`run_monado_nvenc_spike.py` runs the built service and app natively with a private
process-local runtime manifest and NVIDIA ICD. All known diagnostic outputs are
cleared first. A short private `/tmp/nf-xr-*` socket directory avoids Linux's
108-byte Unix-socket path limit; the long checkout path initially failed this
check. The runner holds an exclusive artifact-directory lock, bounds startup and
app/decoder waits, and always terminates/reaps its exact child service.

The integrated run passed on RTX 3090 / driver 615.71.09: the actual encoded
swapchain markers decode correctly, including green=255 for the final frame;
metadata display time exactly matches the app's `xrConvertTimeToTimespecTimeKHR`
conversion, and poses/FOVs are finite with unit quaternion orientations. The
service readback branch did not run. This proves actual OpenXR app → Monado IPC
→ GPU packing → CUDA/NVENC → decodable stereo output, not just a separate pattern
generator. It does not prove pose-based rendering/reprojection or sustained rate.

Artifacts: `.build-cache/meteor-xr/monado-nvenc-spike/` (`monado-stereo.h264`,
`monado-stereo.json`, `decoded.rgb`, `service.log`, `probe.log`). Run evidence:
`/tmp/nightfall-monado-nvenc-integrated.log`. No global runtime, host XR service,
SteamVR setting or headset build was changed.

Limitations: one known frame, SDR RGBA8, per-call allocations/context/encoder,
blocking queue/bitstream waits, and diagnostic fail-fast process exit on bridge
errors. The C ABI borrows handles within one process; it is not a remote protocol.
Production needs a persistent pooled encoder, asynchronous fences, bounded queues,
continuous frame/metadata matching, disconnect/drain handling and transport to
Nightfall. Hardware elsewhere and Windows are not yet validated.

### NVIDIA GPU-memory encoding feasibility (2026-10-18)

`test/meteor_vulkan_nvenc_probe.cpp` and
`tools/build_support/probe_vulkan_nvenc.sh` implement an independent Linux-only
interop proof. This is not yet the Monado image path or a Meteor transport.

- Matches Vulkan and CUDA devices by UUID, not coincidental device index.
- Checks export support, allocates dedicated device-local RGBA8 optimal image
  memory and exports an opaque FD. CUDA owns the FD after successful import.
- Imports that allocation as a CUDA mipmapped array; registers its level-zero
  array with NVENC as ABGR (matching RGBA byte order).
- Uploads a synthetic 512×256 side-by-side pattern once from coherent CPU memory
  via Vulkan. Releases Vulkan ownership to external/GENERAL and waits for the
  queue before encoding. No image pixels return to the CPU between Vulkan and
  NVENC. This uses a blocking diagnostic handoff, not asynchronous shared fences.
- Configures H.264 P1/ultra-low-latency, 4 Mbps CBR, no B frames/lookahead;
  checks output timestamps, writes five encoded copies of that static image,
  and releases mapped/registered input, encoder, CUDA and Vulkan resources.
- FFmpeg decodes the result; `check_nvenc_stereo.py` checks all five frame sizes
  and spatial/color samples with a 20-level tolerance for lossy color conversion.
  Offline negative tests reject black, truncated, vertically flipped and
  eye-swapped images. No silent software-encoder fallback.

Observed on RTX 3090 / driver 615.71.09: initial submit-to-bitstream-lock about
0.97 ms, later calls about 0.24–0.28 ms, **for a tiny static 512×256 test only**.
These are not render latency, sustainable XR encode rate or network measurements.
The probe passed and decoded correctly. Artifacts:
`.build-cache/meteor-xr/nvenc-spike/`; run log
`/tmp/nightfall-vulkan-nvenc-explicit.log`.

The installed FFmpeg 8.1.3 `hwmap=derive_device=cuda:mode=read+direct` route first
failed with ENOSYS (“Function not implemented”). That does not mean the GPU
cannot interoperate: the explicit external-memory probe above succeeded.
We do not depend on that FFmpeg filter route for the future compositor handoff.

NVIDIA documents Vulkan/CUDA-array NVENC interoperability in its
[SDK sample overview](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/read-me/index.html)
and resource registration in the
[encoder programming guide](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvenc-video-encoder-api-prog-guide/index.html).
The build references MIT-licensed nv-codec-headers declarations from the pinned
WiVRn checkout; no WiVRn encoder implementation was copied. Review notices before
vendoring/distribution. Production work still needs persistent pooled surfaces,
per-frame GPU synchronization, backpressure/drain, real stereo packing from
Monado, frame metadata, transport, and AMD/Intel/Windows backends.

At the pinned WiVRn revision:

- `server/target_instance_wivrn.cpp`: replaces `xrt_instance_create`, implements
  `create_system`, creates a session-backed device/compositor system and starts
  it against the IPC server. This is not desktop capture.
- `server/driver/wivrn_session.cpp`: session/device/connection boundary.
- `server/compositor/compositor.cpp`, `layer_squasher.cpp`, `pacer.cpp`: compositor
  output, submitted-layer handling and timing. Inspect image lifetimes/fences
  before choosing what to reuse in a Meteor-specific target.
- `server/encoder/`: separate hardware/software implementations. A working
  runtime is not evidence any specific encoder works on this host.

Next gate: a real output/composition target and GPU-local encoder handoff beyond
the diagnostic raw-image capture. Keep software/test readback
explicitly diagnostic. Do not jump directly back to a game or hide encoder errors
behind a running-session flag.

## Retired host setup and preserved work

The temporary ALVR dashboard was stopped after verifying its process. SteamVR
was not running. Only our exact `alvr_server` external-driver path was removed;
Standable remains registered. The wrapper symlink was moved into the backup
directory as `retired-wrapper-link`, and both prior compositor files were restored.
Verified restored hashes:

- `vrcompositor`: `ebdffa9a8309d9596201cb385ceded35b71a1f16fb8f123fc0196c245cb8186c`.
- `vrcompositor.real`: `cc0c862b5219f00f97c0d68f64c7c9b731ab5ddfcf756bc369786c2477aa0c21`.

The user's reset ALVR settings, Steam launch options and runtime paths were not
restored/overwritten. Keep the ignored research cache until this work is archived.
The ALVR adapter/probe/audit remains for reference, disabled in ordinary builds.
Welcome no longer exposes its remote button and legacy entry reports retirement.
The successful synthetic Nightfall projection and lifecycle tests remain.

## Still not proved (updated after tracked USB scene)

General-purpose composition/output target, sustained-rate asynchronous delivery,
authenticated LAN transport, negotiated real-device FOV/IPD, prediction/recenter/
standby, controller/haptic/audio behavior, automatic Meteor orchestration, Windows
execution, Proton and OpenVR compatibility. Actual app images, GPU encoder interop,
USB framing, live tracking and Quest projection now have diagnostic evidence;
that evidence is not a production-readiness claim.
