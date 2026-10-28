# Meteor's bundled host: Meteor-Vibepollo for Nightfall

> Status: Active (2026-10-21). Phase 2 (Meteor runs the host) works with a
> development build. The fork's self-contained Linux build (Phase 1) and
> one-click pairing (Phase 4) are next.
>
> Replaces Phases 3–4 of [meteor-host.md](meteor-host.md) for now.

## Goal

The answer to "how do I stream PC games to my Quest on Linux" should be:
install Nightfall on the headset and Meteor on the PC. No wiki, no trial
and error.

So Meteor can run its own GameStream host: "Meteor-Vibepollo for Nightfall", our
fork of Vibepollo (github.com/tB0nE/Vibepollo). It's a choice in the tray.
Hosts the user already has (Sunshine, Apollo, Polaris, Vibepollo) keep
working as before.

## Decisions (2026-10-21)

- **Linux first.** Windows needs an installer, drivers and a service; later.
- **Pairing will be one click in the tray**: the headset sends its PIN to
  Meteor, the tray asks "Allow?", and Meteor gives the PIN to the host.
- **Multi-monitor moves to the fork**, not Meteor (meteor-host.md Phases
  3–4 are on hold).
- **Two stacks on one PC are supported**, for development and for users who
  keep another host. See Ports.
- **No `setcap`.** A binary with file capabilities runs in secure mode: the
  loader ignores `LD_LIBRARY_PATH` and `$ORIGIN`, so it can't load the
  libraries shipped beside it. Capture without privileges instead:
  - KDE Wayland: KWin's screencast. KWin allows it for a program whose
    exact path is listed in a desktop entry with
    `X-KDE-Wayland-Interfaces=zkde_screencast_unstable_v1`. Meteor writes
    one to `~/.local/share/applications/`.
  - GNOME and other Wayland desktops: the screen-share portal.
  - X11 with NVIDIA: NvFBC (your commit `4ae9e50`).

## How it works

