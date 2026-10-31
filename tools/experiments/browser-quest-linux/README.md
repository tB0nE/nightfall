# Native ARM64 Linux browser lab on Quest

This is a disposable feasibility experiment, not a Nightfall playback feature or
a hardware VM. PRoot runs ARM64 Linux userspace on the existing Android kernel.
It uses no root, hypervisor, GPU passthrough or Meta Browser DRM files.

## Results on Quest 3, 2026-10-31

- Official Termux PRoot 5.1.107.101 launches children through ADB without root.
- Ubuntu Base 24.04.5 ARM64, glibc 2.39 and apt run natively on the headset.
- Official Chrome 156.0.8078.79 ARM64 installs and renders a blank page.
- Full Chrome startup with its default sandbox fails (SIGTRAP).
- The sandbox-disabled blank-page test succeeds from the companion app's own
  private storage. Under ADB's temporary directory, SELinux denies Chrome's
  filesystem UNIX socket creation; changing to app storage resolves that error.
- The companion app launches Xvfb, x11vnc, noVNC and visible Chrome on Quest.
  HTTP and remote-desktop framebuffer checks pass.
- The local browser probe accepts `com.widevine.alpha` and successfully calls
  `createMediaKeys()`. The result was inspected on the rendered page through VNC.
- The user confirmed Netflix video playback through the Quest-hosted browser.
  Afterwards Android explicitly killed the PRoot tracer with reason
  `Trimming phantom processes` at 14:59:52 device log time. The device reports
  `max_phantom_processes=32`. ENOSYS thread/socket errors and the PulseAudio
  assertion followed the tracer kill; they were not evidence of a Netflix rejection.
  Later process-budget changes stabilized the lab, and the user confirmed
  Netflix sound and AI 3D inside Nightfall. Performance and production suitability
  remain unresolved.

The sandbox checkbox is deliberately off by default. The current lab run was
started explicitly with sandbox disabled for diagnosis. PRoot is not a security
boundary. This is not a safe production browser configuration.

The companion uses target SDK 28 to permit this downloaded-binary experiment.
That does **not** establish compatibility with Nightfall's shipping target SDK,
modern writable-code restrictions, packaging requirements or distribution terms.
Resolving those and Chrome sandboxing is separate work before integration.

## Reproduce

Host dependencies: Python 3.12+, curl-compatible HTTPS access, `ar`, `rg`, JDK 17,
Android SDK platform 36/build tools 36.1.0 and ADB. Set `ANDROID_HOME`, `JAVA_HOME`
and PATH accordingly. Set `ADB` to a specific adb binary if needed, and
`ANDROID_SERIAL` when multiple devices are attached.

```sh
# Fetch official packages, prepare a rootfs archive without Android-denied hardlinks,
# and install browser dependencies in a separate headset staging directory.
bash tools/experiments/browser-quest-linux/deploy.sh

# Build/install the separate companion and copy the prepared userspace into it.
bash tools/experiments/browser-quest-linux/install-lab.sh
```

Ubuntu Base is checksum pinned. Termux packages are checked against SHA-256
values in its official HTTPS package index. Chrome is fetched directly from
Google over HTTPS; its observed hash and package provenance are recorded in
ignored `.build-cache/browser-quest-linux/packages.json`. This is not a
redistributable bundle; no downloaded binaries are committed.

Open **Nightfall Linux Browser Lab** from Unknown Sources. The default start
tests the Chrome sandbox. The explicit sandbox-off checkbox enables the lab
configuration that currently starts successfully. Use the reload button after
the desktop has started. A neutral local page offers video/Netflix links and a
normal EME initialization probe; it requests no content license or DRM secrets.

For desk testing of the same browser running on Quest:

```sh
adb forward tcp:6082 tcp:6082
```

Open <http://127.0.0.1:6082/vnc.html?autoconnect=true&resize=scale> on the PC.
Chrome still executes on Quest; the PC is only displaying its remote desktop.
The guest web/VNC services bind only loopback (6082 and 5902). This stage uses
software graphics. PulseAudio uses a monitor sink; `parec` sends 48 kHz stereo
PCM16 through a stdout pipe into an Android AudioTrack in the companion service.
The PC noVNC viewer does not receive audio; sound plays on the Quest. No microphone
permission or microphone capture is used. The Activity and notification provide
stop controls. The audio bridge reports counters, not recorded content, in the
private `files/linux/audio-status.json` file.

