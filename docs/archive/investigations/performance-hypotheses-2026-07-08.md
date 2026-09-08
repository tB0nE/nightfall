# Nightfall performance analysis (2026-07-08)

Context: Nightfall is a Godot/OpenXR GameStream client targeting Quest-class VR. Reported target is **4K 60 fps with passthrough on**; current observed ceiling is about **1440p 60 fps with passthrough off**, and passthrough reportedly cuts performance by about 50%.

This document records the findings of a read-only analysis pass, with every code claim verified against the repository (file:line citations throughout). It is intended as a handoff artifact for future sessions.

## Executive conclusion

There is **no single bug**. Nightfall does substantially more local work than the flat Moonlight Android client, and two confounds must be eliminated before any benchmark number can be trusted:

1. **The default native build is compiled with no optimization flags at all** (not merely "debug"): `CMakePresets.json` sets no `CMAKE_BUILD_TYPE` and `CMakeLists.txt` adds no `-O` flags, so `cmake --preset android` produces an effectively `-O0` GDExtension. The default APK export also uses the `NightfallDev` preset with `graphics/opengl_debug=true`. An unoptimized decode/memcpy/upload pipeline inflates exactly the costs identified in F2.
2. **The composition viewports are hardcoded to 1920×1080** and never track the negotiated stream resolution. A "4K" stream is squeezed through a 1080p intermediate render target — simultaneously a quality bug (the user never sees true 4K in comp-layer mode) and a correction to earlier per-pixel cost estimates.

The structural performance ceiling, once those are fixed, is:

3. **Confirmed hardware-decoder → CPU → GPU round-trip** in the native video pipeline: three CPU-touch copies between decoder output and GPU texture, four counting packet reassembly. No zero-copy path (Surface, AHardwareBuffer, Vulkan external memory) exists anywhere in the tree.
4. **Composition viewports redraw every headset frame** (`UPDATE_ALWAYS`) regardless of whether a new stream frame arrived. Frame pacing was implemented once (`d6cba05`) and deliberately removed (`1132efd`, "perf: remove frame pacing"); the revert rationale is not recorded and must be recovered before re-implementing.
5. **Passthrough is not free** on Quest: it adds camera/passthrough-service work and per-pixel compositor blending. All of Nightfall's composition layers are alpha-blended even though the video pixels themselves write alpha = 1.0 — making the video layer opaque is a safe, cheap win because nothing visible depends on its alpha.
6. **The main projection layer renders both eyes at full resolution with no foveated rendering, every frame, for near-empty content** during comp-layer streaming. No foveation settings exist anywhere; the one variable that looks like a render-scale hook (`_xr_base_render_scale`) is captured and never used.
7. Opt-in features (filters, stereo, auto-detect) and one always-on hidden UI viewport add load, but they are secondary: filters and readbacks default off, the AI-depth path is currently unreachable dead code, and `VirtualGamepad`/`VirtualTrackpad` are never instantiated.

The friend's suspicion about GPU → CPU → GPU is correct: `av_hwframe_transfer_data()` and `RenderingDevice::texture_update()` are in the hot path. Passthrough's ~50% drop is probably a separate compositor/GPU-budget issue, made worse by alpha blending; it is the one finding that still needs device profiling to apportion.

## Current hot-path sketch

### Main Quest stream path (verified in code)

```text
Moonlight RTP packets
  -> StreamConnection::_cb_submit_decode_unit()
     memcpy of every packet fragment into one AVPacket     [copy 0 — stream_connection.cpp:262-270]
  -> packet_queue_ (FIFO; drops only at 512 / 128-SW high-water marks)
  -> decode thread / FFmpeg MediaCodec (ndk_codec=1)
  -> if hardware frame: av_hwframe_transfer_data() to CPU  [copy 1 — stream_connection.cpp:672-677]
  -> TextureUploader::update_from_frame()
     memcpy Y/UV planes into PackedByteArray staging       [copy 2 — texture_uploader.cpp:304-329]
  -> render thread TextureUploader::perform_gpu_update()
     rd->texture_update() for Y and UV textures            [copy 3 — texture_uploader.cpp:500-504]
  -> Godot SubViewport (comp_viewport or comp_viewport_left/right)
     HARDCODED 1920x1080 (+bezel), UPDATE_ALWAYS
     yuv_display.gdshader / embedded yuv_shader.h converts YUV -> RGB
  -> OpenXRCompositionLayerCylinder/Quad, set_alpha_blend(true) unconditionally
  -> XR compositor, optionally with passthrough under/around app content
```

### Quantified scale

Upload-side bandwidth scales with stream resolution:

| Resolution | NV12 bytes/frame | Upload bandwidth @60 |
|---|---:|---:|
| 2560x1440 | 5.27 MiB | 316 MiB/s |
| 3840x2160 | 11.87 MiB | 712 MiB/s |

Each of copies 1–3 above touches this much data per frame, so the CPU-visible traffic is roughly **3× the table value** (≈ 2.1 GiB/s of memory traffic at 4K60) before cache effects.

Viewport-side fragment cost does **not** scale with stream resolution in the current code: the comp viewports are fixed at 1920×1080 (+16 px bezel padding), so each mono pass is ~2.1 MPix and stereo is ~4.2 MPix per XR frame — not the 8.3 MPix/16.6 MPix a true 4K viewport would cost. Texture-fetch bandwidth in the YUV shader still scales with the 4K source textures.

