# PyroWave Codec Support (Quest 3)

> Status: Done (updated 2026-10-08). Merged in PR #46 (2026-10-01), with the
> zero-copy GPU decoder in PR #47 ([pyrowave-zero-copy-gpu.md](pyrowave-zero-copy-gpu.md));
> on main for the release after v0.7.11. Decode and display work on Quest 3
> against a PyroWave host (`fix(pyrowave)`, 2026-10-01; decode GPU time
> measured in `a4beb30`). Not recorded yet, from "Verification": the
> fallback against a host without PyroWave, and the throughput comparison
> with H264/HEVC/AV1.

## What It Is

[PyroWave](https://github.com/Themaister/pyrowave) is an intra-only, GPU-compute
video codec (practically a still-image codec applied per-frame) implemented
entirely in Vulkan compute shaders. It targets extremely high bitrate
(~200+ Mbit/s) over a local network in exchange for near-zero encode/decode
latency (<0.2ms at 4K on desktop GPUs) — a good fit for Nightfall's "local
network, minimize latency" use case, as an alternative to H264/HEVC/AV1 on
hosts that support it.

It is **not** a hardware video codec — there is no MediaCodec path for it.
Decode is a Vulkan compute dispatch, entirely separate from the
H264/HEVC/AV1 MediaCodec `Surface`→`SurfaceTexture` pipeline Nightfall uses
today.

Host support isn't universal — it requires a patched Sunshine-family host
(the `vibeshine`/Nonary fork, or Zevro's fork). Not all of the user's hosts
have it; some do.

## Why This Is Buildable Without Touching Nightfall's Renderer

The naive assumption (a GPU-compute codec needs a Vulkan rendering context
alongside Godot's GLES-Compatibility one, or a full Vulkan interop layer)
turned out to be wrong. PyroWave's own C library (`pyrowave.h`) owns a
**self-contained, headless Vulkan device** internally
(`pyrowave_create_default_device()`) — it never touches a window surface.
The actual decode call,
`pyrowave_decoder_decode_cpu_buffer_synchronous()`, is **synchronous** and
reads the result back to a plain CPU-side YUV420p planar buffer
(`pyrowave_cpu_buffer { data[3], row_stride_in_bytes[3], plane_size_in_bytes[3] }`)
before returning. Confirmed by reading the real desktop integration
(`zevro-ai/moonlight`'s `app/streaming/video/pyrowave.cpp`): it creates the
device/decoder once, and per-frame just pushes compressed sub-packets and
calls the synchronous decode — no Vulkan objects ever cross into its SDL
renderer.

This means Nightfall's integration is: **decode thread calls into
PyroWave's C API, gets Y/U/V planes back, hands them to the same raw-planar
upload path `texture_uploader.cpp` already has** (the one used for other
non-hardware-decoded paths). No second GPU context, no GLES/Vulkan interop,
no renderer changes.

## Reference Material (read, not just linked)

- [`Themaister/pyrowave`](https://github.com/Themaister/pyrowave) — the
  codec itself. Plain CMake `STATIC`/`SHARED` library target
  (`pyrowave_decoder.cpp/hpp`, `pyrowave_encoder.cpp/hpp`,
  `pyrowave_common.cpp/hpp`), C API surface in `pyrowave.h` and
  `pyrowave_c.cpp`. Depends on its own `Granite` submodule for shader
  codegen (`slangmosh.sh` compiles Slang shaders to SPIR-V and embeds them
  as a generated `shaders/slangmosh.hpp` at build time) — this is the one
  real build-system dependency to carry over, not just a Vulkan link.
- [`zevro-ai/moonlight-common-c`](https://github.com/zevro-ai/moonlight-common-c) —
  fork of upstream `moonlight-common-c` adding PyroWave to GameStream
  negotiation. Two commits, 15 lines across 4 files
  (`Limelight.h`, `RtspConnection.c`, `SdpGenerator.c`,
  `VideoDepacketizer.c`). This is the actual wire-protocol patch to port.
- [`zevro-ai/moonlight`](https://github.com/zevro-ai/moonlight) — desktop
  Qt/SDL client integrating PyroWave decode
  (`app/streaming/video/pyrowave.cpp/h`, `app/streaming/session.cpp`).
  This is the reference for the actual decode-unit parsing and
  `pyrowave_decoder_*` call sequence — ported almost directly, swapping SDL
  texture upload for Nightfall's existing YUV upload path.
- [`MoreOrLessSoftware/moonlight-android`](https://github.com/MoreOrLessSoftware/moonlight-android) —
  an earlier, much heavier Android integration (adds a whole parallel
  Vulkan renderer + frame pacer + partial-frame recovery). Useful for
  understanding packet-loss handling on PyroWave's bitstream, but **not**
  the architecture to follow here — it predates (or ignores) the
  CPU-buffer-readback API the desktop client uses, and building a second
  renderer is unnecessary for Nightfall given the readback approach above.

## Scope Decision: Quest 3 Only

Quest 2's older Adreno 540 is a real question mark for sustained real-time
Vulkan compute at this bitrate/resolution; Quest 3's Adreno 740 is the
target GPU this was evaluated against upstream. Ship this as a Quest
3-only codec option (device-tier gated, same pattern as existing
GPU-tier-dependent features), not a universal one. Not pursuing Quest 2
support as part of this plan.

## Implementation Plan

### Phase 1 — Build PyroWave for Android ✅ done

Turned out much simpler than the "real unknown" framing above suggested.
Building just the `pyrowave-shared` CMake target against the NDK toolchain
worked on the first clean configure/build — `PYROWAVE_DEVEL`/`PYROWAVE_UTILS`
default OFF routes Granite to `GRANITE_PLATFORM=null` automatically (no
SDL, no runtime shader compiler, no renderer pulled in), and
`shaders/slangmosh.hpp` is already pre-generated and checked into
PyroWave's own repo, so no Slang toolchain was needed at all. Vulkan
itself is loaded dynamically via `volk` (`dlopen`, not a link-time
`NEEDED` entry) — the built `.so` only needs `libc/libdl/liblog/libm`.

Build script: `tools/build_support/build_pyrowave_android.sh` (pins
PyroWave and Granite at the commits used here, clones/builds into
`.build-cache/`, strips, and vendors the result). Vendored artifact:
`addons/nightfall-stream/third_party/pyrowave/` (`include/pyrowave.h`,
`lib/android-arm64-v8a/libpyrowave-shared.so`, 1.66MB stripped, `VERSION`
recording exact commits/NDK/ABI for reproducibility). Added a `.gitignore`
exception for this one `.so` — everything else matching `*.so` in this
repo is a build output, this is a checked-in third-party binary.

**On-device validation**: pushed PyroWave's own `pyrowave-c-test` smoke
test (full C API coverage: device creation, encoder/decoder validation,
8 encode→decode roundtrip variants, error-handling, a system-stability
test) to the Quest 3 via `adb push` + `LD_LIBRARY_PATH` and ran it
directly as a native executable. **All tests passed** on the real
hardware/driver.

Real on-device performance data from that stability test, at 4K
(3840x2160, the test's own "upper bound of normal usage"):
decode-side stages (iDWT 6.56ms, Dequant 1.72ms, Packing 1.51ms, Resolve
0.08ms) total **~9.9ms/frame**; encode-side (DWT 6.47ms, Analyze 1.38ms,
Quant 5.90ms) totals ~13.75ms/frame. Scales down roughly with pixel count
at lower resolutions (~2.5ms decode at 1080p, back-of-envelope). Tight but
workable at 4K/90Hz (11.1ms budget) for decode alone; real headroom
needs measuring once this runs inside Nightfall alongside compositor/depth
work, not just standalone (see Verification below). One benign warning:
`Got global priority: expected 1024, got 256` — the Quest's driver doesn't
honor the highest realtime queue-priority request, falls back to medium;
not a failure, just a device limitation worth knowing about (same general
territory as the existing GPU-priority tradeoffs already handled for depth
inference).

### Phase 1 (original framing, kept for context)

PyroWave's repo ships `build_aarch64.sh` (SteamOS/Steam Deck aarch64 Linux,
not Android) and `setup_android_build.sh` (generates a *whole standalone
demo APK* via Granite's own gradle generator — not a cross-compiled library
artifact). Neither is directly usable. The desktop client sidesteps this
entirely by linking a **prebuilt** `libpyrowave-shared.so` built outside
its own build.

Plan: set up an Android NDK CMake toolchain build of just the `pyrowave`
library target (`add_library(pyrowave STATIC ...)` in its `CMakeLists.txt`
— a normal target, the complexity is in getting its `Granite`
submodule/shader-codegen step to run for an Android target, not the
library itself). Vendor the resulting `.so`/`.a` + headers as a prebuilt
artifact in this repo, the same pattern already used for
`addons/godotopenxrvendors`'s AAR and the LiteRT GPU AAR — built once,
checked in as a binary, not rebuilt on every Nightfall build.

Steps:
1. Clone `Themaister/pyrowave` with its `Granite` submodule.
2. Cross-compile for `arm64-v8a` / Android API level matching Nightfall's
   existing NDK target, linking against the NDK's Vulkan loader
   (`libvulkan.so`, present on-device, not bundled).
3. Confirm the shader codegen step (`slangmosh.sh` / Slang compiler) runs
   in this cross-compile, or pre-generate `shaders/slangmosh.hpp` on a
   host build and carry it over if cross-compiling the codegen step proves
   impractical.
4. Produce and vendor a release (and debug, if cheap) build of
   `libpyrowave-shared.so` + the public headers under something like
   `addons/nightfall-stream/third_party/pyrowave/`.
5. Smoke-test: a tiny native test program loading the library on-device
   (adb push + run, or a throwaway JNI entry point) confirming
   `pyrowave_create_default_device()` succeeds on the Quest 3's actual
   Vulkan driver before writing any real decoder integration.

### Phase 2 — Protocol (`moonlight-common-c`) ✅ done

Nightfall vendors `moonlight-common-c` via a vcpkg overlay port
(`addons/nightfall-stream/vcpkg-overlay/moonlight-common-c/`), pinned to
upstream commit `7b026e77be62175104640e7e722b758df6d3d0d7` with two
existing local patches already applied on top. That pinned commit is a
direct ancestor of `zevro-ai/moonlight-common-c`'s fork, so its two
PyroWave commits cherry-picked onto it with zero conflicts — the diff
below is byte-identical to the upstream fork's change, just rebased.
Saved as a third overlay patch, `0003-add-pyrowave-codec.patch`, and
registered in the port's `portfile.cmake`. Verified both that vcpkg
actually re-fetches/re-patches/reinstalls the port (triggered by the
patch-list change) and that the full `nightfall-stream` addon still
builds cleanly against the patched header.

### Phase 2 (original framing, kept for context)

Port `zevro-ai/moonlight-common-c`'s two commits onto Nightfall's vendored
copy:
- `Limelight.h`: `VIDEO_FORMAT_PYROWAVE` (`0x01000000`),
  `VIDEO_FORMAT_MASK_PYROWAVE`, `SCM_PYROWAVE` (`0x00800000`).
- `RtspConnection.c`: negotiate `PYROWAVE/90000` in the RTSP response,
  gated on both the client's supported-formats mask and the server's
  codec-mode-support bits advertising `SCM_PYROWAVE`.
- `SdpGenerator.c`: emit `x-nv-vqos[0].bitStreamFormat=3` when PyroWave is
  the negotiated format.
- `VideoDepacketizer.c`: treat PyroWave payloads as opaque
  (`BUFFER_TYPE_PICDATA`, no bitstream parsing), same handling as AV1.

### Phase 3 — Decoder: build/link infrastructure ✅ done (decode-thread wiring done in Phase 4)

Wrote `pyrowave_decoder.h/cpp` in `addons/nightfall-stream/src/video/` -
a small `PyrowaveDecoder` class wrapping `pyrowave_create_default_device()`
+ `pyrowave_decoder_create()` once per stream, and a `decode()` call per
decode unit that parses the `'PYW1'` framing, pushes sub-packets, and calls
`pyrowave_decoder_decode_cpu_buffer_synchronous()` into persistent Y/U/V
scratch buffers - ported directly from `zevro-ai/moonlight`'s
`pyrowave.cpp`, confirmed against the real API in the vendored header
rather than assumed.

Wired into `addons/nightfall-stream/CMakeLists.txt` (Android-only include
dir + link against the vendored `.so`, plus a post-build copy alongside
`libnightfall-stream.so`) and `tools/build_support/build_android.sh` (the
vendored `.so` has no `nightfall-stream.gdextension` entry of its own, so
nothing would otherwise place it in the APK - it rides along via the same
`aar_extract/jni/arm64-v8a` mechanism already used for the patched
`libgodot_android.so`, plus an `unzip -Z1` presence check matching the
existing ones for the stream/vendor libraries).

Two build issues found and fixed along the way, both header/ABI
mismatches rather than anything wrong with the vendored binary itself:
`pyrowave.h` expects Vulkan headers already included (needs
`<vulkan/vulkan.h>` first); and the NDK's own bundled Vulkan headers are
older than what PyroWave was actually built against (missing
`VkQueueGlobalPriority` - part of `VK_KHR_global_priority`). Fixed by
having `build_pyrowave_android.sh` also vendor the exact pinned
Vulkan-Headers tree Granite itself builds against
(`include/vulkan/` + `include/vk_video/`), so the include path is
guaranteed ABI-consistent with the vendored `.so` rather than whatever the
NDK happens to ship.

**Validated end-to-end on the real Quest 3**: full `nightfall-stream`
rebuild links clean (confirmed `libnightfall-stream.so` now carries a real
`NEEDED: libpyrowave-shared.so` entry, not just a build-time link), a full
`build.sh --release --install` run produces an APK that actually contains
`lib/arm64-v8a/libpyrowave-shared.so`, and the app launches and connects
to a host normally on-device - no `UnsatisfiedLinkError`, no missing-symbol
failures. This was the highest-risk remaining unknown in this phase (does
the dynamic linker actually resolve a net-new runtime `.so` dependency
bundled this way); it's now proven, not assumed.

Remaining for this phase: wire `PyrowaveDecoder` into
`stream_connection.cpp`'s decoder-setup callback (`_cb_decoder_setup()`,
which currently hits `"FATAL: Unsupported video format"` for anything
that isn't H264/HEVC on Android) and its decode thread (`_decode_thread_func()`,
which currently branches straight into MediaCodec-specific
feed/dequeue logic right after popping a packet off `packet_queue_` - the
insertion point for a PyroWave branch that bypasses all of that and calls
`uploader_->update_from_frame()` directly with a lightweight `AVFrame`
view over the decoded planes, confirmed safe since `update_from_frame()`
copies the data out synchronously and never retains the pointer).

### Phase 3 (original framing, kept for context)

New file in `addons/nightfall-stream/src/video/` (e.g.
`pyrowave_decoder.cpp/h`), parallel to the existing MediaCodec-based
decode path, not a replacement for it. Port the real logic from
`zevro-ai/moonlight`'s `pyrowave.cpp`:
- `initialize()`: `pyrowave_create_default_device()` +
  `pyrowave_decoder_create()` once per stream (matching dimensions from
  the negotiated video format), `PYROWAVE_CHROMA_SUBSAMPLING_420`.
- Per decode unit: concatenate the buffer list, validate the `'PYW1'`
  magic + packet-count header, `pyrowave_decoder_clear()` +
  `pyrowave_decoder_push_packet()` per sub-packet, then
  `pyrowave_decoder_decode_is_ready()` and
  `pyrowave_decoder_decode_cpu_buffer_synchronous()` into Y/U/V scratch
  buffers.
- Hand the Y/U/V planes to the existing raw-planar upload path (the one
  `update_from_raw_nv12()`/`update_from_raw_bgra()` already feed) instead
  of MediaCodec's `Surface`/OES texture path.
- Runs on the existing decode thread — the call is synchronous/blocking,
  which is fine there (it already blocks on `dequeue_frame()` today).
- Teardown: `pyrowave_decoder_destroy()` / `pyrowave_device_destroy()`
  mirroring the existing decoder's stop/cleanup path.

### Phase 4 — Wiring and UI ✅ done

`_cb_decoder_setup()` now has a PyroWave branch (before the MediaCodec
mime selection) that records the request and defers the actual
`PyrowaveDecoder::init()` to the decode thread via a `pyrowave_pending_init_`
flag - `_cb_decoder_setup()` runs on moonlight-common-c's own callback
thread, not the decode thread, so (mirroring the existing `native_codec_`
pattern's own reasoning) `pyrowave_decoder_` itself is only ever touched
from one thread. `_decode_thread_func()` checks that flag, initializes
and owns the decoder from there, decodes each packet synchronously, and
hands the result to `uploader_->update_from_frame()` via a lightweight
stack `AVFrame` - then `continue`s past the MediaCodec-specific code
entirely for PyroWave frames. Torn down alongside `native_codec_` at
every point that's provably after `decode_thread_.join()` (confirmed by
checking each of the 4 existing `_replace_native_codec(nullptr)` call
sites individually - one is mid-stream reconfigure on the callback
thread, where resetting it would race the decode thread, so that one's
deliberately left alone; `decoder_ready_.store(false)` already covers
it, since the decode thread's own `pyrowave_pending_init_` handling
replaces the old instance safely on its next init anyway).

UI/negotiation: added "PyroWave" to `codec_labels`, gated in
`is_codec_available()` on both `device_is_quest3` (client) and the
host's `SCM_PYROWAVE` bit (server) via the existing `_client_codec_support`/
`_server_codec_support` dictionaries. Client-side support isn't probed
through `probe_all_video_formats()` (that queries `FfmpegDecoder`'s own
capabilities for the Linux path - unrelated to PyroWave's MediaCodec-free
Android path), so it's set directly from the device-tier check instead.

Hit one real namespace bug along the way: `PyrowaveDecoder` wasn't
declared inside `namespace godot {}` like its `AndroidMediaCodec` sibling,
so `stream_connection.h`'s forward declaration resolved to a different,
incomplete type - fixed by wrapping the class in the same namespace.

**Validated on the real Quest 3**: full rebuild + install + launch,
confirmed via on-device logs that `device_is_quest3=true` and
`pyrowave=true` both resolve correctly, and the app runs normally with
all of this wired in. What's *not* yet validated (no PyroWave-capable
host available this session): an actual end-to-end stream negotiating
and decoding PyroWave content.

### Phase 4 (original framing, kept for context)

- `nightfall_stream.cpp`/`stream_connection.cpp`: codec selection branches
  on the negotiated format, same shape as the existing H264/HEVC/AV1
  branches, routing to the new decoder instead of
  `AndroidMediaCodec` when PyroWave is negotiated.
- `settings_controller.gd`: add "PyroWave" to the Codec cycling button's
  label/preference list, gated to Quest 3 (device-tier check, not shown on
  Quest 2 or Linux unless/until that's revisited).
- Stats/overlay: confirm the existing `[PERF]`/stats plumbing has a
  reasonable label for this codec (decode time here is a GPU readback, not
  a MediaCodec dequeue — the existing decode-time stat should still be
  meaningful, just worth a sanity check once it's running).

## Verification

- On-device: confirm negotiation actually lands on PyroWave against a host
  that advertises `SCM_PYROWAVE` (compared against falling back to
  H264/HEVC/AV1 against a vanilla host — must not break those).
- Confirm visual correctness (no color/chroma shift — PyroWave is YCbCr
  4:2:0 here, matching the existing raw-planar path's expectations).
- Performance: compare decode-thread throughput/latency against the
  existing codecs at matched resolution/bitrate on the same host, using
  the same `[STATS]`/`[PERF]` logging pattern already established in this
  codebase.
- Confirm clean fallback (no crash, sensible error) when PyroWave is
  selected against a host that doesn't support it.
