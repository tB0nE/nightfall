# Windows clean-install checkpoint — 2026-11-05

## November 6 checkpoint

Physical VRChat → Moss → VRChat → quit acceptance now passes, including return
to the desktop after the external SteamVR game exits. The SteamVR Resume
dashboard prompt remains and is accepted for now. See
[SteamVR integration](meteor-steamvr-driver-integration.md) for the implementation
and release capture tests. Current Windows checks pass 161 regular Rust tests
plus the isolated two-cycle capture/game-exit check; GDScript launch-failure
regressions and the full suite also passed.

The installed release received additional tested executable/driver and APK
updates after the original installer. The rebuilt and locally verified
candidate below incorporates those host-side updates.

Clean-install work still to integrate:

- PCVR setup now registers the packaged SteamVR driver automatically; an
  isolated integration fixture verifies the helper invocation and host-only
  setup exclusion without touching real registrations. Package smoke checks
  explicitly preview registration. Include this change in the next installer;
  the successful physical test used the helper manually.
- Make per-game Steam launch setup clear: native SteamVR VRChat no longer
  needs the Meteor wrapper; Moss still needs its Monado/xrizer wrapper.
- Retest hidden-console startup and pairing UI from the new installer.
- Review the extra PCVR approval step against the authenticated paired-host
  connection; do not remove authentication or approve unverified identities.
- Keep setup and Steam at normal user privilege. Bundled physical capture is
  now the Windows default, preserving explicit virtual-monitor choices.
- Retest a second physical monitor and the Browser button when available.

Pairing troubleshooting preserved host keys and pairings. The release client
no longer deletes pairing on a missing session URL or launches an immediate
direct retry after a host-busy response, timeout, or missing URL. Windows host
supervision permits the explicit keep-alive display helper to start. Implicit
virtual-monitor creation still failed driver permissions and exceeded the
client timeout, so this machine now explicitly uses physical-monitor capture.

The earlier checklist and issue entries below describe the original test run;
the checkpoint above supersedes their pending status where acceptance is now
recorded.

## Rebuilt installer candidate

The rebuilt 0.1.1 release installer includes the accepted SteamVR handoff,
game-exit handling, automatic driver registration, GUI executable, host helper
supervision, and default physical-monitor capture. SHA-256:
`57d14b68cd465944b743c74acb712fd0c6b93c2a5605307925f0cc52dd5d3d37`.
Artifact: `meteor/target/windows-release/Nightfall-Meteor-0.1.1-Setup-x64.exe`.

Relocated-package checks passed with fresh AppData and a system-only PATH:
runtime hash verification, eight DLL loads, profiles for both games, repeated
setup with registration preview, and bundled host plus XR service startup on
isolated ports. The test tray/host quit normally without forced cleanup;
the installed Meteor was restored afterward. The packaged executable's PE
subsystem is Windows GUI. Physical capture defaults were inspected in the
generated configuration. No headset or real registration was modified.

## Direct Windows PIN dialog

The subsequent installer includes **Game streaming host → Pair headset…** in
Meteor's tray and **Pair a Nightfall headset** in Start. Start pairing in
Nightfall, then enter its four ASCII digits in the Windows dialog. The helper
sends the PIN to Meteor over stdin; credentials stay inside Meteor and its
authenticated, fixed-loopback host request. No PIN or password is passed in
process arguments. Requests are bounded, follow no redirects, and use only the
saved managed-host port. The private loopback agent accepts the bundled host's
self-signed TLS certificate; it is not used for remote requests.

The dialog reports **PIN sent**, not pairing complete: Nightfall must still
finish the cryptographic handshake. Rejection keeps the dialog open for retry.
External hosts retain their own pairing flow. Existing advanced web/login menu
entries remain available; normal bundled-host pairing no longer needs them.
Separate PCVR identity approval is unchanged.

163 Windows Rust tests passed, including exact PIN validation, authenticated
submission, and host rejection. The actual packaged dialog was driven using
Windows UI automation/native controls against a fake CLI: the PIN arrived over
stdin, status was displayed, and the dialog closed normally. Fresh relocated
package setup and host/XR startup also passed. No real pairing was attempted.

