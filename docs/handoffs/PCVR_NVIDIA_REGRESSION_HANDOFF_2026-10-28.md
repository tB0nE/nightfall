# Handoff: PCVR stopped working on NVIDIA (2026-10-28)

Historical handoff supplied at the start of this investigation. For subsequent
fixes, testing and the current release checkpoint, see the
[managed-host integration plan](../plans/active/meteor-bundled-host.md).

Written by the agent working on `feat/meteor-bundled-host`, for the agent
that built XR streaming and the AMD encoder work in this checkout.

## The problem

On 2026-10-28 the user couldn't start VRChat (438100) or Moss (846470) over
PCVR. The PC has an RTX 3090 and an RX 480. The user's last working PCVR
session was **2026-10-26 23:22**, a VRChat session that encoded 1848 frames
(`lan-sessions/1793053322865986309-1119466`).

**Your first task:** find out why PCVR on NVIDIA fails now, and fix it.

## What the logs show

Sessions are in
`~/.local/share/nightfall-meteor/xr/.build-cache/meteor-xr/lan-sessions/`.
Today's failed ones end in `-2967569`, from 08:26 to 08:32.

- **Every failed session encoded on NVENC.** `encoder-selection.json` says
  `backend: nvenc`; the first four requested `auto`, the last three `nvenc`.
  The AMD card wasn't used.
- **The VRChat sessions failed before any frame was encoded.** They got
  `METEOR_TRACKING_READY`, then `METEOR_TRACKING_DISCONNECTED
  reason=transport_or_protocol`. `runtime.log` says "Tracking disconnected
  before a live XR stream was established". On Meteor's side the log says
  "XR relay AttachTracking stopped: early eof". So the headset closed the
  connection.
- **Moss got further.** In `1793172666762968909-2967569`:
  - 614 frames were encoded (`ENCODE_OK`, ~98 MB `monado-stereo.h264`).
  - XR sessions 1 and 2 were created and destroyed, then session 3 started.
  - After that, every frame failed with `METEOR_CAPTURE_FAILED
    reason=capture_rejected` (220 times). That message comes from
    `meteor_capture_layer()` returning false in
    `test/monado_capture_hook.patch`. The capture was one projection layer,
    2 views, 2064x2208, slice 0/1.
  - `lifecycle-outcome.json`: `interrupted`,
    `tracking_transport_or_protocol_disconnected`.
- **The headset is a release build**, so logcat shows nothing from Godot.

## What has changed since the working session

**1. The XR runtime on the PC.**
- The session on 10-26 ran installed version **`ad325d29…`**.
- Today's sessions ran **`53d31ca1…`**: the `amd-h264-main-package` bundle
  from the AMD work (on `main`: 473f231, 0558500, c80fa0d). It was installed
  10-27 11:39.
- Both are still installed under `~/.local/share/nightfall-meteor/xr/versions/`.
- Diffing their manifests, the changes are:
  - Changed: `libopenxr_monado.so`, `monado-service`,
    `libmeteor-nvenc-probe.so`, `run_monado_nvenc_spike.py`,
    `meteor_xr_runtime.py`.
  - Added: `libmeteor-vaapi-probe.so`, `xr_encoder_backend.py`, and the
    FFmpeg/dav1d libraries in `encoder-lib/`.
  - Manifest: `backend` went from `nvidia` to `linux-gpu`.
- **No session ran on NVIDIA with `53d31ca1` before today.** The Meteor that
  ran from 10-27 13:03 (built in `moonlight-quest-feedback`, same embedded
  bundle) never ran a PCVR session. This is the prime suspect.

**2. The headset APK.**
- It's `0.8.2-preview.1-dev+305aa24-dirty`, from `feat/environments`
  (`../moonlight-quest-env`), installed 10-27 23:15. That's `main` plus 3D
  rooms (Cinema).
- Touches near XR in that branch:
  - `main.gd` saves the render-target size multiplier
    (`_xr_base_target_multiplier`) and calls
    `environment_manager.process()` each frame.
  - `GodotApp.java` gains a file picker.
- Nothing obvious in PCVR code, but it isn't ruled out.

