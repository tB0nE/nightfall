# AMD XR encoding — Linux VA-API spike

Branch: `feat/meteor-xr-streaming`. Started 2026-10-27.

## Objective

Add a Linux AMD encoder backend behind the same Monado, tracking, transport and
headset playback paths as NVIDIA. Use the RX480 for development and end-to-end
validation; modern AMD performance/features require additional hardware testing.
Keep the working NVIDIA encoder and running XR host unchanged during the spike.

The installed RX480 driver exposes H.264 Baseline/Main/High and HEVC Main
hardware encoding through VA-API. It exposes HEVC Main10 decoding but not Main10
encoding. Detect actual codec/profile/dimension support, not the marketing name.
Cards without a hardware encoder cannot be made compatible by this backend.

## Milestones

1. Establish short H.264/HEVC hardware baselines using the explicit AMD render
   node. These may upload test pixels; they are not zero-copy XR measurements.
2. Standalone GPU-resident interop: allocate/export a VA RGBA surface, import its
   DMA-BUF/modifier into Vulkan on the same DRM device, generate test pixels on
   the GPU, use VA video processing for RGBA→NV12 and hardware-encode that surface.
   Verify the decoded output, frame count, color/orientation and latency. No CPU
   pixel readback/upload may occur in this path; synchronization still costs time.
3. Factor the common Monado stereo packing/composition interface away from NVENC,
   add VA-API behind explicit capability detection and preserve NVIDIA behavior.
   Reuse the same queue ownership/lease rules and transport control protocol.
4. Exercise synthetic XR on the headset, then a real game on the AMD GPU. Test
   codec changes, live bitrate, resolution/restart, disconnect/reconnect and
   standby. Expose unsupported encoder features clearly instead of pretending
   NVIDIA-specific settings (such as QP maps) are available.
5. Package the encoder runtime against the existing glibc baseline, relying on
   the host libva/Mesa driver. Obtain a modern AMD tester before advertising
   broad generation coverage or high-resolution/high-refresh performance.

## Interop checks

- Match Vulkan and VA-API by DRM render-device identity; never silently use the
  other GPU in a mixed-vendor machine.
- Honor exported plane offsets, pitches, modifiers and object ownership.
- Synchronize Vulkan writes before VA reads and VA processing before reuse.
- Start with serial, bounded queues and no B-frames/lookahead; measure before
  introducing pipelining or external synchronization optimizations.
- Test both modest and larger stereo-frame sizes against queried capabilities.
- Store logs, encoded test clips and timing reports under
  `.build-cache/meteor-xr/amd-vaapi`; these are diagnostics, not release assets.

## Expected commonality and limits

VA-API is the initial Linux path across supported AMD generations. The RX480 can
exercise the fundamental H.264/8-bit HEVC path; it does not validate AV1, modern
encoder throughput or Windows. Multi-GPU copies are a later explicit policy,
not a hidden fallback. The first implementation keeps rendering/encoding on
the same AMD GPU.


## First spike checkpoint — 2026-10-27

- Standalone HEVC hardware baseline on the explicit RX480 render node succeeded:
  120 frames at 2048×1024, 72 Hz timestamps, no B-frames, 40 Mbps CBR and async
  depth 1. Wall time was 0.899 seconds (about 133.5 fps unpaced throughput).
  Software ffprobe decoded/count-checked all 120 frames at the expected size.
  This baseline uploads generated CPU test pixels: it is not a GPU-only XR
  latency measurement or a prediction of game performance.
- The Vulkan DMA-BUF import / VA VPP / VA hardware encoder prototype compiled
  successfully in the Ubuntu 22.04 build container. It matches VA and Vulkan by
  DRM render identity and contains no CPU pixel mapping or transfer calls.
- A subsequent standard FFmpeg H.264 baseline stalled after roughly 29 frames.
  Kernel logs identify that FFmpeg process as guilty of a `vce0` ring timeout.
  Recovery lost VRAM, then failed SMU firmware loading and ended with
  `GPU Recovery Failed: -22`. The Vulkan prototype had not entered its test loop;
  its log is empty because VA-device initialization became stuck during the
  recovery. No Vulkan interop success or latency result is claimed.
- The tests were stopped. The FFmpeg process exited after SIGKILL; the prototype
  remained in kernel D-state despite SIGKILL. No further GPU commands were run.
  The machine needs a reboot before additional AMD hardware testing.
