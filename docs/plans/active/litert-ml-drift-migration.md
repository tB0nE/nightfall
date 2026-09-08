# LiteRT ML Drift / CompiledModel Migration

> Status: Active proposal

## Context

Nightfall's depth-estimation GPU path uses the classic TFLite `Interpreter`+`GpuDelegate` API (LiteRT 1.4.2), including a hand-patched, Bazel-built AAR (`android/patches/litert-qcom-low-priority-opencl.patch`) that adds an OpenCL low-priority context hint so depth inference doesn't steal GPU time from rendering. Two things prompted this investigation:

1. Depth Anything V2 (DINOv2 ViT-S backbone) was shelved on GPU earlier this session — the classic delegate can't claim GATHER/BATCH_MATMUL/GELU ops inside its transformer blocks, forcing 12 GPU↔CPU handoffs/inference and dropping it to ~2.8Hz vs MiDaS-GPU's ~15-20Hz. It currently only ships as a CPU/int8 model.
2. The user asked whether upgrading to LiteRT's newer **ML Drift** GPU engine (exposed via the **CompiledModel API**, `com.google.ai.edge.litert:litert:2.1.0+`) would unlock DA-V2 on GPU, and/or bring general perf gains to the existing GPU models (MiDaS-256/192-GPU).

Research this session (docs + a Plan agent that inspected the real `litert-2.1.0.aar` bytecode, this repo's actual build pipeline, and installed Python tooling) found real, favorable evidence for both:

- **DA-V2 plausibility**: a public LiteRT port of Metric3D v2 (same DINOv2 ViT-S backbone family) achieves 100% GPU node residency on `LITERT_CL` (OpenCL — our exact backend), where the classic delegate could claim 0%. Not proof for our export, but the specific op-support gap that killed our attempt is credibly resolved.
- **Our custom AAR may become unnecessary**: `libLiteRtOpenClAccelerator.so` in the stock 2.1.0 AAR contains the strings `cl_qcom_priority_hint`/`cl_qcom_perf_hint`, and `CompiledModel.GpuOptions` has a first-party `priority: Priority{DEFAULT,LOW,NORMAL,HIGH}` field — the same Qualcomm extension our hand-patched Bazel build exists to use. If confirmed on-device, this removes a real maintenance burden (no more custom Bazel/TF source build).
- `CompiledModel`'s public API is plain blocking Java-callable methods (no coroutines) — a Kotlin wrapper is a style choice, not a requirement. Kotlin toolchain is already present in the Godot Android template `build.sh` extracts (verified).
- **Important build-pipeline correction**: the committed `android/build.gradle` is NOT what governs real builds — `build.sh` deletes `android/build/` and re-extracts Godot's template fresh every export, `sed`-patching dependencies into that fresh copy (lines ~307-318). Any Gradle changes for this migration must go through that same sed-patching mechanism, not the committed file alone.
- `litert-torch` (the PyTorch→LiteRT conversion tool referenced for the Metric3D precedent) is real and already installed in this project's pyenv, but currently crashes on invocation here due to an unrelated `transformers` import-chain conflict — a Stage 4 concern, not a blocker now.

Two real unknowns remain that can only be resolved on real Quest 3 hardware: whether the stock `GpuOptions.priority=LOW` actually reproduces our patch's contention-avoidance behavior under real streaming load, and whether Adreno's ML Drift OpenCL accelerator actually claims DA-V2's transformer ops (the Metric3D precedent is Mali, not Adreno).

This work is independent of the separate, ongoing ZipDepth-384-GPU correctness-bug investigation (different root cause track, different agent) — not blocking or blocked by it, though a cheap opportunistic check is worth doing once the new engine is wired up (see Stage 5).

## Approach

Staged, gated by real on-device evidence at each step — cheapest/lowest-risk validation first, production integration only after the core engine is proven, existing models validated before the harder DA-V2 attempt, and the classic delegate path kept intact throughout as the fallback for anything not migrated (including ZipDepth, whose bug is out of scope here).

### Stage 0 — Close remaining unknowns cheaply (~1 day, desktop-only)

- **Desktop CompiledModel smoke test**: using the already-installed `ai_edge_litert==2.2.0`, load `models/midas-v21-small-256-gpu.tflite` via its `compiled_model.py`/`Accelerator.CPU` and diff output against `tools/model_tester/run_models.py`'s existing classic-`Interpreter` result on the same input. Confirms "no re-export needed" and the array-based I/O shape (`TensorBuffer.writeFloat`/`readFloat`, not raw `ByteBuffer.putFloat`) before any Android build cycle. Throwaway script in the scratchpad, not the repo.
- **Classpath conflict check**: hand-extract `android/build/` the way `build.sh` does, add `implementation "com.google.ai.edge.litert:litert:2.1.0"` alongside the existing 1.4.2 declarations + custom AAR `implementation files(...)` line, and see whether Gradle resolves cleanly. The 2.1.0 AAR still ships `org.tensorflow.lite.Interpreter` for back-compat but does NOT appear to ship `GpuDelegate`/`GpuDelegateFactory` — need to confirm the classic path (still needed for ZipDepth) and the new path can coexist on one classpath, or whether they need separate build variants. This decides Stage 2's build.sh plumbing shape.

### Stage 1 — Isolated spike: MiDaS-256-GPU under CompiledModel, real Quest 3 hardware (~1-2 days)

Add one small, clearly-marked temporary file, `android/src/main/java/com/godot/game/MlDriftSpike.kt`, with a single entry point called once from `GodotApp.onCreate()` behind a debug flag (removed once done) — mirroring this session's own `dumpZipDepthDiagnostic()` precedent rather than building new test infra.

- Load `midas-v21-small-256-gpu.tflite` via `CompiledModel.create(assets, path, Options(Accelerator.GPU).apply { gpuOptions = GpuOptions(backend=OPENCL, precision=FP16) }, environment)`.
- Reuse `DepthEstimator.java`'s existing dump-to-`getExternalFilesDir(null)`/`adb pull` mechanism so the SAME real captured frame runs through: this new path, the existing classic `GpuVariant` path, and `run_models.py`'s desktop CPU reference — three-way numeric diff (max-abs-diff on raw tensors), not just "looks non-degenerate."
- Time 50-100 invocations, log via the existing `Perf: model=...` telemetry format so numbers are directly comparable to the documented ~15-20Hz classic baseline.
- Test `GpuOptions.priority = LOW` vs `DEFAULT` while streaming is active, measure/eyeball render-frame impact — this is the only way to answer the priority-parity unknown.

**Exit criteria to proceed**: loads on real Adreno hardware, output matches references within tight numeric tolerance, latency ≥ classic delegate.

### Stage 2 — Production integration (~2-4 days, only after Stage 1 passes)

- Thin Kotlin wrapper (e.g. `MlDriftVariant.kt`) mirroring today's `GpuVariant` shape: `load()`/`run(FloatArray): FloatArray`/`close()`, holding a `CompiledModel` + reused `TensorBuffer` pair created once via `createInputBuffers()`/`createOutputBuffers()`.
- In `DepthEstimator.java`: parallel `mlDriftVariants` map alongside the existing `gpuVariants`, duplicating `ensureGpuVariantLoaded()`'s lazy-load/fallback semantics. `runInferenceGpu()`'s per-pixel `ByteBuffer.putFloat()` fill loop needs a real (mechanical) rewrite to build a `float[]` for `TensorBuffer.writeFloat()` — the buffer API genuinely differs.
- Default to **drop-in replacement of the classic path per model**, behind a single build-time/debug toggle — not a new user-facing backend option. Keeps `settings_controller.gd`'s `ai_3d_models` array and JNI-facing enums untouched.
- `GodotApp.java`/`depth_bridge.cpp`/`.h`: confirmed no changes needed (JNI resolution is reflection-based via `GetStaticMethodID`, all involved signatures — `configureDepth`, `submitDepthFrame`, `getLatestDepthMap`, `setDepthGpuPriority`, etc. — are model-agnostic ints/byte-arrays/strings). Re-verify signatures unchanged as a final check, not expected to be an issue.
- `build.sh`: add a new sed block (same anchor line and pattern as the existing `LITERT_GPU_AAR`/`--stock-litert` blocks at lines ~307-318) injecting the 2.1.0 dependency into the freshly-extracted `android/build/build.gradle` — shape depends on Stage 0's classpath-conflict answer. If the custom AAR proves unnecessary for migrated models (pending Stage 1's on-device priority-parity confirmation), retire its use for those models but keep `LITERT_GPU_AAR`/`--stock-litert` for whatever stays on the classic delegate (ZipDepth).
- Update the committed `android/build.gradle` too, now that its real (editor-only) role is understood, so it doesn't keep drifting from the real `build.sh` path.