- **Choice:** `~/.config/nightfall-meteor/host.toml` (owner-only; it holds
  the host's web UI password). `choice = "external"` is the default.
  Switching in the tray saves the choice and restarts Meteor.
- **Files:** the host's config, state, credentials and logs are in
  `~/.config/nightfall-meteor/host/vibepollo/`. Meteor sets
  `CONFIGURATION_DIRECTORY` for the child; Vibepollo reads that before the
  XDG folders, so it never touches `~/.config/vibepollo`.
- **sunshine.conf:** Meteor rewrites `port` on every start. On the first
  run it adds `sunshine_name = <hostname> (Nightfall)` and
  `address_family = both` (USB Link). Anything else the user adds stays.
- **Login:** a random password, set once with `--creds`, used only by Meteor.
- **Supervision** (`meteor/src/host/supervisor.rs`): own process group,
  `PR_SET_PDEATHSIG` so the host dies with Meteor, restarts after 1, 5 and
  30 s, then stops and says why in the tray. It waits while another program
  holds the base port.
- **Install:** a pinned `.tar.zst` from the fork's releases, checked by
  SHA-256, unpacked to `~/.local/share/nightfall-meteor/host/<version>/`.
  The previous version is kept. `RELEASE` in `host/install.rs` is empty
  until the fork publishes; until then `host_binary` in meteor.toml points
  at a build.

## Ports

Meteor's ports now follow the host's base port:

| | Default stack | Second stack |
|---|---|---|
| Host (base) | 47989 (47984–48010) | 49989 (49984–50010) |
| Meteor proxy (base + 1000) | 48984–49010 | 50984–51010 |
| Meteor discovery, depth, mic (base − 89, −88, −87) | 47900–47902 | 49900–49902 |

- The bundled host takes 47989 when its whole stack is free, else the next
  free base of 49989, 51989 and 53989. The base is saved in host.toml, so
  the headset's pairing stays valid.
- The headset probes Meteor at the host's base − 89
  (`MeteorClient.discovery_port()`), so it finds the right Meteor for each
  host. On the default base that's 47900, as before.
- A second Meteor gets its own microphone device,
  "Nightfall Microphone (port 49902)". Before this fix (2026-10-21), it
  removed the first Meteor's device as a leftover.
- The headset's scan list now keeps one entry per host and port, not per
  PC, so two hosts on one PC both show up.
- Pairing a host on a non-default port needs `fix/pairing` (`db94d36`),
  which this branch includes.

## Development: a second stack

`meteor/tools/run_second_meteor.sh <vibepollo binary>` starts an isolated
Meteor (its files in `~/.local/share/nightfall-meteor-dev2`) that runs the
given build as its host. Tested 2026-10-21 next to the usual AppImage
Meteor and Vibepollo:

- The host started on base 49989. Meteor answered on 49900, proxied
  50984–51010 and loaded EdgePad-512 depth on Vulkan.
- The host was advertised over mDNS as "tbones-lair #2".
- On SIGTERM, Meteor stopped the host within a second.

## Findings: the current custom Vibepollo (2026-10-21)

- The PC runs Bazzite 44 (an immutable Fedora). `build-cuda` was built in
  an older toolbox: it needs ICU 76 and miniupnpc .19, while the system has
  ICU 77 and miniupnpc .21. It runs with
  `LD_LIBRARY_PATH=~/.local/lib/vibepollo-libs`, holding copies of those
  libraries. A dev host gets that through `[host_env]` in meteor.toml.
- Its options: NvFBC_VK, CUDA, VAAPI, PyroWave and the tray on; Wayland,
  KMS, Portal and KWin off.
- Its web UI is found through an absolute assets path into `build-cuda/`.
- Bazzite ships Sunshine in the image, so "Sunshine installed, not running"
  is common there.

## Next

### Portable host and onboarding implementation (2026-10-28)

- Independent source checkout: `../meteor-vibepollo`, branch
  `codex/meteor-vibepollo-baseline`, pushed to `tB0nE/Vibepollo`.
- Portable host source: `4faa7b9fa819b6e73811e9cc5a8d7a87a2459f85`.
  The release-optimized Ubuntu 22.04 build uses relative assets and private
  library RUNPATHs. Driver, display and audio libraries remain OS-provided.
- Host preview: `meteor-host-v0.1.0-preview.1`, with binary and matching source
  archives. Meteor pins the binary archive's version, size and SHA-256 and
  validates the installed file manifest before use.
- Implemented first-run desktop setup notification when no local host is
  detected. Setup remains available in the tray, with web username and password
  copy access. Downloading alone never switches hosts; the setup action does.
- Added `--download-host` for installation verification without starting or
  selecting a host. Installation is locked, verified and renamed into place;
  existing profiles and pairing state remain separate.
- Validation so far: portable launch and isolated credential creation passed;
  Meteor suite passed (169 tests, 19 manual checks ignored).
- Public download verified through the optimized AppImage, first in isolated
  XDG folders and then in the real user-data directory. Meteor was restarted
  with the downloaded host; discovery reports the preview version on base
  49989 and startup detects H.264/HEVC through `nvenc_legacy`.
  The APK is installed and its checksum verified. The previous development
  binary/library overrides were removed after backing up `meteor.toml` as
  `meteor.before-portable-host-20261028.toml`; profile and pairing files remain.
- Still required: a real stream from the newly packaged host, followed by
  broader hardware/distro testing and a first-run desktop popup interaction.
  One-click pairing, client host migration and input-permission setup remain
  separate work. The existing mixed-GPU managed profile retains its explicit
  X11 / `nvenc_legacy` compatibility settings; this is not a universal default.

The original next-step list below records the wider acceptance requirements.

### Intermittent black desktop stream on reconnect (2026-10-28)

- Export `Nightfall-diagnostics-20261028-112046.txt`: failed sessions at
  11:20:00 and 11:20:22 receive packets/host depth but display zero video frames.
  Headset firmware reports `H265_CONFIG_FLAG_MISSING` at those times; successful
  sessions at 11:20:14, 11:20:32 and 11:20:39 do not.
- Moonlight starts video delivery before `connectionStarted()`. Nightfall's
  submit callback previously returned success while discarding frames until
  that later callback, potentially losing the initial IDR and parameter sets.
- Fix: accept decode units between the decoder start/stop callbacks, preserve
  early packets until connection readiness, and notify the waiting decoder
  when readiness changes. The initial wait no longer exits upon an early
  queued frame. First-three-frame diagnostics reset for every session and
  include connection readiness.
- Release Android extension and optimized `build.sh --dev` APK built;
  existing native unit suite passed in the cached Ubuntu build container.
  Requires repeated on-headset reconnect acceptance before claiming resolved.

### Acceptance and clean-profile pairing follow-up (2026-10-28)

- User confirmed reconnects (including app and Meteor restarts), USB Link
  switching, repeated XR launch/quit, wristwatch menus, input/audio and
  two-minute headset standby recovery all pass after the startup fix.
- Isolated onboarding profile: `.build-cache/meteor-host-onboarding-test-20261028/`.
  Working profile checksums are retained there; restore with its
  `restore-working-meteor.sh` script. First-run notification download/setup and
  web login were confirmed. The temporary filesystem view used to suppress
  this PC's installed Sunshine blocked native execution/GPU access, so after
  download the separate profile was relaunched normally for hardware testing.
- Pairing exposed a certificate-not-authorized error: discovered-host selection
  reused saved entries by IP, while pairing preflight treated a matching saved
  server ID as authorization. Discovery now always enters identity preflight;
  known identities verify authorization over HTTPS before skipping the PIN.
  Launch certificate rejection enters pairing without clearing all saved hosts.
- Host history deduplicates by server identity, retaining separate identities
  which take turns at the same address/port. Legacy records without IDs still
  use endpoint matching. Host-switch pairing needs on-headset acceptance.
- Hidden pointer now applies only to live desktop screens; welcome/browser/menu
  surfaces fall back to Circle. Cursor regression and existing welcome, USB and
  pointer-input tests pass; scripts parse and Release native extension builds.
- User confirmed the new test host can pair. Streaming then exposed another
  fresh-install problem: automatic encoder selection chooses native `nvenc`,
  whose synthetic probe succeeds but real X11 capture fails device creation
  three times and terminates the session on this AMD-display/NVIDIA-encoder PC.
  The isolated profile now explicitly uses `encoder = nvenc_legacy`, matching
  the already-tested working profile, with its previous config backed up as
  `sunshine.before-encoder-compat.conf`. Pairing files were retained and Meteor
  restarted. This is a local compatibility setting, not a shipped selection
  fix: validate real capture during selection or provide an appropriate fallback
  before treating fresh-install streaming as complete. Do not force an NVIDIA
  encoder globally on AMD-only systems.
- Capture-aware automatic NVENC selection is now implemented in the separate
  host checkout (uncommitted): Auto validates against the actual display rather
  than a synthetic CUDA display. Explicit native selection retains its existing
  encoder-only capability check and fail-closed behavior. Other candidates,
  including VA-API, remain eligible through the existing selection sequence.
- Optimized local package `0.1.0-preview.2-dev` was built and its per-file manifest
  verified. It is installed only in the isolated test profile using `host_binary`;
  the manual `encoder` setting was removed. Startup at 15:29:58 reports real X11
  validation rejecting native NVENC, then H.264/HEVC passing on `nvenc_legacy`.
  Selection-policy assertions pass. Actual stream/reconnect acceptance remains
  pending. The public preview and Meteor's pinned download are still `.1` and
  must be updated after acceptance; this local dev package is not a release.

### Finalized integration checkpoint (2026-10-28)

- User confirmed streaming with the automatic-selection fix. Host source is
  committed and pushed as `382bf6acb9520e63f5b47919d2800863f71d4d21` in
  `tB0nE/Vibepollo`, branch `codex/meteor-vibepollo-baseline`.
- Published [host preview.2](https://github.com/tB0nE/Vibepollo/releases/tag/meteor-host-v0.1.0-preview.2)
  with the optimized binary, matching sources and checksums. Binary archive:
  29,404,669 bytes, SHA-256
  `b1ce96a6f34b3d7b5b6e79bad4a859e3de4aeb844eed39334ba431c59a9226be`.
- Meteor pins that release. The rebuilt XR-enabled optimized AppImage downloaded
  and verified the public archive using `--download-host`; installation did not
  change the selected host or pairing state. The tray retains setup/retry access
  if a newly pinned version is missing while the managed host is selected.
- Normal profile restored through `nightfall-meteor-bundled-preview.service`;
  isolated `nightfall-meteor-onboarding-test.service` stopped. Discovery reports
  preview.2 on base 49989. No development binary override remains in the normal
  Meteor configuration. Its temporary encoder override was removed after backup
  to `sunshine.before-preview2-auto.conf`. Startup automatically rejects native
  NVENC for X11 and selects FFmpeg NVENC. XR remains enabled.
- Normal `host.toml` and `sunshine_state.json` SHA-256 checksums still match the
  copies recorded before the isolated onboarding test. No headset history was
  cleared. The test profile, separate pairing and logs remain available.
- Validation: 54 GDScript test scripts, 169 Meteor tests (19 manual checks
  ignored), native unit checks, Android Release build, optimized APK deployment,
  portable host relocation/credentials checks and public-download verification.
- Remaining immediate acceptance: select the original saved host in Nightfall
  after returning from the isolated profile; stream and reconnect without a PIN
  or clearing history. Broader GPU/desktop testing, one-click pairing and input
  permission setup remain separate follow-up work.

1. **The fork's self-contained Linux build.** Branch `nightfall` from
   `linux-x11-nvfbc-pyrowave`.
   - Build in an Ubuntu 22.04 container with relative assets paths, plus
     Wayland, Portal and KWin.
   - Ship the libraries it needs (ICU, miniupnpc, …) in `lib/` with rpath
     `$ORIGIN/lib`.
   - Publish a `.tar.zst` with its SHA-256, then fill in `RELEASE`.
   - Gate: runs unpacked on Bazzite/Fedora KDE and GNOME, X11 with NvFBC,
     and Ubuntu 24.04.
2. **One-click pairing** (Meteor endpoint, tray prompt, `/api/pin`).
3. **Input permission:** a udev rule for `/dev/uinput`, applied with one
   `pkexec` prompt when the user can't open it. Bazzite already has one.
4. **Risk:** NvFBC on GeForce cards may need a patched driver; check how
   this PC allows it before relying on it for other users.
