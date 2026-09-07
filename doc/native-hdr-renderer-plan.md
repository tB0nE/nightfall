# Native HDR Renderer Integration Plan

## Goal

Render HDR10/PQ and HLG streams through Nightfall's optimized Android/GLES
OpenXR composition-layer renderer. HDR must not force the legacy Godot
SubViewport renderer, add another full-resolution pass, or change the compiled
SDR warp shader.

## Current architecture

- `TextureUploader` owns the decoder's external-OES texture and atomically
  tracks `color_transfer_type`: `0` SDR, `1` PQ/ST 2084, `2` HLG.
- The legacy renderer selects `yuv_display_hdr.gdshader` and supplies a 256x3
  floating-point transfer LUT.
- `NightfallXrRenderer` samples the external-OES texture directly into a
  double-wide OpenXR swapchain. Its native fragment shader currently assumes
  SDR, so `NativeXrRendererManager` rejects HDR and restores the legacy path.

## Design

### Preserve the SDR hot path

Keep `FRAGMENT_SRC` and its program separate from all HDR code. Compile a
second `HDR_FRAGMENT_SRC` program containing the same stereo/depth warp plus:

1. PQ or HLG inverse transfer through a LUT.
2. BT.2020-to-BT.709 conversion in linear light.
3. Luminance-preserving Reinhard tone mapping.
4. Linear-to-sRGB encoding through the LUT.

Only the HDR program receives a runtime transfer uniform to distinguish PQ
from HLG. SDR frames continue using the original program and therefore carry
no HDR instruction/register footprint.

### Transfer state

Expose `TextureUploader::get_color_transfer_type()` to GDScript, forward it
through `StreamBackend`, and include it in the existing `submit_frame()` call.
The renderer caches the value with the rest of the pending frame state and
selects the program immediately before drawing.

This uses the uploader's atomic value as the source of truth and handles a
mid-session transfer change without rebuilding the swapchain.

### LUT ownership

Generate a 256x3 `GL_R32F` texture in `NightfallXrRenderer::init_gl()` using
the same equations and 203-nit normalization as the legacy implementation:

- row 0: PQ/ST 2084 decode;
- row 1: HLG decode plus nominal 1.2 system gamma;
- row 2: linear-to-sRGB encode.

The native renderer owns and deletes this texture in its EGL context. It does
not borrow Godot's `ImageTexture`, avoiding cross-context ownership and resource
lifetime coupling. If float linear filtering is unavailable, shader sampling
will explicitly interpolate adjacent `texelFetch` values so correctness does
not depend on a driver extension.

## Implementation sequence

1. Add and bind the uploader transfer getter.
2. Add the `StreamBackend` forwarding method.
3. Extend `NightfallXrRenderer::submit_frame()` and its desktop stub/binding.
4. Add HDR program members, uniform locations, LUT creation, and cleanup.
5. Select SDR/HDR programs per submitted frame and bind the LUT only for HDR.
6. Remove the HDR guard in `NativeXrRendererManager::_eligible()`.
7. Log transfer-program transitions without logging every frame.

## Correctness and performance checks

- Build both Android and desktop/editor GDExtension targets.
- Confirm SDR still selects the original program and native renderer.
- Confirm PQ/HLG selects the HDR program without a legacy fallback or
  swapchain restart.
- Confirm returning to SDR switches back on the next decoded frame.
- Compare native and legacy HDR output using the same real HDR10 source.
- Measure application FPS, warp GPU time, inference rate, and decoder drops for
  SDR and HDR, including HDR plus AI-3D.

## Failure policy

Failure to compile the HDR program or create its LUT should fail native renderer
startup and retain the known-correct legacy path. Unknown transfer values are
treated as SDR and logged once; the streaming layer currently emits only
`0`, `1`, and `2`.

## Deferred improvements

First match the existing legacy tone mapper exactly. Metadata-aware tone
mapping, selectable peak/reference-white behavior, and decoder-provided HDR-to-
SDR conversion can be evaluated later without blocking native-path parity.
