# Native Windows VRChat rejects an external xrizer OpenVR runtime

Draft for Windows xrizer maintainers / VRChat support. Not submitted.
Date: 2026-11-04.

## Problem

We are developing a PCVR streaming host, Meteor, with a Monado OpenXR runtime
and a Quest client, Nightfall. Our direct OpenVR compatibility path uses xrizer.
The native Windows path works with Moss, including actual headset play, but
VRChat cannot initialize OpenVR with this external runtime selected.

We want a supported runtime integration with anti-cheat enabled. VRChat's
protected launcher, executable, Unity plugins and original Valve OpenVR API
DLL are unchanged. No debugger, process injection, or game-file replacement is
used in the reproduction.

## Exact rejection

Windows System event log, provider `Application Popup`, event ID 26,
record 8513, UTC `2026-11-04T20:19:41.3346812Z`:

```text
Application pop-up: Easy Anti-Cheat : Untrusted system file
(\\?\GLOBALROOT\Device\HarddiskVolume9\Users\<user>\Development\nightfall\meteor\target\windows-xrizer-d3d11-src\target\release\bin\vrclient_x64.dll)
```

The event identifies xrizer's `vrclient_x64.dll` specifically, rather than its
OpenXR loader or Monado dependencies. The rejection message was logged around
normal game exit; the absence of an immediately visible popup did not mean
runtime initialization had succeeded.

VRChat's log reports:

```text
[OpenVR] Could not initialize OpenVR. Error code: Init_VRClientDLLNotFound
Initializing XR Failed. Check Editor or Player log for details.
[SteamVR] Not Initialized (109)
```

The xrizer log did not change during this attempt. VRChat continued in desktop
mode and closed normally when requested.

## Environment

- Native Windows 11 25H2; registry build `26200.9711`.
- NVIDIA GeForce RTX 3090; Windows driver `32.0.16.1742`.
- VRChat build `2026.4.1p1-1937-299983b13b-Release`.
- Unity `6000.0.67f1-DWR`.
- Original Valve `openvr_api.dll` version 2.2.3, valid Authenticode signature.
- Windows xrizer fork: <https://github.com/webhead2oo9/xrizer/tree/feat/windows-d3d11>,
  revision `ee62d2647bb84dd0969be91a6ff430bba4f72090`, built with native MSVC
  in Release. A local patch changes only `cfg(test)` temporary-backend selection
  for the fake OpenXR runtime; production Windows still selects D3D11.
- Monado source pinned to our existing Windows development runtime; its local
  build and the locally built Khronos OpenXR loader are unsigned.

## Reproduction

1. Use the existing per-user OpenVR registration to select the xrizer runtime
   directory containing `bin/vrclient_x64.dll`.
2. Remove `VR_OVERRIDE` and `VR_PATHREG_OVERRIDE` from the launched process's
   environment. This reproduction does **not** rely on per-process OpenVR
   overrides or a staged replacement loader.
3. Provide the locally built Khronos loader on `PATH` and set `XR_RUNTIME_JSON`
   to the development Monado manifest. No Monado service or headset is needed
   to observe this initial DLL-load rejection; this is not a full VR session test.
4. Launch VRChat normally through its `start_protected_game.exe`.
5. Observe the OpenVR failure in the game log, then close the game normally.
6. Read System event ID 26 from provider `Application Popup` for the complete
   EAC message. The dialog's displayed path may be truncated.

The local helper `test/probe_windows_vrchat_runtime.ps1 -Mode Registered`
captures this. It verifies that the existing registration already selects the
expected runtime, never edits that registration or game files, watches UI text,
requests normal closure, and saves the full Windows popup event.

## Controls and scope

- An unprotected OpenVR test application using VRChat's **exact original Valve
  API DLL** and the same xrizer runtime passes a local three-second observation
  with synthetic tracking, Monado and validated encoded stereo frames.
- Moss has separately run successfully through this xrizer/Monado path on the
  Quest; this is not merely a successful DLL-load check.
- VRChat also initializes and renders a stereo world through the original
  SteamVR runtime and our separate experimental SteamVR HMD driver. That capture
  prototype has headset image-alignment defects, so it is not our desired
  evidence of direct-runtime compatibility.
- Earlier per-process/staged xrizer attempts produced the same rejection of
  `vrclient_x64.dll`; the normal-registration reproduction rules out an issue
  limited to `VR_OVERRIDE`.
- We have not tested a commercially trusted signed xrizer build. Signing is a
  hypothesis to confirm, not an established sufficient fix.

## Binary identity

| Library | Authenticode | SHA-256 |
| --- | --- | --- |
| xrizer `vrclient_x64.dll` | NotSigned | `DFD09C0A3436340BD25FF5E474B9EB9F0CDE7898DCF208CCA7C3BE586E8A6A08` |
| Khronos `openxr_loader.dll` | NotSigned | `7F433F396565959286F8589202083238047C42924FF9E0098AD649232D84383A` |
| Monado `openxr_monado.dll` | NotSigned | `D4A2B45D97E6B9BF9CADD5CE529C11085BBC345047F84CABC45A3D917C5EC5E1` |
| Original Valve `openvr_api.dll` | Valid | `E5CA2FD8FB753D7BF69D920E72DC7A120B2416B04DEF194345C3CB01134021BB` |

Monado's locally built cJSON, pthread and Vulkan-loader dependencies are also
unsigned. They may become separate compatibility requirements once the first
rejection is resolved; no claim is made that EAC has accepted those components.
This audit inventories declared/local dependencies, not every library actually
loaded into protected VRChat, since it rejects the first runtime library.

## Questions for maintainers / support

1. Is native Windows VRChat known to work with xrizer or another external
   OpenVR-to-OpenXR runtime while EAC remains enabled? If so, which build and
   installation method were verified?
2. Is a trusted Authenticode signature required for `vrclient_x64.dll` and all
   downstream OpenXR runtime/loader DLLs? Are there additional publisher,
   binary-approval or integration requirements beyond Windows trusting the signature?
3. What is the supported submission/contact process for a legitimate external
   VR runtime to establish compatibility? Should this go through VRChat or EAC?
4. Does an existing signed upstream build exist, or would upstream be willing
   to establish signed native Windows releases if that is the missing requirement?

## Local evidence, not attachments to publish wholesale

Reproduction artifacts:
`meteor/target/windows-vrchat-trust/20261104-201915-Registered/`

- `summary.json`: full popup event, game-log excerpts, unchanged-registration
  check and normal-exit result.
- `signatures.json`: local DLL identities/signatures, OS and GPU versions.
- `pe-imports.json`: direct PE imports of xrizer, loader and Monado. The OpenXR
  loader is loaded dynamically by xrizer and is not in its static import table.
- `unprotected-control-summary.json`: latest unprotected control result.

Local game logs can contain account/session information. Attach only the
relevant error excerpts and the redacted event above unless support requests
more detail through an appropriate private channel.