- The paced HEVC-first revision is prepared in source, defaulting to modest
  1024×512, 48 frames and 72 Hz pacing. Rebuilding it was prevented by an OCI
  container-start sd-bus timeout after the driver failure. The runner requires a
  matching build/source stamp, so the older unpaced binary cannot be used by
  accident. A failed-boot marker blocks GPU probes in the affected boot.
- Two CPU-only runner tests pass: failed-boot blocking and AMD device selection
  independent of render-node numbering. Syntax/build-script checks pass.

Evidence: `.build-cache/meteor-xr/amd-vaapi/` contains baseline clips/logs,
`baseline-probe.json`, the kernel recovery log and the compiled initial probe.
No GPU core dump or VRAM contents were collected. The current NVIDIA XR code,
headset APK, Meteor configuration and Steam launch options were not changed.

Next after reboot:

```sh
bash tools/build_support/build_meteor_vaapi_probe.sh
/usr/bin/python3 test/run_meteor_vaapi_probe.py
```

The runner selects the sole AMD render device (or requires `--device` when there
are several), starts HEVC only by default and validates decoded colors, eye
halves, orientation and frame count if encoding succeeds. Start with that short
paced test. Do not repeat the H.264 stress baseline until the RX480 driver issue
has been investigated. Hardware H.264 is advertised by the driver but was not
stable under this test. Modern AMD behavior remains untested.

## Post-reboot checkpoint — GPU-only HEVC passed

The user rebooted after the failed H.264 recovery. The new boot passed the
failed-boot guard. No H.264 test was repeated.

RADV on this Polaris GPU advertises DMA-BUF and foreign queue ownership but not
`VK_EXT_image_drm_format_modifier`. A VA-owned RGBA surface exported an implicit
modifier, and requesting an explicit linear VA surface was rejected. A
Vulkan-owned linear storage image was also rejected by the external-image format
query. These attempts exited before submitting rendering/encoding work; the
recorded kernel logs show no new recovery failure.

The working implementation therefore uses a **Vulkan-owned device-local storage
buffer**, exported as a DMA-BUF and imported by VA as an explicitly pitched linear
RGBA surface. Compute generates packed RGBA pixels directly into the buffer;
VA video processing converts it to an encoder-owned NV12 surface, followed by
HEVC hardware encoding. Foreign queue ownership and a Vulkan fence synchronize
writes; VA surface synchronization completes conversion before buffer reuse.
No CPU pixel mapping, upload or readback occurs. The test decodes compressed
output on the CPU solely to validate its result.

Short serial tests at 72 Hz pacing, 48 frames each, 40 Mbps CBR:

| Combined stereo frame | Compute p50 | VPP p50 | Encode p50 | Total p50 | Total p95 |
| --- | --- | --- | --- | --- | --- |
| 1024×512 | 0.19 ms | 0.26 ms | 2.51 ms | 2.92 ms | 3.41 ms |
| 2048×1024 | 0.23 ms | 0.48 ms | 5.98 ms | 6.68 ms | 7.11 ms |

Both sustained the paced 72 Hz and decoded all 48 frames with correct dimensions,
left/right colors and vertical orientation. These are simple synthetic patterns,
not game rendering, network/headset latency or sustained XR session results.
The 2048×1024 frame is two 1024×1024 eye regions, not 2048 pixels per eye.

Evidence:
- `run-1793081724164054522/`: 1024×512 HEVC.
- `run-1793081740021252674/`: 2048×1024 HEVC.

Both directories are under `.build-cache/meteor-xr/amd-vaapi/` and contain the
encoded clip, encoder/kernel logs, timing and decoded pixel validation.

Next: factor the existing XR encoder interface to accept an AMD VA-API backend.
For real Monado output, sample/composite the Vulkan eye images into this shared
buffer, preserving the proven same-device selection and ownership rules. Keep
HEVC as the initial AMD path; H.264 remains unvalidated after the earlier hang.
The spike currently loads host FFmpeg 8; production packaging must build/ship
VA-API-enabled FFmpeg against the supported distribution baseline. No production
Meteor backend, packaging, headset APK or NVIDIA path has changed yet.

## Monado compositor bridge checkpoint — 2026-10-27

Implemented an opt-in VA-API bridge using the existing stereo encoder ABI,
source-image leases, synchronous worker handoff and encoded-packet callback.
The common projection/crop/array/channel-order packing code now lives in
`test/meteor_stereo_compositor.h`; the worker channel is in
`test/meteor_encoder_channel.h`. NVIDIA uses the same extracted implementation.
The borrowed Monado Vulkan device and queue remain owned by Monado.

