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

## Frame-rate investigation (2026-11-01)

The optional `frame-metrics.py` loopback collector listens on port 6083.
`stability.html` reports generated-video counters; `performance-viewer.html`
replaces the normal noVNC viewer for this test and counts completed noVNC
display flips. Open the latter **in Nightfall**, not in a second PC viewer,
to avoid mixing producers. Neither page reports account URLs or media content.
The collector is unauthenticated lab-only IPC, with the same production
limitations as the existing VNC endpoint. It adds one Python process.

Use `adb forward tcp:6083 tcp:6083` and GET `http://127.0.0.1:6083/` for
cumulative numeric counters. Calculate deltas using each producer's `elapsed`
value, and reject stale samples using `received_monotonic`. A display flip is
not proof that the video pixels changed. Chrome's `totalVideoFrames` includes
dropped frames; subtract `droppedVideoFrames` for non-dropped frames.

Nightfall's bridge expression
`[telemetry.app_fps, telemetry.video_update_fps]` separates app rendering from
browser texture updates. Texture updates also do not prove unique video frames.

Initial controlled 720p30 clear-video samples:

- AI on: Chrome total-frame rate about 29.3/s; VNC display about 6.4/s.
- AI off: Chrome total-frame rate about 29.5/s; VNC display about 5.5/s.
  Nightfall reported 60 app fps and about 7.9 texture updates/s at the endpoint.
- These are short sequential samples, not a controlled AI performance ranking.
  Some Chrome frames dropped. The AI-on run also reported unusually slow depth
  inference (around 238–266 ms), unlike the earlier 31 ms sample; unresolved.
- The result identifies a large presentation-path loss for this generated clip;
  it does not establish Netflix decoding speed or hardware decoding support.

Raw samples are ignored under
`.build-cache/browser-quest-linux/performance-20261101/`. Next isolate X11/VNC
capture versus noVNC/WebView canvas presentation, then test a direct frame path.

Further isolation: `measure-rfb.py --seconds 10` receives raw incremental RFB
updates without rendering or saving pixels. Use port 5902 forwarded over ADB,
or run the script in the existing Quest Linux environment to remove USB from
the measurement. It adds load and does not count unique video frames.

- Default capture delivered about 12.2 updates/s to the PC and 12.5/s locally.
- A temporary server using `-wait 1 -defer 1 -nonap -speeds 166,100000,1`
  delivered about 26.9 updates/s raw. These values are diagnostic hints, not a
  hardware capability guarantee or measured bandwidth specification.
- MIT-SHM capture failed with `shmget(scanline): Permission denied`.
- Faster polling did not establish an end-to-end improvement: the combined
  run was affected by headset sleep/Guardian focus and had more Chrome drops.
  It was reverted rather than made the default. Recheck with Nightfall fully
  foreground and compare non-dropped frame deltas, CPU and presentation rates.

Foreground follow-up, with the user confirming visible test playback and AI off:
two sequential ~12-second windows measured 29.7 non-dropped video frames/s and
11.1 viewer updates/s at baseline, versus 29.5 and 12.6/s with live
`wait:1,defer:1,nonap`. Nightfall rendered at 60 fps in both windows; texture
updates were about 8–14/s and 12–17/s respectively. No restart was used between
windows. The modest end-to-end change does not justify aggressive polling as a
default; baseline polling was restored. Raw samples:
`performance-20261101/foreground-polling-ab.json`. This supports investigating
a local frame transport that bypasses VNC rather than treating app fps as video
cadence. It is still a generated-clip result, not a Netflix benchmark.

## Direct framebuffer / Android Surface spike

The lab now starts Xvfb with `-fbdir /tmp/nightfall-framebuffer`. Its private
XWD framebuffer is mapped by `DirectFrameRenderer`, layout-checked and copied
into a reusable Bitmap, then posted to Nightfall's existing browser Surface.
The explicit Binder service accepts only the installed Nightfall UID; it does
not expose the file, profile or frames through another network endpoint.
Nightfall's DEV manifest declares visibility of the helper package. Normal
release metadata does not enable this experiment.

Build both APKs using `build-lab.sh` and the normal `./build.sh --dev` pipeline,
install in place and deploy the updated `start-desktop.sh` as described above.
Restart the helper so Xvfb creates its framebuffer, then initialize a browser
screen normally. The DEV browser home has a **Linux Browser Lab** shortcut to
the fallback measurement viewer. To activate direct display from the dev bridge:

