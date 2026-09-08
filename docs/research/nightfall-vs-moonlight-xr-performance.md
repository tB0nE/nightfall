# Nightfall vs Moonlight Android XR v0.3 performance investigation

Date: 2026-09-02

## Goal

Explain and close the performance gap observed on Quest 3 at 2560×1440,
90 FPS / 90 Hz with AI depth enabled. The first rule is to compare equivalent
measurements; this branch adds a Moonlight-XR-compatible statistics panel for
that purpose.

## What Moonlight XR reports

Its performance overlay uses a rolling current-plus-previous interval and
shows:

- video dimensions and stream FPS;
- decoder name;
- incoming and rendered frame rates;
- network frame loss;
- RTT and variance;
- host processing latency min/max/average, when supplied by the host;
- average decoder queue/decode time;
- native warp GPU time;
- depth inference time, depth age, and skipped depth frames.

Nightfall now calculates the corresponding network and decode values from the
same Moonlight-common frame metadata. In particular, MediaCodec PTS is the
individual frame's `enqueueTimeUs`; the old single global submit timestamp
could pair an output with a newer input and under-report latency at high FPS.
Godot does not expose a GPU timestamp for its compositor-viewport draw to
GDScript, so `Warp GPU` is explicitly shown as unavailable rather than filled
with a non-equivalent CPU frame time.

## Main architectural difference

Moonlight XR owns a small native OpenXR/GLES renderer:

1. MediaCodec decodes into a `SurfaceTexture` / external-OES texture created
   in that renderer's EGL context.
2. The renderer samples OES directly while drawing the video (or two warped
   eye views) into its OpenXR video swapchain.
3. The runtime receives that swapchain as a quad/cylinder composition layer.

Nightfall's GLES path currently does:

1. MediaCodec decodes into a `SurfaceTexture` / external-OES texture.
2. Native code blits the entire frame from OES into a full-resolution RGBA 2D
   texture so Godot can import it as an ordinary `sampler2D`.
3. Godot samples that RGBA texture again while rendering one mono or two
   stereo SubViewports used by its OpenXR composition layer(s).

That extra full-resolution read-and-write pass scales directly with pixels and
FPS. At 2560×1440×90 it moves roughly 1.33 GB/s of RGBA output before counting
the OES read, texture-cache traffic, the actual compositor-layer draw, or AI
passes. It is the strongest identified explanation for the gap at 90–120 FPS.

The current Godot `RenderingServer.texture_create_from_native_handle()` API
only accepts ordinary 2D/layered/3D textures. A GLES external texture also
requires `samplerExternalOES`, so simply changing the imported handle cannot
remove this pass.

## Other differences and costs

### AI depth path

Both clients downsample/read pixels for LiteRT inference, then run edge-aware
upsampling and occlusion work on the GPU. Nightfall currently initiates its
readback through `SubViewport.get_texture().get_image()` in GDScript and copies
the result through `PackedByteArray` and JNI. Moonlight XR performs capture and
readback in its native render loop and uses reused buffers. This is a likely
CPU/main-thread latency source after the video-copy issue is removed.

Nightfall also uses independent Godot SubViewports for depth capture,
upsampling, offset search, and each displayed eye. This is convenient and
maintainable, but makes render ordering and synchronization less direct than
Moonlight XR's explicit sequence in one command stream.

### Frame-loop overhead

Nightfall previously rewrote its entire accumulated debug log every 120 drawn
frames and emitted controller-state diagnostics every 90 frames. The file grew
for the lifetime of the process, making each rewrite progressively more
expensive. This branch changes logging to append only new lines every two
seconds and removes the periodic controller dump.

The GLES bridge also used to allocate a Java float array, find JNI methods, and
look up GL uniforms for every decoded frame. Those objects and locations are
now cached for the lifetime of the decoder surface.

## Recommended route before considering a rewrite

Implement a native video composition-layer provider inside
`nightfall-stream` using Godot 4.7's `OpenXRExtensionWrapperExtension` and
`OpenXRAPIExtension.register_composition_layer_provider()` hooks.

That provider can share Godot's existing OpenXR instance/session, own a video
swapchain, sample the MediaCodec OES texture directly, and submit the resulting
quad/cylinder layer. Godot can continue to own application lifecycle, input,
settings, and UI. This should remove the biggest
known extra pass without requiring a second OpenXR session or a ground-up app
rewrite.

Suggested order:

1. Establish repeatable on-device baselines with this branch's overlay.
2. Prototype a mono direct-OES quad provider; require identical image and
   lower GPU/frame pressure before expanding it.
3. Add cylinder geometry and native stereo/depth warp to the provider.
4. Move depth capture/readback into reusable native buffers.
5. Only reconsider removing Godot if the direct provider cannot coexist with
   its frame loop or still misses the target after measured bottlenecks are
   removed.

## Benchmark protocol

Use the same Quest 3, HorizonOS build, host, codec, bitrate, Wi-Fi conditions,
desktop content, and 2560×1440 90 FPS stream for both clients.

For each run, allow 30 seconds for clocks/thermals to settle, then record at
least 60 seconds:

1. AI off.
2. AI on.

Record all overlay fields plus compositor/application FPS from the same system
tool. Do not use headset recording during the measured interval. The `[PERF]`
log line contains Nightfall's primary comparison values for later extraction.

The most useful first decision is whether Nightfall now sustains 90/90 with AI
on. If it does not, direct-OES composition should remain the next engineering
target.
