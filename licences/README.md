# Licences

The texts shown under Settings > About > Licences (`src/licences.gd` lists
the components and which file each uses). Exported with the app
(`export_presets.cfg` includes `licences/*.txt`).

Collected on 2026-10-08 from the sources the release builds use:

| Files | From |
| --- | --- |
| `GPL-3.0.txt` | The repository's `LICENSE` |
| `GPL-2.0.txt`, `curl.txt`, `opus.txt`, `zlib.txt`, `simde.txt`, `godot-cpp.txt` | vcpkg's `share/<port>/copyright` for arm64-android (FFmpeg's is the GPL v2, as built with `gpl`) |
| `enet.txt`, `nanors.txt` | moonlight-common-c's bundled `enet/` and `nanors/` |
| `Apache-2.0.txt` | The OpenXR loader's licence (`addons/godotopenxrvendors/khronos/LICENSE`) |
| `meta-openxr-sdk.txt` | `addons/godotopenxrvendors/meta/LICENSE-SDK` |
| `godot-openxr-vendors.txt` | GodotVR/godot_openxr_vendors `LICENSE` |
| `pyrowave.txt`, `granite.txt`, `volk.txt` | PyroWave and Granite at the commits in `addons/nightfall-stream/third_party/pyrowave/VERSION` |
| `tensorflow.txt`, `xnnpack.txt`, `pthreadpool.txt`, `cpuinfo.txt`, `fp16.txt`, `fxdiv.txt`, `farmhash.txt`, `fft2d.txt`, `MPL-2.0.txt` (Eigen) | TensorFlow 2.17's Bazel dependencies, which LiteRT bundles |
| `zipdepth.txt` | `tools/ZipDepth/LICENSE` |
| `noto-cjk.txt` | `src/assets/fonts/NOTO_CJK_LICENSE.txt` |
| `ncnn.txt` | ncnn's `LICENSE.txt` (Linux builds) |

Godot's own licence and its third-party components come from the engine at
run time (`Engine.get_license_text()`, `Engine.get_copyright_info()`).

Adding a library to the APK means adding its licence here and an entry in
`src/licences.gd`.