## Ranked findings

### F1 — Confirmed: the default build is unoptimized and uses the debug export preset

**Conviction:** Certain (verified in build files).
**Likely impact:** Potentially very high; poisons every benchmark taken on a default build.

**Evidence in repo**

- `build.sh:7-8` defaults to `PRESET="NightfallDev"` and a `-debug.apk` output name; `--release` must be passed explicitly (`build.sh:13-14,20`).
- `addons/nightfall-stream/CMakePresets.json`: **none** of the presets (`base`, `android`, `linux`, `steamos-arm64`) set `CMAKE_BUILD_TYPE`. An unqualified `cmake --preset android` therefore builds with an empty build type — CMake supplies **no `-O` optimization flags at all**.
- `addons/nightfall-stream/CMakeLists.txt`: the only `target_compile_options` are warnings (`/W4` at line 91, `-Wall -Wextra -Wno-unused-parameter` at line 93). `CMAKE_BUILD_TYPE` is read only to pick the `.so` name suffix (lines 72-76), never to force optimization. There is no `-O2`/`-O3` anywhere.
- `export_presets.cfg`: `NightfallDev` has `graphics/opengl_debug=true` (line 56); `NightfallRelease` has it false (line 317). OpenXR validation layers are false in both (lines 257, 518), so that particular layer is not a confound.
- `BUILD.md:37-57` documents the release flow (`cmake --preset android -DCMAKE_BUILD_TYPE=Release` + `llvm-strip`) and the size delta (debug ~162 MB vs release ~35 MB).
- Native logging (`NF_LOG` → `__android_log_print`, `src/nf_log.h:5-6`) is always compiled in, but the per-frame call sites are throttled (first 3 frames / every 60th frame — `stream_connection.cpp:236-246`, `texture_uploader.cpp:290-296`), so log spam is *not* a significant confound.

**Why this is ranked first**

The hot path is dominated by tight copy loops (`memcpy`, plane walks, fragment reassembly) and FFmpeg glue — exactly the code whose cost balloons at `-O0`. If the observed 1440p ceiling was measured on a default build, a large share of the Nightfall-vs-Moonlight gap may be this alone. No other finding can be quantified until this is eliminated.

**Proposed improvements (specific)**

1. **Make optimization unconditional.** In `CMakePresets.json`, add `"CMAKE_BUILD_TYPE": "RelWithDebInfo"` to the `base` preset's `cacheVariables`, and add a dedicated `android-debug` preset for the rare case a debug native build is wanted. Alternatively (belt-and-braces), in `CMakeLists.txt` set a default when none is given:
   ```cmake
   if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
     set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
   endif()
   ```
2. **Flip `build.sh` to default `--release`**, or at minimum print a large warning banner when producing a debug/`NightfallDev` APK.
3. **Add a runtime tripwire:** log (and show in the stats overlay) whether the loaded GDExtension is the `template_debug` or `template_release` `.so`, whether `NDEBUG` was defined at compile time, and the active rendering method (`RenderingServer.get_current_rendering_method()` — `project.godot` never sets `rendering/renderer/rendering_method`, so the Mobile-renderer assumption on Android is unverified; Forward+ on Quest would be very expensive). A mis-built or mis-configured APK should be self-identifying during benchmarks.
4. **Re-run the entire benchmark matrix on a release build before acting on any other finding here.**

---

### F2 — Confirmed: hardware decode frames are round-tripped through CPU before becoming Godot textures

**Conviction:** Certain (verified; no counter-evidence found).
**Likely impact:** High at 4K; also adds latency and synchronization bubbles. This is the structural ceiling once F1 is fixed.

**Evidence in repo**

- `addons/nightfall-stream/src/video/stream_connection.cpp:672-677`: when `tmp->hw_frames_ctx` is set, the code **unconditionally** allocates a software frame and calls `av_hwframe_transfer_data(sw_frame, tmp, 0)`; `final_frame = sw_frame` on success. The only other branch (lines 678-681) fires on transfer *failure* and passes the raw hw frame — a broken-frame fallback, not a zero-copy path. Line 701 hands the CPU frame to `uploader_->update_from_frame(final_frame)`.
- `addons/nightfall-stream/src/video/texture_uploader.cpp:304-329`: the `upload_rd` lambda resizes `PackedByteArray` staging buffers and copies each plane with `memcpy` (line 316 fast path, line 319 per-row when strides differ). Y at line 323; one UV plane for NV12 or two for planar YUV420P at lines 325-329.
- `texture_uploader.cpp:500-504`: `perform_gpu_update()` calls `rd->texture_update()` for each plane texture, scheduled every frame via `call_on_render_thread` (line 336) gated only by `pending_gpu_update` (set on every `update_from_frame`, line 332).
- Android decoder setup: `ffmpeg_decoder.cpp:76-80` tries `<codec>_mediacodec`; line 155 sets `hw_pix_fmt = AV_PIX_FMT_MEDIACODEC`; lines 178-179 set `ndk_codec=1`.
- **Counter-evidence sweep came up empty:** grep across the tree for `Surface`, `AHardwareBuffer`, `texture_create_from_extension`, `VkImage`, `external_memory`, `EGLImage`, `ANativeWindow` finds no decoder-output GPU handoff of any kind. The `dmabuf_importer.cpp` in the same directory belongs to host-side PipeWire screen capture (`nightfall_stream.cpp:174`), and even it CPU-maps the dma-buf (`DMA_BUF_IOCTL_SYNC`, lines 94-211) into a temp buffer for the same `TextureUploader` — it is not a zero-copy path either.