**3. Meteor itself (very unlikely to be the cause).**
- Today's Meteor is `feat/meteor-bundled-host` (`../moonlight-quest-host`,
  95dc0a2, pushed; see below). It embeds the same
  `amd-h264-main-package` bundle, byte-identical to the 10-27 build.
- Its XR changes against `main`:
  - The XR port-overlap check now uses `firewall::ports(&map, side, true)`.
  - `xr_setup::restart_command()` sets `METEOR_RESTARTED=1`.
  - `xr_session.rs` is unchanged.

## Suggested way in

1. **Split the PC side from the headset side.** Run a PCVR session on the
   3090 with the `ad325d29` runtime and the same APK.
   - Rebuild the AppImage with an older bundle, or point
     `xr.runtime_root` at a copy.
   - If it works, the regression is in the AMD-era runtime (Monado capture
     hook, NVENC probe, or `run_monado_nvenc_spike.py`).
   - The alternative is to install a `main` APK without environments, built
     from `../moonlight-quest-host`, and retry with the current runtime.
2. If it's the runtime, look at the conditions in `meteor_capture_layer()`.
   Moss's third XR session was rejected while the first two weren't. Also
   look at what makes the headset drop tracking before the first frame
   (VRChat's slow Proton start).
3. Ask the user before installing an APK on the headset. **Never uninstall it
   to get past a signing mismatch.**

## The user's setup today

- **Host:** the user's own Vibepollo, `~/Development/Personal/Vibepollo/build-cuda`,
  holds 47989. Its config is `~/.config/vibepollo`.
- **Meteor:** the XR-DEV AppImage from
  `../moonlight-quest-host/meteor/target/appimage/`. Autostart points at it.
  Its log: `~/.local/state/nightfall-meteor/meteor.log`.
- **`~/.config/nightfall-meteor/meteor.toml`** was rewritten today. It sets:
  - `host_binary` / `[host_env]` for the bundled-host test;
  - `[xr] enabled = true`;
  - `encoder_backend = "auto"`. The user had picked `vaapi` in the tray at
    08:33, after the failures; it was reset to `auto`.

  Backups: `meteor.before-bundled-host.toml`, `meteor.before-pcvr-setup.toml`.
- **Depth rate:** 72 Hz in `state.toml`.

## Related work on `origin/feat/meteor-bundled-host`

Pushed 2026-10-28, with no PR (the fork's host build is still missing).
These aren't on `main` yet. The branch's worktree is `../moonlight-quest-host`.

- **Depth rate cap fix (624d7ea, `meteor/src/depth.rs`, `RatePace`).**
  It can be cherry-picked onto a `main`-based branch by itself.
  - The cap measured time since the last run and dropped any frame that
    arrived more than 1 ms early. A 72 Hz cap on a 72 fps stream therefore
    ran at ~55 Hz: 16–17 frames a second were skipped, even though the model
    takes only 6 ms.
  - It's now a fixed schedule that accepts frames up to half a period early,
    in both the engine and the decoder gate. Tests:
    `pace_keeps_a_jittery_stream_at_the_cap` and
    `pace_holds_a_lower_cap_on_average`.
  - This bug is on `main` too.
- **Rename:** "Vibepollo for Nightfall" becomes "Meteor-Vibepollo for
  Nightfall", and the discovery `kind` becomes `meteor-vibepollo`.
- **Supervisor tests** use OS-assigned ports. Port 47124 had collided with
  another app's outgoing connection.

## Checkout notes

- **This checkout is on `feat/meteor-xr-streaming` at 0e13cbc: 34 commits
  behind `origin/main`, 0 ahead.** Start from `origin/main` (b0b4b47:
  includes #62–#64) on a new branch, e.g. `fix/pcvr-nvidia`.
- `.build-cache/native-xr` (the Godot engine) was rebuilt on 10-27 with
  `patches/godot-4.7-gles3-render-target-override.patch`. Its backup is in
  `backup-2026-10-27/`.
- **Standing rules:**
  - Warn before network or firewall changes.
  - Don't commit or push unless asked.
  - Don't touch ZipDepth tooling or depth files without asking.
  - Kill processes by PID (pgrep), never `pkill -f`.
  - Don't change xrandr or the monitor layout.
  - Build headset APKs with `build.sh --dev`.
