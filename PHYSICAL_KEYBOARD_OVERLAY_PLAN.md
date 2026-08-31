# Physical Keyboard Overlay Plan

## Objective

Add an optional Quest 3/3S feature that detects one real keyboard and places a
virtual 2D keyboard surface over it. The physical keyboard remains connected
directly to the host PC; Nightfall provides visual guidance only and does not
forward, intercept, or synthesize keyboard input.

The first deliverable is deliberately a tracking wireframe, not a finished
keyboard. It must prove that Meta's tracking pose and bounds are accurate,
stable, and cheap enough while Nightfall is streaming before layout rendering
or settings UI are built.

## Agreed Product Decisions

- Target Meta Quest 3 and Quest 3S on Horizon OS v72 or newer.
- Do not provide a Quest 2 fallback.
- Track one physical keyboard at a time.
- Use Meta's system Dynamic Object Tracker. Do not run Nightfall's own camera
  model or request raw camera frames.
- Keep the physical keyboard connected directly to the streaming host.
- Render the overlay as a world-space OpenXR composition-layer quad so it works
  with Nightfall's projectionless GLES path.
- The first experiment renders only a tracked rectangle/wireframe.
- The eventual keyboard overlay uses a user-confirmed layout preset. Physical
  aspect ratio may suggest a form factor, but must never silently decide the
  exact key layout.
- Do not render hands or fingertips and do not open a passthrough window.
- Mouse detection is out of scope. Meta currently exposes keyboards as the only
  supported dynamic-object class.
- Existing virtual-keyboard behavior and input routing must remain unchanged.

## What the Platform Can and Cannot Supply

Meta exposes physical keyboard tracking through
`XR_META_dynamic_object_tracker` and `XR_META_dynamic_object_keyboard`. On a
supported and enabled headset it can return a keyboard spatial entity, a 6DoF
pose, and 2D/3D bounds. It supports laptop, wired, and wireless keyboards, but
only one keyboard at a time.

It does **not** identify the keyboard make, model, locale, ANSI/ISO arrangement,
or individual key positions. A width/height ratio can separate broad families
such as full-size, TKL, and compact, but cannot reliably distinguish ANSI from
ISO or similar layouts. That is why layout selection remains user-confirmed.

Unusual split keyboards, unusual colors, and keyboards with little contrast
against the desk may not be detected. Those are unsupported cases, not cases in
which Nightfall should fall back to custom computer vision.

The tracker requires:

- Keyboard Tracking enabled under Quest **Settings > Devices > Keyboard**.
- Android permissions `com.oculus.permission.USE_ANCHOR_API` and
  `com.oculus.permission.USE_SCENE`.
- A headset account linked to a Meta developer team for sideloaded builds.

Nightfall should not add Android's `CAMERA` permission for this feature. The
system tracker returns spatial metadata without giving the application raw
camera images.

## Architecture

```text
Meta Dynamic Object Tracker / Scene API
                |
                v
PhysicalKeyboardTracker (native GDExtension)
  - extension and session lifecycle
  - async tracker/query state machine
  - keyboard pose and bounds snapshot
                |
                v
physical_keyboard_overlay.gd
  - state/error presentation
  - pose validation and loss handling
  - wireframe now, key-layout viewport later
                |
                v
OpenXRCompositionLayerQuad
  - world-space, projectionless rendering
  - no passthrough layer
```

### Native OpenXR integration

Implement the bridge in the existing `addons/nightfall-stream` GDExtension so
the project keeps one native Android build pipeline and one shipped Nightfall
library.

Add a small `OpenXRExtensionWrapperExtension` subclass and register it at
`MODULE_INITIALIZATION_LEVEL_CORE`, before Godot creates its OpenXR instance.
Change the library's minimum initialization level to `CORE`, but keep all
existing stream classes registered at `SCENE`; only the OpenXR wrapper and its
lifetime setup should happen early. Godot explicitly requires extension-wrapper
registration at core initialization and before OpenXR initialization.

The wrapper should:

1. Request `XR_META_dynamic_object_tracker`,
   `XR_META_dynamic_object_keyboard`, and the Scene/Spatial Entity extensions
   required by Meta's current `XrDynamicObjects` sample.
2. Chain `XrSystemDynamicObjectTrackerPropertiesMETA` and
   `XrSystemDynamicObjectKeyboardPropertiesMETA` into system properties and
   expose runtime support only when both report support.
3. Resolve all extension entry points through `xrGetInstanceProcAddr`; do not
   link directly to an OpenXR loader implementation.
