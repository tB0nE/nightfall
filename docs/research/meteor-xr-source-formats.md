# SDR projection source formats

This follows source-region/texture-array work in
[the layout report](meteor-xr-eye-subrects.md). It extends the Linux/NVIDIA
diagnostic encoder, not the normal Meteor product connection flow.

## Supported sources

- R8G8B8A8_UNORM: original direct-copy path and legacy display-coded byte policy.
- B8G8R8A8_UNORM: nearest GPU blit changes channel order into RGBA UNORM.
- R8G8B8A8_SRGB: direct copy into an RGBA sRGB packing surface.
- B8G8R8A8_SRGB: nearest GPU blit into RGBA sRGB, preserving the transfer function.

Source rectangles and array slices are retained in each operation. Both eyes
must use the same transfer-function class; RGBA/BGRA order can differ. Source
formats and packed output dimensions remain fixed for the encoder session.
Unsupported formats (including float/HDR), mixed UNORM/sRGB eyes and multisampled
images are rejected. BGRA conversion requires checked source/destination blit
features and a graphics-capable queue. External-image export must also succeed;
there is no software/CPU fallback.

The important distinction: a Vulkan blit from sRGB to UNORM would linearize the
stored RGB values. The sRGB packing surface avoids that unwanted change before
video encoding: sRGB-to-sRGB conversion retains encoded brightness, while the
direct-copy path preserves bytes. See the primary
[Vulkan blit rules](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdBlitImage.html)
and [copy command definition](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdCopyImage.html).
NVENC consumes the packed surface's byte values via the existing CUDA array.
The H.264 transfer tag is sRGB for sRGB sources; UNORM retains BT.709. Primaries,
matrix and range follow the existing SDR profile. An arbitrary application's
*linear-light* UNORM output is not automatically gamma-corrected by this policy.
HDR, alpha blending, tone mapping and full end-to-end color management are not
claimed. The source is still one opaque stereo projection.

## Reproduce the reference-format test

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_XR_SOURCE_FORMAT=bgra8-srgb NIGHTFALL_XR_ARRAY_STEREO=1 \
  NIGHTFALL_XR_PADDED_SUBRECT=1 NIGHTFALL_XR_PROBE_FRAMES=32 \
  NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 \
  bash tools/build_support/probe_xr_transport.sh
```

Select `rgba8`, `bgra8`, `rgba8-srgb` or `bgra8-srgb`. This environment setting
selects the reference fixture; the encoder uses the actual submitted formats.
It deliberately rejects alternate-format GPU scene/hello_xr fixture modes.
Application source-format logs and encoder packed-format logs must agree.
Asymmetric per-eye markers and changing green levels check channel order,
brightness, orientation, slice selection and border exclusion after video
decode. FFprobe separately verifies H.264 transfer metadata. Native format
policy tests run in every Monado/NVENC probe. The app reads back its reference
images for correctness; the encoder still has no full-resolution CPU readback.

The four-format matrix is a host correctness test, not a performance or arbitrary
engine compatibility result. Record per-run counts in the session checkpoint.
Headset interpretation of the new sRGB tag remains a hardware validation gate.
No new APK is required: decoder framing and packed dimensions are unchanged.

Next: an engine-native OpenXR fixture, including negotiated eye size/format,
then an independent application using process-local runtime selection.
