# Nightfall Meteor: Windows

> Status: Planned.
>
> Date: 2026-10-05
>
> Related: [meteor-host-depth.md](meteor-host-depth.md) (host depth),
> [meteor-microphone.md](meteor-microphone.md) (microphone).
>
> Scope: Windows 10/11 x64 hosts with an NVIDIA GPU, running Sunshine,
> Apollo, Vibepollo or Vibeshine. Other GPUs stay out of scope, as on Linux.

## Goal

Meteor does on Windows what it does on Linux: proxy the stream, run host
depth on the GPU, and present the Quest's microphone as a PC microphone, with
a tray icon. The Quest app needs no changes; it can't tell which OS Meteor
runs on.

## Where we start

Most of Meteor was written to be portable, and the Linux-only parts are
switched off elsewhere rather than missing:

| Part | Windows today |
| --- | --- |
| Proxy, discovery, depth port (`proxy.rs`, `discovery.rs`, `depth_server.rs`) | Portable: tokio sockets only |
| Decoding (`nvdec.rs`) | Loads `nvcuda.dll` / `nvcuvid.dll` on Windows; NVDEC and CUDA work the same there. Untested |
| Reduce kernel (`kernels/nv12_to_tensor.ptx`) | Portable: PTX, JIT-compiled by the driver |
| Post-processing (`gpu_post.rs`, `postprocess.rs`) | Portable |
| Model runtime (`onnx.rs`) | ONNX Runtime is loaded at run time (`ort` with `load-dynamic`), so nothing links at build time. Finding the runtime and preloading cuDNN/cuBLAS/TensorRT is Unix-only (`find_dev_runtime()`, `preload_cuda_libraries()`); on Windows it loads nothing |
| Config, models, TensorRT cache (`config.rs`) | Already uses `%APPDATA%\Nightfall Meteor` and `%LOCALAPPDATA%\Nightfall Meteor` |
| Sunshine detection (`config.rs`) | Already looks in `C:\Program Files\{Sunshine,Apollo,Vibepollo,Vibeshine}\config\sunshine.conf` |
| "Open settings file" (`main.rs`) | Uses `explorer` |
| Tray (`tray.rs`, `ksni`) | Linux-only dependency; Windows logs "No tray icon on this platform yet" and waits for Ctrl+C |
| Microphone (`mic.rs`) | `VirtualMic::create()` returns "not supported yet"; the receiver, jitter buffer and drift control are portable |
| Shutdown (`main.rs`) | Ctrl+C only (no SIGTERM on Windows) |

A Windows type-check from Linux (`cargo check --target
x86_64-pc-windows-gnu`, 2026-10-05) stopped only at `zstd-sys`, which needs
a Windows C compiler. No Rust errors were reached, so others may still be
hidden behind it.

## Where to develop

Develop and test on Windows. Building can happen on either OS, but every
piece that needs work (DLL loading, NVDEC on the Windows driver, audio, the
tray) can only be tested on Windows.

Windows setup:

1. Rust with the MSVC toolchain (`rustup`, Visual Studio Build Tools with
   the "Desktop development with C++" workload).
2. NVIDIA driver (provides `nvcuda.dll` and `nvcuvid.dll`).
3. Python 3.12 venv at `meteor\target\bench-venv` with `onnxruntime-gpu` and
   `tensorrt-cu13<11`, as on Linux (see `tools/bench_depth.py`). This is the
   development runtime until Phase 4 decides on distribution.
4. Sunshine (or a fork), streaming to the Quest as usual.
5. VB-CABLE (Phase 3).
6. The models, built with `meteor/tools/make_host_model.py` (it runs on
   Windows) or copied from the Linux machine's
   `~/.local/share/nightfall-meteor/models` into
   `%APPDATA%\Nightfall Meteor\models`.