4. On an active session, asynchronously create the tracker and wait for the
   matching `XR_TYPE_EVENT_DATA_DYNAMIC_OBJECT_TRACKER_CREATE_RESULT_META`
   event.
5. Configure only `XR_DYNAMIC_OBJECT_CLASS_KEYBOARD_META` and wait for the
   matching set-classes result event.
6. Query spaces with the dynamic-object-data component, select the first entity
   whose class is keyboard, enable its locatable component if needed, and retain
   its `XrSpace`.
7. Locate the keyboard relative to Godot's current play space using
   `OpenXRAPIExtension.get_play_space()` and
   `get_predicted_display_time()`.
8. Convert `XrPosef` through `OpenXRAPIExtension.transform_from_pose()` and
   return the 2D and 3D bounds without duplicating OpenXR-to-Godot axis or world
   scale conversion in GDScript.
9. Consume tracker and query completion events in `_on_event_polled()` and
   validate that asynchronous event handles/request IDs match the current
   operation.
10. Destroy the tracker, release queried spaces/results, and clear all handles
    on stop, session loss, and extension shutdown.

Use the OpenXR headers from a pinned Meta OpenXR Mobile SDK release. Import only
the headers/API definitions needed by this bridge and record the SDK version and
license; do not copy the sample framework into Nightfall. Meta's
`XrDynamicObjects` sample is the behavioral reference for the query and
component-enable sequence.

### Godot-facing API

Expose a `PhysicalKeyboardTracker` class with this narrow interface:

```gdscript
enum State {
    UNSUPPORTED,
    STOPPED,
    CREATING,
    CONFIGURING,
    SEARCHING,
    TRACKED,
    LOST,
    ERROR,
}

func is_supported() -> bool
func start() -> Error
func stop() -> void
func get_state() -> State
func get_keyboard_transform() -> Transform3D
func get_keyboard_bounds_2d() -> Rect2
func get_keyboard_bounds_3d() -> AABB
func get_last_error() -> String

signal state_changed(state: State)
signal tracking_updated(transform: Transform3D, bounds_2d: Rect2, bounds_3d: AABB)
```

Do not invent a confidence value: the OpenXR location validity/tracking flags
are the source of truth. Do not emit Godot signals from a render thread. If the
chosen lifecycle callback is not on the main thread, publish a locked snapshot
and dispatch it from `_on_process()`.

### State and recovery behavior

- `XR_ERROR_INITIALIZATION_FAILED` during creation means tracking is disabled
  in system settings; report a specific instruction rather than a generic
  native error.
- Missing extensions, unsupported hardware, or unsupported system properties
  produce `UNSUPPORTED` and leave the rest of Nightfall untouched.
- A pose is usable only when OpenXR marks both orientation and position valid.
  Tracked flags may be logged separately to distinguish inferred from actively
  tracked poses.
- Keep the last valid visual transform through only a short loss grace period
  (target 250 ms), then hide it. Never allow a stale keyboard to remain visible
  indefinitely.
- Continue the spatial query at a low rate while searching. Do not query every
  render frame.
- If tracking data disappears because the user disables tracking mid-session,
  clear the entity and move to `LOST`. Retry tracker creation only on an
  explicit feature re-enable or XR session focus transition; avoid an endless
  high-frequency create loop.
- Stop and destroy the tracker whenever the feature is disabled. Do the same
  when the XR session ends or the application pauses.

### Rendering

Add a dedicated overlay controller rather than adding tracking concerns to
`virtual_keyboard.gd`.

For the wireframe spike:

- Create a transparent `SubViewport` containing only a border, center marker,
  and optional diagnostic axis marks.
- Present it through an `OpenXRCompositionLayerQuad`, using the same established
  viewport-to-composition-layer pattern as Nightfall's current virtual
  keyboard.
- Set the quad size from the tracked keyboard's physical bounds.
- Derive the visible top surface and its orientation from the returned 3D
  bounding box. Validate axis/sign conventions on-device against Meta's sample
  rather than hiding a bad transform with arbitrary offsets.
- Keep the layer hidden unless the state is `TRACKED` and the pose is valid.
- Do not create a projection mesh, passthrough layer, collision surface, pointer
  target, or keyboard input handler.
- Update only the quad transform during tracking. Redraw the viewport only when
  its appearance or bounds change.

This remains compatible with the GLES Quest build because OpenXR composition
layers are submitted independently of Nightfall's projectionless stream layer.
The Linux/Vulkan build should compile the bridge but return unsupported and
never construct the overlay.

