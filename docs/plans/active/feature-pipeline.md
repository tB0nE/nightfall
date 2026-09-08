# Feature Pipeline

> Status: Active backlog

Items on hold pending user testing and prioritization.

## 1. Zero-copy VAAPI Texture Import
- **Impact**: Eliminates ~1GB/s GPU→CPU→GPU copy at 4K60 on Linux
- **Approach**: Vulkan/VAAPI interop in `texture_uploader.cpp`; `rd->texture_create_from_extension()` to import VAAPI decoded surface directly
- **Blocker**: Needs Vulkan/VAAPI interop C++ work; complex; Linux-only

## 2. Frame Pacing
- **Impact**: Reduce unnecessary re-renders when no new frame is available
- **Approach**: `consume_new_frame()` native method exists but unused; needs strategy that doesn't change comp viewport update mode (UPDATE_ONCE/UPDATE_DISABLED caused black screen and swapchain errors)
- **Blocker**: Comp viewports MUST stay UPDATE_ALWAYS; need fundamentally different approach

## 3. Sunshine Raw Frame Passthrough
- **Impact**: For localhost/same-machine streaming; NV12 frames sent raw without HEVC encode/decode; eliminates generation loss
- **Approach**: Custom Moonlight codec ID 0x80; Sunshine patch to send raw NV12; Nightfall receives and displays directly
- **Blocker**: Requires patching Sunshine; see
  [`sunshine-raw-frame-passthrough.md`](sunshine-raw-frame-passthrough.md).

## 4. Per-eye Pointer
- **Impact**: Pointer rendered at correct depth per eye in stereo modes
- **Blocker**: ShaderMaterial cannot do `no_depth_test`; screen shader compositing produced grey screen; needs different rendering approach

## 5. Linux AI-3D (C++ TFLite)
- **Impact**: Bring AI-3D depth estimation to Linux PCVR
- **Approach**: Replace Python TFLite stub with C++ TFLite inference in native plugin
- **Blocker**: Significant C++ work; MiDaS model integration; Linux-only

## Items Needing In-Headset Testing
- **MSAA disabled**: Confirm visual quality acceptable without MSAA (comp layer bypasses main viewport)
- **Smooth/sharpen at 4K**: Test with filters on/off; smooth costs ~15-25ms at 4K stereo
- **Quest 2 H.264 BT.601 fix**: Confirm green/purple hue shift resolved
