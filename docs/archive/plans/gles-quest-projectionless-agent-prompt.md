# Handoff prompt

Implement the plan in `gles-quest-projectionless.md`.

Start by reading the plan, checking the worktree and branches, and inspecting `android-gles-depth-inference`. Make GLES the Quest Android default, retain Vulkan for Linux/experimental use, polish projectionless composition mode, preserve quality tiers during measurement, and port only renderer-independent GPU-depth improvements.

Prioritize:

1. GLES projectionless functional polish.
2. Clean separate 3D AI/backend/quality controls.
3. Validated GPU model expansion with reliable CPU fallback.
4. Lightweight projection-space controller indicators.
5. Optional runtime `XR_FB_render_model` experiment behind a flag.

Do not implement full 3D controller composition layers or virtual keyboard integration in the first pass.

Use release builds and validate 1440p/72 and 4K/72 after a 30-second warm-up. Confirm 72 FPS stability, approximately 20 Hz depth, CPU fallback behavior, projectionless UI/reconnect/passthrough, and Linux Vulkan compatibility. Commit changes in focused checkpoints and report measured results.