## Phased Implementation

### Phase 0: API and build proof

- Pin the Meta OpenXR SDK/header version used by the implementation.
- Confirm the current Meta vendor plugin does not already expose the dynamic
  object tracker. Keep the custom bridge isolated so it can later be removed if
  Godot gains first-party support.
- Add the two Android manifest permissions without enabling the camera
  permission.
- Add the core-level extension wrapper while preserving scene-level
  registration of existing stream classes.
- Build both Android release/GLES and Linux release/Vulkan targets.
- Log extension availability, device support, session creation, and teardown.

Exit criterion: Nightfall launches and streams normally on Quest and Linux,
with no feature behavior yet beyond correct support logging.

### Phase 1: Native tracker state machine

- Implement function loading, support property chains, asynchronous tracker
  creation/configuration, spatial queries, component enabling, and space
  location.
- Expose the Godot-facing state, pose, bounds, and error API.
- Add structured `[PHYSICAL-KB]` logs for every state transition and OpenXR
  failure, but do not log every pose update.
- Add a developer-only feature switch, default off. Do not add permanent user
  settings UI during the spike.

Exit criterion: logs show a keyboard entity being found, located, lost,
reacquired, and safely released without rendering it.

### Phase 2: Wireframe tracking spike

- Add `src/physical_keyboard_overlay.gd` and a transparent composition-layer
  viewport.
- Draw only the tracked bounds and axis/origin diagnostics.
- Verify translation, rotation, scale, top-plane selection, and world-locking
  against the real keyboard.
- Test stationary use, normal head movement, keyboard repositioning, temporary
  occlusion, leaving and re-entering view, recentering, app pause/resume, and
  stopping/restarting a stream.
- Record screen capture and logs for visible drift or pose jumps.

Exit criterion: the rectangle consistently identifies the correct keyboard and
stays close enough to its edges to make individual key rendering credible.

### Phase 3: Performance gate

Run matched release-build tests on both Quest 3 and Quest 3S:

1. Stream with tracking feature off.
2. Stream with tracker active and wireframe visible.
3. Repeat both with AI 3D off and on.
4. Use the performance-sensitive setup already under test: 60 fps stream,
   120 Hz display, and the normal projectionless GLES path.
5. Warm up each run, then capture at least two minutes of steady-state metrics.

Compare application/stream FPS, compositor dropped frames, CPU/GPU levels and
utilization, thermal warnings, and AI depth inference cadence. The spike passes
only if it causes no sustained stream-FPS regression or new compositor drops,
and AI depth cadence remains within 5% of the matched tracker-off run. Also
record the tracker's acquisition/reacquisition behavior; do not disguise poor
tracking with heavy pose smoothing.

If the cost is too high, stop here. A small passthrough window is not an
automatic fallback because a projected passthrough surface still runs Meta's
passthrough service and has its own nontrivial cost.

### Phase 4: Conditional key-layout MVP

Proceed only after the tracking and performance gates pass.

- Refactor reusable keycap styling/data from `virtual_keyboard.gd` without
  sharing its pointer handling, input state, trackpad, or host event emission.
- Define keyboard templates in normalized physical coordinates. Initial preset
  families:
  - ANSI full-size
  - ISO full-size
  - ANSI TKL
  - ISO TKL
  - ANSI laptop/75%
  - ISO laptop/75%
  - ANSI compact 60/65%
  - ISO compact 60/65%
- Scale the selected template to the tracked physical bounds.
- Use aspect ratio only to rank likely form-factor presets. If there is no saved
  choice, show the best suggestion and require the user to confirm or cycle it;
  never use aspect ratio to infer ANSI versus ISO.
- Persist one confirmed preset as `physical_keyboard_layout_preset`. The saved
  user choice wins over future automatic suggestions.
- Render legends for visual orientation only. Key highlights must not imply
  that Nightfall can observe typing on the host-connected keyboard.
- If tracking accuracy proves consistently biased, add a small explicit
  calibration transform after measuring the bias. Do not make calibration a
  prerequisite or use it to compensate for unstable tracking.

Exit criterion: the selected key layout is legible, remains aligned during
normal seated use, and can be enabled without changing virtual keyboard or host
input behavior.

### Phase 5: Product UI and release hardening

- Replace the developer switch with a user-facing **Physical Keyboard** setting
  and a separate **Layout** selector. Choose final placement only after the
  spike, because the current Controls tab is already dense.
