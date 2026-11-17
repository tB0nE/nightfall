# Vibepollo upstream contributions, and open bugs (paused 2026-11-17)

Status: paused. Work stopped here to switch to the screen placement grid. This
records where it stopped, so it can be picked up later.

## Goal

Offer as much of our Vibepollo fork (`tB0nE/Vibepollo`) as is generally useful
to upstream (`Nonary/Vibepollo`), so the code that is specific to Nightfall
stays small. The user agreed to the PR split below on 2026-11-11.

**Rule:** prepare each branch in the fork. Don't open a PR on
`Nonary/Vibepollo` until the user has reviewed that branch.

## State of the fork

- `tB0nE/Vibepollo` `master` merged upstream `master` (about 5,400 commits
  since 2026-10-02) in PR #5 (2026-11-11). Later PRs #6 and #7 added host
  monitor, cursor, clipboard and macOS changes. PR #8 (Pages and Arch
  packaging) was still open on 2026-11-17.
- Merge decisions that matter for upstream PRs:
  - **KWin capture:** we auto-select KWin capture on any KDE Wayland desktop.
    Upstream does this only on SteamOS builds.
  - **TrueHDR:** our release build sets `SUNSHINE_ENABLE_NV_TRUEHDR=OFF`.
    Upstream's TrueHDR fetch needs Python 3.11, while the Ubuntu 22.04 builder
    has 3.10.
- `third-party/libvirtualdisplay` points at `tB0nE/libvirtualdisplay`
  `meteor-windows`. That branch merges our two Windows commits with upstream's
  20 newer ones (`908ad738`).

## The PRs

| # | Branch (in the fork) | Contents | State |
|---|---|---|---|
| 1 | `upstream-pr/dmabuf-implicit-modifier` | Offer `DRM_FORMAT_MOD_INVALID` when EGL lists no DMA-BUF modifiers (amdgpu before GFX9, such as Polaris), and log the format count at debug. | Ready for review. Built on upstream `master` at the time; tested on an RX 480. |
| 2 | `upstream-pr/truehdr-off-build` | Guard `synthesize_rtx_hdr_metadata()` in `pyrowave_session_colorspace()`. Upstream fails to build with `-DSUNSHINE_ENABLE_NV_TRUEHDR=OFF`. | Ready for review. |
| 3 | not started | **Multi-monitor protocol.** Covers `display_plan.h`, the display manifest endpoint (`/polaris/v1/display/manifest`), the `outputs=`, `virtual_displays=` and `virtual_only=` launch options, frame tiles with input mapping, encoder-fit scaling and unit tests. | To do. Port by hand: upstream reworked `nvhttp.cpp` and input geometry. |
| 4 | not started | **X11.** Covers multi-monitor X11 capture composed into tiles (needs PR 3), GPU-resident NvFBC for PyroWave and CUDA (`4ae9e50c`, standalone), and validating capture before auto-selecting native NVENC (`382bf6ac`, standalone). | To do. Needs testing in an X11 session. |
| 5 | not started | **macOS.** Covers multi-monitor capture and virtual displays (needs PR 3), and surviving a display missing from `NSScreen`. Upstream already fixed macOS building (`c339e694`, `eacc5263`). | To do. The Mac agent must build and test it. |

Before offering PRs 3–5:
- Replace the `METEOR_*` environment switches with normal config options, or
  turn the features always on. The affected settings are
  `METEOR_MACOS_MULTIMONITOR`, `METEOR_WINDOWS_MULTIMONITOR` and
  `METEOR_CURSOR_SCALE_FILE`.
- Keep `METEOR_CAPTURE_REGION_FILE` (Meteor's depth crop) out of upstream.

The pairing permission change (`ea94a2b0`: every paired device gets full
permissions) needs a discussion with the maintainers before any PR.

### Building upstream-based branches

`packaging/meteor/` exists only in the fork. To build a branch based on
upstream:
1. Copy `packaging/meteor/build-release.sh`.
2. Set `ROOT` to the source tree and the build directory to
   `build-upstream-pr` (ignored by `/build-*/`).
3. Drop `-DSUNSHINE_BUILD_METEOR=ON` and keep `-DSUNSHINE_ENABLE_NV_TRUEHDR=OFF`.
4. Reuse the `nightfall-meteor-host:ubuntu22.04` image.

Build in the main Vibepollo checkout, which has every submodule cloned. Switch
branches there, then run `git submodule update --recursive`.

## Open bugs found 2026-11-10/11, not yet fixed

- **On-device AI depth can reboot the Quest.** It happens when the headset
  refuses Meteor's key (for example after pairing with the other OS on a
  dual-boot PC), so depth runs on the headset's GPU. It reproduced twice with
  AI 3D on, and never with it off. A reboot is a system-level failure (GPU or
  compositor), so the app should fail safely instead.
- **The Meteor key mismatch isn't shown in the headset.** It only appears as a
  log line ("Meteor's key changed …; Settings > Forget Meteor Keys"), and it
  caused two confusing problems.
- **The pairing pop-up is hidden while KDE is in Do Not Disturb.** Plasma turns
  DND on during screen sharing or recording, such as OBS. Meteor's request is
  a plain notification. It could open its own window when notifications are
  inhibited, or the headset could say "approve in Meteor's tray".
- **The GDScript CI job hangs until its 6-hour timeout.** A failed assertion
  leaves headless Godot running instead of exiting. Run the suite with a
  timeout locally.
- **The Windows mask fix is merged (PR #78) but unbuilt.**
  `monado_windows_tracking.patch` now builds the default mask from a mirrored
  FOV. Confirm on the next Windows build that Moss shows no strip at the bottom
  and that the corners are still masked.
- **Issue #72 (Quest 2 PCVR):** the 72 Hz fix shipped in `0.9.1-preview.1` and
  later. The reporter hasn't confirmed it yet.

## Done in the same sessions (for reference)

- Linux host: input maps through the whole desktop, which fixed clicks when
  only virtual monitors are streamed. Also: encoder-fit scaling, the implicit
  DMA-BUF modifier, and primary-region publishing on GNOME.
- PCVR:
  - fit both eyes into the encoder's largest frame (`max_frame`);
  - offer 72 Hz on every headset;
  - VR library discovery from `appinfo.vdf`;
  - visibility mask placed the right way up on Linux.
- Client: remember each screen's placement across reconnects (`7003bdd`, in
  `0.9.1-preview.2`). The screen placement grid may replace how placement is
  stored.

## Local state on the development PC (2026-11-17)

- `~/.config/nightfall-meteor/meteor.toml` has a `host_binary` line pointing at
  a dev host (`Meteor-Vibepollo-0.1.0-preview.6-cursor-dev`). Remove it to go
  back to the pinned host.
- Older clean-install backups (`nightfall-meteor.pre-clean-test3/4/5` under
  `~/.config`, `~/.local/share`, `~/.cache` and `~/.local/state`) are waiting
  for the user's OK to delete.
