# Repository cleanup and refactoring plan

> Status: Active
>
> Original baseline: `main` after the v0.7.8 native-XR integration (`10a7426`)
>
> Current continuation: `refactor/linux-restoration-and-cleanup`, branched from
> v0.7.10 `main` (`718122a`).
>
> Current checkpoint: Linux build restoration, Vulkan depth inference,
> EdgePad Android quality tiers, profiling tools, and their documentation are
> implemented and runtime-tested on this branch. Linux local capture remains
> available as an explicit experiment, but normal Sunshine encode/decode is
> the production default until the local path has a zero-copy presentation
> implementation.

## Objective

Make the repository easier to navigate, build, test, and change without
altering the release renderer's behavior or performance. Structural moves and
behavioral refactors should be separate commits or pull requests.

## Guardrails

- Preserve the v0.7.8 release-build performance baseline.
- Keep Android and Linux behavior explicit; do not silently remove Linux paths.
- Do not combine large path moves with renderer or stream-lifecycle changes.
- Verify connection failure, reconnect, cursor alignment, resolution/refresh
  changes, curvature, passthrough, ambient lighting, and AI 3D on a headset
  after each behavioral phase.

## Phases

### 1. Repository hygiene

> Status: Implemented and merged in PR #26. Continue to keep the active-plan
> index accurate as later phases land.

- Consolidate project documentation under `docs/`.
- Separate active plans from historical investigations and completed plans.
- Remove proven-unused backup files and deprecated shaders.
- Repair documentation and source references after moves.

### 2. Reproducible builds and basic CI

> Status: Implemented and merged in PR #27.

- Keep `build.sh` as a compatibility entry point while extracting focused
  Android, Linux, native-XR, model-packaging, and deployment scripts.
- Pin the custom Godot checkout and generated bindings; rebuild them outside
  ephemeral `/tmp` storage.
- Record and verify the patched LiteRT AAR's provenance and checksum.
- Add automated GDScript parsing, native unit tests, generated-file checks, and
  documentation-link checks.

### 3. Settings and menu ownership

> Status: Implemented and merged in PR #28. Typed app/host stores,
> platform policy, persistence codecs, declarative menu construction, and direct
> typed-store consumption are complete.

- Introduce one typed settings store with defaults and versioned migrations.
- Separate settings data, platform policy, persistence, UI presentation, and
  runtime side effects.
- Describe menu tabs/options declaratively instead of keeping a field and
  callback chain for every button.
- Keep Android-only policy such as ZipDepth/native-sharpen locks in one place.

### 4. Application lifecycle

> Status: Partially implemented and merged in PR #29. Connection intent, media
> activity, timeout state, performance sampling, and the active-screen registry
> now have explicit owners. Further dependency narrowing remains.

- Model boot, server selection, connecting, streaming, reconnecting, failed,
  and disconnecting as explicit states.
- Extract session, screen registry, XR scene, input routing, and telemetry
  ownership from `main.gd`.
- Replace modules' unrestricted `main` reference with narrow dependencies,
  commands, and typed signals.

### 5. Rendering boundary

> Status: Partially implemented and merged in PRs #30 and #32. Video-path
> selection is explicit behind `VideoPresentation`; panel, environment, pointer,
> controller-indicator, and screen-control overlays have resource owners. PR #33
> consolidated layers to stay within the Quest layer limit. Remaining work is
> narrowing consumers and verifying renderer ownership boundaries.

- Define one renderer-facing contract for mesh, legacy composition-layer, and
  native OpenXR implementations.
- Split composition-layer ownership into video, cursor/input overlays,
  UI/keyboard overlays, and backgrounds.
- Keep swapchain/resource lifetime inside the renderer that owns it.

### 6. Native subsystem splits

> Status: Not started as a focused refactor. Keep each split behavior-preserving
> and validate Android and Linux paths separately.

- Split Android depth model loading, scheduling, preprocessing,
  post-processing, and telemetry.
- Split stream session/callbacks, decoder selection, queues, and rendering
  handoff in the native stream extension.
- Split texture upload by CPU, GLES/OES, and Android-image paths.
- Split native-XR session, swapchain, frame submission, pipeline, and
  Android-platform responsibilities.

### 7. Restore and validate Linux releases

> Status: Build, packaging, CPU/Vulkan model smoke tests, AppImage export, and
> WiVRN PCVR runtime validation are complete on
> `refactor/linux-restoration-and-cleanup`. Linux depth timing is exposed in
> the status bar, and the experimental same-machine capture path is opt-in via
> `NIGHTFALL_ENABLE_LOCAL_CAPTURE=1` after its CPU conversion/upload cost was
> found to limit a 2560x1440/120fps test near 80fps.

- Rebuild the Linux streaming extension in the Ubuntu 22.04 container and
  export a Linux binary/AppImage from the current source.
- Verify all bundled Linux CPU/Vulkan depth variants and the OpenXR vendor plugin are
  present; fail packaging clearly when an input is missing.
- Run the Linux build and unit tests, then launch the packaged client with a
  PCVR runtime. Exercise connection, controls, SBS, AI 3D, and stream restarts.
- Publish a Linux artifact only after on-device/runtime validation; build
  success alone is not a release sign-off.

## Completion criteria

- The repository root contains only essential project entry points.
- Documentation has one index and an explicit lifecycle.
- A fresh checkout can reproduce a release build from pinned inputs.
- Settings have one source of truth and one migration path.
- UI code does not mutate stream or renderer internals directly.
- `main.gd` coordinates modules instead of acting as their shared state store.
- Automated tests cover settings, layouts, and stream lifecycle transitions.
- Release APK size and runtime performance do not regress from v0.7.8.
