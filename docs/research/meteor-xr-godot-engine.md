# Godot OpenXR engine fixture

This is an engine-compatibility smoke test following the texture-layout/color
work, not a game integration or normal Meteor feature. The standalone project
is `test/fixtures/meteor_xr_godot/`. It renders fifteen rotating colored cubes
through stock Godot 4.7's Mobile/Vulkan renderer and its own OpenXR session/frame
loop. It does not load Nightfall scripts/extensions or replace the engine renderer.

## Isolated launch

```bash
bash tools/build_support/probe_monado_runtime.sh --build
bash tools/build_support/build_xr_engine_fixture.sh
export NIGHTFALL_GODOT_EDITOR="$PWD/.build-cache/meteor-xr/godot-engine-cleanup/bin/godot.linuxbsd.editor.x86_64"
NIGHTFALL_XR_GODOT_ENGINE=1 NIGHTFALL_XR_HEADSET_OPTICS=1 \
  NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_PROBE_FRAMES=32 NIGHTFALL_XR_ASYNC_ENCODE=1 \
  NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  python3 test/run_monado_tracking_spike.py "$PWD"
```

Requires the existing Linux/NVIDIA host prerequisites and an accessible X11
display. This opens a 320×180 **game** window, not the editor. Godot headless
mode installs a dummy renderer and is not a GPU-rendering test. The installed
4.7 editor executable runs in game mode; this is not a release-export performance
benchmark. Audio is explicitly dummy (audio streaming is not part of this gate).
`NIGHTFALL_GODOT_EDITOR` may select the same compatible 4.7 executable elsewhere.
No system OpenXR runtime registration, Steam launch options or SteamVR changes.

The private simulated HMD advertises 256/512 square recommended/max eye sizes
from the existing diagnostic profile before clients create their sessions.
Unlike adapted hello_xr, the engine selects its own swapchains from those caps.
Observed Godot output: one shared two-layer R8G8B8A8_SRGB swapchain, slice 0/1,
512×512 per eye. Encoder source-layout logs must prove that path actually ran.

## Checks and limits

The scene exits after at least the requested number of **encoded** frames, not
an assumed engine FPS. Extra in-flight frames are allowed within the 240-packet
diagnostic bound; use 32 for host smoke tests and 120 for short headset tests.
Frame-count logs are not app submission timestamps or pixel oracles. Validation
checks ordered finite pose/FOV metadata, contiguous bitstream ranges, actual
decode dimensions/nonblank stereo, balanced image leases, encoder release/drain,
and bounded raw/network worker accounting when enabled. Loopback bytes and
metadata are also checked. The synthetic publisher test separately checks head
motion, adopted origin and negotiated eye spacing/asymmetric FOV propagation.

The fixture requests exit with a private output marker. Only with
`METEOR_XR_ENGINE_FIXTURE` enabled, the test runtime sends the standard
`XRT_SESSION_EVENT_REQUEST_EXIT` through the current client event sink. Godot
handles session STOPPING, calls its own xrEndSession, then the scene quits.
This avoids quitting a running session before STOPPING. The helper's single
process-lifetime flag is diagnostic-only; it is NOT a multi-client/product
session lifecycle implementation. A production service needs per-session state.

Do not switch the root viewport out of XR while it is stopping: testing that
introduced framebuffer/view-count errors. Keeping its normal XR layout until
shutdown removed those errors. The remaining observed Godot shutdown diagnostics
are recorded in `engine-outcome.json`:

- Three OpenXR InteractionProfile RID allocations reported leaked at exit.
- A spatial-extension signal disconnect reported a nonexistent connection.

These are outstanding diagnostics, not silently accepted as a clean lifecycle
pass. The validator permits only those specific known messages, flags the report
`engine_shutdown_clean: false`, and rejects other engine/XR/script errors. The
causes were found and fixed in an isolated engine copy: interaction-profile RIDs
were appended to the wrong array under an inverted condition, and marker tracking
disconnected a signal that unsupported extensions had never connected.
`patches/godot-4.7-xr-engine-cleanup.patch` corrects those two sites. The build
helper reflinks the pinned toolchain into a separate cache; APK engine inputs
are unchanged. Select that executable explicitly as above. A 33-frame async
host run passed with neither diagnostic (`engine_shutdown_clean: true`).

