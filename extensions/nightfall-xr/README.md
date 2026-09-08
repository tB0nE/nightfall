# Nightfall native XR renderer

This Android-only GDExtension submits Nightfall's video as two OpenXR quad (or
cylinder) composition layers backed by one double-wide swapchain. Each eye is
drawn directly from MediaCodec's external OES texture. AI depth is upsampled
and warped in the same native GLES pass, avoiding the two full-resolution Godot
SubViewports used by the compatibility path. The native shader variants also
apply AI separation/convergence, HDR tonemapping, and Picture-tab grading. A
32x32 asynchronous readback of the finished left-eye image supplies reactive
ambient lighting without re-enabling either legacy video viewport. Runtime
and Runtime Quality sharpening are attached to the native quad/cylinder layer
through `XR_FB_composition_layer_settings`, avoiding shader neighbourhood
samples and preserving the fast path.

The extension is an `OpenXRExtensionWrapperExtension` registered as a
composition-layer provider. It deliberately does not call `xrWaitFrame`,
`xrBeginFrame`, or `xrEndFrame`; Godot remains the sole owner of the OpenXR
frame loop.

## Build requirements

- The pinned patched Godot source tree.
- A pinned `godot-cpp` tree generated from that engine's extension API.
- Android NDK 29.0.14206865.

Create all of these persistent inputs from the project root with:

```bash
tools/build_support/bootstrap_native_xr.sh
```

The generated sources, bindings, and Android runtimes live under the ignored
`.build-cache/native-xr/` directory. Upstream commits and the NDK version are
recorded in `tools/build_support/native_xr_versions.sh`; no native-XR build
input defaults to `/tmp`. Set `ANDROID_HOME` when the Android SDK is installed
outside the default path.

Build an individual extension variant with:

```bash
extensions/nightfall-xr/build_android.sh debug
extensions/nightfall-xr/build_android.sh release
```

The build writes the shared library to `bin/android/`. Shared libraries and
build directories are intentionally ignored by Git. The small
`bin/nightfall-xr.gdextension` descriptor is source-controlled (force-added,
like the existing nightfall-stream descriptor) so a fresh checkout knows which
library to package.

`build.sh --debug` and `build.sh --release` build the matching extension
variant automatically before exporting the APK. Packaging fails if the
matching patched Godot runtime is unavailable, preventing accidental stock
engine builds. The app retains the original Godot renderer as a runtime
fallback for Linux, multiple monitors, diagnostic depth modes, optional
picture filters, and `--nf-legacy-video`.
