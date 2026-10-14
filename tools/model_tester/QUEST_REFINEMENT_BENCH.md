# Quest refinement GPU benchmark — 2026-10-14

Standalone GLES microbenchmark on the connected Quest 3, Adreno 740, GLES 3.2
driver V@0837.0.9. No APK replacement or production-path changes.

Uses the Bounded-2 and Bounded-4 comparison shaders, converted to GLES 300 ES
with high precision. Bounded-2 writes RGBA8; cleanup writes RGBA16F, matching
the local comparison. Baseline is a one-pass hardware-linear depth sample.

## Results

Median GPU milliseconds, second round (first round was very similar):

| Working grid | Linear | Alignment | Alignment + cleanup | Extra vs linear, both |
| --- | ---: | ---: | ---: | ---: |
| 512x288 | 0.0168 | 0.2611 | 0.3366 | 0.3198 |
| 640x360 | 0.0233 | 0.3056 | 0.4173 | 0.3940 |
| 960x540 | 0.0435 | 0.5193 | 0.7519 | 0.7084 |

Also measured 480x270: 0.0152 / 0.2104 / 0.2766 ms, but the current native
linear path keeps a matching EdgePad-512 map at least 512x288 even for 1080p.
Quarter-stream 1440p and 4K grids are 640x360 and 960x540 respectively.

Every mode has 30 warm-up draws and 100 measured samples per round, two rounds.
GPU timings use `GL_EXT_disjoint_timer_query`, with **zero disjoint samples**.
Raw results are retained in ignored `output/quest-refinement-20261014.txt`.

## Scope and limitations

- Input: saved **desktop CPU-generated** EdgePad-512 normalized depth (512x288),
  from `output/native-meteor-pipeline-report-20261012/2/normalized.png`, plus its
  2560x1440 `original.png` colour guide. This is real model output, **not a new
  on-headset inference measurement** or an exported live headset map.
- Only these shader passes are measured. No inference, capture, model loading,
  OpenCL/GLES interop, depth upload, stereo warp, streaming or XR composition.
- Guide is an already-resident RGB texture, not a MediaCodec external OES
  texture. Any new conversion/capture cost in live integration is additional.
- GPU timer readings are the useful shader comparison. Wall timings also
  include deliberate `glFinish` stalls and CPU driver overhead; do not add
  those stalls to the production renderer.
- No clock/performance-level override. Isolated shell process, not concurrent
  live streaming with OpenCL inference. Cost varies with scene edges, GPU
  clocks, temperature and contention; these are not end-to-end latency promises.
- Native integration is **not implemented** by this benchmark. In particular,
  decide whether to refine at inference cadence or every rendered frame before
  estimating sustained GPU load. Quality needs an on-headset A/B test.

## Reproduce

Build `quest_refinement_bench.cpp` using NDK 29's
`aarch64-linux-android29-clang++ -O3 -std=c++17 -static-libstdc++`, linking
`-lEGL -lGLESv3`. It expects:

- `depth.r8`: 512x288 tightly packed normalized depth bytes;
- `guide.rgb`: tightly packed RGB8 source pixels;
- `edge_alignment.glsl` and `depth_contour_cleanup.glsl` from this directory.

Convert the depth PNG to grayscale and the original to RGB using Pillow and
export their `tobytes()` buffers. Push the executable and fixtures to
`/data/local/tmp/nightfall-refinement-bench/`, chmod the executable to 755, then:

```sh
adb shell /data/local/tmp/nightfall-refinement-bench/nightfall-quest-refinement-bench \
  /data/local/tmp/nightfall-refinement-bench 2560 1440
```

The tool refuses to report timing without GPU timer support, checks shader
compilation/linking and framebuffer completeness, and rejects disjoint samples.