```sh
/usr/bin/python3 tools/nf.py eval 'browser_prototype._gamepad_bridge().browserLinuxFramesFor(browser_prototype.browser_id,true)'
adb shell run-as app.nightfall.browserlab cat files/linux/direct-frame-status.json
# Restore the normal browser display:
/usr/bin/python3 tools/nf.py eval 'browser_prototype._gamepad_bridge().browserLinuxFramesFor(browser_prototype.browser_id,false)'
```

Wait for browser initialization before enabling. This blanks/pauses the old
viewer, detaches the virtual-display producer, then hands off the Surface.
The native uploader and on-headset inference continue to use the same screen.
No extra XR layer is added. Binder death and service teardown stop the producer.

Controlled active-video measurements: ~29.4 posts/s, ~26 changed sampled hashes/s
and ~29.5 Nightfall texture updates/s. AI-on reported ~29 ms / 20 Hz inference
with ~29.5 producer posts/s. Sampling a hash does not count unique decoded video
frames, and depth processing can also trigger texture-update counters.

This is still CPU-copy, with no Xvfb completion fence: tearing is possible.
The configured target is 30 Hz. Linux controller input, cursor hiding, tabs,
direct-path audio synchronization and production lifecycle are not implemented.
For this display test, control Linux Chrome through the existing desk-side RFB
input and use the normal Nightfall menus for AI settings. Do not expect screen
clicks to control Chrome while the direct producer is active.

An optional `--ez probe_frames true` Activity extra requests a bounded offscreen
ImageReader test; no successful probe result has yet been established. Its
output is `files/linux/direct-frame-probe.json`. It is distinct from the successful
direct-to-Nightfall measurements above.

### GPU drawing and refresh targets (2026-11-01 follow-up)

The direct renderer now defaults to `Surface.lockHardwareCanvas()`. Scaling,
drawing and BGRX-to-RGB correction use the GPU. The supported little-endian,
unpadded XWD layout takes a native `Bitmap.copyPixelsFromBuffer` upload rather
than converting every pixel in Java. There is still a CPU memory copy and a GPU
upload; this is not zero-copy or hardware video decoding.

The DEV browser forwards the actual XR refresh target, bounded by the app's
render cap, once per second. The helper accepts live targets from 30 to 120 Hz.
A monotonic deadline scheduler skips missed slots without a catch-up queue.
This is not true display-vsync or source-frame synchronization. Posting-interval
metrics expose jitter; posts can repeat source frames.

The earlier unsuccessful offscreen probe was subsequently fixed to run through
the helper's existing foreground service, independent of Quest panel focus:

```sh
# Stop direct-to-Nightfall rendering before running this separate probe.
adb shell "run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.BrowserLabService --ez probe_frames true"
```

With the synthetic `color-probe.html` displayed in Linux Chrome, the GPU probe
received 299 frames in ten seconds at a 30 Hz target and measured **zero channel
error over 780 sampled RGB channels** against Xvfb. This validates sampled pixel
conversion on the static chart; it does not establish tear-free moving capture.
Its saved result is `performance-20261101/gpu-color-probe.json` in the host cache.

Short live tests with a generated 720p60 clip and AI 3D enabled:

| App target | Producer posts/s | Non-dropped source frames/s | Source drops in window | Post interval p95 |
| --- | --- | --- | --- | --- |
| 60 | 60.0 | 59.5 | 0 | 21.4 ms |
| 72 | 71.6 | 59.3 | 1 | 17.8 ms |
| 90 | 90.0 | 59.3 | 0 | 16.4 ms |

These are sequential ~10-second samples after warmup, not Netflix benchmarks.
The 60 Hz app case uses Nightfall's normal 120 Hz headset mode; 72 and 90 use
matching runtime refresh. Drawing/submission fell from roughly 23 ms CPU-side
to around 1–3 ms, plus about 0.7–0.9 ms of copy work. These timings include CPU
submission/blocking, not isolated GPU execution time. Frame posting still has
measurable jitter, and source-frame fences are still absent.