A run-specific atomic completion marker distinguishes normal engine shutdown
from an overlapping headset disconnect. It must match the random run ID and
encoded-frame target. It only permits normal validation: process exit, encoded
bytes, decode, ownership and drain still must pass. Early disconnects remain
interrupted; the marker alone never proves success.

## Evidence and next gates

Synchronous and asynchronous host runs rendered/decoded 32–33 engine frames with
balanced ownership and encoder drain. Seven validator unit tests cover blank
output, wrong slices, unbalanced leases, bad metadata and visible known warnings.
New engine metadata/negotiation checks are recorded in the session checkpoint.

For headset testing, use `NIGHTFALL_XR_GODOT_ENGINE=1` instead of hello_xr/internal
renderer flags with the existing USB script. Start from clean welcome. Expect
colored rotating cubes, no hand/controller objects. Check head tracking, stereo,
color and return to welcome. No new APK is required. Visual hardware validation
with the isolated fixes has now passed: the user confirmed the visual result,
and full normal validation checked 121 decoded stereo frames, balanced leases,
encoder drain and no shutdown diagnostics. This clears the fixture gate, not
general real-application compatibility or a performance target.

## Upstream application gate

The next profile runs the official Godot OpenXR origin-centric movement demo,
pinned to `b761b4cd5718a7118f2c95eb55f181d0a5f004f1` from
https://github.com/godotengine/godot-demo-projects. Prepare its ignored checkout:

```bash
bash tools/build_support/prepare_xr_upstream_demo.sh
```

Add `NIGHTFALL_XR_UPSTREAM_DEMO=1` to the engine commands above (including the USB
headset script). The runner stages a separate project copy, imports its assets,
selects Mobile/Vulkan, disables optional depth submission and adds a lifecycle
observer autoload. Upstream scenes, camera, bindings and XR viewport/session
initialization are retained. The observer inherits only our bounded completion/
exit monitoring; it does not construct cubes or replace the upstream scene.

One upstream script correction is explicit: `get_gravity()` is called on the
CharacterBody3D instead of the XROrigin3D. The first run exposed that parse error
and was rejected, despite rendering frames. The staged correction then passed
33 decoded stereo frames, metadata/tracking/optics, ownership and clean drain.
The original checkout is unchanged. This is an adapted upstream demo test, not
an unmodified shipped-game compatibility claim. Audio remains dummy. Controllers
are deliberately disabled in this first profile; movement interaction is a
separate next gate. No global runtime registration or APK rebuild is needed.

For the next headset check, expect the upstream environment rather than rotating
cubes. The user confirmed this environment looked correct on the headset.
Full normal validation passed 121 decoded stereo frames at 512 square per eye,
balanced image leases, encoder drain and no engine shutdown diagnostics.
Controller interaction remains unverified in this profile.

### Upstream controller movement

Add `NIGHTFALL_XR_CONTROLLERS=1 NIGHTFALL_XR_CONTROLLER_PROFILE=touch
NIGHTFALL_XR_TOUCH_INPUTS=1` (as separate environment assignments on one command)
to enable the existing native Touch bridge in this profile. Do not add the
hello_xr-only duration or haptics flags. The USB script defaults this profile to
200 frames (about 10 seconds at the 20-Hz target, not a guaranteed duration).

The upstream binding uses the **right stick**: vertical moves forward/back,
horizontal smoothly turns. Left-stick movement is deliberately unbound. Use
small movements for comfort; hold B/Y for local exit. Hands are upstream's small
placeholder cubes, not a new hand-model implementation.

A non-rendering observer logs both tracker states, both movement actions and
the actual upstream origin position/yaw. Synthetic host validation requires
active trackers, unbound left action, expected right input and actual movement.
It does not apply the cube fixture's stationary-world-origin assertion to an
application that intentionally moves its origin. Encoded optics validation stays
enabled. Hardware observations report movement without assuming the user acted;
visual/input confirmation remains separate.

Host run passed 121 decoded stereo frames, action-to-locomotion checks, optics,
ownership and clean shutdown. Five input-validator tests cover inactive trackers,
unbound-action leakage, absent locomotion and hardware-vs-synthetic reporting.
Log: /tmp/nightfall-xr-upstream-input.log. Headset interaction check pending.
