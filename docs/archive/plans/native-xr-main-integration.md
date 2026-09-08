# Native XR performance integration plan

Date: 2026-09-04

## Goal

Produce a focused Nightfall performance release based on `main`. Port the
proven rendering and depth-pipeline improvements from the experimental
`3d-environments` branch, add the completed ZipDepth model, and exclude its 3D
rooms, temporary diagnostics, feature-suppression switches, and unrelated
quality-of-life work.

The separate `ai_3d_tab` product branch will be merged only after this focused
performance release is stable. Keeping these stages separate reduces the
amount of new behavior that must be tested in the first release.

## Repository topology

There are two sibling development lines:

- `ai_3d_tab` contains the approved product work: AI 3D controls, HDR and
  Picture controls, double-click behavior, ambient lighting, extended refresh
  rates, and compositor filtering improvements.
- `3d-environments` contains the native renderer, direct depth capture,
  performance instrumentation, runtime LiteRT priority selection, and
  ZipDepth work.

Neither branch contains the other. Current local `main` is at `1e46fcc`.
`3d-environments` starts at that revision, while `ai_3d_tab` diverged from the
earlier `2ccb902` revision.

The intended order is deliberate:

1. Create a performance integration branch from local `main`.
2. Selectively port performance and ZipDepth work from `3d-environments`.
3. Build, test, and release that focused change set.
4. Merge or replay `ai_3d_tab` onto the proven performance foundation later.

The performance branch must not pull in `ai_3d_tab` during the first release,
but its architecture and commits should make that later merge understandable.

Suggested branch name:

```text
perf/native-xr-integration
```

Do not merge or cherry-pick the complete `3d-environments` branch. Several of
its commits intentionally mix useful performance work with experiments that
must not ship.

## Change inventory

### Defer to the later product-feature merge

Do not cherry-pick these `ai_3d_tab` commits into the focused performance
release:

1. `0d60592` — AI 3D controls and backend behavior.
2. `fa51a63` — HDR rendering and Picture controls.
3. `6836b90` — controller chord for double-click.
4. `b4dcbdc` — ambient screen lighting.
5. `8be368a` — Quest 3 extended refresh rates.
6. `8e30852` — compositor filtering and ambient-light improvements.

These remain approved work, but they require their own broader feature and UI
test pass after the performance release.

### Port from the experimental branch

- Correct network, decoder, frame-rate, loss, host-latency, warp, and depth
  statistics.
- Optional on-screen performance overlay, disabled by default.
- Direct decoder-to-depth input.
- Asynchronous GLES depth capture using reusable PBOs and non-blocking fences.
- JNI, GL uniform, and per-frame allocation caching.
- Rendering-on-demand for hidden panel viewports.
- Native Android/GLES single-pass OpenXR video renderer.
- Refresh-rate, renderer restart, OES startup, cursor-aspect, depth-size, and
  orientation fixes.
- Menu maximum-follow-distance fix.
- Runtime `Stream`/`Default` LiteRT GPU priority selection.
- ZipDepth-384 runtime support, conversion tools, validation tools, and
  documentation.
- `--stock-litert` and `--nf-legacy-video` as diagnostic/A/B fallbacks.

### Port only after reworking

- Performance overlay integration: keep it optional and ensure the native and
  legacy paths report equivalent values.
- Native-renderer eligibility: expand the checks so unsupported features fall
  back instead of being silently ignored.
- Performance logging: retain useful bounded/append-only logging, but remove
  high-frequency experimental output.
- Depth diagnostics: retain useful debug views where desired, but remove the
  temporary inference-freeze control and diagnostic data dumps.

### Do not port

- `src/environment_manager.gd`.
- Minimal Room and PSX Cinema UI/state logic.
- PSX Cinema model, texture, and attribution assets.
- The room-specific global foveation configuration change.
- `PERF_FAST_PARITY`.
- Any change that disables the background, laser, grab bar, corners, controller
  markers, or hand indicators merely to match the minimal prototype.
- The `Live 20Hz`/`Frozen` depth-inference diagnostic control.
- Stock LiteRT as the production default.
- One-shot tensor captures, temporary file dumps, and noisy profiling logs.

## Implementation sequence

### Phase 1: Preserve and establish baselines

1. Record the current hashes of `main`, `ai_3d_tab`, and `3d-environments`.
2. Preserve `3d-environments` as the working reference; optionally add an
   archive tag before later cleanup.
3. Create `perf/native-xr-integration` from local `main`.
4. Commit this integration plan without importing either development branch.
5. Build or identify a release APK from unmodified `main` and record its
   behavior and performance before adding optimizations.