Generate a `stability-60.mp4` using the existing ffmpeg command with `rate=60`,
deploy it, and open `stability.html?rate=60` for the higher-rate source test.
The current headset test was left at 72 Hz with AI on and the 60 fps clip playing.
Rate changes used temporary in-memory settings, not an explicit save operation.
Full measurements: `performance-20261101/gpu-refresh-sweep.json` and
`gpu-final-72.json`.

To compare the software path, write `{"hardware_canvas":false,"target_hz":30}`
to the helper's private `files/linux/direct-frame-config.json` before a fresh
producer attachment. Use `true` to return to GPU drawing. An active Nightfall
DEV session subsequently forwards its render/refresh target; a configured 30 Hz
value is only the initial target. Never switch canvas backends on a live producer.

### Real-service playback sampling

`measure-playback.py` samples private numeric producer/audio counters and
Nightfall's bridge state during **user-confirmed** playback. It does not inspect
the browser profile, page contents or media frames. Run with the host Python:

```sh
ADB=/path/to/adb /usr/bin/python3 tools/experiments/browser-quest-linux/measure-playback.py \
  --label netflix-ai-on --seconds 300 --interval 10
```

Results are written progressively to ignored
`.build-cache/browser-quest-linux/playback/<label>-<UTC time>.json`. Check `complete`,
sample errors, counter resets and the final summary. A changing sampled picture
hash is diagnostic, not a decoded-frame counter; audio progress does not prove
lip sync. Android battery temperature uses tenths of a degree Celsius.

On 2026-11-01 the user confirmed Netflix playback looked good with AI enabled,
then disabled AI for a baseline. That 25-second baseline measured 72.0 producer
posts/s, zero missed slots, advancing nonzero audio and no bridge errors.
The following five-minute AI-on run completed with 31 samples and no bridge
errors. It averaged 71.98 producer posts/s, with seven missed producer slots in
total, advancing audio, and 9,392 changed sampled picture hashes. Copy plus
drawing/submission averaged about 2.47 ms/frame (AI-off: 2.07 ms). Inference at
the final check was 31.8 ms / 19.9 Hz. Battery temperature ranged 41–43 C and
Android thermal status was 0 at the final check. These are sequential playback
windows, not identical-scene controlled benchmarks. User feedback on lip sync
and fan noise is still pending. Do not infer Netflix decode fps from posts.

Results: `performance-20261101/netflix-comparison-summary.json`, process-only
top snapshots and final thermal output, plus the full `playback/netflix-*` JSON
samples. No browser profile or media frames were collected for this measurement.

### 1080p desktop follow-up

The 1920×1080 experiment was rolled back after the user reported worse
performance; the current default is **1280×720**. The renderer reports both source
and output dimensions. To retry 1080p, write `1920x1080` into the guest
`/tmp/nightfall-display-size` before restarting the lab (remove that file for the
720p default). Only those two sizes are accepted. Chrome's window size
and Xvfb dimensions change together; the existing Nightfall Surface stays 1080p.

The same Netflix title played after the in-place helper update. Its normal
statistics UI initially reported **1280×720 at 30 fps**, video ~1024 kbps, ~234
seconds buffered and ~14 Mbps reported throughput. Increasing the desktop does
not establish 1080p Netflix delivery. Later fullscreen adaptation remains
unconfirmed. Two attempted performance samples had only bridge timeouts because
Horizon paused Nightfall behind ClearActivity; neither is a valid speed result.
Keep the headset worn and Nightfall foreground for the next sample.

`rfb-control.py` provides paced input without framebuffer capture. `--url` uses
Alt+D (Ctrl+L clears the DevTools console when it has focus). Complex scripted
console inspection proved unreliable; use the ordinary Netflix statistics UI
and verify focus rather than typing long expressions blindly. Diagnostic panels
were closed and fullscreen playback/audio restored. Temporary diagnostic
screenshots were removed; only numeric stats were retained in
`performance-20261101/netflix-1080-resolution-check.json`.

### Direct-display input routing

Controller pointer events and virtual-keyboard keys now route through the
authorized helper Binder connection while direct display is active. Coordinates
are normalized from Nightfall's browser Surface and scaled to the actual Linux
desktop dimensions. The helper uses a separate input-only RFB connection: it
never requests or decodes framebuffer updates. Display remains on the GPU path.
The ordinary WebView keeps its original input route when direct display is off
or its address field is being edited.

