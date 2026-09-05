# Nightfall native XR renderer

This Android-only GDExtension submits Nightfall's video as two OpenXR quad (or
cylinder) composition layers backed by one double-wide swapchain. Each eye is
drawn directly from MediaCodec's external OES texture. AI depth is upsampled
and warped in the same native GLES pass, avoiding the two full-resolution Godot
SubViewports used by the compatibility path. The native shader variants also
apply AI separation/convergence, HDR tonemapping, and Picture-tab grading. A
32x32 asynchronous readback of the finished left-eye image supplies reactive
ambient lighting without re-enabling either legacy video viewport.

The extension is an `OpenXRExtensionWrapperExtension` registered as a
composition-layer provider. It deliberately does not call `xrWaitFrame`,
`xrBeginFrame`, or `xrEndFrame`; Godot remains the sole owner of the OpenXR
frame loop.

## Build requirements

- The patched Godot source tree, defaulting to
  `/tmp/nightfall-godot-sharpen`.
- A matching `godot-cpp` tree generated from that engine's extension API,
  defaulting to `/tmp/godot-cpp-custom`.
- Android NDK 29, defaulting to the SDK path used by `build.sh`.

Build the release library with:

```bash
extensions/nightfall-xr/build_android.sh release
```

The build writes the shared library to `bin/android/`. Shared libraries and
build directories are intentionally ignored by Git. The small
`bin/nightfall-xr.gdextension` descriptor is source-controlled (force-added,
like the existing nightfall-stream descriptor) so a fresh checkout knows which
library to package.

`build.sh --release` builds this extension automatically before exporting the
APK. The app retains the original Godot renderer as a runtime fallback for
Linux, multiple monitors, diagnostic depth modes, optional picture filters,
and `--nf-legacy-video`.
