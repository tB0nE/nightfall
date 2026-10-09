# Nightfall Meteor: AMD and Intel GPUs

> Status: Active proposal (2026-10-09). Not started.
>
> Related: [meteor-host-depth.md](meteor-host-depth.md) (the depth
> pipeline), [meteor-windows.md](meteor-windows.md) (the Windows port),
> [meteor-appimage.md](meteor-appimage.md) (the Linux release).

## Goal

Host depth on any PC with a reasonably recent GPU, not only NVIDIA:

- **AMD** (Radeon desktop and laptop GPUs, Ryzen APUs) and **Intel** (Arc,
  and Iris Xe and newer integrated graphics) run EdgePad on the PC's GPU.
- NVIDIA keeps today's path unchanged: NVDEC and CUDA, plus VDA on TensorRT.
- On Linux and on Windows.
- **VDA stays NVIDIA-only in the first version.** AMD and Intel users get
  EdgePad, which is the default model anyway.

Without an NVIDIA GPU today, Meteor starts as a plain proxy with host depth
off, so the Quest uses on-device depth. That keeps working as the fallback.

## What's NVIDIA-specific today

| Stage | Today | Vendor-neutral? |
| --- | --- | --- |
| Decoding (`nvdec.rs`) | NVDEC through `libcuda`/`libnvcuvid` (`nvcuda.dll`/`nvcuvid.dll`), loaded at run time; it reduces each frame to the model's size while decoding | No |
| Frame preparation (`kernels/nv12_to_tensor.cu`) | CUDA: NV12 (or P016 for 10-bit) to the model's planar RGB tensor, a 4x4 box filter over each output pixel's footprint | No, but `nvdec::nv12_box_to_rgb()` is a CPU version of the same arithmetic |
| EdgePad (`ncnn.rs`) | ncnn on Vulkan; the CUDA tensor is copied back to the CPU first (1.8 MB at 512x288), because Vulkan can't read CUDA memory | **Yes** |
| Post-processing (`gpu_post.rs`, `postprocess.rs`) | CUDA kernels, with a CPU `PostProcessor` that falls back automatically | **Yes** (CPU) |
| VDA (`vda.rs`, `tensorrt.rs`) | TensorRT and CUDA kernels (`kernels/vda.cu`) | No |