**Copy count, decoder output → GPU texture: 3** (hw→CPU transfer; plane memcpy into staging; `texture_update` upload). Counting network-buffer → GPU: **4**, adding the ingest fragment-reassembly memcpy (`stream_connection.cpp:262-270`: walks `decodeUnit->bufferList` and memcpys each fragment into one AVPacket at line 266).

**Chroma texture detail:** for NV12 on the RenderingDevice path, the chroma texture is created at **full luma width in `R8_UNORM`** (`texture_uploader.cpp:214`: `create_rd_texture(1, is_nv12 ? y_w : uv_w, uv_h, DATA_FORMAT_R8_UNORM)`), and the shader does **two `texelFetch` calls per texel** to reconstruct U and V. Note the shader that actually runs on the RD path is the embedded `src/video/yuv_shader.h` (`YUV_SHADER_CODE`, loaded at `texture_uploader.cpp:232`), lines 27-34 — not the standalone `.gdshader`; the standalone `src/shaders/yuv_display.gdshader` (used as the compositor material, `main.gd:285,414,463`) does the same under `yuv_mode == 1` (lines 30-36). An `RG8` path exists only in the non-RD `Image` fallback (`texture_uploader.cpp:195-197,362,433`), which is not the hardware path.

**Queue policy:** `stream_connection.cpp:296-310` — packets are dropped only at a hard cap of 512 queued (any decoder) or 128 (software decode only, which also flushes and requests an IDR). The decode loop (lines 527-540) drains strictly FIFO oldest-first; there is **no drop-late/skip-to-newest logic and no drop on the decoded-frame side**. Under sustained backlog below the caps, hardware decode builds latency rather than shedding it.

**Why Moonlight is faster here**

Moonlight Android configures `MediaCodec` with an output `Surface` and renders decoded output buffers directly (`videoDecoder.configure(format, renderTarget.getSurface(), null, 0)` + `releaseOutputBuffer(..., true/timestamp)`); decoded frames never become CPU-visible. Nightfall asks FFmpeg/MediaCodec for CPU-uploadable frames, which forces the round-trip.

**How to test/falsify**

- Add per-frame timers (log rolling p50/p95 in ms) around: `av_hwframe_transfer_data()`; the plane memcpys in `update_from_frame()`; `rd->texture_update()` in `perform_gpu_update()`. Compare 1440p vs 4K, on a **release** build (F1).
- Compare forced software decode vs hardware decode. If hardware decode still spends significant time in transfer/upload, the round-trip is confirmed as the dominant native cost.

**Proposed improvements (specific, in order of increasing effort)**