The helper tracks button/key ownership, releases held state on focus loss and
close, and preserves matching keysyms across modifier changes. Special-key
mappings include Insert, function keys, arrows, Page Up/Down and lock keys. No
keystroke contents or clipboard data are logged; `direct-input-status.json`
contains only connection state, dimensions and event counts.

Both input-enabled APKs built and were installed in place. Existing browser
regression tests passed and the input connection reached `ready`. The first
in-app attempt timed out with Nightfall paused, but the foreground retest
**passed** through the normal native Java entry points: two button clicks,
three matching down/up pairs, held drag motion, two typed characters including
Shift+B, one Insert event, matching key down/up counts and no remaining Shift.
Artifact: `performance-20261101/native-input-probe.json`.
`input-probe.html` plus the loopback metrics collector exposes
numeric click, drag, key, Insert and input-length counters for that check. The
page does not report entered text. Reopen Nightfall and keep it foreground, then
drive the normal `browserPointerFor` / `browserKeyFor` paths through the bridge.
Netflix was restored after this pass. A short 1080p post-reload sample averaged
57.3 producer posts/s, with bridge access throughout; this includes startup and
is not a settled playback result. Nonzero audio did not advance in that window;
the user may need to press Play/unmute on the restored player. Do not claim this
is the prior healthy five-minute 720p result. Physical controller hit alignment
still requires a user check. No claim that Netflix exposes a manual resolution
selector or that routing input changes its selected video quality.

### Performance rollback and startup timing correction

The user confirmed pause/fullscreen input worked, but reported worse performance.
Restored 1280×720 capture while keeping input enabled. Also found that a fresh
app could load the saved 72 fps setting after applying the default boot timing,
leaving 60 app fps / 120 Hz. Direct activation now reapplies loaded timing once.
Verified fresh activation changed `[saved=72, display=120, app≈60]` into
`[saved=72, display=72, app≈72]`; see `direct-startup-timing-fix.json`.

Native click/typing tests passed again with the smaller source and the same
1920×1080 Surface (`native-input-720-rollback.json`), verifying coordinate scaling.
Latest producer status showed about 72 posts/s, copy ~0.56 ms and draw/submission
~1.21 ms, versus the earlier 1080p status ~1.46/~3.59 ms. These are cumulative
transport metrics, not matched active-video windows. The attempted 20-second
Netflix sample again had bridge timeouts after the headset was put down, so
settled playback performance still needs confirmation. Do not report it as a
completed post-rollback Netflix benchmark. Controls remain enabled; Netflix was
restored for a user Play/quality check.

### Desktop-cursor latency (2026-11-01)

The user clarified that video playback was smooth; the **Linux desktop arrow**
was intermittently stuck. Hover-only tests through Nightfall's normal native
input entry point, observed using XQueryPointer inside the guest, reproduced
roughly 9–227 ms of input delay. Disabling ordinary x11vnc idle sleeps alone
was insufficient. Switching it live to `-nofb` reduced the six observed delays
to 25–50 ms, implicating its framebuffer polling loop rather than video decode.

The lab now starts a second loopback-only x11vnc on **5903** with
`-nofb -nonap -sb 0 -wait 5 -nosel -nobell`. LinuxRfbInput connects to that
input-only server. Port 5902 and noVNC remain unchanged for framebuffer fallback
and desk-side inspection. No video transport, XR layer, resolution or inference
setting changed. This adds one Linux process; account for it in the Android
phantom-process budget. Neither loopback RFB endpoint is authenticated; this
remains an isolated lab configuration, not a production security design.

After rebuilding and installing the companion in place, the same six-event
native-input test measured **10–32 ms**, including dev-bridge, UI scheduling and
20 ms observer sampling. These are small diagnostic samples, not a sustained
latency percentile or proof of physical-controller feel. Numeric artifacts are
under `.build-cache/browser-quest-linux/performance-20261101/`:
`pointer-latency-before.json`, `pointer-latency-nonap.json`,
`pointer-latency-nofb.json`, `pointer-latency-dedicated.json`.
Rebuild/install the companion **and** deploy the updated start-desktop.sh;
restart the Linux runtime before attaching direct display. An old runtime has
no 5903 listener and will not accept the new helper's input connection.