Updated installer SHA-256:
`f58959e6b73a7f32c03182c42ead24b9d022f07bb1e80635f36111dc7b8a1dcc`.
This supersedes the pre-dialog candidate above. Real clean-install/headset PIN
acceptance is still pending. Do not reset the user's working profile merely
to inspect the dialog.

The release installer now stages the tested custom Vibepollo host, Monado,
xrizer, OpenXR loader, SteamVR direct-capture service/driver, tracking/encoder
DLLs and app-local Microsoft CRT/OpenMP DLLs. No development configuration,
pairing secrets, logs or absolute build paths are staged as user profiles.
Runtime files carry a SHA-256 manifest, source revisions, patch hashes and
third-party licences. SteamVR and games remain Steam installations.

Installer tasks offer the built-in host and NVIDIA PCVR setup. Setup detects
Moss/VRChat across Steam libraries, creates per-user profiles referencing the
installed runtime and retains existing backend choices. Moss uses xrizer;
VRChat uses SteamVR. Re-run **Set up Nightfall Meteor** from Start after adding
a supported game. Missing games/SteamVR produce an explicit setup message;
details are saved in Local AppData/Nightfall Meteor/setup-summary.json.

The PCVR profiles folder contains steam-launch-options.txt for direct Steam
launches. The installer does not overwrite Steam options; VR Apps works without
that step. Automatic discovery currently covers these two tested games.
Other games, AMD XR encoding and HDR multi-monitor capture remain follow-ups.
The built-in multi-monitor capture is SDR, same GPU, unrotated displays.

The default EdgePad-512 weights are included. EdgePad-256 is included only when
available; the current build machine lacks it. VDA/TensorRT remain downloads.

## Checks before resetting the real profile

- Meteor: 155 release tests pass, including setup/backend-choice regression.
- xrizer: 106 release tests pass, including concurrent injected interface access.
  The clean-profile Moss test reproduced the earlier clientcore.rs:309 race;
  `test/xrizer_windows_injection.patch` fixes the losing OnceLock publication.
- Relocated package, fresh AppData and system-only PATH: runtime hashes, eight
  key DLL loads, setup of both games, repeated setup and built-in host discovery
  pass. Startup uses isolated ports and quits its own tray/host normally.
- Packaged XR with fresh AppData/system-only PATH: Moss 350 and VRChat 363
  decoded HEVC frames at 4128x2208; wrapper cancellation and owned cleanup pass.
- Nightfall 0.8.2 release APK: v2 signature verified; streaming, native XR,
  Godot, browser blocker and pyrowave ARM64 libraries are present. No headset
  install or launch has been performed for this clean-install preparation.

Evidence (ignored): meteor/target/windows-packaged-{setup,host}-summary.json,
windows-catalog-summary.json, windows-package-unit.log and
windows-xrizer-packaged-build.log. Smoke checks open games with synthetic
tracking; they do not establish headset comfort, controller feel or sustained
session reliability.

## Reset and user test

`test/reset_windows_clean_install.ps1` previews by default; `-Apply` needs
Windows administrator rights for the old firewall exceptions. It preserves
recovery state under Local AppData/Nightfall Meteor clean-install backups:
Meteor Roaming/Local data, the development host config, old installed program,
OpenVR registry, startup setting and original firewall enabled states. Steam
launch options are cleared only if they exactly match Meteor's generated line,
with a separate backup beside Steam's config. Custom options are refused.
Old Meteor firewall rules are disabled rather than deleted.

The standard SteamVR runtime is retained; only development xrizer registration
is removed. GPU/audio drivers, Steam/games, VB-CABLE and Quest state remain.
The reset report records each moved folder. To recover, quit Meteor, restore
the saved folders/registry and re-enable only the rules previously enabled.
Keep the backup private: it contains pairing keys and host credentials.

Reset applied and verified on November 5: three state folders moved, 29
Meteor-owned firewall rules disabled, exact Steam wrapper options cleared and
development OpenVR registration removed. No old state folders or enabled old
rules remained, and Meteor was stopped. Recovery directory on this machine:
`C:\Users\Ty\AppData\Local\Nightfall Meteor clean-install backups\20261105-110734-949`.
The standard SteamVR runtime and external Sunshine/Apollo rules were retained.

User acceptance checklist:

1. Run the new installer and inspect the host/PCVR choices and any setup message.
2. Start Meteor from Start, allow its private-network firewall prompt, and pair
   the new desktop host in Nightfall. Old saved host identities may still exist
   on the Quest because its data was preserved.
