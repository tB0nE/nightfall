# Meteor on macOS

Goal: Meteor and its managed Meteor-Vibepollo host on a Mac, with everything
except XR. Desktop streaming and multiple monitors come first. Branches:
`feat/meteor-macos` here and `feat/macos` in tB0nE/Vibepollo, both based on
the multi-monitor work (`feat/linux-virtual-monitors`, `linux-virtual-monitors`).

Developed on an M1 MacBook Air, macOS 26.4.

## Done

### Vibepollo builds and runs on macOS (Apple Silicon)

```sh
brew install cmake ninja pkgconf miniupnpc openssl@3 opus icu4c@79 node@22
export MACOSX_DEPLOYMENT_TARGET=14.2 BUILD_VERSION=2.0.0
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_DOCS=OFF \
  -DSUNSHINE_ENABLE_WEBRTC=OFF -DCMAKE_DISABLE_FIND_PACKAGE_Boost=TRUE \
  -DSUNSHINE_NPM_EXECUTABLE=$(brew --prefix node@22)/bin/npm \
  -DICU_ROOT=$(brew --prefix icu4c@79) -DOPENSSL_ROOT_DIR=$(brew --prefix openssl@3) \
  -DOpus_ROOT_DIR=$(brew --prefix opus) -DSUNSHINE_REPO_OWNER=tB0nE -DSUNSHINE_REPO_NAME=Vibepollo
cmake --build build --target sunshine
cmake --install build --prefix "$PWD/build/stage"   # self-contained, ad hoc signed .app
```

Don't let a Homebrew Boost into the build: its headers in `/opt/homebrew/include`
shadow the pinned Boost 1.89's, and Boost.Process then fails to link.

Fixes on `feat/macos`:
- A Homebrew FFmpeg's headers in `/opt/homebrew/include` shadowed the pinned
  FFmpeg (no `AV_PROFILE_*`). On Apple the pinned headers are now `-I`.
- libc++ counts file times in `__int128`: casts in three hash/fingerprint sites.
- `v2::process_start_dir` (was a non-existent `start_dir`), a `string_view`
  passed to Bonjour, a function capture clang rejects, and a lease variable
  declared only on Windows/Linux in `webrtc_stream.cpp`.
- `CONFIGURATION_DIRECTORY` is honoured, as on Linux, so Meteor's host keeps
  its own config apart from a Vibepollo the user runs.
- Install: `fixup_bundle` gets Homebrew's lib folder (webp's `@rpath` siblings),
  the unset `SHOULD_SIGN` check no longer breaks, and an unsigned build is
  signed ad hoc (Apple Silicon won't start it otherwise).

Checked: the host starts, answers `serverinfo`, listens on all its ports, and
finds the VideoToolbox H.264 and HEVC encoders (the M1 has no AV1 encoder).

### Meteor runs the managed host on macOS

- Mac folders: settings in `~/Library/Application Support/Nightfall Meteor`,
  data in its `Data/` subfolder (both have a `host` folder), cache in
  `~/Library/Caches/Nightfall Meteor`, log in `~/Library/Logs/Nightfall Meteor`.
- Sunshine-family hosts' own config is still found in `~/.config/<host>`.
- The `host` module is built on macOS. The Linux host download is Linux-only
  (it used to apply to every non-Windows OS). On a Mac the host is expected in
  `Meteor.app/Contents/Resources/host/bin/meteor-vibepollo`, or `host_binary`.
  A new Mac install defaults to it; a saved `host.toml` choice is kept.
- No `PR_SET_PDEATHSIG` on macOS: the host's pid is kept in `meteor-host.pid`,
  and a host left running by a crashed Meteor is stopped at the next start
  (only if that pid is still the host's executable).
- `desktop_macos.rs`: notifications, the pairing PIN dialog (Approve/Reject,
  closes itself when answered elsewhere or expired), `pbcopy`, `open`.
- Restart re-executes Meteor; the host is named after the Mac's Computer Name.

Checked with an isolated `HOME`: Meteor starts the host, discovery advertises
the managed host and its pairing endpoint, `serverinfo` answers through Meteor's
proxy, and the host stops with Meteor. 161 Meteor tests pass on macOS.

### Multiple monitors and virtual displays (host)

`feat/macos`, same design as Windows `display_multi.h`, on with
`METEOR_MACOS_MULTIMONITOR=1` (Meteor sets it): one plan per launch, each
display captured with ScreenCaptureKit at its tile's size in NV12, composited
into one IOSurface buffer for VideoToolbox. Input maps tiles back to displays in
points (Retina-aware). Virtual displays come from `CGVirtualDisplay`, extend the
desktop to the right without disturbing mirroring (`kCGConfigureForAppOnly`,
restored by macOS when the host exits) and are released after the revert delay.
`AVCaptureScreenInput` gets no frames from virtual displays, hence ScreenCaptureKit.

Checked without a headset: `--meteor-display-layout` plans, and
`--meteor-capture-probe 1 out.nv12` makes a virtual display and writes a 3840x1080
composite of the real desktop beside the virtual one. Not yet checked: a real
stream, input on a second screen, the depth crop.

### Meteor.app

`meteor/tools/build_macos_app.sh <Vibepollo checkout>` builds
`meteor/target/macos/Nightfall Meteor.app` (84 MB): Meteor, the host in
`Contents/Resources/host` with its dylibs and web UI, an Info.plist with the
Local Network, Bonjour and Screen Recording keys, signed ad hoc. Checked: a new
install finds and runs the bundled host, `serverinfo` and its web UI answer.

## To do

1. **Headset checks.** A desktop stream through Meteor.app, two screens and a
   virtual one, input on each, depth crop. Single-display capture still uses
   `AVCaptureScreenInput`; consider ScreenCaptureKit there too.
3. **Menu-bar item.** `NSStatusItem` whose menu is rebuilt in `menuNeedsUpdate:`
   (as Windows rebuilds on open), with the Windows tray's entries.
4. **Start at login** (LaunchAgent), and a `.dmg`.
5. **Microphone.** Play into a virtual input (BlackHole), as Windows uses VB-CABLE.
6. **Host audio.** Check whether Vibepollo's `av_audio.mm` system-audio capture
   (`NSAudioCaptureUsageDescription`) needs no loopback driver.
7. **Firewall.** `socketfilterfw` check for the application firewall.
8. **Host depth.** ncnn's Vulkan backend through MoltenVK, VideoToolbox decode.