AMD composition renders into an ordinary optimal-tiled RGBA image, then copies
it GPU-to-GPU into the linear exported buffer proven by the standalone spike.
VA converts that buffer to NV12 and encodes HEVC. Session refresh, initial bitrate
and source transfer metadata are honored. Compositor optional device extensions
now include DMA-BUF and foreign queue ownership. Neither a global runtime nor the
installed Meteor session configuration was changed.

### Polaris quad rendering issue and fix

Plain projection copies and fullscreen equirectangular composition worked, but
ordinary quads rendered black before VA processing. Tests isolated the failure
using generated pixels only: a temporary solid fragment shader, valid CPU clip
coordinates, depth/projection experiments, compression disabled for the test,
and an explicitly enabled diagnostic buffer readback. The same ordinary-quad
fixture passed on NVIDIA.

Replacing dynamic `pc.corner[i]` reads for `gl_Position` with fixed-index reads
and selection in `meteor_quad.vert` fixed the issue on this RADV Polaris stack.
The actual homogeneous positions, interpolation and texture processing are
unchanged. This is an observed shader workaround, not proof of which compiler
or driver component is responsible. All unsuccessful shader/depth/color
experiments were reverted. The production fragment shader is unchanged.

Optional `METEOR_VAAPI_INSPECT_PIXELS=1` remains diagnostic-only: it saves the first
composed test frame to `<bitstream>.rgba` and explicitly logs pixel readback.
It is OFF by default. Normal tests below ran without it and remain GPU-only.
Vulkan validation is available in the isolated build output; it exposed a
pre-existing Monado instance-extension dependency warning for
`VK_KHR_get_surface_capabilities2` without `VK_KHR_surface`, not a draw-command
validation error explaining the quads. This warning has not been fixed here.

### Verification

- Basic actual Monado projection → AMD HEVC: 16 decoded frames, timestamps,
  byte ranges, source leases, persistent encoder and clean drain passed.
- BGRA/sRGB, reversed stereo-array slices and padded source sub-rectangles:
  decoded pixel and transfer-metadata checks passed.
- Fullscreen equirectangular loading sky: decoded colors/alpha, both eyes,
  overlay/projection transitions and image drain passed.
- Final AMD rectangular-eye fixture (512×768 per eye, 60 Hz target): eight
  quads, eye visibility, alpha, 650 ms static loading hold, overlay/projection
  transitions, direct loopback transport, bounded async encoding/delivery,
  invalid-layer rejection and same-session recovery all passed.
- The matching final NVIDIA HEVC rectangular-eye fixture also passed.
- Seven CPU tests covering the failed-boot guard, AMD device selection and XR
  helper-cache validation passed. Python/shell syntax and whitespace checks pass.

Final AMD evidence: `.build-cache/meteor-xr/quad-smoke-skxsykbk/`.
After excluding the first eight worker frames, this synthetic scene measured:

| Stage | Median | p95 |
| --- | --- | --- |
| Composition + GPU packing/copy | 0.392 ms | 0.556 ms |
| VA color conversion | 0.270 ms | 0.424 ms |
| VA HEVC encoding | 3.714 ms | 4.476 ms |
| Whole encoding worker | 4.613 ms | 5.539 ms |

69 measured worker frames; simple generated scene, 32 Mbps. These are CPU-wall
stage timings, not game rendering, network/headset latency or motion-to-photon.
The timed worker excludes raw queue wait. No new GPU recovery failure occurred.
NVIDIA final evidence is recorded in
`.build-cache/meteor-xr/amd-vaapi/final-nvidia-layer.log` and its referenced
`quad-smoke-*` directory.

### Running the guarded AMD test

After building the runtime and VA bridge:

```sh
/usr/bin/python3 test/run_monado_vaapi_spike.py
```

The runner enforces a healthy boot, matching source/binary/shader hashes, HEVC
and no foveated QP maps. Diagnostic backend selection is
`NIGHTFALL_XR_ENCODER_BACKEND=vaapi`; the default remains `nvenc`. Failed-boot and
post-test kernel checks are also applied by the AMD layer smoke harness.

### Outstanding before normal Meteor/headset use

1. Package a VA-API-enabled FFmpeg encoder runtime against the release baseline;
   the diagnostic still dynamically loads host FFmpeg 8.
2. Add the validated VA bridge and its dependencies to release staging/source
   metadata, with capability-aware AMD encoder/device selection in the normal
   host launcher. The opt-in diagnostic bridge is not bundled into the current
   AppImage and no new headset APK was deployed.