This establishes current `main` as the behavioral reference for the focused
performance release. `ai_3d_tab` remains untouched for the later product merge.

### Phase 2: Add trustworthy measurements

Port the measurement plumbing before changing the renderer:

- incoming and rendered frame rates;
- decoder name and queue/decode duration;
- network RTT and variance;
- network loss and decoder drops;
- host processing latency;
- application frame rate;
- depth inference duration, frequency, age, and skipped work;
- native warp GPU duration when the native renderer is active.

Use frame-specific decoder enqueue timestamps rather than a global most-recent
submit timestamp. Keep the overlay disabled by default and avoid consuming a
new-frame flag merely to calculate statistics.

Commit this independently so it can be used to evaluate every later phase.

### Phase 3: Apply low-risk lifecycle optimizations

Port independently:

- disabling hidden panel viewports and re-enabling them when shown;
- cached JNI method handles and reusable arrays;
- cached GL uniform locations;
- bounded, append-only periodic logging;
- removal of periodic controller-state log spam;
- the menu reach/follow-distance correction.

Do not bring across `PERF_FAST_PARITY`. Existing projectionless visuals must
remain enabled. On-demand viewport gating should depend on whether a feature
is visible or needed, not on a compile-time parity switch.

### Phase 4: Port asynchronous depth capture

Port the direct decoder and native GLES depth-input path:

1. Obtain the model-sized input directly from decoder output.
2. Avoid the redundant full-resolution mono viewport.
3. Stage readback through a reusable PBO ring.
4. Poll fences without blocking the XR render loop.
5. Preserve the existing Godot viewport/readback path as a fallback outside
   supported Android/GLES configurations.
6. Support the real model input size rather than assuming 256 pixels.

Validate MiDaS-192, MiDaS-256, and later ZipDepth-384 independently before
continuing.

### Phase 5: Introduce the native renderer behind a gate

Port `extensions/nightfall-xr` and `src/native_xr_renderer.gd` as a coherent
unit. Initially require an explicit development setting or command-line flag
to activate it. Keep `--nf-legacy-video` permanently as a recovery and A/B
switch.

The renderer must:

- remain an `OpenXRExtensionWrapperExtension` composition-layer provider;
- leave Godot as the sole owner of `xrWaitFrame`, `xrBeginFrame`, and
  `xrEndFrame`;
- sample MediaCodec's external-OES texture directly;
- render both eyes into one double-wide swapchain;
- submit two eye-specific sub-images;
- explicitly synchronize texture access across the shared EGL contexts;
- cleanly stop before decoder, display-rate, or OpenXR lifecycle changes.

Initial eligibility should be deliberately conservative:

- Android;
- GLES Compatibility renderer;
- exactly one monitor;
- no unsupported filtering;
- a supported stereo/debug mode;
- successful native provider and swapchain creation.

Any unsupported combination must automatically retain or restore the legacy
renderer.

### Phase 6: Preserve current-main feature parity

Before making the native path the default, verify that it preserves every
feature already present on current `main`:

- blur and shader sharpening;
- cursor aspect, hover, and click alignment;
- bezel state;
- flat and curved screen geometry;
- side-by-side stereo modes;
- passthrough and backgrounds;
- menu, keyboard, controller, and hand composition layers;
- performance-overlay placement;
- Linux and multi-monitor fallback behavior.

Features that exist only on `ai_3d_tab` are not part of this release. The later
merge is already known to require native implementation or explicit fallbacks
for HDR, Picture grading, runtime compositor sharpening, adjustable AI
separation/convergence, AI cursor positioning, extended refresh rates, and
ambient lighting. Keep those boundaries localized so that later merge cannot
silently ignore a selected setting.

### Phase 7: Port stabilization fixes

Bring across and validate:

- applying the saved display refresh rate before streaming starts;
- avoiding a display-rate request when the requested rate is already active;
- deactivating native resources before a stream restart or refresh-rate
  change;
- waiting for the first valid OES texture without thrashing between renderers;
- keeping the appropriate cursor viewport active;
- using the pointer texture's natural aspect ratio;
- correcting depth debug-view orientation;
- deriving upsampling dimensions from the actual depth texture;
- pause/resume, disconnect/reconnect, and application shutdown behavior.

### Phase 8: Port runtime LiteRT priority

Port this separately from the renderer and from ZipDepth.

- `Stream` selects the low-priority Qualcomm OpenCL context and is the default.
- `Default` selects the driver's normal context priority.
- Changing the option recreates the delegate/interpreter on its inference
  thread without restarting the stream or application.
- `--stock-litert` remains available only for comparison and recovery.

