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
> Scope: Windows 10/11 x64 hosts with an NVIDIA GPU, running Sunshine,
> Apollo, Vibepollo or Vibeshine. Other GPUs stay out of scope, as on Linux
> (decoding is NVDEC).

## Current Windows status (2026-10-09)

- The Windows release exe proxies a Quest 3 stream and runs EdgePad on ncnn
  and VDA on TensorRT. VDA's 75-frame parity test passed. A fresh download
  of the VDA graphs and NVIDIA's Windows DLLs passed SHA-256 verification;
  after a first engine build, the 1440p replay made 3775 maps from 3796
  frames at 120 fps, with 6.2 ms median and 7.3 ms p95 frame-to-map latency.
- The Windows tray has the Nightfall icon, model, rate, smoothing, edge
  softening, microphone, VDA download/progress/cancel/remove, autostart and
  basic stream status controls. VB-CABLE output and an isolated tone test
  work; a real headset-microphone application test remains.
- The Quest's USB depth connection previously had repeated 230-275 ms
  blocked writes. A larger TCP receive buffer removed those stalls in a
  three-minute USB run. Longer USB testing and Wi-Fi/IPv4 validation remain.
- The current Windows build is a folder of manually placed files, not an
  installer. Windows firewall checking and setup, notifications, no-console
  startup, packaging, and the TensorRT engine-build Job object remain.
- Windows VDA download hashes are pinned for the sm86 resource used by the
  RTX 3090. Other NVIDIA GPU resources need signed-file hashes before their
  downloads can be offered.

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
