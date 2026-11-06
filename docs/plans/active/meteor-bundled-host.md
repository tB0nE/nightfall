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