Cross-building from Linux is optional (for CI or release builds): either
`cargo-xwin` (MSVC target; downloads the Windows SDK and CRT, which means
accepting Microsoft's licence) or `mingw-w64` (GNU target). Run it in a
container rather than installing toolchains on the host.

## Phases

### Phase 1: builds and proxies

- Build `cargo build --release` on Windows; fix whatever the type-check
  didn't reach.
- Run Meteor in a console with `--no-depth --no-mic`, connect the Quest
  through it, and stream.
- Windows Firewall: allow Meteor's proxy ports and the depth (47901) and
  microphone (47902) ports, for private networks only. For development,
  accept the first-run prompt; the installer adds rules later (Phase 4).

Done when: the Quest streams through Meteor on Windows with no visible
difference from connecting to Sunshine directly.

### Phase 2: host depth

- Port `find_dev_runtime()`: on Windows the venv layout is
  `target\bench-venv\Lib\site-packages\onnxruntime\capi\onnxruntime.dll`.
- Port `preload_cuda_libraries()`: instead of `dlopen(RTLD_GLOBAL)`, add each
  `site-packages\nvidia\*\bin` folder and `site-packages\tensorrt_libs` to
  the DLL search path with `AddDllDirectory()` (after
  `SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_DEFAULT_DIRS)`), so the CUDA
  and TensorRT providers find cuDNN, cuBLAS and `nvinfer` when ONNX Runtime
  loads them. Check the folder names in the installed wheels; NVIDIA's
  Windows wheels put DLLs in `bin`, not `lib`.
- Check NVDEC: the decoder log line ("NVDEC: 2560x1440 codec 8 8-bit,
  decoding ..., reduced to 512x288") and `nvdec::tests::gpu_reduction_matches_the_cpu`.
- Run the replay benchmark on a recorded dump (`--replay <file> --fps 120`)
  and compare with Linux: about 3.3 ms frame to map with 512x288 or 672x384
  on the RTX 3090 (2026-10-04).
- Check the TensorRT engine cache lands in `%LOCALAPPDATA%\Nightfall Meteor`
  and is reused on the next start.
- Run `cargo test --release`.

Done when: the Quest shows host depth with Depth Sync on, and the replay
timings are close to Linux.

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

- Tray: replace `ksni` on Windows with a Win32 tray (the `tray-icon` crate,
  or `Shell_NotifyIconW` through the `windows` crate). It needs its own
  thread with a Win32 message loop. Split `tray.rs` into a shared menu model
  (status lines, Model and Rate menus, the microphone item, "Open settings
  file", Quit) and per-platform hosts. `icon.rs` already draws RGBA pixels,
  which become an `HICON`. Use a white glyph; the Windows taskbar is dark by
  default. Consider an outlined variant for the light theme later.
- No console: build as a Windows-subsystem app
  (`#![cfg_attr(windows, windows_subsystem = "windows")]`), and log to
  `%LOCALAPPDATA%\Nightfall Meteor\meteor.log` (rotated) instead of stderr.
  Keep a `--console` flag for development.
- Single instance: a named mutex, so a second launch exits (or shows the
  first one's tray).
- Shutdown: handle `WM_QUERYENDSESSION` and `WM_ENDSESSION` (logoff and
  shutdown), and close the console or Ctrl+C in `--console` mode.
- Start with Windows: a tray toggle that writes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
- GPU runtime distribution (decision needed, see below).
- Installer: start with a zip (`nightfall-meteor.exe`, models, README),
  then an Inno Setup or MSIX installer that also adds the firewall rules
  (`netsh advfirewall`, private profile) and the Start menu entry.

Done when: a fresh Windows machine with Sunshine and an NVIDIA driver can
install Meteor, see its tray icon, and stream with host depth and the
microphone without touching a terminal.

## Decisions to make

1. **GPU runtime distribution** (Phase 4). ONNX Runtime GPU plus cuDNN,
   cuBLAS and TensorRT is roughly 1.5-2 GB of DLLs.
   - Bundle everything: simplest for users, a huge download, and every
     update ships it again.
   - Download on first run: Meteor fetches the pinned runtime (for example
     from the PyPI wheels it already uses) into `%LOCALAPPDATA%`, showing
     progress in the tray. Small installer; needs a network on first run.
   - CUDA only, no TensorRT: drops about 1 GB, but the model takes roughly
     twice as long (still under 2 ms at 512x288).

   Recommendation: download on first run, CUDA first so depth works within
   seconds, with TensorRT fetched in the background and switched to once
   it's built (Meteor already switches CUDA to TensorRT live).
2. **Microphone driver.** VB-CABLE (recommended) or another virtual cable
   (Virtual Audio Cable, VoiceMeeter). The code only needs an endpoint name,
   so supporting a list of known names is cheap.
3. **Default recording device.** Leave it to the user (recommended), or use
   the undocumented `IPolicyConfig` behind an opt-in tray item.

## Risks

| Risk | Mitigation |
| --- | --- |
| DLL search order picks up a different CUDA or cuDNN from `PATH` (another app's install) | `SetDefaultDllDirectories` plus explicit `AddDllDirectory` for our folders; log the loaded DLL paths at startup |
| NVDEC behaves differently on the Windows driver (surface limits, pitch) | Phase 2's GPU-vs-CPU reduction test and replay comparison |
| WASAPI shared mode adds latency or crackles under load | Event-driven mode, an MMCSS "Pro Audio" thread priority (`AvSetMmThreadCharacteristicsW`), measured in Phase 3 |
| VB-CABLE missing or renamed | Find endpoints by name, accept several known names, and show a clear tray message |
| Antivirus flags an unsigned exe that opens ports and loads DLLs | Code-sign release builds; publish hashes |
| Firewall blocks the depth or microphone port, so the Quest silently falls back to on-device depth | Installer rules; the tray shows "no Quest connected to depth" when a stream runs but nobody connects to 47901 |