1. **RG8 chroma texture for NV12 (small, immediate).** Create texture 1 as `DATA_FORMAT_R8G8_UNORM` at `uv_w × uv_h` in `texture_uploader.cpp:214`, upload the interleaved UV plane unchanged (NV12's UV plane is already interleaved — the bytes are identical, only the view changes), and replace the two `texelFetch` calls in `yuv_shader.h:27-34` and `yuv_display.gdshader` `yuv_mode==1` with a single fetch of `.rg`. Halves chroma fetch count and removes the full-width over-allocation.
2. **Queue policy: shed latency (small).** In the decode loop, when `packet_queue_.size() > N` (N ≈ 3-4 frames' worth), drain to the most recent IDR-safe point or request an IDR and skip ahead, counting drops in stats. On the uploaded-frame side, if a new decoded frame arrives before the previous one was consumed, overwrite rather than queue (latest-frame-wins) — the uploader already effectively does this via `pending_gpu_update`; make it explicit and count skips.
3. **Reduce ingest copies (medium).** For single-fragment decode units, wrap the buffer with `av_packet_from_data`/custom free instead of `av_new_packet`+memcpy; for multi-fragment units the reassembly copy is hard to avoid with FFmpeg's API, but the buffer can be pooled to avoid per-packet allocation.
4. **Architectural fix (large, the real answer):** MediaCodec output to an `AHardwareBuffer`-backed `ImageReader` (or a `Surface` bound to one), import via `VK_ANDROID_external_memory_android_hardware_buffer` into a `VkImage`, and wrap it for Godot with `RenderingDevice::texture_create_from_extension()` (Godot 4.7 documents this as wrapping an existing external image such as a `VkImage`). This deletes copies 1-3 entirely. Two sub-options:
   - **4a. Stay in Godot:** wrapped external image replaces the Y/UV textures; the existing shader converts YCbCr → RGB (or use a Vulkan sampler YCbCr conversion and sample RGB directly).
   - **4b. Bypass Godot for the stream plane:** decode into an OpenXR swapchain image (or submit the AHardwareBuffer-backed image) and submit a native `XrCompositionLayerQuad`/`Cylinder` directly. This also solves F4 (pacing) for free, because layer submission becomes explicit per decoded frame. Prefer 4b as the end state; 4a is a useful intermediate that keeps UI/cursor compositing in Godot.
5. **Linux/PCVR analog:** import VAAPI/PipeWire DMA-BUFs as Vulkan external memory instead of the current CPU mapping in `dmabuf_importer.cpp`.
6. **Boost decode/upload thread priority (small).** The native code contains no `setpriority`/`sched_*`/affinity calls anywhere. Moonlight raises its decoder thread priority; on a big.LITTLE SoC under load, the threads doing gigabytes/sec of memcpy (copies 1-3) can land on little cores. Set the decode thread (and the receive callback thread if separate) to elevated priority via `setpriority(PRIO_PROCESS, gettid(), ...)` or `pthread_setschedparam`, and verify placement with `systrace`/Perfetto CPU tracks. Secondary to removing the copies, but cheap and additive.

---

### F3 — Confirmed bug: composition viewports are hardcoded to 1920×1080 and never track stream resolution

**Conviction:** Certain (verified).
**Likely impact:** Quality: high (4K streams are downsampled to 1080p mid-pipeline in comp-layer mode). Performance accounting: changes the math of F4 and F7 — viewport fragment cost is fixed at ~1080p regardless of stream resolution.

**Evidence in repo**

- `comp_viewport` and the stereo pair are created at `Vector2i(1920, 1080)` (`main.gd:258-265, 392, 441`).
- Resizing goes through `_update_comp_bezel` (`main.gd:543, 560`) to `_comp_base_size` + bezel padding, but `_comp_base_size` is only ever assigned the hardcoded `1920x1080` (`main.gd:263, 498`) — nothing updates it from the negotiated stream resolution.

**Consequences**

- In comp-layer mode a 4K stream renders 4K YUV textures into a 1080p viewport: the user never sees more than 1080p of resolved detail, and any "4K" benchmark in this mode was not measuring 4K rendering — only 4K decode + upload (F2).
- Earlier drafts' estimate of ~8.3 MPix per redundant mono viewport pass at 4K was 4× too high; the true figure is ~2.1 MPix. Texture-fetch bandwidth from the 4K source textures is still real.

**Proposed improvements (specific)**

1. On stream negotiation (wherever width/height first become known in `stream_manager.gd`/`StreamBackend`), set `_comp_base_size = Vector2i(stream_w, stream_h)` and call `_update_comp_bezel()` so the viewport and layer aspect update together.
2. Cap the viewport at a device-appropriate maximum (the layer's on-screen angular size × panel pixels-per-degree — beyond that, extra viewport pixels are invisible). Expose the cap as the "4K performance mode" knob: e.g. render the comp viewport at 1.0×/0.75×/0.5× of stream size.
3. When the fix lands, re-benchmark: true-4K viewport passes quadruple the fragment work relative to today's accidental 1080p, so F4's pacing fix and F5's opaque-layer fix become correspondingly more valuable.

---

### F4 — Confirmed mechanics: video composition viewports redraw every XR frame rather than every decoded frame — but the fix was tried once and reverted

**Conviction:** High on mechanics (verified). The *net win* of re-fixing is uncertain until the revert rationale is recovered.
**Likely impact:** Medium at today's 1080p viewport size; high once F3 makes viewports stream-sized. Worst when a 60 fps stream runs on a 72/90 Hz headset.

**Evidence in repo**

- `main.gd:264` creates `comp_viewport` with `UPDATE_ALWAYS`; `_switch_to_comp_layer()` sets `stream_viewport` to `UPDATE_DISABLED` (`main.gd:1023`) and `comp_viewport` to `UPDATE_ALWAYS` (`main.gd:1038`); stereo sets both eye viewports to `UPDATE_ALWAYS` (`main.gd:1063-1064`, with mono `comp_viewport` disabled at `main.gd:1053`).
- `TextureUploader::consume_new_frame()` exists (`texture_uploader.cpp:543`, exposed via `stream_backend.gd:217-222`) but its **only** caller is `stream_manager.gd:314` inside `update_stats()` (0.5 s cadence), and the return value is discarded. It does not pace anything.
- **History:** commit `d6cba05` implemented exactly the pacing this finding proposes — `consume_new_frame()` in `_process()`, setting the active viewport to `UPDATE_ONCE` on each new frame. Commit `1132efd` (2026-06-12, "perf: remove frame pacing, add 72fps stream support, and tune refresh rate targets") removed it and flipped the standing modes to unconditional `UPDATE_ALWAYS`. No source comment or commit body records *why*; notably the removal was itself labeled a perf change.

**Why this matters**

At 60 fps stream on a 72 Hz display, ≥17% of viewport renders repeat old content even in the perfect case; at 90/120 Hz the waste grows. Today each wasted pass is ~2.1 MPix (F3); after F3 is fixed it becomes the full stream size per eye.

**How to test/falsify**

- Count decoded/uploaded frames vs comp-viewport renders per second (add a counter in the viewport's draw path or use `RenderingServer` frame stats).
- Recover the `1132efd` revert rationale: read the full commit message/PR discussion, test the old pacing code on-device, and characterize what broke (judder from UPDATE_ONCE racing the XR frame loop? black layer frames? interaction with the 72 fps stream support added in the same commit?).
- Static-texture A/B: with no stream, measure `UPDATE_ALWAYS` vs `UPDATE_DISABLED` on the comp viewport to bound the per-frame cost.

**Proposed improvements (specific)**

1. **Re-implement pacing with the failure modes designed out**, in `_process()`:
   ```gdscript
   var new_frame := stream_backend.consume_new_frame()
   var dirty := new_frame or _overlay_dirty or _uniforms_dirty
   if dirty:
       _active_comp_viewports()  # mono or stereo pair
           .render_target_update_mode = SubViewport.UPDATE_ONCE
   ```
   where `_overlay_dirty` is set by cursor/overlay movement inside the video viewport and `_uniforms_dirty` by filter/stereo/bezel changes. Keep a low-rate keepalive (e.g. force `UPDATE_ONCE` at least every 500 ms) so the swapchain never starves if the runtime requires periodic redraws — this addresses the suspected black-frame risk without paying full refresh-rate redraws.
2. **Consume, don't poll, in stats:** `update_stats()` must stop calling `consume_new_frame()` (it currently *eats* the new-frame flag twice per second, which would silently break pacing) — give stats its own non-consuming counter accessor.
3. If pacing proves incompatible with the Godot comp-layer path on-device, treat that as additional justification for F2 option 4b (native OpenXR layer with explicit per-frame submission), where pacing is inherent.

---

### F5 — Likely: passthrough's ~50% drop is real compositor/GPU work; all layers are needlessly alpha-blended

**Conviction:** High that the mechanism exists; the exact split (camera service vs compositor blend vs app render) needs device profiling. This is the least code-verifiable finding.
**Likely impact:** High when already near GPU budget.

**Evidence in repo**

- `project.godot:48` enables `openxr/extensions/meta/passthrough=true`.
- `main.gd:1350-1355`: passthrough-on sets `get_viewport().transparent_bg = true` and `XR_ENV_BLEND_MODE_ALPHA_BLEND`. This is correctly **gated on device support** (`has_alpha_blend` from `get_supported_environment_blend_modes()`, `main.gd:1343-1348`) with an opaque fallback (`main.gd:1356-1361`). `settings_controller.gd:66-97` cycles alpha / opaque / background-effect modes at runtime.
- **Every composition layer calls `set_alpha_blend(true)`** — video cylinder `main.gd:250`, UI/cursor layers `:311,322`, stereo pair `:363,374,383`. There is no code path that passes `false`; no layer is ever opaque.
- **But the video pixels are fully opaque:** every output in `yuv_display.gdshader` writes alpha = 1.0 (lines 181, 183, 185). The compositor performs per-pixel blend math over the whole layer while the video region contributes nothing visible via alpha. Passthrough only actually shows through the bezel/background region: the bezel `ColorRect` is opaque black when enabled (`main.gd:507,528,545`) and `Color(0,0,0,0)` when disabled (`main.gd:566`).
- **Alpha-zero geometry is drawn instead of hidden:** `_make_screen_transparent()` (`main.gd:648-654`) assigns a `TRANSPARENCY_ALPHA`, `albedo_color=Color(0,0,0,0)` material override to `screen_mesh` and leaves it visible (called at `:1041,1065`; only `bezel_mesh` is hidden at `:1066`). The same pattern covers the UI panel (`:656-662`) and keyboard (`:664-672`). Fully transparent meshes still cost vertex work and, depending on the renderer, sorted transparent-pass fragment work.
- Meta's passthrough docs: passthrough is rendered by a dedicated service into a separate layer composited by the XR compositor — camera processing + compositor blending consume real GPU/CPU budget outside the app.

**Hypothesis detail**

With passthrough on, the app may pay simultaneously for: projection-layer alpha blending, one or more large alpha-blended video layers, UI/cursor/keyboard layers, passthrough camera/service processing, and the per-XR-frame viewport renders of F4. If the app is near budget, passthrough pushes it over and appears as a ~50% fps cliff.

**How to test/falsify**

Run identical stream/filter settings across: (1) passthrough off + layer alpha on; (2) passthrough on + layer alpha on; (3) passthrough on + video layer opaque; (4) no stream/static scene, passthrough on vs off. Use OVR Metrics/Perfetto/AGI to split app GPU time from compositor time. If app render time stays flat while compositor time jumps, composition dominates.

**Proposed improvements (specific)**

1. **Make the video layer opaque by default.** Change `main.gd:250,374,383` to `set_alpha_blend(false)` for the video cylinder(s) whenever the bezel is enabled or the video fills the layer; keep alpha only on UI/cursor/keyboard layers. Since the shader already writes alpha = 1.0 everywhere, this is visually lossless in those states. When the bezel is disabled and passthrough is on (the one state that needs transparency around the video), either keep alpha for that state only, or shrink the layer to the video rect so no transparent margin exists.
2. **Hide, don't alpha-out, the screen/UI/keyboard meshes in comp-layer mode.** Replace `_make_screen_transparent()`'s material override with `screen_mesh.visible = false`, preserving pointer interaction via a collision-only `Area3D` (the collision shape already exists independently of the mesh material). Delete the transparent-material helpers once nothing uses them.
3. **Layer count audit:** log the number of composition layers submitted per frame on Quest along with `is_natively_supported()`; if the runtime is falling back to non-native emulation for any layer, that layer is being rendered by Godot into the main projection layer at extra cost.
4. **"4K performance mode" preset:** one toggle that sets — filters off (F8), stereo/AI off (F7), auto-detect off, video layer opaque, bezel on (enables the opaque fast path), keyboard viewport disabled while hidden (F9), projection-layer render scale reduced (F6), and warns if the build is debug (F1).

---

### F6 — Confirmed settings gap: the main projection layer renders at full scale, with no foveated rendering, for near-empty content during streaming

**Conviction:** Certain that the settings are absent (verified); the recoverable GPU budget needs device measurement.
**Likely impact:** Medium — a constant per-XR-frame tax on both eye buffers that the earlier findings never account for, and directly relevant to the passthrough cliff (F5) since it competes for the same GPU budget.

**Evidence in repo**

- **No foveated rendering anywhere.** Neither `project.godot` nor `export_presets.cfg` contains `xr/openxr/foveation_level` or `foveation_dynamic`; Godot's default is foveation off. Fixed foveated rendering is close to a free GPU win on Quest for everything rendered into the projection layer.
- **A render-scale hook exists but is dead.** `main.gd:111` declares `_xr_base_render_scale`; `main.gd:1369` captures `get_viewport().scaling_3d_scale` into it — and it is never read anywhere. It looks like the remnant of an intent to scale the projection layer down during streaming that was never finished.
- **The projection layer's content during comp-layer streaming is near-empty but still rendered stereo at full resolution:** the alpha-zero screen mesh (F5), hidden UI/keyboard meshes, and the `WorldEnvironment` background. Both eye buffers render every XR frame regardless.
- **MSAA:** `main.gd:1366-1368` sets `msaa_3d` to `MSAA_2X` in one mode (disabled in the other) — multisampling the same near-empty content.
- **Renderer method is unverified:** `project.godot` never sets `rendering/renderer/rendering_method`; the Android default should resolve to the Mobile renderer, but this is an assumption (see the F1 tripwire).

**How to test/falsify**

- OVR Metrics / Perfetto with a static comp-layer stream: measure app GPU time at foveation off vs level 3, and at `scaling_3d_scale` 1.0 vs 0.5. The delta is pure recovered budget — comp layers are sampled by the compositor at their own resolution and are unaffected.
- Confirm the active renderer with `RenderingServer.get_current_rendering_method()` on-device.

**Proposed improvements (specific)**

1. **Enable foveated rendering:** set `xr/openxr/foveation_level = 3` and `xr/openxr/foveation_dynamic = true` in `project.godot`. The video composition layer is unaffected (composited at its own resolution by the runtime); only the projection layer's periphery loses shading resolution, which during streaming shows nothing.
2. **Drop projection render scale while streaming:** in `_switch_to_comp_layer()` / `_switch_to_stereo_comp_layer()`, set `get_viewport().scaling_3d_scale = 0.5` (make the factor a constant, tune on device); restore `_xr_base_render_scale` when the stream ends or the in-world menu opens — finally using the variable for what it was created for. Verify first that no visible UI is rendered in the projection layer during streaming (with F5.2's mesh-hiding in place, it shouldn't be).
3. **Disable MSAA during comp-layer streaming** (`main.gd:1366-1368` already has the switch point); re-enable with the menu.
4. Keep the renderer-method assertion in the F1 tripwire so a Forward+ fallback can never silently ship.

---

### F7 — Partially confirmed: stereo doubles the (1080p) viewport workload; the AI-depth path is currently unreachable

**Conviction:** High for stereo mechanics; the AI-depth cost is moot in current code.
**Likely impact:** Medium for SBS (doubles F3's fixed-size viewport cost, and will double the full stream-size cost once F3 is fixed); zero for AI depth until the mode clamp changes.

**Evidence in repo**

- `_switch_to_stereo_comp_layer()` (`main.gd:1045-1071`) makes both eye cylinders visible, binds each to its own SubViewport, and sets both to `UPDATE_ALWAYS` (`:1063-1064`) while disabling the mono viewport (`:1053`) — genuinely two render targets instead of one, each at the hardcoded 1920×1080 (+bezel) of F3, **not** stream size.
- `yuv_display.gdshader` handles SBS at lines 126-137 and AI depth (`stereo_mode >= 3`) at 138-177 with depth-texture samples at 145, 164, 165.
- **AI depth is dead code today:** `depth_estimator.gd` defaults `enabled = false` (`:8`), is Android-only (`setup()` early-returns off-Android, `:21-23`), and is enabled only via `settings_controller.gd:58` `set_enabled(mode >= 3)` — but `main.gd:1224` clamps `ai_3d_mode` to 0-1, so `mode >= 3` is unreachable. Its 0.1 s pipeline (256×256 viewport → `get_image()` CPU readback at `depth_estimator.gd:70` → native TFLite via `submit_depth_frame`, `:74` — the inference runs in the native backend, not GDScript) cannot currently fire.

**How to test/falsify**

- Measure mono vs SBS at identical settings (release build). Expect roughly +1× viewport render cost, not +1× decode cost (decode/upload is shared).
- For SBS content, check whether each eye actually needs the full-width source: each eye reads only half the input width.

**Proposed improvements (specific)**

1. **Size stereo viewports to per-eye content.** For SBS, each eye's viewport needs at most `stream_w/2 × stream_h` (half-SBS) source pixels before layer scaling — when F3's fix makes viewports stream-sized, size the eye viewports to the per-eye source, not the full frame.
2. **Apply F4's pacing to both eye viewports** (the pacing snippet above already handles the stereo pair).
3. **Decide the AI-depth feature's status.** Either remove the clamp at `main.gd:1224` and ship it as an explicitly-1440p-only feature (its per-eye depth sampling adds 1-2 texture reads per fragment plus the 0.1 s readback+inference), or delete `depth_estimator.gd` and the `stereo_mode >= 3` shader branches as dead code. Leaving unreachable code with a live settings hook invites accidental re-enablement.

---

### F8 — Confirmed but opt-in: smooth/sharpen filters are expensive at high resolution, and default off

**Conviction:** Certain on mechanics; only affects users who raise the sliders.
**Likely impact:** Zero at defaults; medium to very high when enabled at 4K.

**Evidence in repo**

- `yuv_display.gdshader:84-121` `filtered_stream()`: smooth = 9 `sample_stream()` taps, sharpen (CAS) = 5 taps. Each tap fetches Y plus chroma — up to 3 fetches per tap depending on `yuv_mode` (lines 25-43) — so 9-tap smooth ≈ up to 27 texture fetches per fragment.
- The filter selection is a **dynamic uniform branch** (`filter_mode`/`sharpen` uniforms, lines 10-11), not a compile-time variant; there is an early-out when both are zero (lines 86-88).
- `stereo_screen.gdshader:125-181` mirrors this on the mesh-fallback path — with a **much wider blur kernel** (radius factor `float(filter_mode) * 4.0` at lines 135/163 vs `* 0.3` in yuv_display's line 94), so the fallback path's smooth is disproportionately expensive.
- Defaults are off: `main.gd:107-108` `smooth_mode = 0`, `sharpen_mode = 0`; UI exposes up to 50% (`main.gd:109-110`); `settings_controller.gd:194-195` passes `filter_mode` as an integer and `sharpen = sharpen_mode * 0.5`.

**Proposed improvements (specific)**

1. Force filters to 0 (grey out the sliders) whenever the "4K performance mode" of F5.4 is active, with a tooltip explaining why.
2. If filtering must stay available at 4K: compile no-filter/smooth/sharpen as **separate shader variants** (Godot: three materials or `#define`-style preprocessing) rather than a uniform branch, and reduce per-tap cost by sampling chroma once per tap group (chroma is quarter-res; the neighboring taps mostly hit the same chroma texel).
3. Reconcile the `stereo_screen.gdshader` kernel radius with yuv_display's (×4.0 vs ×0.3 looks like a bug or stale tuning, and makes the fallback path far more expensive for the same slider value).

---

### F9 — Partially confirmed: one hidden always-updating viewport is real; the rest of the "auxiliary drain" is dead code or off by default

**Conviction:** Certain (verified).
**Likely impact:** Low-medium for the keyboard viewport; zero for the rest out-of-the-box.

**Evidence in repo**

- **Real cost:** `virtual_keyboard.gd` builds a **2080×600 SubViewport with `UPDATE_ALWAYS`** (`:12, :48-53`), constructed unconditionally at startup (`main.gd:1226-1228`). Line 52 is the only `render_target_update_mode` reference in the file — visibility toggles (`virtual_keyboard.gd:498-514`, `main.gd:877-885`) never touch it, so the ~1.25 MPix viewport redraws every frame for the whole session, keyboard hidden or not. No code anywhere in the repo gates a UI viewport's update mode on visibility.
- **Dead code:** `VirtualGamepad` (1200×720, `virtual_gamepad.gd:10,71`) and `VirtualTrackpad` (500×500, `virtual_trackpad.gd:10,33`) do use unconditional `UPDATE_ALWAYS`, but **neither class is instantiated anywhere** (no `.new()`, no scene reference) — zero runtime cost today. (The keyboard's internal `_build_trackpad()` is a separate widget inside the keyboard viewport.)
- **Off by default:** `depth_estimator.gd` readback is disabled and unreachable (see F7). `auto_detect.gd:22` does a `get_image()` readback every 0.3 s, but only while streaming *and* `auto_detect_enabled`, which defaults false (`main.gd:78`, `ui_controller.gd:39,43`); it also uses `UPDATE_ONCE` + `await frame_post_draw` per invocation (`auto_detect.gd:20-21`) rather than a continuously-updating viewport.

**Proposed improvements (specific)**

1. In `virtual_keyboard.gd`, set the viewport to `UPDATE_DISABLED` after build; in the show/hide path (`:498-514`) set `UPDATE_ALWAYS` while visible (it's interactive — keys highlight on hover) and back to `UPDATE_DISABLED` on hide. One-time `UPDATE_ONCE` after build so the texture isn't blank on first show.
2. Delete `virtual_gamepad.gd` and `virtual_trackpad.gd`, or if they're planned features, add the same visibility-gated update-mode pattern before wiring them up.
3. Keep the F5.2 rule general: any future SubViewport gets `UPDATE_DISABLED` as its resting state, with updates driven by visibility or dirtiness.

## What is probably *not* the primary bottleneck

- **Network bandwidth / host encode**: low confidence as primary cause — Moonlight does 4K60 on the same network, and Nightfall's cliffs correlate with local resolution/passthrough/rendering features. Still worth logging decoded-frame count, queue depth (the FIFO of F2 makes backlog visible), network drops, and server encode latency to rule out.
- **Per-frame log spam**: the native hot-path logging is throttled to ~1 line/sec (F1 evidence); not a meaningful cost.
- **OpenXR validation layers**: disabled in both export presets.
- **FFmpeg decoder configuration**: already sensible — `AV_CODEC_FLAG_LOW_DELAY` and `AV_CODEC_FLAG2_FAST` are set (`ffmpeg_decoder.cpp:129-133`) with thread count = cores−1 for software decode (`:162-171`).
- **Audio pipeline**: Opus → miniaudio with an SPSC ring buffer (`src/audio/`); small fixed cost, not examined further.
- **Background starfield particles**: `visible = false` outside the background-effect mode and capped at `fixed_fps = 30` (`main.gd:1815-1824`).
- **The old "YUV SubViewport then mesh shader" doc**
  (`../plans/4k-performance-optimization.md`) is partly stale for the comp-layer
  path: current code binds Y/UV textures into the display shader and disables
  `stream_viewport` in comp mode. The full-resolution-SubViewport concern
  survives, amended by F3 (the viewport is actually fixed 1080p).

## Recommended roadmap

### Phase 0 — Kill the confounds, then measure (fast; do first)

1. **F1:** default the build to optimized (`RelWithDebInfo` in presets + `build.sh --release` default + runtime debug-build tripwire). Re-run all benchmarks on `NightfallRelease` + `template_release`.
2. **F3:** size comp viewports from the negotiated stream resolution so "4K" benchmarks actually render 4K.
3. Add timing counters: `av_hwframe_transfer_data` ms, plane-memcpy ms, `texture_update` ms, decoded-frames/s vs viewport-renders/s, packet-queue depth.
4. Log `comp_cylinder.is_natively_supported()` and the count of layers submitted per frame on Quest.
5. Benchmark matrix (release build only): 1440p vs 4K; passthrough off/on; video layer alpha on/off; filters off/on; mono vs SBS; 60 vs 72 Hz.

### Phase 1 — Low-risk wins

1. Enable foveated rendering; drop projection-layer render scale and MSAA during comp-layer streaming (F6.1-F6.3).
2. Video composition layer opaque by default (F5.1); alpha only when bezel-off + passthrough-on requires it.
3. Hide (don't alpha-out) screen/UI/keyboard meshes in comp mode; collision-only `Area3D` for interaction (F5.2).
4. Visibility-gated update mode for the keyboard viewport; delete or gate the dead gamepad/trackpad classes (F9).
5. RG8 chroma texture + single-fetch shader for NV12 (F2.1).
6. "4K performance mode" preset (F5.4).
7. Recover the frame-pacing revert rationale from `1132efd`/`d6cba05`; if the failure mode is understood and addressable, re-implement pacing with the dirty-flag + keepalive design of F4.1-F4.2. Do **not** re-add the old code verbatim.

### Phase 2 — Medium native changes

1. Latency-shedding queue policy: drop-to-latest with IDR request instead of 512-deep FIFO (F2.2).
2. Reduce ingest copies / pool AVPacket buffers (F2.3); boost decode/upload thread priority (F2.6).
3. Per-eye-sized stereo viewports (F7.1); decide the AI-depth feature's fate (F7.3).
4. Filter shader variants + kernel-radius fix in `stereo_screen.gdshader` (F8.2-F8.3).

### Phase 3 — Architectural fix (the 4K60+passthrough enabler)

1. MediaCodec → AHardwareBuffer → Vulkan external memory (F2.4): first via `texture_create_from_extension()` inside Godot (4a), then native OpenXR layer submission for the stream plane (4b), which also makes frame pacing explicit and removes the comp-viewport render entirely.
2. Linux/PCVR: VAAPI/PipeWire DMA-BUF Vulkan import (F2.5).

If, after Phase 0-1, 4K+passthrough is still over budget, treat it as a Phase-3 requirement rather than something the Godot viewport path can reach.

## Source-backed notes

- Android `MediaCodec` output-Surface mode: output buffers are not accessible as ByteBuffers and are rendered to the Surface via `releaseOutputBuffer(index, true/timestamp)`.
- Android `AHardwareBuffer`: bindable to EGL/OpenGL and Vulkan external memory; cross-process passing is zero-copy shared views.
- Godot 4.7: `OpenXRCompositionLayer.layer_viewport` is a `SubViewport`; `is_natively_supported()` reports runtime support; `RenderingDevice::texture_create_from_extension()` wraps an existing external image such as a `VkImage`.
- Meta passthrough docs: passthrough is rendered by a dedicated service into a separate layer submitted directly to the XR compositor; composite layering/blending controls placement and alpha.
- Moonlight Android source: configures MediaCodec with `renderTarget.getSurface()` and uses `releaseOutputBuffer()`; advertises direct-submit/reference-frame capabilities for supported decoders.

## Useful files and artifacts

- Existing archived plan: `../plans/4k-performance-optimization.md` (partly stale; see above)
- This analysis: `docs/archive/investigations/performance-hypotheses-2026-07-08.md`
- Relevant commits: `d6cba05` (frame pacing added), `1132efd` (frame pacing removed, 2026-06-12)
