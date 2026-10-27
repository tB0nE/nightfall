# Vulkan diagnostic scene

The opt-in GPU scene replaces CPU pixel upload with a Vulkan compute dispatch
for the same world-fixed spheres and floor. It uses the application's actual
`xrLocateViews` poses/FOV, writes RGBA8 into an app-owned storage buffer, then
copies that buffer into the acquired OpenXR eye swapchain. The existing image
leases, asynchronous encoder, transport and headset decoder are unchanged.

This is a compute-rendered OpenXR test app, not a general rasterized game or a
new compositor. The graphics queue must also support compute. The shader is
compiled and SPIR-V validated inside the existing build container; no new host
packages or system runtime registration are needed.

## Correctness gate

CPU reference generation and GPU readback are deliberately retained in this
first implementation. The CPU oracle is independent of shader execution.
Per eye, mean absolute RGBA error must be at most one byte and at most 0.2% of
channels may differ by more than three bytes. The allowance covers floating-point
differences at sphere silhouettes and floor boundaries. The previous CPU-only
path retains its byte-exact check. Encoder output is separately compared against
the actual GPU readback, using the existing compressed-scene checks.

The GPU storage buffer currently uses the existing host-visible allocation and
queue-idle completion, reused only after completion. This is intentionally a
correctness-first path. CPU oracle work, per-eye readback, artifact writes and
queue-idle waits mean **these timings are not a GPU-only throughput benchmark**.
Next split validation from measurement, use a device-local output allocation,
and measure with GPU timestamps/completion fences before claiming a frame-rate
improvement. Do not remove ownership protection simply to improve timings.

## Reproduce

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_XR_GPU_SCENE=1 NIGHTFALL_XR_EYE_SIZE=512 \
  NIGHTFALL_XR_TARGET_HZ=60 NIGHTFALL_XR_ASYNC_ENCODE=1 \
  NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  .build-cache/model-tester-venv/bin/python test/run_monado_tracking_spike.py "$PWD"
```

For headset confirmation, pass those same flags to
`tools/build_support/probe_headset_xr_tracking_runtime.sh` only when the tester
is ready. The installed optimized DEV APK needs no change. The scene looks the
same by design; check orientation, stable world-lock and clean local exit.
Headset confirmation is recorded below.

Initial host check: 32 submitted, 31 encoded/delivered, one pending raw frame
replaced, compressed-image mean byte error 0.964, final frame drained and clean
shutdown. Shader compilation/SPIR-V validation and CPU pixel-oracle checks pass.
The longer run also passed: 120 submitted, 119 accepted by the raw worker,
118 encoded/delivered, one pending replacement and one submission skipped before
the raw worker; final frame drained, mean compressed-image error 0.962.

The preceding CPU-rendered 512-eye headset run completed 240 submissions,
239 decoded frames, one pending replacement, error 0.888 and clean shutdown;
the user reported no definite visual problem but did not give a strong
sharpness/smoothness assessment. Do not treat that as a measured 60 Hz result.

## Separate measurement mode

Add `NIGHTFALL_XR_GPU_MEASURE=1` to the GPU-scene invocation above. This explicit
opt-in requires GPU scene mode; default correctness tests are unchanged.
Measurement allocates device-local storage, performs no pixel map/upload,
CPU oracle, app readback or image artifact writes, and uses per-eye completion
fences instead of app `vkQueueWaitIdle`. One shared buffer/command buffer remains
serially reused only after the fence completes. The service's encoder/packing
ownership and synchronization have not been weakened.

GPU timestamp queries surround compute dispatch, buffer-to-swapchain copy and
layout transitions. Queue timestamp support is required; timestamp period and
valid-bit wrapping are applied. CPU submit/fence-wait time is reported separately.
There is still a one-second completion deadline, not GPU-hang recovery.

The harness labels this **measurement only**: it verifies transport byte equality,
metadata, decoded frame dimensions/count, accounting and clean shutdown, but does
not claim pixel-oracle validation. Do a correctness run separately before relying
on measurements; no stale reference files are consumed in measurement mode.

Linux RTX 3090, 512-eye/60-target, 120 submissions:

- 119 raw jobs accepted, 118 encoded/delivered, one raw replacement and one
  pre-worker skipped submission; final frame drained.
- Median both-eye app work: 335.5 microseconds (p95 500).
- GPU dispatch/copy: 240 samples, median 33.984 microseconds per eye, p95 35.456.
- CPU submit/fence wait: median 155 microseconds per eye, p95 208.
- Packing CPU wall: median 189 microseconds; encode/packet copy 755 microseconds.
- Host scheduled display cadence: 55.28 Hz, **not actual headset FPS**.

Evidence retained in ignored
`.build-cache/meteor-xr/profiles/512-60-gpu-measure-timing.json`.
This remains a short synthetic scene, not a realistic game workload or latency
benchmark. Next confirm the measurement path visually on Quest, then negotiate
real headset optics and exercise a more representative OpenXR application.

### Quest USB confirmation

The user tested the measurement path and reported: "It felt quite smooth."
At 512 pixels per eye and a 60 Hz host target, 240 submissions produced 238
encoded/delivered frames, all 238 logged as decoded by the headset. One submission
was skipped before the raw worker and one pending raw job replaced; final frame
drained, transport peak pending two. Host scheduled cadence was 58.04 Hz, not a
measurement of headset presentation rate. Both-eye app CPU-wall median was
815 us (p95 1464), GPU dispatch/copy median 33.92 us per eye (480 samples).
The host pipeline shut down cleanly; captured device logs end holding the final
picture, so this evidence alone does not confirm the subsequent local exit.
Evidence: `.build-cache/meteor-xr/profiles/512-60-gpu-headset-timing.json`.
Next: real headset optics negotiation and a representative OpenXR workload;
the short synthetic scene is not proof of game performance.