- Show actionable states: unsupported headset, enable Keyboard Tracking in Quest
  settings, searching, tracked, and tracking lost.
- Default the feature to off and persist the choice.
- Add first-run text explaining that the keyboard stays connected to the host
  and that Nightfall receives no camera image or physical key events.
- Check the Fast/Wide Motion hand-tracking settings before release. Meta tracking
  modes that conflict with Dynamic Object Tracking must be rejected or disabled
  explicitly rather than allowed to fail unpredictably.
- Re-run store manifest checks, privacy copy, pause/resume tests, long thermal
  tests, and release APK deployment.

## Test Matrix

| Area | Required coverage |
| --- | --- |
| Devices | Quest 3 and Quest 3S; Quest 2 must fail closed without a crash |
| Rendering | Quest release GLES/projectionless; Linux release Vulkan unaffected |
| Stream modes | SDR, HDR when available, AI 3D off/on |
| Refresh/load | 60 fps stream at 120 Hz; current performance-heavy resolution |
| Keyboard types | At least one external full/TKL board and one laptop/compact board |
| Tracking | Stationary, head motion, moved keyboard, occlusion, out/in of view |
| Lifecycle | Enable/disable, recenter, stream reconnect, app pause/resume, XR restart |
| Permissions | Enabled, system tracking disabled, manifest/runtime failure |
| Regression | Existing virtual keyboard, controllers, mouse cursor, and input routing |

## Go/No-Go Criteria

The feature advances beyond the wireframe only when all of these are true:

- A supported headset reliably finds the intended keyboard under ordinary desk
  lighting.
- Alignment remains within roughly one quarter of a standard key pitch (target
  5 mm) while the keyboard is stationary and the user moves their head.
- Repositioning or temporary loss does not leave a stale overlay behind and
  reacquisition does not require restarting Nightfall.
- The performance gate in Phase 3 passes on both Quest 3 and Quest 3S.
- The feature remains entirely optional and produces no behavior change when
  disabled or unsupported.

If tracking is stable but has a repeatable fixed offset, proceed with a measured
calibration design. If it jitters, drifts, regularly chooses the wrong plane, or
materially reduces streaming/AI-3D performance, do not build the layout layer.

## Expected File Areas

- `addons/nightfall-stream/src/register_types.cpp`: early wrapper registration,
  scene-level class registration retained.
- `addons/nightfall-stream/src/xr/physical_keyboard_tracker.*`: OpenXR wrapper,
  tracker state machine, queries, pose/bounds conversion.
- `addons/nightfall-stream/CMakeLists.txt`: pinned OpenXR header include/setup.
- `export_presets.cfg` and/or the Android export plugin/custom manifest:
  `USE_ANCHOR_API` and `USE_SCENE`; camera permission remains false.
- `src/physical_keyboard_overlay.gd`: rendering/lifecycle controller.
- `src/composition_layer_manager.gd`: composition-layer creation and teardown.
- `main.gd`: ownership and lifecycle wiring only.
- `src/state_manager.gd` and settings/UI files: Phase 5 only, after the spike.
- `src/virtual_keyboard.gd`: Phase 4 styling/template extraction only; no
  physical-tracking logic.

## Explicit Non-Goals

- Raw passthrough-camera access or custom keyboard recognition.
- Any visible passthrough region in the spike or MVP.
- Physical mouse detection or mouse overlay.
- Hand/fingertip models, hand occlusion, or passthrough hands.
- Detecting pressed physical keys.
- Forwarding physical-keyboard input to the host.
- Automatic make/model/locale detection.
- Multiple simultaneously tracked keyboards.
- Quest 2 support.
- A projection-mesh fallback for the overlay.

## References

- [Meta: Using the Dynamic Object Tracker](https://developers.meta.com/horizon/documentation/native/android/mobile-dynamic-object-tracker/)
- [Meta OpenXR SDK and XrDynamicObjects sample](https://github.com/meta-quest/Meta-OpenXR-SDK/tree/main/Samples/XrSamples/XrDynamicObjects)
- [Godot: OpenXRExtensionWrapper](https://docs.godotengine.org/en/4.7/classes/class_openxrextensionwrapper.html)
- [Meta: Passthrough best practices](https://developers.meta.com/horizon/documentation/native/android/mobile-passthrough-bp/)
- [Meta: Passthrough Camera API overview](https://developers.meta.com/horizon/documentation/spatial-sdk/spatial-sdk-pca-overview/)
