# Nightfall Meteor: Windows

> Status: In progress. The inventory below describes the 2026-10-07
> starting point. See the current status below for the Windows work since then.
>
> Date: 2026-10-05
>
> Related: [meteor-host-depth.md](meteor-host-depth.md) (host depth),
> [meteor-appimage.md](meteor-appimage.md) (the Linux release this
> mirrors), [meteor-microphone.md](meteor-microphone.md) (microphone).
>
> Scope: Windows 10/11 x64 hosts with NVIDIA or AMD GPUs, running Sunshine,
> Apollo, Vibepollo or Vibeshine. NVIDIA keeps NVDEC; AMD uses D3D11VA and
> ncnn Vulkan for EdgePad.

## Windows compatibility update (2026-10-29)

November 3 acceptance: the user confirmed that both Windows monitors display
correctly after the manifest capability/resolution correction. Live switching
between one and two monitors passed. Windows multi-monitor remains an
experimental SDR/same-adapter/unrotated path; packaging is still pending.

Open input issue (deferred at the user's request): grip right-click feels too
sensitive or like a simultaneous left-click with Follow pointer enabled;
turning Follow pointer off avoids it. A Windows low-level hook recorded six
grip presses as right down/up only, with no left-button events. Do not treat
this as a proven duplicate-click bug; investigate pointer motion/click target
stability separately after the main Windows XR work.

Next priority: Windows XR streaming. Native Monado stereo pixel readback and
Vulkan→CUDA→NVENC encode/decode proofs pass. Windows runtime supervision,
tracking/controller/haptic transport, live encoded delivery and actual game
compatibility remain outstanding. Do not describe the diagnostic adapter as
a finished XR streaming implementation.

- The Windows release build compiles from main on branch
  `feat/meteor-windows-compat`. An XR profile validator was moved into shared
  code because the Windows control module could not reference Linux-only
  `xr_session`.
- Auto decoder choice on a selected AMD GPU now tries FFmpeg D3D11VA, then
  software. The advanced decode menu exposes D3D11VA on Windows. FFmpeg's
  `vendor_id` device option selects the RX 480 in a multi-GPU machine.
- A 20-frame H.264 and HEVC B-frame replay passed through both software and
  RX 480 D3D11VA, preserving frame IDs and matching RGB output. The Windows
  release Rust suite passed: 131 tests, 16 ignored.
- EdgePad 512x288 produced finite depth on the RX 480 and RTX 3090. On a
  synthetic frame, ten warm GPU inferences averaged 28.5 ms on RX 480 versus
  2.2 ms on RTX 3090. This is model-only timing; it does not measure a stream.
- A 360-frame, 120 fps Windows host replay with EdgePad 512 at 20 Hz selected
  RX 480 D3D11VA decoding, ncnn Vulkan inference and Vulkan postprocessing:
  60 maps, 0 skipped, 43.7 ms median and 49.6 ms p95 frame-to-map latency.
  Selecting RTX 3090 in a separate state selected NVDEC and NVIDIA inference:
  58 maps, 9.6 ms median and 11.9 ms p95. These are replay measurements,
  not headset streaming results. The cached ncnn SDK built the optional
  Vulkan DLL after fixing MSVC include paths and Windows min/max macros.
- ncnn listed the RX 480 three times in Vulkan enumeration on this PC. The
  GPU choice list now keeps one entry per name so the tray does not repeat it.
- The release and installer scripts now stage four pinned FFmpeg 8 LGPL DLLs
  and their licence. The installer also includes the 256 EdgePad model and
  Vulkan VDA DLL that the previous installer script omitted. Packaging syntax
  has been checked, but a full installer build still needs the new 256 model
  files, which are absent from the older Windows model folder.
- A live RX 480 stream to the headset remains to be checked.
  Headset checks require user approval under `docs/guides/agent-testing.md`.
- Windows XR remains the next major compatibility task. The Linux runtime,
  Vulkan capture and encoder path are not Windows artifacts. First validate a
  native Windows OpenXR session with a candidate runtime; then add Windows
  capture and managed lifecycle adapters. Keep OpenVR compatibility as a
  separate acceptance check. Today `xr_control::validate_runtime_root` rejects
  Windows and runtime startup is Linux-gated, so a live Windows XR stream is
  not available yet.
- One active 2560x1440 display was present on this Windows PC during the
  October 29 check. On October 30 the RX 480 was removed and Windows reported
  two active displays: 2560x1440 primary and 1920x1080 secondary, both on the
  RTX 3090. The fork's `/polaris/v1/display/manifest` still returns a layout
  only on Linux, so Windows multi-monitor streaming needs host capture and
  manifest work before these displays can be validated end to end.

## Bundled host and XR checkpoint (2026-10-30)

- `origin/main` remained at `e5dd63c`; the bundled host was on
  `origin/feat/meteor-bundled-host` at `95dc0a2`. That branch was merged into
  `feat/meteor-windows-compat`, retaining the Windows depth fixes.
- Meteor now compiles the bundled-host controller on Windows, shows its choice
  and lifecycle in the Windows tray, and uses an isolated Windows host config
  beside the dedicated host executable. It refuses to adopt a non-Meteor host
  config in that directory. The host process supervisor and restart path are
  native Windows code. This is integration code, not a validated stream yet.
- The fork's development branch `codex/meteor-vibepollo-baseline` at `b6efac1`
  was cloned into ignored `meteor/target/windows-vibepollo-src`. MSYS2 UCRT64
  and the fork's documented Windows dependencies were installed. A Release
  `sunshine.exe` build reports `2.0.0-meteor.win.dev` and that revision. Its
  current Windows `appdata()` is relative to its executable, so package the
  host in its own directory. Meteor sets `system_tray = false` for the managed
  copy; the host still needs its tray implementation linked to build.
- The Windows tray's Game streaming host menu exposes the managed host's
  status, start/stop, web page, generated login file, and host folder. The
  web login file is needed for manual pairing until the one-click flow lands.
- Isolated Windows host smoke: the managed host started on base 51989, Meteor
  advertised `host.kind = meteor-vibepollo` on discovery port 51900, its proxy
  returned HTTP 200 for `/serverinfo` on 52989, and the Windows job object
  terminated the host after Meteor was killed. The normal Windows profile was
  backed up and configured to use this development host; Meteor and host were
  left running at those ports for manual desktop-stream testing. Apollo was
  left running on its own stack.
- The updated Windows release passed 144 Rust tests (16 ignored, one known
  GPU fixture skipped), plus 12 host-specific tests including job cleanup.
  EdgePad 512 replay on RTX 3090 produced 58 maps from a 360-frame 120 fps
  fixture at a selected 20 Hz rate: 7.9 ms median and 11.6 ms p95
  frame-to-map latency, with NVDEC and NVIDIA Vulkan inference. This is a
  replay, not a client stream.
- The fork's DXGI tool sees both active displays, but the Windows host
  manifest endpoint is Linux-gated and Windows capture selects one output.
  The client's `outputs=` multi-monitor flow therefore has no matching
  Windows host implementation yet.
- Pinned Monado `eab5ff02` and Khronos `hello_xr` build natively on Windows.
  With a process-local `XR_RUNTIME_JSON` and simulated HMD, `hello_xr`
  created both 640x720 eye swapchains. This proves local OpenXR session
  creation, not Nightfall XR capture, encoding or headset streaming. Meteor's
  managed XR runtime path remains Linux-gated.

## XR capture and Windows monitor work (2026-10-30)

- Added a reproducible Windows null-compositor capture hook in
  `test/monado_windows_capture.h`, with a patch and build script beside it.
  The native Release `monado-service.exe` compiles with it. The hook validates
  that a submitted stereo projection references two live Vulkan swapchain
  images and logs their formats, image indices and subrects. It currently
  stops at metadata: there is no Windows image readback, encoder bridge,
  tracking transport, or Meteor runtime supervisor yet.
- In a local simulated-HMD run, `hello_xr` created two 640x720 eye
  swapchains and the patched service reached the hook, but the sample only
  triggered an empty layer commit during a 25-second run. Stereo submission
  is therefore **not proven yet**. A deterministic Windows OpenXR probe that
  submits a coloured stereo pattern is the next XR gate; reuse the Linux
  `monado_runtime_probe.cpp` after replacing its POSIX time conversion.
- October 31: the deterministic probe now builds with MSVC using the OpenXR
  Win32 performance-counter time extension. Its initial `0xc0000409` startup
  failure was caused by buffered stdout initialization with a zero buffer
  size; unbuffered stdout fixed it. A local run submitted five stereo frames
  with app-side pixel verification. The service logged 18 eye-image
  references and zero capture validation failures. These logs prove stereo
  layer delivery to the server; server-side pixel readback and encoding are
  still pending. `test/windows-probe/CMakeLists.txt` builds the probe, and
  `test/smoke_monado_windows.ps1 -HelloXr <probe.exe>` runs it locally.
- Server-side pixel verification now passes on Windows with
  `METEOR_WINDOWS_PIXEL_PROBE=1`: the probe exits successfully, both eye
  patterns pass Vulkan readback in Monado, and the final green=255 marker
  reaches both eyes. The opt-in diagnostic saves server-eye PPMs and writes
  the completion marker. It uses synchronous GPU readback for proof only;
  production capture still needs the encoder bridge and asynchronous delivery.
- Native Windows Vulkan → CUDA → NVENC interop now builds and passes on the
  RTX 3090. The probe exports opaque Win32 memory, imports it into CUDA on
  the same UUID-matched GPU, and encodes five 512x256 H.264 frames without
  CPU pixel readback. NVENC submit-to-lock was 0.44–0.94 ms for this tiny
  fixture; this is not an XR performance measurement. The Windows path
  closes the exported handle after CUDA import, as CUDA retains no ownership
  of opaque Win32 handles. Connecting this encoder to Monado remains pending.
- The diagnostic Windows Monado encoder adapter now passes a local stereo
  encode/decode check. With `METEOR_WINDOWS_ENCODER` pointing at
  `meteor-windows-nvenc.dll`, Monado packs live eye images on the GPU and
  calls NVENC. Two captured frames decoded correctly with left/right eye
  identity, RGB channel order, spatial steps and green markers 64/255.
  The source probe exited successfully and both server pixel checks passed.
  Session end/destruction drains the encoder worker before unloading its DLL.
  This adapter supports one opaque projection; overlay composition, tracking,
  transport and Meteor's Windows runtime lifecycle still need integration.
- A standalone DXGI composition prototype now builds and runs on Windows:
  `meteor-dxgi-composite.exe` enumerates active outputs on the first adapter,
  duplicates each output and submits GPU copies into a shared desktop-sized
  surface. The one-display check captured DISPLAY1 at 2560x1440. Two-display
  capture, pixel verification, frame pacing and Vibepollo integration remain
  pending. The prototype currently supports SDR, unrotated, same-adapter
  outputs only and is not used by the streaming host yet.
- With the second monitor connected, the DXGI prototype captured DISPLAY1
  2560x1440 at (0,0) and DISPLAY2 1920x1080 at (2560,0), producing a
  4480x1440 GPU surface. Mapping a staging copy completed successfully;
  both monitor regions contained nonblack pixels and distinct checksums.
  This verifies actual two-output GPU capture/composition, but does not yet
  verify continuous capture or stream it through Vibepollo.
- Continuous prototype check: 600 polling ticks in 5008.9 ms at a requested
  120 Hz, preserving each monitor's previous pixels when DXGI reports idle.
  DISPLAY1 delivered 333 updates and DISPLAY2 67; these are desktop-change
  updates, not encoded fps. CPU capture/copy submission took 117.0 us median,
  279.3 us p95. Final GPU readback verified populated regions on both outputs.
  Encoder integration, cursor composition, mode-change recovery and HDR
  remain pending in the streaming host.
- Checked the fork's previously untracked `master` at `0f213e6f` before host
  integration. Relative to the Meteor baseline, its Windows platform changes
  are in Playnite integration; it does not provide the missing multi-output
  capture backend. The built host remains on the dedicated Meteor baseline.
- The fork now builds an experimental `display_multi_t` backend using the
  existing `display_vram_t` encoder buffers and keyed-mutex synchronization.
  `METEOR_WINDOWS_MULTIMONITOR=1` selects it explicitly for DXGI encoders.
  The Release host build passed. The durable source patch is
  `test/vibepollo_windows_multimonitor.patch`. This is not enabled in the
  running profile and has not been stream-tested. It currently captures all
  active outputs on one adapter, supports SDR/unrotated displays, and omits
  cursor composition. Manifest/selection support, HDR, mode-change handling
  and a host encode smoke remain required before normal use.
- An isolated Meteor-managed host startup with the experimental flag passed:
  discovery and proxied `/serverinfo` returned HTTP 200, H.264/HEVC NVENC
  initialization passed, and the host died with Meteor. This exercised the
  fork's synthetic encoder validation, not `display_multi_t`: startup could
  not acquire a temporary virtual-display lease and selected synthetic
  surfaces. A real capture-to-encoder check is still required; do not treat
  this startup smoke as multi-monitor encoding validation.
- Real-backend encoder validation now passes with both
  `METEOR_WINDOWS_MULTIMONITOR=1` and `METEOR_WINDOWS_MULTIMONITOR_PROBE=1`.
  The host initialized two-output 4480x1440 capture and explicitly supplied
  captured desktop pixels to its encoder probe; H.264 and HEVC NVENC passed.
  AV1 failed as expected on RTX 3090. This checks capture/conversion/encoding
  compatibility using the probe's output configurations, not sustained
  streaming at native combined resolution. Layout metadata, cursor support,
  output selection and an actual client stream remain pending.
- Windows manifest and selection implementation added behind the experimental
  flag: `/polaris/v1/display/manifest` uses the same geometry policy as the
  DXGI compositor, and `/launch`/`resume` output names select which monitors
  are copied. Unknown outputs, unsupported layouts and multiple active GPU
  adapters are rejected. Software capture is refused while the flag is on,
  so it cannot silently supply a single-output stream with a multi-output
  manifest. The manifest implementation compiled successfully; authenticated
  endpoint and selection behavior still need runtime checks. Cursor support
  remains pending.
- Live Windows selection checks passed via the host's
  `--meteor-display-layout` diagnostic: DISPLAY1 alone is 2560x1440,
  DISPLAY2 alone is 1920x1080 with its frame origin reset to (0,0), both are
  4480x1440, and an unknown name exits with an error. This exercises the
  geometry helper shared by capture and the authenticated manifest endpoint.
- Cursor composition was added using a separate GDI-compatible GPU surface
  and the Windows cursor hotspot, preserving the cursor-free persistent
  desktop to avoid trails. The host rebuilt and repeated its captured-pixel
  H.264/HEVC encoder checks successfully with cursor composition enabled.
  Cursor appearance and movement across both screens still need visual
  verification, as does the authenticated manifest endpoint/client stream.
- November 3 headset check: the physical-display-only trial now streams
  both monitors. The authenticated host manifest reached Nightfall with a
  4480x1440 frame, DISPLAY1 2560x1440 at (0,0), DISPLAY2 1920x1080 at
  (2560,0), both enabled. The client reports two visible screens, HEVC HW,
  72 fps and about 3 ms network latency. Negotiated video output remains
  2560x1440, so native combined-resolution quality is not validated yet.
  The multi-output backend now populates DXGI-derived frame and pacing
  timestamps; no missing-timestamp warnings appeared after the rebuild.
  User visual checks for monitor content, aspect and cursor remain pending.
- The initial two-monitor view was vertically compressed because the client
  retained `is_polaris_host=false` despite a valid launch manifest. That
  disabled monitor controls and selected a 2560x1440 preset for the 4480x1440
  capture, introducing host letterboxing absent from the manifest's UVs.
  The launch-response handler now treats a validated manifest as authoritative
  capability evidence and stores its capture size. Applying equivalent live
  state produced a 4480x1440 HEVC stream with two screens. Reducing to one
  monitor then passed at 2560x1440/72 fps. The source change needs packaging
  in a future APK; live host settings were saved for this test. The required
  unit runner could not start because WSL lacks cargo (see unit verification
  summary dated 2026-11-03); runtime behavior was checked through the bridge.
- Vibepollo Windows presently chooses a single `IDXGIOutput` during
  `display_base_t::init` and makes one `IDXGIOutputDuplication`. Its
  `/polaris/v1/display/manifest` endpoint is Linux-only. Windows support
  needs a capture surface spanning selected DXGI outputs, each output copied
  at its desktop offset (or packed frame offset when the decoder limit is
  exceeded). Only after this is implemented should the endpoint advertise a
  Windows layout or accept a multi-output `outputs=` request. The current
  monitor names are `\\.\DISPLAY1` and `\\.\DISPLAY2` in the fork's DXGI
  enumeration. The active Windows profile still captures one monitor.

## Current Windows status (2026-10-09)

- The Windows release exe proxies a Quest 3 stream and runs EdgePad on ncnn
  and VDA on TensorRT. VDA's 75-frame parity test passed. A fresh download
  of the VDA graphs and NVIDIA's Windows DLLs passed SHA-256 verification;
  after a first engine build, the 1440p replay made 3775 maps from 3796
  frames at 120 fps, with 6.2 ms median and 7.3 ms p95 frame-to-map latency.
- The Windows tray has the Nightfall icon, model, rate, smoothing, edge
  softening, microphone, VDA download/progress/cancel/remove, autostart and
  basic stream status controls. VB-CABLE output, an isolated tone test, and
  a real headset-microphone application test work (user confirmed 2026-10-09).
- The Quest's USB depth connection previously had repeated 230-275 ms
  blocked writes. A larger TCP receive buffer removed those stalls in a
  three-minute USB run. Longer USB testing and Wi-Fi/IPv4 validation remain.
- The Windows PowerShell release script builds a 28.8 MiB zip with EdgePad
  and notices. Its default path fetched and hash-checked ncnn, and the
  extracted zip processed a 360-frame H.264 replay: 352 maps at 120 fps,
  5.4 ms median and 6.4 ms p95 frame-to-map (2026-10-09). An Inno Setup 7
  script builds a 28.9 MiB per-user installer. A silent install/uninstall
  test verified the files and registry entry, and left `meteor.key` intact.
  Windows firewall checking and setup, notifications, no-console startup,
  the Visual C++ prerequisite, and the TensorRT engine-build Job object
  remain.
- Windows VDA download hashes are pinned for the sm86 resource used by the
  RTX 3090. Other NVIDIA GPU resources need signed-file hashes before their
  downloads can be offered.

## Pre-release handoff (2026-10-09)

The 0.1.0 installer is suitable for a small tester pre-release on Windows
10/11 x64 with an NVIDIA GPU, Sunshine-compatible host, and the Microsoft
Visual C++ x64 Redistributable. VB-CABLE is an optional separate install for
microphone use. Quit any portable Meteor before starting the installed copy:
only one instance can own the ports. The installer is per-user, makes Start
menu and uninstall entries, and leaves `%LOCALAPPDATA%\Nightfall Meteor`
(including `meteor.key`, models, and VDA downloads) and the roaming settings
in place on uninstall. It is unsigned and does not add Windows Firewall
rules; accept the private-network prompt when Windows shows one. The
installer is built by `meteor/tools/build_windows_installer.ps1` into
`meteor/target/windows-release/` and was copied to the Windows/Linux share
at `G:\Temp\nightfall-windows-build` for handoff. The copied bytes were
verified against the build with SHA-256.

Before a wider release, test the installed app on a clean Windows PC,
including missing Visual C++ runtime and firewall behavior; test longer USB
and Wi-Fi/IPv4 headset sessions; start Meteor without a console and handle
Windows logoff/shutdown; stop a TensorRT engine-build child when Meteor exits;
and add firewall status/setup, code signing, and published checksums. The
Windows VDA download is currently verified for sm86 only; other NVIDIA GPU
builders need hashes and testing. Notifications and DLL search hardening
remain lower-priority follow-ups.

## Goal

Meteor does on Windows what it does on Linux:
- proxy the stream;
- run host depth on the GPU: EdgePad on Vulkan out of the box, and VDA
  after a download from the tray;
- present the Quest's microphone as a PC microphone;
- show a tray icon.

The Quest app needs no changes; it can't tell which OS Meteor runs on.

## The runtimes, as built on Linux

The Windows release should match the Linux one
([meteor-appimage.md](meteor-appimage.md)):

| | What | Linux | Windows |
| --- | --- | --- | --- |
| EdgePad (default) | ncnn on Vulkan (`ncnn.rs`), `<name>.ncnn.param`/`.bin` | `libncnn.so.1`, 20 MB | `ncnn.dll` from `ncnn-20260526-windows-vs2022-shared.zip` (x64), 13 MB |
| VDA (on request) | Native TensorRT (`tensorrt.rs`, shim `native/tensorrt.cpp`), engines built in a child process | Downloaded from NVIDIA's `manylinux` wheel: 0.4 to 0.55 GB | NVIDIA's `win_amd64` wheel (1.9 GB) has the same files: `nvinfer_10.dll` 193 MB compressed, `nvonnxparser_10.dll` 1.3 MB, builder resources 94 MB (sm75) to 235 MB (sm120). About 0.29 to 0.43 GB per GPU |
| Development only | ONNX Runtime (`onnxruntime` feature) | `target/bench-venv` | `target\bench-venv` (layout below) |

The release builds without the `onnxruntime` feature
(`--no-default-features`).

## Where we start

Most of Meteor is portable. These are the parts that need work, checked
against the code on 2026-10-07:

| Part | Windows today |
| --- | --- |
| Proxy, discovery, depth and mic ports (`proxy.rs`, `discovery.rs`, `depth_server.rs`, `mic.rs`) | **Broken for IPv4.** Every listener binds `::`, relying on Linux's dual-stack default. Windows sockets default to `IPV6_V6ONLY`, so a Quest on IPv4 would reach none of them. Discovery's fallback to `0.0.0.0` would also let a second Meteor start, because the single-instance lock is the discovery port. Fix: bind through `socket2` with `set_only_v6(false)` (already a dependency) |
| Decoding (`nvdec.rs`) | Loads `nvcuda.dll` and `nvcuvid.dll`; NVDEC and CUDA work the same there. Untested |
| Kernels (`kernels/*.ptx`) | Portable: PTX, JIT-compiled by the driver |
| Post-processing (`gpu_post.rs`, `postprocess.rs`) | Portable |
| ncnn (`ncnn.rs`) | Looks for `ncnn.dll` next to the exe, in `../lib`, `target/ncnn/lib`, or on the search path. **Four GPU functions are found by their GCC (Itanium) names, which MSVC's `ncnn.dll` doesn't export.** On Windows they are `?create_gpu_instance@ncnn@@YAHPEBD@Z`, `?get_gpu_count@ncnn@@YAHXZ`, `?get_default_gpu_index@ncnn@@YAHXZ`, `?get_gpu_info@ncnn@@YAAEBVGpuInfo@1@H@Z` and `?device_name@GpuInfo@ncnn@@QEBAPEBDXZ` (checked in the 20260526 DLL). `ncnn.dll` imports the MSVC runtime and `VCOMP140.DLL` (OpenMP) |
| TensorRT shim (`native/tensorrt.cpp`, `build.rs`) | **Doesn't compile on Windows:** `<dlfcn.h>`, `dlopen` and `dlsym`. Needs `LoadLibraryW` and `GetProcAddress`, with `LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR` so `nvinfer_10.dll` finds its builder resource next to it. `build.rs` passes GCC's `-isystem`; MSVC needs `/external:I` (or `.include()`). The `_INTERNAL` factory functions are the same names on both |
| TensorRT lookup (`tensorrt.rs`) | Library names are Linux-only (`libnvinfer.so.10`, `libnvonnxparser.so.10`), and the venv path is the Unix layout. Windows: `nvinfer_10.dll`, `nvonnxparser_10.dll`, and `target\bench-venv\Lib\site-packages\tensorrt_libs` |
| Engine-build child (`tensorrt.rs`) | `--build-tensorrt` in a child process works as is, but it only dies with Meteor on Linux (`PR_SET_PDEATHSIG`). Windows: put it in a Job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` |
| VDA download (`download.rs`) | Pins the Linux wheel and file names. Windows needs the `win_amd64` wheel's URL, sizes, SHA-256s and `.dll` names, and `GetDiskFreeSpaceExW` (today free space isn't checked off Unix). The zip reader handles both: the Windows wheel has no zip64 record. **The Windows wheel's `RECORD` hashes can't be used:** NVIDIA signs the DLLs after writing it. `nvinfer_10.dll` carries a 10,352-byte Authenticode table past `RECORD`'s size (found 2026-10-07; the zip's CRC-32 matched). Pin our own SHA-256s of the signed files instead |
| Data folder (`config.rs`) | `data_dir()` is `%APPDATA%` (roaming) on Windows, so models and the 1 GB TensorRT download would land in the roaming profile. Move it to `%LOCALAPPDATA%\Nightfall Meteor` |
| ONNX Runtime (`onnx/runtime.rs`, development only) | `find_dev_runtime()` and `preload_cuda_libraries()` are Unix-only, as before |
| Shutdown (`main.rs`) | `exit_now()` skips the libraries' exit handlers with `_exit` on Unix (the Linux crash fix). Off Unix it falls back to `std::process::exit`, which runs DLL detach and static destructors: the same race. Use `TerminateProcess(GetCurrentProcess(), code)` after the cleanup. Ctrl+C only (no SIGTERM on Windows) |
| Logging (`logfile.rs`) | Done: `%LOCALAPPDATA%\Nightfall Meteor\meteor.log`, rotated at 5 MB, as well as stderr |
| Single instance (`main.rs`) | The discovery port is the lock, taken before the models load. It works once the dual-stack bind is fixed (above). A named mutex isn't needed |
| Firewall check (`firewall.rs`) | Compiled everywhere, but it queries firewalld and ufw, so on Windows it always reports open. Make it Linux-only, and use Windows Firewall (Phase 4) |
| Autostart and notifications (`desktop.rs`) | Linux-only: `~/.config/autostart` and D-Bus. Windows: the `HKCU\...\Run` key and toast notifications (Phase 4) |
| Tray (`tray.rs`, `ksni`) | Linux-only. The menu has grown: the Model menu with the VDA download offer and progress, the firewall warning and Allow, Start with my computer, Open log. Windows logs "No tray icon on this platform yet" and waits for Ctrl+C |
| Microphone (`mic.rs`) | `VirtualMic::create()` returns "not supported yet"; the receiver, jitter buffer and drift control are portable |
| Packaging | Linux has `tools/build_appimage.sh`. Windows has nothing yet (Phase 4) |

A Windows type-check from Linux (`cargo check --target
x86_64-pc-windows-gnu`, 2026-10-05) stopped at `zstd-sys`, which needs a
Windows C compiler. It now also needs the shim to compile, so do the first
check on Windows.

## Where to develop

Develop and test on Windows. Building can happen on either OS, but every
piece that needs work (DLL loading, NVDEC on the Windows driver, Vulkan,
audio, the tray) can only be tested on Windows.

Windows setup:

1. Rust 1.92.0 with the MSVC toolchain (`rustup`, plus Visual Studio Build
   Tools with the "Desktop development with C++" workload, which also
   compiles the TensorRT shim), and CMake on the path: `audiopus_sys` builds
   libopus from its bundled source for the microphone's Opus decoder
   (2026-10-08). `.cargo/config.toml` sets `CMAKE_POLICY_VERSION_MINIMUM`
   for CMake 4; its lib64 workaround applies to Linux only.
   Meteor's key (`meteor.key`, 2026-10-08) lives in `data_dir()`.
2. NVIDIA driver: `nvcuda.dll`, `nvcuvid.dll` and the Vulkan driver.
3. ncnn: unpack `ncnn-20260526-windows-vs2022-shared.zip` and copy
   `x64\bin\ncnn.dll` into `meteor\target\ncnn\lib\` (`tools/fetch_ncnn.sh`
   does this on Linux; a PowerShell twin is part of Phase 2).
4. The models in `%APPDATA%\Nightfall Meteor\models` (or wherever
   `data_dir()` points after the fix above), copied from the Linux
   machine's `~/.local/share/nightfall-meteor/models`:
   - `zipdepth_wide_512x288.ncnn.param` and `.bin`, the default;
   - the VDA graphs, or let the VDA download fetch them.

   `models/convert_ncnn.py` runs on Windows too, with `pip install pnnx`.
5. TensorRT for VDA, either:
   - a Python 3.12 venv at `meteor\target\bench-venv` with
     `tensorrt-cu13<11`, which Meteor finds in
     `Lib\site-packages\tensorrt_libs` once the lookup is ported; or
   - `tensorrt_dir` in `meteor.toml`; or
   - the VDA download, once ported.

   Add `onnxruntime-gpu` to the venv only to compare with ONNX Runtime.
6. Sunshine (or a fork), streaming to the Quest as usual.
7. VB-CABLE (Phase 3).

Cross-building from Linux is optional, for CI or release builds:
- `cargo-xwin` (the MSVC target; it downloads the Windows SDK and CRT,
  which means accepting Microsoft's licence); or
- `mingw-w64` (the GNU target; it can't link against MSVC's `ncnn.dll`
  import library, but the DLLs are loaded at run time anyway).

Run either in a container, as the AppImage build does.

## Phases

### Phase 1: builds and proxies

- Fix the dual-stack binds (above) on every listener, then check the Quest
  connects over IPv4 and a second Meteor exits.
- Make the TensorRT shim compile on Windows (`LoadLibraryW`,
  `GetProcAddress`, MSVC include flags), so `cargo build --release` works.
  Fix whatever else the build finds.
- `exit_now()` on Windows: `TerminateProcess` after the cleanup.
- Run Meteor in a console with `--no-depth --no-mic`, connect the Quest
  through it, and stream.
- Windows Firewall: allow Meteor's proxy ports and the depth (47901) and
  microphone (47902) ports, for private networks only. For development,
  accept the first-run prompt; the installer adds rules later (Phase 4).

Done when: the Quest streams through Meteor on Windows with no visible
difference from connecting to Sunshine directly.

### Phase 2: host depth

EdgePad on ncnn first, since it's the default and needs only the driver:

- Pick the ncnn GPU function names per platform (the MSVC names above).
- Look for `ncnn.dll` next to the exe (the release layout) and in
  `target\ncnn\lib` (development), and check `VCOMP140.DLL` and the MSVC
  runtime are found.
- Check NVDEC: the decoder log line ("NVDEC: 2560x1440 codec 8 8-bit,
  decoding ..., reduced to 512x288") and
  `nvdec::tests::gpu_reduction_matches_the_cpu`.
- The parity test, `cargo test --release -- --ignored edgepad` with
  `EDGEPAD_TEST_DATA`. Linux: 0.061% mean error, 0.72% worst.
- The replay benchmark on a recorded dump (`--replay <file> --fps 120`).
  Compare with Linux on the RTX 3090: EdgePad on ncnn 5.2 to 6 ms frame to
  map; VDA 5.1 ms.

Then VDA on native TensorRT:

- Port the TensorRT lookup: DLL names, venv path, `tensorrt_dir`.
- Check that the engine-build child finds `nvinfer_10.dll`'s builder
  resource, and that its plan lands in `%LOCALAPPDATA%\Nightfall
  Meteor\tensorrt` and is reused.
- The Job object for the build child; quitting mid-build must leave no
  build process.
- Check whether `nvinfer_10.dll` needs anything beyond the driver. On Linux
  it needs nothing: it links CUDA's runtime statically.
- The VDA parity test (`cargo test --release -- --ignored vda`, with the
  researcher's data). Linux: correlation 0.99995 mean, 0.99965 worst.

Then the VDA download:

- Pin the `win_amd64` wheel (URL, size, and each signed DLL's SHA-256,
  measured ourselves; not `RECORD`'s), chosen by platform in `download.rs`.
  Free space through `GetDiskFreeSpaceExW`. Measured 2026-10-07, checked
  against the zip's CRC-32:
  - `nvinfer_10.dll`
    `73fd99ba7448ebe7b75f3a97bca5fd996f166fa75760f616c0b0eda5c2f7005b`
    (375,812,208 bytes);
  - `nvonnxparser_10.dll`
    `4474757aac9e6abe12b3086fa2ed95f97e93e7b26cc5e89dbada2670842f471e`;
  - `nvinfer_builder_resource_sm86_10.dll`
    `35331ca0164b785b85a9f3d48bb7be1195af9d5ccb760033c0854e133f53b621`.
- Test it end to end, as on Linux (`--download-vda`, then a replay).

Finally `cargo test --release`, and `--quit-after` during a replay and
during an engine build, which must exit cleanly.

Done when: the Quest shows host depth with Depth Sync on (EdgePad out of
the box, VDA after the download), and the replay timings are close to
Linux.

### Phase 3: microphone through VB-CABLE

Windows can't create a microphone without a kernel driver. Writing and
signing our own is out of scope (an EV certificate plus Microsoft's driver
signing). VB-CABLE is free for users to install and is the usual answer:

```text
Meteor ─► WASAPI render (shared mode) ─► "CABLE Input" ─┐
                                                          │ VB-CABLE
apps record from ◄────────────── "CABLE Output" ◄────────┘
```

- Add a Windows `VirtualMic` (`mic.rs`) with the same three methods as Linux:
  - `create()`: finds the "CABLE Input" render endpoint by name through
    `IMMDeviceEnumerator`; returns an error naming VB-CABLE if it isn't
    installed.
  - `write()`: feeds PCM into an `IAudioClient` / `IAudioRenderClient` in
    shared mode, event-driven, with a small buffer (aim for 10-20 ms).
  - `fill()`: reports the endpoint's queued frames
    (`GetCurrentPadding`), so the existing drift control keeps working.
- Use the `windows` crate for WASAPI rather than a cross-platform audio
  library, to keep control of buffer sizes.
- Formats: the Quest sends 48 kHz mono 16-bit; convert to the endpoint's
  shared-mode mix format (usually 48 kHz stereo float).
- Default device: Windows has no public API to change the default recording
  device (only the undocumented `IPolicyConfig`). Don't use it. Instead, the
  tray says which device to choose ("Choose CABLE Output as your
  microphone") and links to the Sound control panel. Apps such as Discord
  can pick CABLE Output directly.
- Not installed: the tray shows "Microphone: install VB-CABLE" with the
  download link; everything else keeps working.
- Measure latency the same way as on Linux (8 ms write to recorder there)
  and listen for crackles under game load.

Done when: Discord or a game hears the Quest's microphone, with latency and
quality comparable to Linux.

Licensing: VB-CABLE is donationware. Users install it themselves. Meteor
doesn't bundle it without a distribution agreement with VB-Audio.

### Phase 4: tray, packaging and startup

Mirror the Linux first-run work ([meteor-appimage.md](meteor-appimage.md),
Phase 4):

- **Tray:** replace `ksni` on Windows with a Win32 tray (the `tray-icon`
  crate, or `Shell_NotifyIconW` through the `windows` crate). It needs its
  own thread with a Win32 message loop.
  - Split `tray.rs` into a shared menu model and per-platform hosts. The
    menu model covers the status lines, the Model menu (with the VDA
    download offer, progress, Cancel and Remove), Rate, smoothing, edge
    softening, the microphone, the firewall warning, Start with my
    computer, Open log, Open settings file and Quit.
  - `icon.rs` already draws RGBA pixels, which become an `HICON`. Use a
    white glyph; the Windows taskbar is dark by default. Consider an
    outlined variant for the light theme later.
- **No console:** build as a Windows-subsystem app
  (`#![cfg_attr(windows, windows_subsystem = "windows")]`); the log file
  already exists. Keep a `--console` flag for development.
- **Notifications:** a toast for "already running" and for a missing tray,
  as `desktop::notify` does on Linux.
- **Shutdown:** handle `WM_QUERYENDSESSION` and `WM_ENDSESSION` (logoff and
  shutdown) through `quit()`, and close the console or Ctrl+C in
  `--console` mode.
- **Start with Windows:** a tray toggle that writes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, turned on once at
  the first run, like the AppImage. It follows the exe if it moves.
- **Firewall:** the installer adds the rules (`netsh advfirewall`, private
  profile). For the zip, the tray checks the rules and offers to add them
  through one elevated `netsh` (UAC prompt), like Linux's `pkexec`.
- **Packaging:** start with a zip, then an Inno Setup or MSIX installer
  that also adds the firewall rules and the Start menu entry. Both build
  from a script like `tools/build_appimage.sh`. Contents:
  - `nightfall-meteor.exe` (no ONNX Runtime);
  - `ncnn.dll`;
  - the MSVC runtime and `vcomp140.dll` next to it (app-local, allowed by
    Microsoft's redistributable terms), or the VC++ Redistributable as an
    installer prerequisite;
  - EdgePad 512 for ncnn;
  - README, LICENSE and THIRD_PARTY_NOTICES (cargo-about, as for the
    AppImage).

  About 30 MB.

Done when: a fresh Windows machine with Sunshine and an NVIDIA driver can
install Meteor, see its tray icon, stream with host depth (and download
VDA) and the microphone, without touching a terminal.

## Decisions

1. **GPU runtime distribution** (decided 2026-10-05, built on Linux
   2026-10-07; see [meteor-appimage.md](meteor-appimage.md)):
   - EdgePad runs on ncnn (Vulkan), shipped with Meteor; the release is
     about 30 MB and needs only the GPU driver.
   - VDA is downloaded from the tray on request: TensorRT's files straight
     from NVIDIA's wheel (only the ones this GPU needs, 0.29 to 0.43 GB
     on Windows) and the VDA graphs from our release. Meteor then builds
     the engines and switches to VDA while EdgePad serves.
   - ONNX Runtime isn't shipped.
   - VDA's files are published (release `meteor-vda-s-518x294`,
     2026-10-08). NVIDIA's answer on fetching the wheel's files this way
     isn't a blocker
     (meteor-appimage.md, Open questions); a Windows installer that
     bundled TensorRT would make it one.