3. Implement or explicitly disable unsupported live bitrate / foveated-QP
   controls for this backend. Initial bitrate works; NVENC reconfiguration and
   QP maps must not be silently advertised for VA-API.
4. Perform a real headset session, game, reconnect/standby and sustained-load
   testing. Test modern AMD hardware before claiming generation-wide coverage.
5. H.264 remains unvalidated after the earlier VCE recovery failure; HEVC is the
   only AMD bridge codec enabled for now. Windows remains a separate task.

## Packaged host checkpoint — 2026-10-27

The AMD backend is now included in the release-optimized XR AppImage. The normal
launcher performs read-only HEVC Main/VPP capability checks and records the
selected backend, render node and Vulkan ICD in `encoder-selection.json`.
Auto preserves NVIDIA on mixed-vendor systems; AMD-only systems select AMD after
capability checks. The tray's **PCVR encoder** menu offers Auto, NVIDIA/NVENC and
AMD/HEVC (experimental), applying to the next session without a host restart.
Advanced `[xr] render_device` selects an explicit AMD DRM node. Per-process
`DRI_PRIME` pins the selected AMD PCI device for the runtime and game; the bridge
rejects a mismatched compositor GPU. No cross-GPU frame copy is hidden here.

The package now builds the pinned LGPL FFmpeg 8.0.1 with `hevc_vaapi` enabled.
FFmpeg/dav1d are stored under `xr-runtime/encoder-lib`; only the encoder opens
these libraries through their explicit package path. A packaged hardware test
first exposed a system-FFmpeg collision when these libraries shared the general
loader path. Separating them fixed that issue; generated source input hashes,
component notices and ELF audits cover the new files. Host libva, DRM and actual
GPU drivers remain external. No host FFmpeg installation is needed for normal
XR gameplay. Test-only software decode still uses the system tools.

Initial bitrate/rate/codec settings are honored. Unsupported live bitrate
changes receive a rejected acknowledgment (code 95); live foveation enable also
receives code 95 with applied=false, while disabling it succeeds. Rust reports
an encoder-independent explanation rather than a misleading NVENC error. AMD
currently requires H.265 and Foveated Encoding Off before session startup.
H.264 on the RX480 remains deliberately untested after the earlier driver hang.

Verification:
- Final packaged AMD full Monado/overlay/transport/layer-recovery test passed:
  `.build-cache/meteor-xr/quad-smoke-9f0n4ri0/`.
- The log confirms use of the **bundled** `encoder-lib/libavcodec.so.62`, not
  the build machine's system FFmpeg.
- Packaged Auto on the mixed AMD/NVIDIA system selected NVENC and passed the
  same fixture: `quad-smoke-bp8zgxkv/`.
- The isolated Ubuntu 22.04 loader check passed with no GPU drivers/compiler:
  `amd-vaapi/final-baseline-runtime-check.log`.
- Static ELF audit passed glibc 2.35 compatibility and declared dependencies.
- Meteor optimized tests: 148 passed, 19 intentionally ignored, zero failures.
- 25 encoder-selection/packaging/audit/launcher Python tests passed; the direct
  C++ foveation test also verifies rejection without pretending it was applied.

Artifact:
`meteor/target/appimage/Nightfall-Meteor-0.1.1-XR-DEV-x86_64.AppImage`
(67 MB), SHA256
`c58cd7d0541f586c4dc2af922854e2e61a70ac5264f459382d1051cd379e3bcd`.
The updated runtime was installed into the existing user-data location, retaining
configuration, Steam options, the host key and headset approvals. Previous Meteor
PID 6771 shut down cleanly; the new AppImage is running under transient user unit
**`nightfall-meteor-amd-preview.service`**. Auto remains selected; normal depth
inference remains on the existing NVIDIA selection. Sunshine was not restarted.
No APK changes were needed or deployed.

Next physical test: select AMD in the Meteor tray, choose H.265 and Foveated
Encoding Off in the headset PCVR settings, set bitrate before launching and
start with a modest resolution for the RX480. Launch the usual XR application
through the unchanged Steam shortcut and check stereo, wrist menu, sound,
exit/relaunch and reconnect. Real-game/headset, sustained-load and modern AMD
hardware testing remain outstanding. This has not been published as a release.

## H.264 investigation and encoder-aware controls — 2026-10-27

The user explicitly approved another short hardware test after the earlier
failed-recovery incident. No GPU timeout/reset occurred in this investigation.

### H.264 findings