### Stage 3 — Validate existing models end-to-end (~1-2 days)

Its own gate even though Stage 1 proved the core loop, because Stage 2 adds new production wiring (variant selection, priority hot-swap through `close()`/recreate) Stage 1 didn't exercise.

- Checksum (`sha256sum`) `models/midas-v21-small-{256,192}-gpu.tflite` unchanged before/after.
- Extend `run_models.py` with a CompiledModel inference path (from Stage 0a) so the dump/pull/diff comparison against classic-GPU and desktop-CPU references is scriptable, not a one-off.
- Real headset check via existing debug views (`src/settings_controller.gd`'s `ai_3d_debug_labels` → stereo_mode 7 DMap / 8 DMap-Raw / 9 DMap-Input, in `stereo_screen.gdshader`/`yuv_display.gdshader`) on both engines back-to-back.
- Perf via existing `Perf:`/`getDepthLastInferenceMs()`/`Hz` telemetry vs. documented classic baselines.
- Regression-test `setDepthGpuPriority()` hot-swap through the new engine's variant specifically — added just this session on the classic path, must not silently break.

### Stage 4 — DA-V2 GPU re-attempt (~3-5 days, only after Stage 3 passes; independently valuable even if this stalls)

1. Fix `litert-torch`'s local `transformers` import crash (likely a pin conflict), then confirm whether it offers anything `tools/convert_depth_anything_v2.py`'s existing onnx2tf pipeline doesn't for ViT ops under the new engine. Prefer reusing the existing, already-integrated onnx2tf pipeline if a GELU substitution alone suffices.
2. Apply GELU→tanh-approximation to DA-V2's ViT FFN blocks before conversion (the one Metric3D-precedent gotcha directly applicable — same op class). Do NOT pre-apply the convex-upsampling/Mali-specific fix speculatively; only chase it if on-device testing shows the same "far-depth collapse" signature via DMap-Raw.
3. Convert at existing sizes first (196/252) — one variable at a time (new engine, known model), not new engine + new size + new tool simultaneously.
4. Run the identical Stage 3 verification loop.
5. Judge success against the actual failure mode that killed the last attempt: **latency competitive with MiDaS-GPU**, not just correctness (the classic delegate already produced correct output at 2.8Hz).

### Stage 5 — Classic delegate path fate

Keep `GpuVariant`/classic delegate as-is for any non-migrated model (currently ZipDepth-384-GPU, unrelated bug, out of scope here). Once Stage 2's wiring exists, trying ZipDepth through the new engine is close to free and worth an opportunistic, non-blocking check. Don't delete `LITERT_GPU_AAR`/`--stock-litert` — keep for the shrinking fallback set.

## Critical files

- `android/src/main/java/com/godot/game/DepthEstimator.java` — new `mlDriftVariants` map/lazy-load, `runInferenceGpu()` buffer-fill rewrite
- `android/src/main/java/com/godot/game/GodotApp.java` — Stage 1 spike entry point only; no signature changes expected
- `build.sh` — new sed block for the 2.1.0 dependency, alongside existing `LITERT_GPU_AAR`/`--stock-litert` (lines ~40, ~307-318)
- `android/patches/litert-qcom-low-priority-opencl.patch` — reference only; likely retired for migrated models pending Stage 1's priority-parity confirmation
- `tools/model_tester/run_models.py` — add CompiledModel inference path for scriptable comparison
- `tools/convert_depth_anything_v2.py` — GELU→tanh substitution point for Stage 4
- `src/settings_controller.gd` — `ai_3d_models`/`ai_3d_debug_labels`, untouched unless Stage 2 decides on a user-facing toggle
- `BUILD.md` — document the new dependency/build step once Stage 2 lands
- New: `android/src/main/java/com/godot/game/MlDriftSpike.kt` (Stage 1, temporary) → `MlDriftVariant.kt` (Stage 2, permanent)

## Verification

- Stage 0: desktop script output + Gradle sync log (no device needed).
- Stage 1/3: three-way numeric diff (max-abs-diff) between CompiledModel output, classic-GPU output, and desktop-CPU reference on the identical captured frame, via the existing dump/`adb pull` mechanism; `Perf:` telemetry Hz/ms vs. documented baselines; real headset DMap/DMap-Raw/DMap-Input visual check.
- Stage 4: same loop, success bar is latency parity with MiDaS-GPU, not just correctness.
- Throughout: `sha256sum` on any `.tflite` file that should be unmodified, to catch accidental re-exports.