The depth loop in `depth.rs` already takes CPU frames: `Pixels::Rgb` (packed
RGB at the model's size) goes straight to `NcnnModel::infer()`. So the core
of AMD/Intel support is **a second decoder that produces `Pixels::Rgb`**. The
model and post-processing stages need no change.

## Design

### A generic decoder: FFmpeg with hardware decoding

A new `generic_decoder.rs` next to `nvdec.rs`, with the same shape
(`new(codec, width, height)`, `decode(data, frame_number) ->
Option<Pixels>`, `set_target(width, height)`), built on FFmpeg's libavcodec
with a hardware device:

- **Linux: VAAPI.** Mesa's `radeonsi` driver on AMD, Intel's `iHD` driver on
  Intel. VAAPI decodes H.264, HEVC (8- and 10-bit) and AV1 on recent GPUs.
- **Windows: D3D11VA.** It works on every Windows GPU (AMD, Intel and
  NVIDIA), through the vendor's own driver.

Why FFmpeg rather than calling VAAPI and D3D11 directly: libavcodec already
parses H.264/HEVC/AV1 and drives both APIs, and Meteor receives exactly the
elementary streams it understands (`video_tap.rs` reassembles them). Doing it
directly would mean two decode implementations, plus bitstream parsing, that
FFmpeg already has. The FFI is small: open a decoder with a hardware device
context, send packets, receive frames, transfer them.

Per frame:

1. The video tap hands over the reassembled access unit with its frame
   number, as it does for NVDEC.
2. libavcodec decodes on the GPU into a hardware surface.
3. **Reduce to the model's size.** Two options, measured in Phase 1:
   - **CPU first (simplest):** `av_hwframe_transfer_data()` copies the
     full-size NV12 frame to system memory (5.5 MB at 1440p, about 660 MB/s
     at 120 fps), and `nvdec::nv12_box_to_rgb()` reduces it with the same
     arithmetic as the CUDA kernel. The output then matches the NVIDIA path,
     which keeps host maps looking the same on every vendor.
   - **GPU scaling (if the copy or CPU time is too high):** scale on the GPU
     before the copy (VAAPI video processing through FFmpeg's `scale_vaapi`,
     or a D3D11 `ID3D11VideoProcessor`), then copy only the small frame
     (about 0.3 MB at 512x288). This needs care to match the box filter's
     output closely enough.
4. The RGB frame goes to the existing ncnn path (`Pixels::Rgb`).
5. CPU post-processing (`PostProcessor`), then the depth server, unchanged.

**10-bit and HDR streams:** NVDEC handles P016 today. The generic decoder
must handle P010 from 10-bit HEVC and AV1 too, taking the high byte as
`nvdec.rs` does, or reducing at 10 bits. Check against the NVIDIA path on an
HDR stream.

### Choosing the decoder

At stream start (`DepthFeed::push`), in order:

1. **NVDEC** if NVIDIA's driver libraries load and initialise. This is
   today's path, unchanged.
2. **Generic** (VAAPI or D3D11VA) if FFmpeg opens a hardware device for the
   codec.
3. **None:** host depth off for that stream, logged once, and the Quest
   falls back to on-device depth.

An override for development and support: `METEOR_DECODER=auto|nvdec|generic`
(default `auto`). Forcing `generic` on the RTX 3090 is how the new path gets
exercised every day without an AMD machine.

The tray and log say which decoder is in use, for example
"Host depth: EdgePad 512 (Vulkan), decoding with VAAPI".

### Which GPU ncnn uses

ncnn picks its default Vulkan device. On a laptop with integrated and
discrete GPUs that's usually the discrete one, which might not be the one
decoding. That's correct but costs a copy across GPUs. Log the ncnn device and
the decode device. Add a `vulkan_device` setting only if testing shows it's
needed.

### What AMD and Intel users get in the tray

- The Model menu lists EdgePad sizes (512, 672).
- VDA shows as "Needs an NVIDIA GPU" rather than as a download.
- Everything else (proxy, microphone, encryption, autostart) is unchanged:
  none of it depends on the GPU.

## Phases

### Phase 1: generic decoder, developed on the RTX 3090 (Linux)

- Install `nvidia-vaapi-driver` (the VAAPI-on-NVDEC shim Firefox uses) so
  VAAPI decodes on the 3090. Check first whether Bazzite already ships it
  (`vainfo`).
- FFmpeg FFI (`generic_decoder.rs`): device, decoder, packets, frames and
  transfer, for H.264, HEVC and AV1, 8- and 10-bit.
- Reduction on the CPU with `nv12_box_to_rgb()`, then `Pixels::Rgb`.
- `METEOR_DECODER` and the selection order above.
- Measure on the 3090 at 1440p and 120 fps: decode, transfer and reduce time
  per frame, CPU use, and frame to map against the NVDEC path (5.2–6 ms
  today).
- **Exit:**
  - `--replay` of the 1440p test clip with `METEOR_DECODER=generic` produces
    maps at 120 fps;
  - EdgePad parity against the NVDEC path on the same frames: the depth maps
    agree within the existing EdgePad parity bounds;
  - a real Quest stream runs on the generic path.

### Phase 2: Windows D3D11VA

- The same decoder with a D3D11VA device. Develop on the RTX 3090 under
  Windows: D3D11VA is vendor-neutral, so it runs there as-is.
- Ship FFmpeg's DLLs in the installer.
- **Exit:** the Phase 1 checks on Windows with `METEOR_DECODER=generic`.

### Phase 3: real AMD (and Intel) hardware

The shim and the NVIDIA driver hide vendor differences: supported surface
formats, scaler behaviour, 10-bit handling, timing. Test on real hardware
before calling it supported:

- **The AMD laptop** (model and OS to note here when tested). On Windows it
  checks D3D11VA; on Linux (or a Bazzite live USB) it checks Mesa's VAAPI and
  RADV for ncnn.
- **Checklist:**
  - Meteor picks the generic decoder by itself;
  - H.264 and HEVC, then 10-bit HEVC;
  - EdgePad at 512x288 delivers maps to the Quest;
  - frame-to-map time and CPU use at 60 and 120 fps;
  - the tray shows the decoder and the VDA entry correctly;
  - an hour-long session with no leaks or stalls.
- Intel if one is available; otherwise report it as expected to work,
  untested.
- **Exit:** the checklist passes on the AMD laptop. Record the numbers here.

### Phase 4: GPU scaling (only if Phase 1–3 numbers need it)

If the full-frame copy or the CPU reduction costs too much (for example on
an APU at 120 fps), move the reduction to the GPU (`scale_vaapi` / D3D11
video processor), and re-check EdgePad parity against the box filter.

### Later: VDA on AMD and Intel

Not planned yet. Options to research:

- **ONNX Runtime with DirectML** on Windows (all vendors). Meteor already
  has an ONNX Runtime path (the `onnxruntime` feature); this would ship the
  DirectML build. It needs the VDA graphs to run on DirectML, and their
  recurrent state handled there.
- **MIGraphX (ROCm)** on Linux for AMD: heavy to ship, limited to supported
  Radeon cards.
- **ncnn on Vulkan:** convert VDA itself. It's a ViT-S transformer with a
  recurrent temporal head, so it's harder to convert than EdgePad, but it
  would be vendor-neutral on both platforms.

## Packaging and licences

- **FFmpeg as an LGPL build** with only what's needed: libavcodec and
  libavutil (and libavfilter only if Phase 4 uses `scale_vaapi`); the
  H.264/HEVC/AV1 parsers; and the VAAPI (Linux) or D3D11VA (Windows) hardware
  decoders. No GPL parts, no software decoders.
  - **Linux AppImage:** bundle the shared libraries (about 5–10 MB). libva
    and the GPU's VAAPI driver come from the system: they belong to the
    graphics stack, like the Vulkan driver.
  - **Windows installer:** bundle the DLLs.
  - Add FFmpeg's licence and its build configuration to the notices, and
    publish the exact FFmpeg source version used, as LGPL asks for shipped
    binaries.
- **Size:** the AppImage grows by about 5–10 MB, still well under its
  100 MB limit.

## Risks

| Risk | Mitigation |
| --- | --- |
| Full-frame copy plus CPU reduction too slow on low-end APUs at 120 fps | Phase 4 GPU scaling; measured in Phase 1 before committing to it |
| VAAPI on NVIDIA (the shim) behaves differently from Mesa and Intel | Phase 3 on real hardware before calling it supported |
| A GPU with no hardware AV1 decode | Codec selection is per stream; such a stream gets no host depth, and the Quest falls back to on-device depth. Log it clearly |
| 10-bit and HDR colour differs from the NVDEC path | Parity check on an HDR stream in Phase 1 |
| Hybrid laptops decode on one GPU and run ncnn on the other | Log both devices; add a device setting only if needed |

## Open questions

- The AMD laptop's model, GPU and OS (to plan Phase 3).
- Whether to load the system's FFmpeg first on Linux (fewer bytes, but
  version drift between distributions) or always use the bundled build.
  Bundled is the safer default.
- Whether macOS hosts (VideoToolbox, Metal through MoltenVK for ncnn) are
  worth a later phase.