Stop the entire experiment, including its children, with:

```sh
adb shell am force-stop app.nightfall.browserlab
```

Nightfall itself is neither replaced nor modified by these scripts. The lab's
profile stays in its private `files/linux/rootfs/home/browser/` directory; do not
copy or publish it. Reinstall the lab in place to preserve it. The initial
staging filesystem is `/data/local/tmp/nightfall-browser-linux/`. Logs and VM
profiles are not copied from either desktop VM. The unused ARM64 desktop VM was
removed at the user's request; the working x86 VM was retained.

## Child-process budget and stability checks

The lab now uses websockify's threaded `--libserver` backend, limits renderer
processes, disables browser extensions/background services, and avoids D-Bus
autolaunch helpers. Chrome retains its official launcher: replacing that launcher
or using `--no-zygote` caused file-descriptor ownership failures in this setup.
The standard launcher sanitizes inherited standard streams. PulseAudio clients
and the server both disable shared memory. No headset-wide process limit or
other Android process-management policy was changed.

A foreground media service owns the Linux process and Android audio track,
independent of Activity/panel recreation. It exposes a stop notification/action. These are
lab adjustments; production lifecycle/sandbox/packaging design is still separate.

To reproduce the controlled, non-account video test, generate a local sample:

```sh
/usr/bin/ffmpeg -hide_banner -loglevel error \
  -f lavfi -i testsrc2=size=1280x720:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000 -t 12 \
  -c:v libx264 -preset veryfast -crf 27 -pix_fmt yuv420p -threads 2 \
  -c:a aac -b:a 96k -movflags +faststart -y \
  .build-cache/browser-quest-linux/stability.mp4
```

`install-lab.sh` deploys the optional test page/video if the sample exists.
In the Linux Chrome browser, open `http://127.0.0.1:6082/stability.html` and click
**Start stability test**. Its generated tone now plays through the Quest. It loops the 720p H.264/AAC sample and displays elapsed
time, decoded/dropped frames, loops and errors. This is a clear-video stress
check, not a Netflix session test or an XR performance benchmark.

While it plays, run from the host:

```sh
/usr/bin/python3 tools/experiments/browser-quest-linux/monitor.py --seconds 420
```

The monitor samples the original tracer's survival, viewer HTTP availability and
app child-process count into ignored
`.build-cache/browser-quest-linux/stability-summary.json`. Inspect the on-screen
video counters too; HTTP liveness alone does not establish continued playback.
Netflix playback needs a separate user test with the new launch configuration.

Validation on 2026-10-31: a seven-minute monitored run retained the original
tracer and returned HTTP 200 throughout, with at most 22 app child processes.
The final visual check at 476 seconds showed 39 video loops, 14,059 frames,
zero dropped frames and no error. Widevine initialization is checked separately
on the lab page. The user subsequently confirmed stable Netflix viewing, audio and AI 3D, but
reported poor performance. The controlled clear-video results are not a Netflix
performance benchmark and do not establish production reliability.

## Audio validation and initial Nightfall integration

The audio-enabled service is installed in place; its browser profile is retained.
The generated AAC test produced non-zero monitor PCM and increasing Android
playback-head frames. The bridge keeps partial pipe reads frame-aligned, uses
GAME audio usage with spatialization disabled, and respects media focus. Do not
raise system volume to diagnose a stalled stream: sleeping Quest output can
stop consuming PCM until the headset wakes.

The lab service remains active when another app is foreground. An initial
Nightfall browser screen has been opened at the localhost noVNC URL using the
existing address/key-input path. Its browser navigation reports the expected URL
and ordinary headset inference reports updates. The user confirmed seeing the
Linux Chrome test page inside Nightfall; the system screenshot was black and
was not sufficient evidence either way. The user subsequently confirmed Netflix picture, sound and AI 3D in this combined
path. They reported poor performance and loud fan activity. Lip sync, final input
quality and measured playback cadence remain to be checked.

See [the integration plan](../../../docs/plans/active/quest-linux-browser-integration.md)
for the proof path, direct-frame transport, lifecycle, audio coordination, sandbox
and modern-target-SDK gates. This remains an experimental helper, not a shipping
DRM browser backend.