The serial Vulkan/VA path passed these tests using system FFmpeg:
- 512×256, constrained-baseline/CQP, 16 then 48 frames at 30 Hz pacing.
- 512×256, High/CBR, 48 frames at 30 Hz pacing.
- 2048×1024, High/CBR, 48 frames at both 30 and 72 Hz pacing.

The original CPU-upload/unpaced FFmpeg hang was not reproduced. Its exact cause
remains unconfirmed; successful serial tests are not proof that the original
command or driver failure has been fixed.

Packaged FFmpeg 8.0.1 exposed a separate correctness problem: High-profile H.264
at 2048×1024 produced corrupt frames (`top block unavailable for requested intra
mode`). The smaller 1024×768 real-compositor fixture decoded correctly, so it
would not have caught this alone. Main and constrained-baseline profiles were
clean at 2048×1024. The production AMD H.264 path now explicitly uses **Main**,
preserving CABAC, full resolution and the requested bitrate. The High-specific
coding path (including the 8×8 transform flag set by FFmpeg) remains uninvestigated
below that profile comparison; do not describe this as a proven driver root cause.
NVIDIA's encoding implementation/profile is unchanged.

The final packaged Main test encoded and strictly decoded all **120 frames at
2048×1024**, at 72 Hz target pacing. Actual serial throughput was 55.3 fps,
median total processing 18.30 ms (encode 17.67 ms), p95 total 18.40 ms.
HEVC remains faster on this RX480. Test evidence:
`.build-cache/meteor-xr/amd-vaapi/run-1793097207436543573/` and
`amd-vaapi/h264-main-120-result.log`.

Both standalone and full compositor tests now perform strict software decoding
of **every** compressed frame (`-xerror -err_detect explode`), not just count
frames and sample the first one. This catches malformed bitstreams which
ffprobe can otherwise count while concealing decode errors. Final Main-profile
Monado/overlay/transport/layer-recovery fixture passed with clean strict decode:
`.build-cache/meteor-xr/quad-smoke-9s9qw053/`.

Upstream references reviewed:
- FFmpeg VA-API profile and entropy options:
  https://github.com/FFmpeg/FFmpeg/blob/master/doc/encoders.texi
- FFmpeg VA-API H.264 implementation:
  https://github.com/FFmpeg/FFmpeg/blob/master/libavcodec/vaapi_encode_h264.c
- Sunshine's independent rate-control/quality settings:
  https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html
These establish available controls, not the cause of this machine's hang.
No kernel, Mesa, firmware or system encoder configuration was changed.

### Automatic foveation availability

- The package provides a read-only `meteor_xr_runtime.py --capabilities` query
  using the same selector as real session startup. Codec flags come from VA
  profiles plus the bundled encoder inventory; capabilities include supported
  codecs, foveation and live bitrate.
- The authenticated control reply includes optional encoder capabilities.
  Meteor refreshes them when the configured backend/device/runtime changes
  while idle and retains session capabilities during a session.
- Nightfall shows Foveated Encode disabled and effectively Off for unsupported
  encoders, before or during XR. Its saved preference is retained and restored
  when a supported encoder is selected again. ConfigureVideo also masks an
  unsupported request on the host, protecting older clients with a saved On value.
- Codec selection retains Quest 3's HEVC / Quest 2's H.264 preference, falling
  back within the advertised codec list when necessary. No manual codec button
  was added. Do not tell the user to look for an existing H.265 selector.
- Unsupported live bitrate remains rejected by the AMD backend; no AMD QP-map
  implementation was added. The menu's live-control description reflects this.

Verification: 149 optimized Rust tests passed (19 intentionally ignored), 33
Python tests passed, and the isolated Godot capability/preference test passed.
The final clean Ubuntu 22.04 loading check and static ELF audit passed.

Deployment:
- Release-optimized, signed DEV APK `Nightfall-Android-arm64-v8a-dev.apk` installed
  successfully on Quest 3 `2G0YC1ZF8P08QN`; app data was preserved.
- Final Meteor AppImage SHA256:
  `151bf056abb1181bd3f70b674540e990252d652d6e9b168901ebc2c9b03ef320`.
- Runtime installed into the existing user-data location; host restarted under
  `nightfall-meteor-amd-preview.service`. Auto still prefers the RTX3090 on this
  machine. No Steam launch options, Sunshine configuration or approvals changed.

Remaining physical check: connect the desktop, open PCVR settings, choose AMD in
Meteor's tray and confirm Foveated Encode greys out/Off automatically. Switch
back to NVIDIA and confirm availability/preference returns. Real-game/headset
H.264 stability and modern AMD hardware remain unverified; new work is not yet published.
