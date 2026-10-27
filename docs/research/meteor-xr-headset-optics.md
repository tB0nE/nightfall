# Headset optics snapshot for the Monado spike

The optional `NIGHTFALL_XR_HEADSET_OPTICS=1` host flag requests actual per-eye
geometry from Nightfall before the virtual Monado HMD is made available.
Previously head tracking came from Quest but eye offsets and FOV came from the
simulated HMD. This change replaces those simulated values, without changing
tracking clock mapping, world origin or encoded frame pose semantics.

## Flow

1. The Quest render thread locates stereo views in its dedicated VIEW/head space
   at the same OpenXR time used for the head tracking sample. It publishes each
   eye's full head-relative position, quaternion and FOV with the sample epoch.
2. After the existing clock exchange, the host worker requests an optics
   snapshot on the same loopback tracking socket. Socket waits remain off the
   Quest render thread. Invalid or absent optics fail initialization when the
   flag is enabled: no silent simulated-geometry fallback.
3. The host validates and freezes this geometry for the diagnostic session.
   Tracking samples must subsequently match its epoch. A C ABI query copies
   the immutable snapshot into the Monado device at initialization.
4. The pinned simulated-driver adapter initializes the HMD's static FOV and
   overrides its view-pose callback, returning the negotiated eye-relative poses
   and FOV alongside the existing live head relation. Full eye quaternions and
   offsets are retained, not collapsed to a scalar IPD.
5. `xrLocateViews` supplies the resulting world-space eyes/FOV to the OpenXR app.
   Those exact render values already travel with the encoded frame to Quest.

Default diagnostic runs remain backward-compatible and do not request optics.
The new APK can serve both old and new host diagnostics. Older APKs cannot serve
the opt-in request and must be updated first.

## Diagnostic wire extension

`NFXO` request: existing 32-byte request envelope (version 1, size 32, zero
payload). Response: 112 bytes, little-endian:

- Bytes 0–3: `NFXO`; 4–5: version 1; 6–7: size 112.
- Bytes 8–15: nonzero tracking-session epoch.
- Bytes 16–103: 22 float32 values, left eye then right eye. Each eye contains
  position xyz, quaternion xyzw, FOV left/right/up/down in radians.
- Bytes 104–111: reserved, zero.

Validation rejects nonfinite values, nonunit eye quaternions, eye offsets over
15 cm per axis, FOV sides of incorrect sign or reaching 1.56 radians, eye
separation outside 40–90 mm, reversed left/right order, bad headers/reserved
bytes and a subsequent tracking epoch mismatch. These are deliberate limits
for the two-eye Quest diagnostic, not a general XR optics protocol.
Endpoint optics must come from a fresh (at most 250 ms old) published sample;
the worker's existing two-second request deadline applies.

## Reproduce

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_XR_HEADSET_OPTICS=1 NIGHTFALL_XR_GPU_SCENE=1 \
  NIGHTFALL_XR_GPU_MEASURE=1 NIGHTFALL_XR_EYE_SIZE=512 \
  NIGHTFALL_XR_TARGET_HZ=60 NIGHTFALL_XR_ASYNC_ENCODE=1 \
  NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  .build-cache/model-tester-venv/bin/python test/run_monado_tracking_spike.py "$PWD"
```

This uses synthetic poses/optics, not an attached headset. The fixture asserts
that asymmetric FOVs and 64 mm eye separation reach the **actual encoded view
metadata**, rather than merely checking handshake success. Measurement passed
32 submissions / 30 delivered; full GPU/CPU pixel-oracle validation passed
32 / 31, compressed-image mean byte error 1.008. Skips/replacements are accounted
for and final frames drained. Seven endpoint/bridge socket tests and the native
tracking/optics packet tests pass, including malformed optics rejection.

An optimized release-signed DEV APK was rebuilt (including changed native XR
code) and installed successfully. Headset confirmation of this optics path is
still outstanding. When ready, use the same flags with
`tools/build_support/probe_headset_xr_tracking_runtime.sh`, with `NIGHTFALL_ADB`
set if necessary, then press `DEV: Meteor decoded stereo`. Check natural scale,
stereo comfort and world-lock while moving gently. Exit by holding B/Y one second.

## Remaining limitations

### Successful headset retry

After the host startup correction, the user reported: "Felt very smooth and the
fov filled the screen this time." The real-optics session used 62.464 mm eye
separation. 240 submissions produced 237 encoded/delivered frames; all 237 were
logged decoded by Quest. Two submissions were skipped before the raw worker,
one pending raw job replaced, and the final frame drained. Host scheduled
cadence was 57.27 Hz against the 60 Hz target (not headset presentation FPS).
Median both-eye app CPU wall was 590 us, GPU dispatch/copy 33.984 us per eye.
The host pipeline completed cleanly; captured device logs end holding the final
picture and do not establish the later local-exit result. No delivery rejection
occurred in the actual service run. Fixture preflight includes intentional
negative queue tests; their failure logs are expected, not session failures.
Timing evidence is retained in ignored
`.build-cache/meteor-xr/profiles/512-60-headset-optics-timing.json`.

The first headset attempt received valid real optics (62.464 mm eye separation)
but failed during video startup: the two-slot delivery queue saturated before
the hardware decoder finished acknowledging its first packet. The host now
applies bounded backpressure on the raw encode worker only. See the
[delivery report](meteor-xr-async-delivery.md). A headset retry remains pending;
the retry above subsequently confirmed smooth playback with the full headset FOV.

This is an explicit session snapshot: changing physical lens/IPD settings
requires a fresh diagnostic session. There is no in-session geometry revision
protocol, dynamic FOV updates, display refresh negotiation, negotiated render
resolution or lens distortion mesh transport. Images remain the fixed 256/512
square-eye SDR profiles. The headset runtime performs final lens correction.
Clock drift/prediction, recenter and standby handling remain separate gates.
The transport remains unauthenticated USB-loopback diagnostics, not a LAN API.
