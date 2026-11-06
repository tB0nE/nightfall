# Virtual Desktop vs Nightfall — Technical Deep Dive

Decompilation analysis · November 2026 · Working directory: C:\\Users\\Ty\\Development\\VD_decompile

Virtual Desktop 1.33.x Nightfall feat/meteor-xr-streaming Reverse engineered from binary + source

[Overview](#overview) [Protocol & Transport](#protocol) [Encoding Pipeline](#encoding) [OpenXR / SteamVR](#openxr) [Audio](#audio) [Discovery & NAT](#network) [Feature Matrix](#features) [Gaps & Actions](#gaps) [XR Streaming](#xr-streaming) [Game Launch](#game-launch) [Settings](#settings) [Multi-Monitor](#multimonitor)

## Architecture Overview

**Sources:** strings extracted from `VirtualDesktop.Streamer.exe` (SmartAssembly-obfuscated .NET), `libVirtualDesktopAMF.dll`, `driver_VirtualDesktop.dll`, `virtualdesktop-openxr.dll`, `vdvad.inf`; full source of Nightfall Meteor + nightfall-xr extension; Nightfall docs.

#### 🟠 Virtual Desktop — Stack

### Host (Windows only)

C# / .NET 8 WPF SmartAssembly obfuscated SharpDX (D3D11) FFmpeg 7.x (avcodec-61) SteamKit2 Open.Nat UPnP

### Native Components

libVirtualDesktopAMF.dll — custom AMF wrapper VirtualDesktop.Shell.Native.dll — DXGI capture VirtualDesktop.Injector32/64.dll — process injection

### Drivers

vdvad.sys — WDM virtual audio (KS) driver_VirtualDesktop.dll — SteamVR HMD shim virtualdesktop-openxr.dll — custom OpenXR runtime (VDXR by Matthieu Bucchianeri)

### Clients

Meta Quest 2/3/3S/Pro Apple Vision Pro M2/M5 Android (phone/tablet/desktop) iPhone/iPad (H.264/HEVC 10-bit)

#### 🟣 Nightfall — Stack

### Host (Windows + Linux)

Rust (Meteor) — async Tokio ring (crypto/AEAD) Vulkan / DXGI interop NVENC (Windows/Linux) VA-API (Linux/AMD) Sunshine proxy layer

### XR Layer

Monado (bundled, patched) xrizer (OpenVR→OpenXR bridge) Meteor SteamVR driver (new, Windows) C++ nightfall-xr GDExtension

### AI / Depth

ZipDepth ncnn/ONNX/TensorRT GPU depth refinement (Vulkan)

### Clients

Meta Quest 2/3/3S iOS/Android — not yet Vision Pro — not yet

### High-Level Architecture Comparison

| Dimension | Virtual Desktop | Nightfall | Edge |
| --- | --- | --- | --- |
| Host OS | Windows only | Linux + Windows | Nightfall |
| Host language | C# / .NET WPF | Rust (Meteor) + Godot GDScript | Nightfall (memory safety, perf) |
| Obfuscation | SmartAssembly on .NET core | Open source | Nightfall |
| Encryption | "Encrypt local traffic" toggle (optional) | Always-on AEAD (ring) | Nightfall |
| Client platform breadth | Quest + AVP + Android + iOS | Quest only | VD |
| Depth AI | None | ZipDepth ncnn/TensorRT | Nightfall (unique) |
| Capture method | DXGI (SharpDX D3D11) | Vulkan DMA-BUF / DXGI NVENC | Comparable |

## Protocol & Transport

#### 🟠 Virtual Desktop Protocol

Proprietary; partially reconstructed from binary strings and VirtualDesktop.Net namespace.

### Transport

TCP + likely UDP Relay server infrastructure relay_codes / relay_pings DoubleNAT / CGNAT handling

### Key Classes Found

VirtualDesktop.Net.NetMessage VirtualDesktop.Net.VideoCodec VirtualDesktop.Net.TraceRoute VirtualDesktop.Net.UPnPManager ConnectionManager

### Frame-Level

ForceKeyFrame property SkipFrames property BadConnectionMemoryTimeSpan NumDisconnectsToMigrate AccumulatedFrames tracking

#### 🟣 Nightfall / Meteor Protocol

Fully open-sourced NFXR v1 binary protocol over TCP.

### Transport

TCP only (dual-stack IPv4/IPv6) No relay infrastructure yet Encrypted always (AEAD) Allowlist-based authorization

### Message Types

NFXR — video frame (152-byte header) NFXA — per-frame ACK NFXC — clock sync (4-timestamp) NFXO — optics/FOV snapshot NFXP/NFXT — head tracking NFXI/NFXJ — controller input (v1/v2) NFXH — haptic command NFXQ — clean disconnect NFXE — END acknowledgement

### Guarantees

epoch + sequence monotonicity Frozen codec/dims within stream IDR/config NAL validation MAX_FRAMES = 32768 hard limit Explicit END ACK

### Frame Header Comparison (NFXR v1 — 152 bytes)

magic\[4\] "NFXR"

→

version\[2\] = 1

→

header_size\[2\] = 152

→

epoch\[8\]

→

sequence\[8\]

→

frame_id\[8\]

→

display_ns\[8\]

→

payload_len\[4\]

→

width\[2\] height\[2\]

→

codec\[1\] flags\[1\] end\[1\] fps\[1\]

→

reserved\[12\]

→

views\[22×4\] = 88 bytes (2×eye pose+FOV)

| Protocol Aspect | Virtual Desktop | Nightfall | Edge |
| --- | --- | --- | --- |
| Transport layer | TCP + UDP (inferred) | TCP only | VD (UDP = lower latency) |
| Encryption | Optional toggle | Always-on AEAD | Nightfall |
| NAT traversal | UPnP + relay servers (hosted) | Direct only | VD |
| Protocol documentation | Proprietary / obfuscated | Fully spec'd in source + comments | Nightfall |
| Clock sync | Unknown | 4-timestamp exchange (NTP-style) | Nightfall |
| Frame ACKs | AccumulatedFrames tracking (inferred) | Per-frame NFXA ACK with sequence + id | Nightfall |
| Haptic back-channel | Unknown | NFXH with 150ms staleness guard | Nightfall |
| Graceful end | DisconnectReason / ExpectDisconnection | NFXQ + NFXE (dual acknowledgement) | Comparable |

🔵 Gap: Nightfall has no UDP path

VD likely sends video over UDP for lower latency jitter. Nightfall's TCP-only transport adds head-of-line blocking — a single dropped TCP segment stalls delivery until retransmit. For LAN use this is usually fine, but over 5 GHz WiFi with occasional drops, UDP with application-level FEC or selective retransmit would reduce stalls significantly.

🔵 Gap: No relay server

VD maintains hosted relay infrastructure with relay_codes + relay_pings, handling CGNAT and DoubleNAT. Nightfall requires a direct routable path. This is a significant feature gap for users behind CGNAT (mobile hotspot, ISPs without public IPs).

## Encoding Pipeline

#### 🟠 Virtual Desktop Encoding

### GPU Encoder Backends

NVENC (via SharpDX D3D11) AMD AMF (libVirtualDesktopAMF.dll) Intel QSV (inferred from "Hardware Encoder" selector)

### Codecs

H.264 (AVC) — primary H.265 (HEVC) AV1 — including 10-bit Per-codec VR bitrate settings: H264VRBitrate, H264PlusVRBitrate, HevcVRBitrate, AV1VRBitrate

### Post-Processing (.tkb shaders)

Fovea.tkb — eye tracking foveation Foveation.tkb — fixed foveation Sharpening.tkb — post-encode sharpening Supersample.tkb — supersampling

### Capture

DXGI (D3D11) — zero-copy GPU path AcquireNextFrame / AcquireVideoStreamingService Process injection (Injector32/64.dll)

### Notable Settings

Auto Adjust Bitrate (dynamic) Adaptive quantization Fov Stencil (render only visible region)

#### 🟣 Nightfall / Meteor Encoding

### GPU Encoder Backends

NVENC — Linux + Windows (Vulkan/CUDA interop) VA-API — Linux AMD (H.264 Main; HEVC faster) Intel — not yet

### Codecs

H.264 (AVC) H.265 (HEVC) AV1 — not implemented

### Post-Processing

QP-map foveated encoding (NVIDIA only) Vulkan GPU sharpening (via xr_foveation.rs) ZipDepth AI 3D depth (unique feature) Supersampling (client-side)

### Capture (XR path)

Monado's shared eye textures + NVENC SteamVR IVRDriverDirectModeComponent (direct) SteamVR GetMirrorTextureD3D11 (mirror/fallback) Vulkan DMA-BUF (Linux)

### Notable Settings

Live bitrate (NVIDIA only) Foveated encoding QP-map encoder_backend: auto / nvenc / vaapi

### AMD AMF API Wrapper (libVirtualDesktopAMF.dll)

VD ships a custom native AMF wrapper with this exact ABI (from binary export table):

AMFInitialize()

AMFCreateContext()

AMFCreateEncoder()

AMFCreateInputBuffers()

AMFSetBitrate(bitrate)

AMFSetFramerate(fps)

AMFApplyCodec()

AMFGetInputBuffer()

AMFSubmitInput()

AMFTryAcquireOutputBuffer()

AMFFlushEncoder()

AMFReleaseInputBuffers()

AMFReleaseOutputBuffer()

AMFReleaseEncoder()

AMFReleaseContext()

AMFShutdown()

| Encoding Aspect | Virtual Desktop | Nightfall | Edge |
| --- | --- | --- | --- |
| NVENC | ✅ SharpDX D3D11 | ✅ Vulkan/CUDA interop | Comparable |
| AMD GPU encoding | ✅ Custom libVirtualDesktopAMF.dll | ✅ VA-API (Linux); Windows pending | VD (Windows AMD works) |
| Intel GPU encoding | ✅ (inferred — QSV via FFmpeg) | ❌ Not supported | VD |
| AV1 codec | ✅ AV1 + AV1 10-bit | ❌ Not implemented | VD |
| HEVC 10-bit | ✅ (iOS) | ❌ Not implemented | VD |
| Foveated encoding | ✅ Shader-based (.tkb) + eye tracking | ✅ QP-map (NVIDIA only) | VD (eye tracking foveation) |
| Dynamic bitrate | ✅ Auto Adjust Bitrate | ⚠️ NVIDIA only | VD |
| Adaptive quantization | ✅ Adaptive quantization UI option | ❌ Not exposed | VD |
| Depth AI | ❌ None | ✅ ZipDepth ncnn/TensorRT | Nightfall (unique) |
| Encryption of stream | ⚠️ Optional toggle | ✅ Always-on AEAD | Nightfall |

🟠 VD Insight: .tkb shader files for foveation

VD ships Fovea.tkb, Foveation.tkb, Sharpening.tkb, Supersample.tkb — these are likely NVIDIA TensorRT-based or vendor post-processing shaders applied GPU-side before encode. The "Fov Stencil" string suggests they can skip rendering outside the foveal region entirely using an OpenXR eye-tracked stencil mask, which dramatically cuts GPU load on supported headsets (Quest Pro, Quest 3).

🔵 Gap: No AV1 support in Nightfall

AV1 at the same bitrate is 30-50% better quality than H.265, and Quest 3 decodes it in hardware. VD has `AV1VRBitrate` plus separate `AV1 10-bit` support. Adding AV1 via NVENC (Ada/RTX40 series) or VA-API would significantly improve quality at constrained bitrates.

## OpenXR & SteamVR Runtime Strategy

#### 🟠 Virtual Desktop Runtime Architecture

### OpenXR Runtime (VDXR)

- Custom proprietary OpenXR runtime: `virtualdesktop-openxr.dll`
- Author: Matthieu Bucchianeri (MIT 2022) — same as OpenXR-Toolkit
- Registered as "VirtualDesktopXR (Bundled)"
- Ships as both 32-bit and 64-bit DLLs
- Likely implements: hand tracking, eye tracking, passthrough, foveation extensions

### SteamVR Driver (OpenVR)

- **Shim architecture:** CHMDShimDriver wraps whatever SteamVR HMD is registered
- CHandSkeletonShimDriver — hand skeleton input shim
- CBodyJointTrackerDriver — body tracking
- CDriverDataWatcher — shared memory/IPC with Streamer process
- Supports Index Controller emulation
- Eye tracking: `Headset supports eyetracking, CreateEyeTrackingComponent`
- **Key:** `alwaysActivate: true` + `redirectsDisplay: true`
- PDB path: `D:\VirtualDesktop\Applications\VirtualDesktop\VirtualDesktop.OpenVRDriver\`

#### 🟣 Nightfall Runtime Architecture

### OpenXR Runtime (Linux)

- Bundled **Monado** (patched, managed install)
- Bundled **xrizer** for OpenVR→OpenXR translation
- Meteor manages install/enable/restart with integrity checks
- One-time headset authorization (allowlist, approval/reject notification)

### SteamVR Driver (Windows — new)

- **Native architecture:** Full HMD + Touch controller driver (not a shim)
- IVRDriverDirectModeComponent for direct frame capture
- IVRVirtualDisplay fallback (compositor mirror)
- Meteor tracking/optics/haptics over existing XR lanes
- Private session config (no global SteamVR pollution)
- Job object ownership for clean process tree
- Quest Touch/Touch Plus grip→raw origin correction (Rx +20.6°)

### Windows xrizer (OpenXR games)

- Works for Moss and other games not using EAC
- VRChat EAC rejects unsigned DLLs (blocked)
- Requires trusted code signing or VRChat support approval

| Runtime Aspect | Virtual Desktop | Nightfall | Edge |
| --- | --- | --- | --- |
| Windows OpenXR | ✅ Custom VDXR (bundled, proprietary) | ✅ xrizer + Monado (Windows) | VD (more polished, eye tracking) |
| Linux OpenXR | ❌ Windows only | ✅ Monado (bundled, managed) | Nightfall |
| SteamVR (OpenVR games) | ✅ Shim driver (always active) | ✅ Native driver (Windows, new) | Comparable (different approach) |
| VRChat (EAC-protected) | ✅ Works via SteamVR shim | ⚠️ SteamVR backend works; direct xrizer blocked by EAC | VD |
| Eye tracking foveation | ✅ Fovea.tkb + EyeTrackingComponent | ❌ Not implemented | VD |
| Body tracking | ✅ CBodyJointTrackerDriver | ❌ Not implemented | VD |
| Hand skeleton | ✅ CHandSkeletonShimDriver | ❌ Not in current release | VD |
| Runtime transparency | Proprietary VDXR (closed) | Open source Monado fork | Nightfall |
| Apple Vision Pro | ✅ M2 + M5 | ❌ Not supported | VD |

🟠 VD Insight: Shim driver = always-works, but limited

VD's SteamVR driver uses `alwaysActivate: true` and a "shim" design: CHMDShimDriver intercepts whatever HMD SteamVR has registered. This means VD works with any SteamVR setup, including one with an existing VR headset connected. The tradeoff is they don't own the render path — they read the compositor output via shared memory. Nightfall's native driver owns the render path end-to-end (IVRDriverDirectModeComponent), giving better pose/frame timing correlation but requiring SteamVR to be started fresh.

## Audio Subsystem

#### 🟠 Virtual Desktop Audio

### Virtual Audio Driver

- **vdvad.sys** — WDM KS Wave Extensible virtual audio device
- Installed as kernel driver (WHQL-signed, DigiCert)
- KSCATEGORY_AUDIO category
- ARM64, x64, IA64 support
- Driver version: 1.6.1.0 (2022-01-28)

### Audio Routing

- VoiceMeeter mode (audio mixer integration)
- Auto-select microphone
- Private SteamVR audio config: disables OS playback/recording override
- CSCore library (Ms-PL) for audio capture
- AAC encoder (AacEncoder in strings)
- "Enable this option if you experience issues streaming audio"

### Audio Codec

AAC (custom AacEncoder) AACProfile_L2/L4/L5 (MPEG-4)

#### 🟣 Nightfall Audio

### Current State

- Desktop stream audio via **Sunshine connection** (existing path)
- No independent XR audio transport
- Microphone via Meteor mic.rs (Opus 48 kHz mono + PCM 16-bit fallback)
- Quest audio confirmed working (desktop volume at 2% was root cause of earlier silence)
- VRChat world audio confirmed after volume correction

### Audio Codec

Opus 48 kHz mono (mic) PCM S16LE 48 kHz (mic fallback) Desktop audio — Sunshine path

### XR Audio Gap

- XR mode relies on retaining Sunshine connection for audio
- No virtual audio driver — requires Windows USB speaker to be at sufficient volume
- "An independent XR audio transport is optional future work"

🔵 Gap: Nightfall has no virtual audio driver

VD installs `vdvad.sys` — a kernel-mode virtual audio device that creates a loopback endpoint. This means any game that plays audio outputs to VD's virtual device automatically, which VD then encodes and streams. Nightfall depends on Sunshine capturing the existing default audio endpoint. Building even a simple WASAPI loopback capture (no kernel driver needed) feeding Opus into the existing mic transport would solve the XR standalone audio gap.

## Discovery & NAT Traversal

#### 🟠 Virtual Desktop Network

### Discovery

- Unknown mechanism (likely mDNS / Bonjour or broadcast)
- AllowRemoteConnections toggle (LAN vs internet)
- PCEthernetConverter — USB NCM ethernet adapter detection

### NAT Traversal

- **Open.Nat** library: UPnP + NAT-PMP port mapping
- UPnPManager, PmpNatDevice — both protocols
- Hosted relay server infrastructure (relay_codes + relay_pings)
- CGNAT handling, DoubleNAT detection
- PublicIP / PrivateIP / InternalPort / ExternalPort fields
- IPCountryCode — geo-based relay selection

### USB Link (NCM)

NcmDriverManager IsUsb property PCEthernetConverter

#### 🟣 Nightfall Network

### Discovery

- **HTTP GET** `http://<host>:47900/meteor`
- Returns JSON: service, version, protocol, mode, ports, features
- Advertises: key, mic_port, xr_port, depth, host info
- DISCOVERY_BELOW_BASE = 89 (port 47900 = 47989 - 89)
- No multicast/mDNS — user manually enters host IP

### NAT Traversal

- No relay infrastructure
- No UPnP/NAT-PMP
- Direct TCP only
- Firewall rules managed by meteor/src/firewall.rs

### USB Link

Not explicitly supported (ADB forward used in dev)

| Network Aspect | Virtual Desktop | Nightfall | Edge |
| --- | --- | --- | --- |
| Host discovery | Auto (mDNS/broadcast inferred) | Manual HTTP probe (port 47900) | VD |
| NAT traversal | UPnP + NAT-PMP + relay servers | None (direct only) | VD |
| CGNAT/DoubleNAT | ✅ Handled via relay | ❌ No solution | VD |
| USB direct link | ✅ NCM driver (vdvad+NCM) | ⚠️ ADB forward (dev only) | VD |
| Discovery transparency | Opaque | Open JSON HTTP spec | Nightfall |
| Multi-host support | Unclear | ✅ Port offset per-host | Nightfall |

## Feature Matrix

| Feature | Virtual Desktop | Nightfall | Notes |
| --- | --- | --- | --- |
| Codecs |  |  |  |
| H.264 (AVC) | ✅ | ✅ |  |
| H.265 / HEVC | ✅ | ✅ |  |
| AV1 | ✅ incl. 10-bit | ❌ | Quest 3 HW decode; big quality win |
| HEVC 10-bit (iOS) | ✅ | ❌ | VD iPhone/iPad support |
| GPU Encoder Support |  |  |  |
| NVIDIA NVENC | ✅ (D3D11) | ✅ (Vulkan/CUDA) |  |
| AMD AMF (Windows) | ✅ (custom DLL) | ❌ | Nightfall AMD is Linux VA-API only |
| Intel QSV | ✅ (inferred) | ❌ |  |
| Image Quality |  |  |  |
| Foveated encoding | ✅ Eye-tracked + fixed | ✅ QP-map (NVIDIA) | VD supports eye tracking |
| Sharpening | ✅ Shader (.tkb) | ✅ GPU pass |  |
| Supersampling | ✅ Shader (.tkb) | ✅ Client-side |  |
| Adaptive quantization | ✅ | ❌ Not exposed |  |
| HDR streaming | ⚠️ "Improves color accuracy" toggle | ❌ |  |
| AI 3D Depth | ❌ | ✅ ZipDepth (unique) | Nightfall's differentiating feature |
| Input & Tracking |  |  |  |
| Controller tracking | ✅ Full (via SteamVR/VDXR) | ✅ Full (Quest tracking) |  |
| Haptic feedback | ✅ | ✅ NFXH with staleness guard |  |
| Hand tracking / skeleton | ✅ CHandSkeletonShimDriver | ❌ |  |
| Body tracking | ✅ CBodyJointTrackerDriver | ❌ |  |
| Eye tracking | ✅ For foveation | ❌ |  |
| Gamepad emulation | ✅ ViGEm (GamepadEmulation) | ❌ | VD maps Quest controllers to Xbox gamepad |
| Index Controller emu | ✅ (OpenVR driver) | ❌ |  |
| Platform & Compatibility |  |  |  |
| VRChat (EAC) | ✅ Via SteamVR shim | ⚠️ SteamVR backend works; not fully shipped |  |
| Apple Vision Pro | ✅ M2 + M5 | ❌ |  |
| Android clients | ✅ Phone/tablet/desktop | ❌ |  |
| iOS/iPadOS | ✅ | ❌ |  |
| Linux host | ❌ | ✅ |  |
| UX / QoL |  |  |  |
| Auto discovery | ✅ | ❌ Manual host IP |  |
| Relay (internet play) | ✅ Hosted relay servers | ❌ |  |
| USB direct link | ✅ NCM driver | ❌ |  |
| Virtual audio driver | ✅ vdvad.sys (kernel) | ❌ Via Sunshine only |  |
| Open source | ❌ | ✅ |  |
| Encryption (always-on) | ❌ Optional | ✅ AEAD |  |
| Boost game priority | ✅ | ❌ |  |
| Lock PC on disconnect | ✅ | ❌ | Security feature |

## Key Gaps & Recommended Actions

Prioritized by user impact. VD-superior approaches that Nightfall should close.

### High Priority

1

UDP / QUIC Transport for XR Video

VD uses UDP for video delivery. Nightfall's TCP transport causes head-of-line blocking on WiFi packet loss — a single dropped packet stalls the entire stream until retransmit. Adding a UDP path with sequence-number frame-skip (or QUIC for per-stream HOL isolation) would eliminate this. The NFXR protocol already has sequence numbers; UDP framing is the missing piece. Tracking/control can stay on TCP.

2

Windows AMD GPU Encoding (AMF)

VD ships `libVirtualDesktopAMF.dll` — a minimal native wrapper around AMD's AMF SDK with 16 exported functions. Nightfall supports AMD on Linux via VA-API but Windows AMD users have no encoder. AMD's Windows GPU market share is \~25–30%, making this the largest encoder coverage gap.

3

Steam Game Library + One-Click Launch from Quest

VD's `GameManager` + SteamKit2 lets users browse and launch VR games directly from the headset. Nightfall requires alt-tabbing to a PC window. A minimal fix: expose the Steam library via the discovery endpoint so the Quest client can render a launcher panel, plus a pre-launch check for conflicting OpenXR runtimes.

### Medium Priority

4

Zero-Config Auto-Discovery (mDNS)

VD auto-discovers the PC on the LAN; Nightfall requires the user to enter the PC's IP manually. Adding mDNS (Avahi on Linux, Bonjour/dns-sd on Windows) so the Quest can find the host without an IP removes the most common first-launch friction. The discovery HTTP endpoint is already well-designed — only the zero-config probe is missing.

5

Auto-Viewport Detection (Follow Game Across Monitors)

VD's `AutoViewportFromRenderTargets` reads which DXGI output the game rendered to and switches the VR viewport automatically. Moving a game window from monitor 1 to monitor 2 is seamlessly followed in the headset. Nightfall currently requires manual monitor selection. Query the game window's HWND → DXGI output index and emit it on the control channel.

6

Relay Server for CGNAT / Internet Play

VD maintains hosted relay servers for CGNAT/DoubleNAT traversal. For an open-source project the equivalent is a self-hostable relay (simple TCP/UDP forwarder) that users can point Nightfall at, combined with UPnP/NAT-PMP. Required for users on mobile hotspots or ISPs with CGNAT.

### Lower Priority / Nice to Have

7

Virtual Display Driver (Headset-Only Resolution)

VD's `IsVirtual` flag creates a virtual display without a physical monitor, at headset-native resolution (e.g. 2064×2208 per eye). Users with a single physical monitor can still have an independent VR desktop. An IddSampleDriver-style minimal display driver on Windows would cover this.

8

USB NCM Direct Link (Replace ADB Forwarding)

VD's `NcmDriverManager` creates a USB NCM (Network Control Model) virtual ethernet adapter — the Quest appears as a network device at \~400 Mbps, with a full IP stack. Nightfall currently uses ADB port forwarding which is per-port and requires USB debugging enabled. NCM would work for all users without WiFi and doesn't require developer mode.

### Where Nightfall is Demonstrably Better

🟣 Nightfall Advantages

- **AI 3D depth** (ZipDepth ncnn/TensorRT) — no competitor has this; genuine depth in the virtual world
- **Protocol robustness** — NFXR's explicit epoch/sequence monotonicity, 4-timestamp clock sync, per-frame ACK, and dual END acknowledgement are more rigorous than anything visible in VD
- **Security architecture** — always-on AEAD encryption, one-time headset authorization, allowlist model; VD's encryption is an optional toggle
- **Linux host support** — VD is Windows-only on the streaming side
- **Open source** — community contribution, auditability, no lock-in
- **SteamVR driver accuracy** — Nightfall owns the render path (direct mode); VD uses a shim that reads compositor output. Nightfall's pose/FOV metadata travels with the exact frame that encoded it
- **Multi-host support** — per-host port offsets mean two hosts on the same LAN work without conflict

## XR Streaming — Deep Dive

**Evidence:** `driver_VirtualDesktop.dll` class names, `VirtualDesktop.Streamer.exe` backing fields (`DisableRenderPose`, `ForceKeyFrame`, `ClientStreaming`, `ServerStreaming`, `H264VRBitrate` etc.), `virtualdesktop-openxr.json`, Nightfall `pcvr_meteor_receiver.cpp` + `xr_relay.rs`.

### VD XR Streaming Pipeline

VR Game (OpenXR/OpenVR)

→

VDXR / CHMDShimDriver

→

CDriverDataWatcher shared mem

→

VideoStreamer (FFmpeg + AMF/NVENC)

→

UDP transport

→

Quest HW decode → display

#### 🟠 VD — Two Interception Points

### OpenXR path (VDXR)

`virtualdesktop-openxr.dll` (by Matthieu Bucchianeri, same author as OpenXR-Toolkit) is registered as the active OpenXR runtime. It intercepts `xrBeginFrame`/`xrEndFrame` and passes stereo eye textures directly to the Streamer — no SteamVR compositor involved. Gives VD the lowest-latency path and works with EAC games because VDXR is a properly signed native DLL.

### OpenVR / SteamVR path (shim)

`CHMDShimDriver` wraps the existing SteamVR HMD. `CDriverDataWatcher` reads frames from shared memory written by the Streamer. `alwaysActivate:true` + `redirectsDisplay:true` means SteamVR hands rendering entirely to VD without needing a physical display.

### Key XR properties found

DisableRenderPose — disable ATW reprojection ForceKeyFrame — force IDR on demand AllowMotionExtrapolation Phase / TargetElapsedTime — frame timing sync ClientStreaming / ServerStreaming — stream state flags

### Per-codec VR bitrate

H264VRBitrate H264PlusVRBitrate HevcVRBitrate AV1VRBitrate

Each codec has its own VR-specific bitrate setting separate from the desktop streaming bitrate — VR encode budgets are tuned independently.

#### 🟣 Nightfall — XR Pipeline

### Capture (Windows)

Meteor SteamVR driver (`driver_meteor.dll`) implements `IVRDriverDirectModeComponent` (direct mode) or mirror sampling. Direct mode: the driver owns the render target — games render directly into Meteor's texture, bypassing the SteamVR compositor entirely. The pose + FOV sent in the NFXR frame header matches exactly the frame that was encoded.

### Transport

NFXR frames travel over **TCP** (encrypted AEAD, 152-byte binary header). Control channel (NFXC clock sync, NFXO optics, NFXP/NFXI/NFXJ tracking, NFXH haptics) is a separate TCP stream on port 47912. IO timeout: 5 seconds (`xr_relay.rs`).

### Quest decode

Android MediaCodec (Qualcomm hardware, `pcvr_meteor_receiver.cpp`). Binds loopback :49090, 2-second input timeout, AHardwareBuffer GPU-sampled output. Sends NFXA ACK per frame. H.264 and H.265 only (Nightfall's NVENC backend).

### Tracking

NFXP head (7 floats: pos + quat), NFXI/NFXJ controllers (flags, trigger, squeeze, sticks, buttons, 14 pose floats), NFXH haptics (150ms staleness guard). 250ms staleness guard on tracking delivery.

### Transport: TCP vs UDP — The Critical XR Question

| Aspect | VD (UDP inferred) | Nightfall (TCP confirmed) | Impact |
| --- | --- | --- | --- |
| Protocol | UDP (UPnP maps UDP port; relay uses UDP; `udpClient` present) | TCP (NFXR over encrypted TCP, `xr_relay.rs`) | Architecture difference |
| WiFi packet loss | Skip stale frame, decode next — sub-millisecond recovery | Head-of-line block until retransmit — visible stutter | **High impact on 2.4 GHz / congested WiFi** |
| Ordering | Receiver handles out-of-order; IDR on request | TCP guarantees ordering (no jitter from reorder) | Lower code complexity |
| Encryption | Optional (EncryptLocalTraffic setting) | Always-on AEAD (ring) | Nightfall wins |
| Bitrate adaptation | AutoAdjustBitrate — feedback loop from Quest | Not yet implemented on Windows (live_bitrate=false) | VD wins |

Action: Switch XR video to UDP or QUIC

TCP is the single biggest XR transport risk. On a lossy WiFi channel VD skips stale frames immediately; Nightfall's TCP path stalls the entire stream until retransmit. The fix is UDP with a jitter buffer + frame skip on timeout, or QUIC (which has per-stream HOL isolation). The tracking/control channel can remain TCP — it's low-bandwidth and reliability matters there.

## Game Launching

**Evidence:** namespace strings `VirtualDesktop.Streamer.GameManager`, `AppsCheckerManager`, `AppsCheckerWindow`; backing fields `OpenVRSupport`, `OpenXRSupport`, `LaunchParameters`, `LaunchType`, `BannedApps`, `BannedGameId`, `OculusExperienceNames`; UI strings `Boost game priority`, `Check for interfering apps`, `Doesn't require a restart of game or SteamVR to take effect`; SteamKit2 integration.

#### 🟠 VD — Game Launch Flow

1. **Library scan** — SteamKit2 enumerates installed Steam apps; `OculusExperienceNames` handles Meta Store games
2. **Support detection** — Each game tagged with `OpenVRSupport` and/or `OpenXRSupport` (from Steam manifest + heuristics)
3. **Pre-flight check** — `AppsCheckerManager` calls `CheckForProblemApps`; shows `AppsCheckerWindow` if conflicting software found (e.g. Oculus runtime, conflicting OpenXR runtime, VAC-conflicting injectors)
4. **Runtime registration** — VD registers VDXR as the active OpenXR runtime in the Windows registry before launch
5. **Launch** — `GameManager` builds `LaunchParameters` per `ELauncherType` (Steam, direct .exe, etc.) and starts the process
6. **Priority boost** — `Boost game priority` sets the game process to HIGH priority (reduces CPU scheduling latency)
7. **Dynamic settings** — `DynamicSettings` class applies live-reloadable settings; label: *"Doesn't require a restart of game or SteamVR to take effect"*

#### 🟣 Nightfall — Current Game Launch

Nightfall's Windows XR session config (`xr_session_windows.rs`) covers the runtime side. Game launch itself is currently manual — the user launches the game and Nightfall's driver is registered:

- Meteor SteamVR driver is registered as an additionalDriver (private session config, no global SteamVR pollution)
- No integrated game library or one-click launch from the Quest headset
- No automated conflicting-app detection
- No process priority boost
- Job object process ownership (clean kill on disconnect)

### VRChat / EAC specifics

VD's VDXR passes EAC because it's a signed native DLL registered as OpenXR runtime. xrizer's `vrclient_x64.dll` (used by Nightfall's Linux path) is unsigned — EAC rejects it. Nightfall's native SteamVR driver (`driver_meteor.dll`) is the production path and avoids this issue on Windows. VRChat tested: 3,374 frames in one Quest session, 71.42 received fps / 67.66 projected fps.

### Banned / Problem Apps Detection

| VD mechanism | Purpose | Nightfall equivalent |
| --- | --- | --- |
| `BannedApps` / `BannedGameId` | Block apps known to cause conflicts (e.g. Oculus runtime interfering with VDXR) | None — user must manually close conflicts |
| `CheckForProblemApps` → `AppsCheckerWindow` | Pre-launch scan with user-visible warning dialog | None |
| `BannedIp` / `BannedPort` | Network-level ban (unusual — may be for firewall conflict detection) | Allowlist model (no ban list) |
| `OtherVRSupport` (inferred) | Detect non-Steam, non-Oculus VR launchers | Not implemented |

Action: Add game library + one-click launch from Quest

The biggest UX gap. VD lets users browse and launch Steam VR games directly from the headset. Nightfall requires the user to alt-tab to a PC window. A minimal fix: expose the Steam library via the discovery endpoint so the Quest client can render a launcher panel. Add a pre-launch check for known conflicting OpenXR runtimes (Oculus, SteamVR as active runtime).

## VD Settings — Complete Breakdown

**Method:** C# auto-property backing fields (`<Prop>k__BackingField`) survive SmartAssembly obfuscation and reveal every property name in the data model. UI label strings extracted separately. 2,935 properties total; below are the VR/streaming-relevant ones.

### Video & Encoding

| Setting | Type / Values | Notes |
| --- | --- | --- |
| `H264VRBitrate` | int (Mbps) | Bitrate when H.264 codec selected for VR games |
| `H264PlusVRBitrate` | int (Mbps) | H.264+ (high-bitrate H.264 profile) for VR |
| `HevcVRBitrate` | int (Mbps) | HEVC/H.265 VR bitrate |
| `AV1VRBitrate` | int (Mbps) | AV1 VR bitrate (Quest 3 HW decode) |
| Auto Adjust Bitrate | bool | Feedback loop from Quest to Streamer; label: *"Automatically adjust bitrate"* |
| Adaptive quantization | bool | Per-block QP variance; reduces block artifacts in uniform regions |
| Additional sharpening | enum/slider | Post-encode sharpening filter (`Sharpening.tkb` shader on Quest) |
| Hardware Encoder | enum: NVENC / AMF / QSV | Via `VideoCodecProvider`; AMD uses `libVirtualDesktopAMF.dll` |
| Preferred Codec | H.264 / H.265 / AV1 / AV1 10-bit | `VideoCodecProvider` selector; AV1 10-bit is Quest 3 only |
| `DisableRenderPose` | bool | Disables ATW/reprojection pose injection — use if head-tracking causes nausea with reprojection |
| `ForceKeyFrame` | bool / trigger | Force IDR keyframe (useful when stream corrupts) |
| `PreferredGraphicsProfile` | enum | GPU profile hint for encoder selection |
| `CaptureType` | enum | Desktop capture method (DXGI duplication, GDI, etc.) |

### Display & Multi-Monitor

| Setting | Type / Values | Notes |
| --- | --- | --- |
| `AllowMultiMonitor` | bool | Enable multi-monitor support |
| `DefaultViewport` | int (monitor index) | Which monitor to show in VR by default |
| `AutoViewportFromRenderTargets` | bool | Auto-detect which monitor the game is rendering to; switch VR viewport automatically |
| `BottomFrames` / `TopFrames` | int | Viewport slicing — number of frames at bottom/top of combined frame; used for multi-monitor layout |
| `DisplayFrequency` | int (Hz) | Target display refresh rate |
| `IsVirtual` | bool | Virtual display (create a headset-only display without a physical monitor) |
| `PrefferedFullScreenOutputIndex` | int | Which DXGI output adapter to prefer for fullscreen |

### Audio

| Setting | Notes |
| --- | --- |
| Use virtual audio driver | Installs/enables `vdvad.sys` (WDM KS Wave virtual device); required for audio-over-VR |
| VoiceMeeter mode | Compatibility mode when VoiceMeeter is active on the system (avoids WASAPI conflicts) |
| Enable this option if you experience issues streaming audio | Fallback audio streaming mode |

### Network & Security

| Setting | Notes |
| --- | --- |
| `AllowRemoteConnections` | Allow connections from outside the LAN (via relay servers); off = LAN-only |
| Encrypt local traffic | AEAD encryption for LAN connections (off by default — Nightfall always-on) |
| Lock computer on disconnect | Lock Windows session when headset disconnects |

### Game & App Settings

| Setting | Notes |
| --- | --- |
| Boost game priority | Sets VR game process to HIGH CPU priority; reduces frame time variance |
| `OpenVRSupport` / `OpenXRSupport` | Per-game flags; determines whether VD uses VDXR or the SteamVR shim path |
| Check for interfering apps | AppsCheckerManager pre-launch scan; `BannedApps` list |
| OpenXR runtime selector | `OpenXRRuntimeProvider` — switch between VDXR (bundled) and system-default runtime |
| Doesn't require restart | `DynamicSettings` — applied live; contrast with settings that need a full SteamVR restart |

### Other

| Setting | Notes |
| --- | --- |
| Fov Stencil | Apply an FOV stencil (black out peripheral pixels); saves encode bandwidth; enabled on Quest 3 with eye tracking + fixed fovea |
| Gamepad emulation | `GamepadEmulationProvider` — ViGEm virtual Xbox controller; lets VR controllers emulate gamepad for non-VR games |
| Shortcut editor | `ShortcutEditor` — rebind keyboard shortcuts (e.g. toggle passthrough, recenter, screenshot) |
| `AllowScreensavers` | Allow Windows screensaver while streaming |
| Screenshots folder | VR screenshots auto-copied to configured folder |

## Multi-Monitor Handling

**Evidence:** VD backing fields `AllowMultiMonitor`, `DefaultViewport`, `AutoViewportFromRenderTargets`, `BottomFrames`, `TopFrames`, `IsVirtual`, `HasSwitchedMonitor`; Nightfall: modified Vibepollo host (monitor stitching confirmed by user).

#### 🟠 VD — Multi-Monitor Architecture

### Capture

VD uses DXGI Output Duplication per monitor (via `VirtualDesktop.Shell.Native.dll`). Each `IDXGIOutput` is captured independently, giving per-monitor control over resolution, refresh rate, and HDR state.

### Viewport model

`BottomFrames` and `TopFrames` imply vertical slicing of a combined frame — monitors are stacked vertically in the encoded stream, with metadata telling the Quest client how many rows belong to each display. `AutoViewportFromRenderTargets` reads the game's D3D render targets to auto-detect which DXGI output the game rendered to, then switches the active VR viewport automatically — so moving a game window from monitor 1 to monitor 2 is seamlessly followed in VR.

### Virtual display

`IsVirtual` flag enables a virtual display driver — creates a headset-only resolution (e.g. 2064×2208 per eye) without needing a physical monitor. Users with a single monitor can still have an independent VR desktop.

### Switching

`HasSwitchedMonitor` + `DefaultViewport` handle the case where the user manually picks a monitor from the Quest. The switch is signalled back to the Streamer which adjusts the active capture source.

#### 🟣 Nightfall — Monitor Stitching

### Modified Vibepollo host

Nightfall uses a modified version of the Vibepollo host that captures each physical monitor and stitches them horizontally into a single wide frame before passing to the Sunshine encode pipeline. The Quest client divides the frame horizontally by monitor count to reconstruct per-monitor viewports in VR.

### Tradeoffs

- **Single encode** — one encoder run for all monitors; simpler pipeline, no per-monitor bitrate budget splitting
- **Lower latency** — no per-monitor synchronisation overhead
- **Fixed horizontal layout** — monitors must be arranged left-to-right; vertical stacking not supported
- **No auto-viewport** — no equivalent of `AutoViewportFromRenderTargets`; user must manually pick the monitor in VR
- **No virtual display** — requires a physical monitor per display slot
- **Wide frame encoding** — a 3×1920 wide stitched frame may exceed encoder limits or force downscaling

### Direct Comparison

| Capability | VD | Nightfall | Winner |
| --- | --- | --- | --- |
| Multi-monitor support | Yes (`AllowMultiMonitor`) | Yes (Vibepollo stitch) | Tie |
| Layout flexibility | Vertical stacking (BottomFrames/TopFrames) | Horizontal stitch only | VD |
| Auto-viewport detection | `AutoViewportFromRenderTargets` | Not implemented | VD |
| Virtual display | Yes (`IsVirtual`) | Not yet | VD |
| Encode overhead | Per-monitor (multiple encode runs) | Single wide frame encode | NF |
| Complexity | High (per-output capture + compositor) | Low (single stitched texture) | NF |

Action: Add AutoViewportFromRenderTargets equivalent + virtual display

The two highest-value gaps: (1) **Auto-detect which monitor the game is on** — query DXGI output index of the game window's HWND and emit it in the discovery/control channel so the Quest client follows automatically. (2) **Virtual display driver** — a minimal Windows display driver (IddSampleDriver style) would let users without a second monitor create a headset-resolution virtual desktop. VD's `IsVirtual` path suggests they have exactly this.