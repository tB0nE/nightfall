# XR diagnostic: independently owned raw encode jobs

2026-10-18, `feat/meteor-xr-streaming`. Follows
[image reservations](meteor-xr-image-ownership.md) and
[asynchronous delivery](meteor-xr-async-delivery.md).

## Ownership and execution

Opt-in `NIGHTFALL_XR_ASYNC_ENCODE=1` requires both free-running app submissions and
asynchronous packet delivery. The native compositor copies a submitted frame's
layer metadata and system frame ID into a raw job. Each job acquires independent
swapchain object references **and image-use reservations** before native commit
returns. No borrowed pointer to mutable layer accumulation is retained.

A worker serially runs the existing GPU stereo-pack/NVENC bridge. The compositor
does not wait for that work or the network. Each job retains its eye images until
GPU/encoder consumption and compressed-byte handoff complete, then releases the
reservations before dropping the swapchain object references. Metadata uses the
job's saved frame ID, never `c->base.layer_accum` read later by the worker.

The raw queue contains at most one active and one pending job. A newer submission
can replace the unencoded pending job, releasing its reservations/references
immediately. The active job is never replaced. This is raw-frame dropping before
encoding; it does not break the compressed H.264 dependency chain. The delivery
queue remains separately bounded and does not discard encoded interframes.

Native session-end/destroy drains and joins the raw worker before shutting down
NVENC, draining network delivery or destroying the native device/context. The
job's compositor pointer is valid only under that lifetime contract. GPU driver
hang recovery is **not** implemented: existing queue-idle/NVENC waits remain in
the worker. Do not interpret a bounded job count as a bounded GPU execution time.

The multi-system list/timing lock now protects only short enqueue/ownership
operations in this mode, not GPU packing/encoding/network waits. GPU queue use
still serializes with Monado's Vulkan queue mutex, held through the existing
synchronous bridge call. A later GPU completion-fence/pool change can narrow that
scope; this step deliberately preserves the working image lifetime and barriers.

The final exact-timestamp file acknowledgment is written by the encode worker,
not enqueue. Therefore app swapchains do not retire just because the final job
was accepted: the final submitted frame must actually encode. The parent harness
also requires all encoded packets to drain, balanced image reservations and
consistent raw-queue accepted/completed/replaced counts.

## Validation

- Generic queue unit test: pending replacement, active job preserved, exact-once
  disposal, failure propagation, pending-job disposal on active failure, restart
  and empty shutdown.
- Full stripe pipeline: 120 app submissions, 106 raw jobs accepted, one pending
  replacement, 105 encoded/delivered frames. Fourteen app frames were skipped
  before the raw queue. Bitstream hashes, source markers, poses/FOVs, timestamps,
  final drain and ownership ledgers passed. Network peak pending was one.
- Tracked-scene host test: 32 submitted/accepted, one pending replacement, 31
  encoded/delivered, root-origin checks and mean decoded-reference byte error
  1.053. No scene corruption tolerance was relaxed.
- Original synchronous 32-frame loopback regression passed.
- Original software Vulkan app/service pixel-capture regression passed.

No APK changes were needed. Full worker-driven USB visual testing subsequently
passed: the user confirmed the scene looked stable. Logs show 120 submitted,
accepted, encoded and delivered frames, no pending replacements or submission
skips, delivery peak pending one, decoded-reference mean byte error 1.182, final
drain and clean codec/render-resource teardown with the OpenXR session unchanged.
This establishes visual correctness in this diagnostic, not realistic-rate
performance or standby/crash recovery.

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 NIGHTFALL_XR_PROBE_FRAMES=120 \
  bash tools/build_support/probe_xr_transport.sh

# Arm only when the tester is ready:
NIGHTFALL_ADB=/home/linuxbrew/.linuxbrew/bin/adb \
  NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 \
  bash tools/build_support/probe_headset_xr_tracking_runtime.sh
```

The scene is still the tiny CPU-reference renderer with fixed 256x256 eye images,
fixed simulated FOV/IPD and diagnostic pacing. This is not a visual-quality or
sustained-rate result. Next: headset regression, then negotiate dimensions/FOV,
raise resolution/rate, profile stage timings and replace coarse GPU waits with
explicit completion fences where measurements justify it. Full raw-worker app
crash/standby recovery remains a separate gate; existing synchronous app-crash
tests and generic queue failure tests do not establish that hardware path.