3. Enable two physical monitors in Screens; check proportions and input on both.
4. Approve the headset's PCVR code in the tray after comparing both displays.
5. Launch Moss and VRChat through VR Apps; check resolution, audio and controls.
6. Set Steam launch options from the generated file and test direct Steam launch.
7. Check microphone, model downloads, tray startup, restart and normal game exit.

Record issues against this checklist, including the setup-summary.json and
meteor.log entries relevant to a failure. Actual clean-profile user acceptance
is pending; the local checks above are not a substitute for it.

## First user issue: Android renderer crash on connect

The first installed release APK crashed on the GL thread during stream-start
layout changes, including the automatic trim from two captured monitors to one.
Logcat reported render-target texture-free errors followed by SIGSEGV at 0xe0
in libgodot_android.so (old BuildId cde1e893aabfbe6e07d91160f319d50c846b8123).
The cached September Android engine had four patches and lacked the required
godot-4.7-gles3-render-target-override.patch. The APK had been rebuilt with newer
project/native-extension sources but this older engine binary.

Rebuilt only the release engine with the fifth patch. Bootstrap now stamps
compiled runtimes with all required patch hashes and the binary hash; APK
export rejects missing/stale stamps. Four regression checks cover valid builds,
changed render patches, replaced binaries, and a source-only stamp. Bootstrap
also supports extending an exact recorded patch prefix despite overlapping
earlier patches, and --android-release-only avoids building debug artifacts.
Replacement release APK passed signature verification and contains rebuilt
Godot BuildId f6a4d257d7211f4104b97206aa9704f0be1a8e47 (verified directly
inside the APK). Physical connection acceptance is still pending.

## Second user issue: input stops when focusing Steam

After the renderer update the user connected and reproduced mouse input
stopping when focusing Steam. Process token checks confirmed Steam elevated
(PID 30696), while installed Meteor and Sunshine were not elevated. The
administrator reset had restarted Steam through the launch-options helper,
causing this mismatch. Windows input injection into an elevated foreground
application is restricted.

Steam was shut down gracefully and restarted normally (PID 30108). Token
checks then confirmed Steam, Meteor and Sunshine all non-elevated. The reset
now passes -NoRestart to the Steam helper; that helper refuses an elevated
automatic restart unless -NoRestart is used. Future administrator resets leave
Steam closed when they need to change its options; open Steam normally after
reset. External host permissions and Windows input security were not changed.
User input acceptance after the privilege correction remains pending.

## Third user issue: direct Steam launch has no Meteor handoff

The user launched VRChat after the clean reset. Standard SteamVR logged HMD
Not Found (108); Meteor had no XR session/launch record. Both games' Steam
options were still empty as intended by the reset, and the fresh PCVR trust
list contained no approved headset. This exposed missing setup guidance:
desktop pairing alone does not approve PCVR, and ordinary Steam launches need
the wrapper even though VR Apps launches do not.

Closed the failed standard SteamVR monitor gracefully and applied wrapper
options for Moss/VRChat pointing to the installed Meteor executable and its
per-user catalog, with a Steam config backup and normal-privilege restart.
The user must open VR Apps and compare/approve the PCVR headset code locally.
Installer setup currently documents these steps; integrating them visibly
into the first-run flow remains a usability issue.

## Fourth user issue: PCVR hidden in release APK

The user could not reach VR Apps because PCVR did not appear. Discovery was
working, but PCVR provider registration and automatic authentication still
depended on the diagnostic/development entry flag. The settings link also
required authentication, hiding the first-approval screen before it could be
completed. A one-screen workspace restriction additionally stopped the watcher
when using multiple monitors.

Production Meteor provider registration now runs in release builds; diagnostic
UI retains its existing opt-in gate. A pinned discovered XR service exposes the
PCVR setup page before authentication, including the code/status message. Library
access and streaming still require cryptographic authentication and host
approval. The watcher can authenticate without changing a multi-screen desktop.
All 54 GDScript scripts pass, including the new first-approval menu regression.
Release APK rebuilt and signature verified, with no GDScript export errors.
The replacement APK deployment is recorded in the local package/check summaries;
physical PCVR-menu and first-approval acceptance remain pending.
