# First remote-controller diagnostic

Opt-in `NIGHTFALL_XR_CONTROLLERS=1` carries both controller grip/aim poses,
trigger values and grip/squeeze values to the isolated Monado host. Initial
validation uses the independent Khronos hello_xr sample. This is not complete
Quest Touch emulation or production PCVR input support.

## Headset acquisition

The existing Godot action map already owns/synchronizes grip_pose, aim_pose,
trigger and grip actions. The native DEV projection adapter resolves those
existing action handles, creates per-hand action spaces, and samples them in
the same dedicated Quest LOCAL space and converted OpenXR time as head tracking.
It does not create/attach another action set or run a second xrSyncActions.
Only the adapter's action spaces are destroyed; Godot-owned actions remain.
Normal stream/menu controller handling is not changed by this diagnostic.

Grip/aim validity are explicit. Analog state is forwarded only with a valid grip
pose and active trigger/grip actions. Invalid/inactive inputs are sent cleared,
not left held. The local B/Y exit shortcut is not forwarded. Missing action
handles/entry points are logged as controller capture unavailable.

## Wire and host ownership

The same loopback tracking connection handles a new 32-byte NFXI request.
Its 192-byte little-endian version-1 response contains:

- Bytes 0–7: magic NFXI, uint16 version 1, uint16 size 192.
- Bytes 8–31: uint64 session epoch, independent input sequence, client sample ns.
- Two 80-byte hand records (left then right): uint32 flags; float trigger and
  squeeze; four reserved bytes; grip pose xyz/xyzw; aim pose xyz/xyzw; eight
  reserved bytes. Flags: grip valid=1, aim valid=2, analog active=4.

Checks reject malformed headers/reserved bytes, replay/order/epoch changes,
nonfinite/out-of-range analog values, nonunit quaternions, positions beyond
100 m per axis, and analog-active state without a valid grip pose. Inactive
analogs must be zero. Response snapshots must be fresh within 250 ms and advance
sample time. Existing two-second socket request deadlines apply.

The host tracking worker polls inputs only when explicitly enabled. It maps
their sample clock, binds them to the head-tracking epoch and stores one latest
snapshot. Pose/input callbacks do not wait on network I/O. Queries outside the
250 ms freshness/query window or after disconnect return invalid/cleared state.
No prediction, velocities, event queue or edge-preserving button protocol exists
yet; this first step carries levels, so very short presses may be missed.

The HMD-owned bridge publishes one process-local active client. Controller
queries copy state under short lifetime/sample locks; unregistering the active
client precedes deletion. Controller objects hold their own shared-library
references, not a raw ownership claim over the HMD's client. Teardown cannot
retain an active pointer across sessions. One diagnostic HMD/client per process
is supported.

## Monado profile and sample behavior

The pinned simulated controller driver is adapted in an output copy using
`test/monado_controller_hook.patch`. Explicit WinMR left/right devices share
the HMD origin and use received poses, never static simulated positions when
the input bridge is enabled. Active grip/aim states and trigger values map to
their declared inputs. Squeeze is a click at >0.5 because that is the declared
WinMR profile input. This first milestone deliberately does not pretend the
remaining Quest buttons/sticks are mapped. Menu stays inactive remotely.

hello_xr's existing grip binding changes each rendered hand cube from 10 cm
to 5 cm when squeezed. A small diagnostic log records the application's own
hand location and actual rendered scale; it does not replace its action logic.
The sample may request haptics, but this driver does not forward haptics to Quest.

## Validation and deployment

Native packet tests cover replay, bad headers/reserved bytes, invalid flags,
analogs, quaternions and nonfinite poses. Eight tracking/endpoint/bridge socket
tests pass, including both hand identities/values and cleared outputs after a
publisher disconnect. Existing tracking/optics tests remain enabled.

Synthetic-controller host tests passed:

- Initial 32 submissions / 30 delivered, with final drain.
- Longer 120 submissions / 116 delivered; four pre-worker skipped submissions,
  all 116 accepted raw jobs encoded, zero pending replacements, clean drain.
- Assertions checked both actual sample hand positions/identities, movement,
  correct root coordinates, and rendered scales of both 0.05 and 0.1 metres.
- Negotiated asymmetric optics and the existing video/lease/transport checks
  also passed. This remains synthetic-input evidence, not headset input proof.

Retained host timings:
`.build-cache/meteor-xr/profiles/512-60-controller-host-timing.json`.
The optimized release-signed DEV APK is rebuilt with the native publisher;
headset controller validation remains pending. No debug APK is used.

First Quest run: 240 submissions / 235 delivered frames, final drain and clean
host shutdown. Device confirmed existing action capture initialized. Sample
logs show changing real controller positions for both hands; left squeeze=1
reached the host and rendered its cube at 0.05 m while the right unsqueezed cube
was 0.1 m. The user mostly missed the brief live interval and saw the final
held positions, so live visual movement/comfort and right-hand squeeze still
need an explicit retry. Do not count the held picture as live tracking proof.

Retry confirmed by the user: both controller movement and grip squeeze behavior
worked visually. Sample logs independently show both hands rendering at both
0.05 m and 0.1 m scales. 240 submissions produced 237 delivered/decoded frames,
two pre-worker skips plus one pending replacement; final frame drained and
host shutdown passed. Device logs end holding the final picture, not the later
local exit. Retained timing evidence:
`.build-cache/meteor-xr/profiles/512-60-controller-headset-timing.json`.

## Reproduce

```bash
bash tools/build_support/probe_monado_runtime.sh --build
bash tools/build_support/build_hello_xr_probe.sh
NIGHTFALL_PCVR_ALVR=OFF ./build.sh --dev --install
NIGHTFALL_XR_CONTROLLERS=1 NIGHTFALL_XR_HELLO_XR=1 \
  NIGHTFALL_XR_HEADSET_OPTICS=1 NIGHTFALL_XR_EYE_SIZE=512 \
  NIGHTFALL_XR_TARGET_HZ=60 NIGHTFALL_XR_ASYNC_ENCODE=1 \
  NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  .build-cache/model-tester-venv/bin/python test/run_monado_tracking_spike.py "$PWD"
```

For headset testing, use the same flags with
`tools/build_support/probe_headset_xr_tracking_runtime.sh` when ready, setting
NIGHTFALL_ADB if needed. Press DEV: Meteor decoded stereo, bring both controllers
into view, move each independently and squeeze/release the side grip. Expect
its small hand cube to follow and shrink/grow; reference-space cubes also remain
visible. The finite scene lasts only a few seconds. Exit after the live sequence
by holding B/Y one second. Haptics, sticks/face buttons, controller reconnection,
standby/origin reset and complete Touch profiles are later gates.