2. **Microphone driver.** VB-CABLE (recommended) or another virtual cable
   (Virtual Audio Cable, VoiceMeeter). The code only needs an endpoint name,
   so supporting a list of known names is cheap.
3. **Default recording device.** Leave it to the user (recommended), or use
   the undocumented `IPolicyConfig` behind an opt-in tray item.

## Risks

| Risk | Mitigation |
| --- | --- |
| DLL search order picks up a different `ncnn.dll`, MSVC runtime or TensorRT from `PATH` (another app's install) | `SetDefaultDllDirectories` plus explicit paths for our DLLs; log the loaded DLL paths at startup, as Linux logs TensorRT's |
| ncnn's C++ names change with its compiler or version | They're pinned with the ncnn version; `ncnn.rs` fails with the missing symbol's name; the version bump checks them |
| Dual-stack sockets behave differently (some adapters, IPv6 disabled) | Bind with `only_v6(false)`, fall back to `0.0.0.0` on failure, and log which one |
| NVDEC behaves differently on the Windows driver (surface limits, pitch) | Phase 2's GPU-vs-CPU reduction test and replay comparison |
| Vulkan interop with a game running (another Vulkan or DX12 app on the GPU) | Measure ncnn timings under game load in Phase 2 |
| WASAPI shared mode adds latency or crackles under load | Event-driven mode, an MMCSS "Pro Audio" thread priority (`AvSetMmThreadCharacteristicsW`), measured in Phase 3 |
| VB-CABLE missing or renamed | Find endpoints by name, accept several known names, and show a clear tray message |
| Antivirus flags an unsigned exe that opens ports, loads DLLs and downloads more | Code-sign release builds; publish hashes; downloads are verified against pinned SHA-256s |
| Firewall blocks the depth or microphone port, so the Quest silently falls back to on-device depth | Installer rules; the tray's firewall check |
