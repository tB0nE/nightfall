# Free-running diagnostic: submitted-image ownership

2026-10-18, `feat/meteor-xr-streaming`. Follows
[the tracked-scene checkpoint](meteor-xr-session-checkpoint.md).

## Failure and cause

Removing per-frame app file-ACK waits exposed a real association failure: an
encoded frame carried the first app timestamp, but its changing-green stripe
pixels came from a later submitted frame. Timestamp matching alone cannot fix
this. The smooth sphere scene's mean-error check initially passed because adjacent
views looked similar; retain the changing-stripe test as the stronger oracle.

The pinned multi-compositor retains `xrt_swapchain` object references in
progress/scheduled/delivered slots, but does not reserve the individual submitted
images. In this pinned implementation `swapchain_wait_image` permits writing once
the image's `use_count` is zero. With no image-use reservation, keeping the object
alive does not prevent its pixels being overwritten while older layer metadata
still references that index. No image-use increment/decrement callers existed in
the pinned source outside the API/implementation before this patch.

## Diagnostic correction

Only when `METEOR_NVENC_BRIDGE` is enabled, plain stereo projection slots now
increment image-use counters for each submitted eye/index. Slot moves transfer
that ownership unchanged. Clearing a slot decrements the counters **before**
dropping swapchain object references. This covers discarded scheduled frames,
replaced delivered frames, session teardown and client disappearance. Shared
stereo images acquire two balanced reservations.

The synchronous null-compositor hook consumes borrowed layer pointers. For this
diagnostic only, the multi-system list/timing lock now stays held across native
layer commit, preventing concurrent client retirement from releasing those
reservations during capture/encode. This is deliberately conservative and can
block app pacing through synchronous delivery; it is **not** the final async
design. Network waits remain outside the Vulkan queue mutex, but now occur inside
this diagnostic system lock. A production target must own its submitted-image
leases/references independently and release them after GPU consumption, without
holding a global session/timing lock through encode/network I/O.

Activating the image-use API also exposed a pinned implementation defect:
`swapchain_dec_image_use` unlocked its mutex inside the zero-count branch and
again after the branch. Our local patch removes the inner unlock and broadcasts
the condition while still holding the mutex, then unlocks exactly once. The
source pin remains untouched; all changes apply to the isolated output copy.

## Checks

`monado_image_lease_test.c` uses fake swapchains to verify default-off behavior,
per-eye indices, two simultaneous owners, dropped-owner release, shared stereo
images and final zero counts. `probe_monado_nvenc.sh` runs this unit test, and the
Python harness checks that service-side acquire/release ledger counts balance.
The runtime itself also checks zero image-use counts at swapchain teardown.

The formerly failing 32-frame free-running stripe run now passed: 32 submitted,
27 encoded, five compositor skips, correct markers/timestamps and final drain.
The longer run also passed (120 submitted / 108 encoded), as did the original
32-frame stop-and-wait test and five-frame interrupted-app drain, with balanced
reservation ledgers. The software app/service byte-matching capture regression
passed. The free-running tracked-scene host test passed 32 submitted / 31 encoded,
one skip, root-origin checks and decoded-reference mean byte error 1.046.
Neither pixel tolerances nor the strict
timestamp/reference matching were relaxed. Free-running abrupt-app accounting
is still explicitly unsupported; abrupt-app coverage uses the original mode.

No headset C++ or APK changes are required for this host runtime correction.
USB validation then passed: user confirmed the spheres remained in place while
moving their head, noting very low resolution/frame rate. All 120 submitted
frames were encoded/delivered, final drain completed, decoded-reference mean byte
error was 1.123, and hardware-decoder/resource teardown completed cleanly. This
does not establish acceptable stream quality or asynchronous performance.