Verify that changing priority cannot race an active delegate invocation and
do not change current `main`'s backend-failure policy as an accidental side
effect. The separately approved visible-failure/no-silent-fallback behavior
belongs to the later `ai_3d_tab` merge.

### Phase 9: Port ZipDepth

Port ZipDepth as a separate feature commit after the native/depth foundations
are stable:

- ZipDepth-384 model registration and UI entry;
- standard-backbone/decoder plus NPU upsampling-head hybrid export;
- explicit materialization of attention-map broadcasts for Adreno OpenCL;
- conversion and GPU-safe export tools;
- desktop/on-device comparison tooling;
- `../../guides/zipdepth-quest-gpu.md` and model documentation.

Remove temporary captures and diagnostic dumps. Verify the production
precision setting. Keep model failure behavior consistent with current `main`;
the explicit no-silent-fallback policy will arrive with `ai_3d_tab` later.

The model file is ignored by Git, so document its expected location,
acquisition/build procedure, and checksum. A release build should fail clearly
when it is absent.

## Engine and build reproducibility

The current native extension builds against `/tmp/nightfall-godot-sharpen`.
That tree contains local OpenXR interface changes which are not represented by
a newly checked-in patch. The current native renderer appears to use
`OpenXRAPIExtension` directly, so the experimental raw-handle getters may no
longer be necessary.

Before landing the integration:

1. Start from a clean Godot 4.7 checkout at the documented revision.
2. Apply only the engine patches stored in this repository.
3. Build the Android debug and release templates.
4. Generate a matching `godot-cpp` API and build `nightfall-xr`.
5. Build and launch the APK.
6. If any additional engine change is actually required, create a standalone
   repository patch and document its application order.

The integration is not reproducible if it only builds against the current
modified `/tmp` tree.

## Commit strategy

Use narrow commits that can be reverted or bisected independently. A suggested
series is:

1. Correct performance counters and optional overlay.
2. Hidden-viewport and logging lifecycle optimizations.
3. Direct decoder depth source.
4. Asynchronous GLES/PBO depth capture.
5. Native OpenXR renderer foundation and build integration.
6. Native renderer lifecycle and refresh-rate fixes.
7. Current-main feature-parity implementation and fallback gates.
8. Runtime LiteRT GPU priority.
9. ZipDepth-384 runtime support.
10. ZipDepth conversion tools and documentation, if kept separate from the
    runtime commit.
11. Removal of remaining experimental diagnostics.

Avoid preserving the experimental commit boundaries where a commit mixes room
work, diagnostics, and performance changes.

## Validation matrix

Run release builds for performance measurements. Use `--nf-legacy-video` as
the visual and behavioral reference for the native path.

Test at minimum:

- 2D, SBS, and AI-generated stereo;
- MiDaS-192, MiDaS-256, and ZipDepth-384;
- 72, 90, and 120 FPS/Hz;
- 1920x1080 and 2560x1440;
- flat and curved screens;
- bezel on and off;
- passthrough and every background mode;
- blur and sharpening modes;
- cursor types, hover behavior, and click alignment;
- menu, virtual keyboard, controllers, and hands;
- display-rate changes while connected and disconnected;
- disconnect/reconnect, app pause/resume, and headset sleep/wake;
- Linux and multi-monitor behavior through the legacy renderer.

For each performance run, keep the headset, HorizonOS version, host, codec,
bitrate, network, resolution, desktop content, and test duration fixed. Allow
thermal and clock state to settle before recording results.

## Acceptance criteria

The integration is ready to replace the experimental branch when:

- Quest 3/GLES sustains approximately 90 application FPS at 2560x1440,
  90 FPS/90 Hz, with AI 3D enabled;
- depth inference publishes at the requested 20 Hz;
- Stream-priority MiDaS inference remains approximately 30-35 ms;
- the native path does not silently ignore any selected setting;
- unsupported configurations automatically use the legacy path;
- cursor hover and click positions remain aligned;
- display-rate changes, reconnects, and pause/resume do not crash;
- the release build is reproducible from a clean checkout and documented
  dependencies;
- current `main` behavior and features remain present;
- no `ai_3d_tab` quality-of-life or UI commits are included in this release;
- none of the experimental rooms, parity feature suppression, or temporary
  diagnostics are included.

## Later `ai_3d_tab` integration

After the focused performance release is stable, merge or replay `ai_3d_tab`
onto this foundation as a separate integration effort. Resolve it feature by
feature rather than assuming the native renderer automatically supports the
new settings. In particular, test HDR, Picture controls, ambient lighting,
runtime compositor sharpening, adjustable AI separation/convergence, AI cursor
positioning, double-click behavior, and extended refresh-rate lifecycle after
that merge.
