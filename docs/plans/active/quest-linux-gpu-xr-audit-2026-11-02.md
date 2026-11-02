# Quest Linux GPU / XR coexistence audit — 2026-11-02

> Activity-reporting correction (2026-11-02): earlier claims that Horizon was
> blocking launches are not established. The test reporter selected the last
> resumed activity across multiple displays, often the taskbar even when
> Nightfall was resumed. Reporter corrected; a plain GPU-experiment-off launch
> reached XR-ready in ~2.65s. GPU hangs remain independently confirmed.


Status: unresolved; experimental GPU mode stays disabled. No production change
or model/inference optimization is claimed. Continue on
`codex/quest-linux-browser-spike`.

## Evidence

| Test | Result | Limits |
| --- | --- | --- |
| Headless ImageReader, CSS animation | Passed two short cycles, ~59 posts/s | No active Nightfall XR renderer; not unique content FPS |
| Headless ImageReader, generated AVC | Passed; hardware AVC decoder selected | Same limits |
| Nightfall XR, generated scroll/layout, AI3D off after startup | GPU hang; Xvfb reported | Source import and all graphics clients present |
| Nightfall XR, generated colours instead of source blit, AI3D off | GPU hang before first post | Imports, Chrome and Xvfb still present |
| Same colour-only path, untiled Mesa rendering across Linux processes | Failed; acquisition timeout and repeated kernel hangs | Not a successful mitigation |

Corrected colour-only artifact:
`.build-cache/browser-quest-linux/gpu-nightfall-20261102T173638Z.json`.
Untiled artifact:
`.build-cache/browser-quest-linux/gpu-nightfall-20261102T174155Z.json`.
Final untiled kernel log:
`.build-cache/browser-quest-linux/freeze-20261102/untiled-final-logcat.txt`.
The untiled run lost the dev bridge before its ordinary monitor loop reported
a hang; the final kernel log confirms hangs affecting multiple clients.

This is not proof that any context named by the kernel caused the fault.
Video decode, per-frame X11 source blits and active AI inference are not
necessary for at least the corrected colour-only reproduction. Imports and
concurrent Linux rendering have not been eliminated. Do not infer that a
Wayland port will fix it: that can retain the same Mesa/KGSL driver path.

## Offline driver audit

The pinned Mesa checkout is `eb3e7fd4f009cab04b1482aad4843c0bde28a786`.

- KGSL BO destruction already waits on tracked fences; merged-submit lifetime
  retention is already in the pinned source. Do not re-add these as fixes.
- Both Freedreno GLES and Turnip contain the shader early-preamble reset
  workaround in their static state setup. It was inspected, not missing.
- Context creation uses SAVE_GMEM, NO_GMEM_ALLOC and PREAMBLE; inspecting an
  old description of KGSL's original submit ABI does not establish modern
  GPU_COMMAND semantics. No speculative kernel context flags were changed.
- The `os_same_file_description` warning is from a process-local screen cache
  falling back to inode/device comparisons when OFD comparison is unavailable.
  It cannot directly alias Mesa state across Linux and Android processes.
  Incorrect aliasing within one process is not yet excluded.
- Quest's FD740v3 entry differs from regular FD740: default highest_bank_bit=15
  rather than explicit 16, plus a UBWC flag hint override. The former is used
  in Vulkan/layout code rather than the inspected Gallium GLES emission path;
  it is not grounds to change the headset's hardware table blindly. Hint
  compatibility remains a candidate to validate against device metadata.
- The failed sysmem comparison is a diagnostic result, not a performance
  recommendation. It still uses the GPU and adds no full-frame pixel copy.

Primary references:
- [Mesa Freedreno architecture and debugging](https://docs.mesa3d.org/drivers/freedreno.html)
- [Qualcomm gen7 ringbuffer implementation](https://github.com/qualcomm-linux/kgsl/blob/gfx-kernel.le.0.0/adreno_gen7_ringbuffer.c)
- [Historical KGSL documentation](https://github.com/freedreno/freedreno/wiki/kgsl-kernel)
  (2014, older ABI; not a modern recipe)

## Test improvements

`--driver-policy sysmem` applies FD_MESA_DEBUG=sysmem to Xvfb and Chrome via
start-desktop.sh, and to the separate Linux capture process before loading
EGL. Temporary policy and capture-mode files are restored/removed afterward.
Default remains unchanged. `--capture-mode solid` deliberately omits per-frame
source reads but does not skip source import/setup.

The main app's dev bridge starts before saved host settings load. Runner now
waits for `_startup_ready` before setting AI3D off and verifies it remains off.
Earlier cold runs that saw default speed=0 before settings loaded are invalid
AI3D-isolation evidence; see chronological handoff for those artifacts.

New `gpu_hang_monitor.py` reads kernel logs on a separate host thread and
force-stops both apps on first hang independently of blocked dev-bridge
requests. The existing detached device watchdog remains a second deadline.
This improvement is locally tested, not hardware-validated yet. It cannot
promise to interrupt every hung kernel/driver operation immediately.

17 local helper tests pass. Shell/Python syntax and diff checks pass. No driver
library or main APK rebuilt in this audit; no system graphics/security changes.

## Next useful isolation

Avoid further all-components interactive stress tests. Prepare a minimal
Linux offscreen EGL clear with NO Xvfb, Chrome, XComposite, imported pixel
buffers or video, while Nightfall is already in XR. Compare the same clear
without Nightfall. If only the XR combination fails, investigate driver state
and scheduling coexistence before touching browser input or transports.

If minimal coexistence passes, add Android-owned shared-buffer import, then
capture, then Xvfb/Chrome one at a time. Use short bounded tests with independent
kernel monitoring and abort on the first failure. Verify correct dimensions,
source/destination ownership and process scheduling at each stage.

Final verified device state after untiled test: both apps stopped, no watchdog
lease, awake override cleared, gpu_renderer=false, temporary driver-policy and
capture-mode files removed. All repository work remains uncommitted.


### Minimal private-pbuffer baseline — 2026-11-02

Added probe-minimal-gpu-clear.py: GLES3 32x32 private pbuffer, changing GPU
clears and 1-pixel correctness checks, 120 frames paced at60/s, four-second
local alarm. No X11/Chrome/video/imports/sharing. GpuAllocationService's new
minimal_clear option uses the same matched Mesa bundle/preloads as the failed
browser route, with its existing five-second subprocess deadline. Optimized
companion rebuilt and installed in place; main APK unchanged.

run-minimal-gpu-xr-probe.py wraps standalone then real-XR comparison in70s
on-device watchdog plus independent kernel-log monitor. Baseline passed:
FD740v3,120 correct frames,2.0s; the OFD warning still appears despite success.
Artifact minimal-gpu-xr-20261102T175950Z.json. XR phase did not run: Nightfall
launch was held by Horizon and hit12s command deadline. Both apps stopped,
no watchdog lease/awake override;GPUfalse. No additional graphics stress.

Runner now offers --already-open to skip baseline and preserve a manually
foregrounded Nightfall. XR preconditions require startup ready, OpenXR
initialized, no browser and no stream. This avoids modifying AI3D preferences.
Next: user opens Nightfall, then run minimal runner --already-open. Cannot
claim XR coexistence pass/failure from the baseline alone.17 local helper
tests pass; shell/Python syntax and diff checks pass. Work uncommitted.


### Minimal XR coexistence comparisons passed — 2026-11-02

Private clear WITH active Nightfall XR passed:120 correct frames in2.0s on
FD740v3. Artifact minimal-gpu-xr-20261102T180212Z.json. First retry aborted
before GPU work because Expression cannot resolve XRServer as a singleton;
fixed precondition to main.get_viewport().use_xr. Corrected run confirmed
[XR viewport=true,browser active=false,streaming=false]. No saved settings
were modified. Both standalone and XR private clears now have passing evidence.

Advanced the same runner with --share (128x128) and --hd (1280x720), reusing
the established Android-owned AHB sharing probe. BOTH passed alongside XR:
three RGB clears written with Linux Mesa and exact corresponding Android
readback colours;guest_exit=0,native_exit=0. No Xvfb,Chrome,video or actual XR
output Surface in these sharing tests. Synchronization is glFinish/ack, not
the continuous frame fence protocol. Thus these are correctness checks, not
sustained throughput/stability validation.
Artifacts minimal-gpu-xr-20261102T190109Z.json (128) and
minimal-gpu-xr-20261102T190216Z.json (720p); combined summary in
freeze-20261102/minimal-xr-comparison-summary.json. Their kernel logs contain
zero GPU-hang messages. The descriptor warning remains in passing probes.

This narrows the fault: neither basic Linux hardware GLES alongside XR nor
simple synchronous Android/Linux AHB sharing necessarily hangs. Next add the
continuous fence handoff without X11/Chrome, followed by the actual output
Surface. Keep those variables separate; do not attribute prior failures to
all Linux/XR coexistence. Do not re-enable ordinary accelerated playback yet.

Cleanup verified after all runs: apps stopped,no lease,no awake override,
gpu_renderer=false. Main APK unchanged; optimized companion from minimal-clear
build installed. Python compilation/diff checks pass. Changes uncommitted.


### Continuous ownership handoff passed; no-X11 real Surface prepared — 2026-11-02

Added GpuCapture mode generated, which skips all X11/Composite/DRI3 setup and
source imports, creating only the Android-owned destination EGLImage/FBO.
This differs from solid mode, which retained X11 source setup. Guest
probe-gpu-fence-loop.py uses generated GPU colours for120 paced frames.
Native reference exporter now waits acquire sync-files with a100ms CPU poll
and sends a native release fence per acknowledgement, matching the strict
producer protocol. Old3-colour glFinish/ack route remains separate.

run-minimal-gpu-xr-probe.py --fences PASSED baseline AND XR welcome-screen
phases:120 frames,120 acquire fences,120 release fences each,correct changing
pixel values,guest_exit=0,native_exit=0. Artifact
minimal-gpu-xr-20261102T190630Z.json, copied to
freeze-20261102/continuous-fence-comparison.json. No detected kernel GPU hangs.
Limits:1280x720,~2seconds,Android1-pixel diagnostic reads/glFinish;no native
Nightfall output Surface,Chrome,Xvfb orvideo. Not a sustained playback claim.

Next stage prepared: --surface-only on run-gpu-nightfall-probe.py. Private
config generated_minimal_gpu_test bypasses BrowserLabService and all Chrome,
Xvfb,audio/input/runtime readiness setup. GpuFrameRenderer launches bounded
probe-gpu-surface-generated.py with generated mode into the REAL Binder-supplied
Nightfall Surface;120 frames,5s producer alarm. NoXWD header needed;1280x720
diagnostic dimensions. Normal runtime unchanged when privateflag absent.
Expected completion of this generated producer is not treated as a live
browser crash. GPU config and temporary files restored by runner.

Optimized companion/native reference probe rebuilt and installed.18 local
helper tests pass,shell/Python syntax/diff checks pass. MainAPK unchanged.
First actual Surface attempt gpu-nightfall-20261102T190836Z.json blocked at
bridge because Horizon taskbar paused Nightfall;NO graphics test ran. Need
user to foreground Nightfall, then run:
run-gpu-nightfall-probe.py --surface-only --disable-ai3d --already-open

All apps stopped by cleanup;GPU mode remains false. Work uncommitted.


### Actual Nightfall Surface, no X11/Chrome: PASS — 2026-11-02

After user foregrounded Nightfall, ran --surface-only --disable-ai3d
--already-open. Artifact gpu-nightfall-20261102T192136Z.json and matching
kernel log; copied summary freeze-20261102/generated-real-surface-retry.json.
AI3D initial3/test0/last0;browser active and direct_active true. Native actual
Binder-supplied Surface posted120 frames,120 acquire fences,120 release fences,
state stopped/closed,1280x720,~59.15 posts/s,~0.691ms mean draw/post wall time.
Producer120 frames in2.0s,120 release waits,passed. No full-frame CPU copy.
Kernel monitor reported no hangs. This is a SHORT generated-path pass, not
ordinary browser playback stability or a performance/comfort guarantee.

No Chrome,Xvfb,video,audio or Linux input service was started in this route.
Together with prior private-clear and repeated shared-buffer checks,this shows
the basic XR/interop/display route can work. Next isolate adding Xvfb without
Chrome,then Chrome separately. Do not attribute the old fault to general
LinuxGPU/XR coexistence or declare the browser repaired. GPU default stays off.

Both apps stopped;watchdog and awake override cleared;GPUfalse verified after
this test. MainAPK unchanged. All experiment work remains uncommitted.


### Xvfb-only addition reproduces; GLES fallback also fails — 2026-11-02

Extended generated real-Surface probe with X11 modes off/idle/capture and
idle-gles/capture-gles. Idle starts private GPU Xvfb :9, creates a1280x720
window and fills it with changing X11 colours, while the Android Surface still
receives INDEPENDENT generated AHB colours (no X11 imports/copies). No Chrome,
VNC,video,audio,input services. Existing watchdog/kernel monitor retained.

idle mode reproduced GPU hang after17 posts,balanced17 fences. Kernel names
Xvfb context56 ts20 at21:06:47.810. Artifact
gpu-nightfall-20261102T200640Z.json. Thus adding Xvfb accelerated drawing can
reproduce WITHOUT consuming its image or running Chrome; not proof of exact
root cause, nor a claim the server alone fails without XR.

Compared desktop GL against Xvfb's existing GLES fallback. Added app-private
opt-in NF_XVFB_GLES (default unchanged),reproducible patches/build script and
explicit GL_VERSION/renderer/glamor-ready diagnostics. Rebuilt isolated Xvfb
and optimized companion;staged privately. Original binary retained at
files/linux/rootfs/opt/nightfall-xvfb/Xvfb.before-gles-test.
GLES test verified OpenGL ES3.2 Mesa27 FD740v3 +GLAMOR_READY=1,then also hung
after17 posts. Artifact gpu-nightfall-20261102T201009Z.json. Kernel first names
vrshell;context naming is not proof of root fault. No GLES mitigation claimed.

Next candidate: resource layout. Passing probes use linear buffers;Xvfb can
allocate internally tiled/UBWC-compressed pixmaps. Added driver-policy linear
(FD_MESA_DEBUG=notile,noubwc),applied before EGL loading and inherited by
isolated Xvfb,still GPU rendering/no full CPU copy. This is separate from
sysmem rendering (which does not itself disable texture tiling/compression).
No hardware claim: first linear attempt gpu-nightfall-20261102T201133Z.json
blocked at bridge by Horizon taskbar BEFORE GPU capture.

Next requested manual-foreground command:
run-gpu-nightfall-probe.py --surface-x11 idle --driver-policy linear --disable-ai3d --already-open
If it passes,validate Xvfb image capture separately,then add Chrome.
If it hangs,stop and investigate source draw/driver state;do not blindly
repeat full playback. No Chrome-added test run this turn.

18 local helper tests pass,shell/Python syntax/diff checks pass. Both apps
stopped,watchdog/awake override cleared,GPUfalse restored. No system driver,
security policy or mainAPK changes. Work remains uncommitted.


### Linear-buffer Xvfb retry: still GPU hangs — 2026-11-02

User foregrounded Nightfall. Ran --surface-x11 idle --driver-policy linear
--disable-ai3d --already-open. Artifact gpu-nightfall-20261102T203232Z.json,
matching kernel log,copy freeze-20261102/xvfb-linear-idle-retry.json.
Initial AI3D3,test0,last0. Kernel monitor detected a GPU hang and aborted.
Native stopped/closed after16 posts with16 acquire/release fences. Producer
was killed before final status. This is NOT a fix; requested notile,noubwc
policy does not resolve this reproducer. No claim every allocation modifier
was independently measured; imports can impose their own layouts.

No additional hardware tests this turn. Next offline investigation should
focus on Xvfb GLAMOR draw submission/state/resource lifetime under concurrent
XR. Compare Xvfb startup-only against its first XFillRectangle draws,then
examine affected command emission and batching. Chrome/video/AI inference
and consuming Xvfb's image are not prerequisites for this isolated repro.
Avoid a string of further ungrounded debug-flag hardware attempts.


### Breakthrough: tiny shader draw reproduces without Xvfb — 2026-11-02

See docs/plans/active/quest-linux-minimal-triangle-reproducer.md. Added --draw
to the private clear comparison. Standalone passed120 triangle frames in2.0s;
same tiny shader draw with XR active hung. Kernel names the probe's own Mesa
context46 timestamp1. No Xvfb,Chrome,video,imported image or Surface handoff.
The old Xvfb-specific interpretation is superseded: shader drawing in the
Mesa/KGSL path alongside XR is enough for this reproducer. Exact cause remains
unconfirmed. No need to keep reproducing full-browser freezes.

Artifact minimal-gpu-xr-20261102T204039Z.json and kernel log. Driver recovery
caused Triangle centre mismatch; first-bad-frame/pixel diagnostics were added
locally afterward,not yet deployed/retested. Startup-only Xvfb test mode also
prepared (no window map/fill) but not run; lower priority now.

18 helper tests passed;optimized companion compiled/installed for minimal
triangle. No driver patch from speculative command offsets or missing common
BO waits. Both apps stopped,no lease/awake override,GPUfalse verified. MainAPK
unchanged. No more hardware tests this turn;all work uncommitted.


### Generated shader diagnostics and arithmetic control — 2026-11-02

Added --standalone-only / --diagnostics to minimal runner. Diagnostics uses
ONE generated frame and IR3 vs/fs/disasm/nocache flags with XR stopped;
saves only our generated shader code locally. No website/media/profile data.
Artifacts: minimal-gpu-xr-20261102T204557Z.json and generated-shaders.txt.
Default array-position VS has a constant-table UBO load and early preamble.
Internal helper shaders also appear in this log;don't attribute every
preamble count to the application's actual VS/FS.

Tested --no-early-preamble: standalone diagnostic confirmed all reported
preamble early flags0. Artifact204714. Full120-frame standalone passed but
XR still hung (minimal-gpu-xr-20261102T204728Z.json). Not a fix. Tested
--no-preamble only in standalone compiler diagnostic (artifact204923): it
still emits10-instruction ordinary preambles. Do not call this preamble-free;
no XR test was run for that option.

Added --arithmetic-vertex: generate positions using gl_VertexID arithmetic,
with centre/background correctness checks and no position table. Standalone
compiler output confirms no UBO loads/preamble in actual application
VS/BVERT; red FS also has no preamble. Artifact205121 and shader log.
Standalone120 frames passed in2.0s in artifact205137. XR phase blocked by
Horizon before probe start. A retry using normal MAIN+LAUNCHER intent flags
also failed to foreground/complete startup (artifact205257);no GPU work in
that retry. Do not report arithmetic-control XR success or failure yet.

Next pending manual-foreground test:
run-minimal-gpu-xr-probe.py --already-open --draw --arithmetic-vertex
If this passes,constant-data/preamble path is narrower candidate. If it hangs,
the generic graphics state/context coexistence issue remains. No browser or
Xvfb tests needed until this minimal comparison is understood.

Optimized companion updated in place;mainAPK and normal browser/driver
configuration unchanged. Shader diagnostics are opt-in and probe-local.
Both apps stopped,lease/awake override cleared,GPUfalse verified. Python
compilation/diff checks pass. Work remains uncommitted.


### Arithmetic triangle fails too; launch-reporting bug corrected — 2026-11-02

User manually opened Nightfall; arithmetic-only XR retry reproduced GPU hang.
Artifact minimal-gpu-xr-20261102T205507Z.json;kernel21:55:09.660 identifies
probe python3 context51 ts3. Application VS/BVERT have no table UBO/preamble,
so that particular shader feature is not necessary for the failure. Do not
infer every internal helper shader is preamble-free. Monitor killed apps
before the probe wrote final numeric failure fields;no failed-frame claim.

User questioned repeated Horizon launch-block explanations. Found an actual
reporting bug: run-gpu-nightfall-probe.py selected split(...)[-1],the LAST
resumed activity across multiple Android displays. TaskBar can remain listed
while Nightfall itself is resumed. Snapshots after hang errors can also be
after the monitor already stopped Nightfall,so they cannot establish the
cause of a launch failure. Old Horizon-cause claims are withdrawn pending
proper lifecycle evidence. Startup timeouts themselves were real.

Added android_activity_state.py;report all resumed activities,prefer the app
record for display,explicitly state limits,and preserve original test errors
if snapshot collection fails. Three regression tests cover app+taskbar,
absent app and duplicate/empty records;21 total local tests pass. Both test
runners use the structured snapshot now. No mainAPK/runtime changes for this.

Ran one plain Nightfall launcher check with LinuxGPU config=false and no
companion process. Ready at~2.65s;OpenXR viewporttrue. Android listed BOTH
Nightfall and taskbar as top-resumed on their separate displays. Artifact
plain-launch-20261102T205725Z.json and log. This demonstrates the taskbar
observation alone was misleading,not a new confirmed Horizon restriction.
It does not explain every earlier intermittent startup timeout.

Final cleanup verified: apps stopped,no lease/awake override,GPUfalse.
Recorded findings;no further GPU tests this turn. Next driver work should use
the arithmetic triangle for a minimal shader/context coexistence reproducer.
All work remains uncommitted;mainAPK unchanged.


### Earlier software-browser baseline revalidated — 2026-11-02

User correctly asked why the previously working browser became unstable.
Two GPU boundaries must be distinguished: the earlier route renders Linux
Chrome/Xvfb in software,then uses Android hardware Canvas to scale/post to
Nightfall's Surface. The new accelerated route additionally runs Linux Mesa
shader workloads;the isolated XR hang is in that experimental addition.

Compared CPU Canvas renderer against commit151f5cd: only FrameRenderer
interface/visibility annotations changed,no pixel-copy implementation change.
Device config GPUfalse,hardwareCanvastrue,1920x1080;no legacy renderer/policy
file override found. Added explicit service NF_GPU_DIRECT=0 ->software
selection so a future stale manual GPU renderer file cannot override failure
shutdown. This is defensive,not the cause found on this headset. NF_GPU_DIRECT
unset retains manual lab overrides;1 selectsgpu-direct. Shell syntax checked.

Added --software-baseline to existing real-Surface runner:GPUfalse,software
Chrome renderer pinned temporarily,temporary generated-only browser profile,
Android Canvas path,original renderer/config restored afterward. First launch
blocked with actual GuardianDialogActivity/ClearActivity records (unlike the
previous erroneous taskbar-last attribution);no browser capture ran then.
User foregrounded app for retry.

PASS artifact gpu-nightfall-20261102T210458Z.json,copy
freeze-20261102/software-browser-baseline-retry.json:
- source/output1920x1080,hardware_canvas,rawbitmapcopytrue;
-814 posts over11.40s,71.42 posted/s,target72Hz;
-247 changed samples,7late slots;
-meanCPUcopy1.18ms,meanCanvasdraw/post2.35ms;
-post intervalp50~13.89ms,p95~14.61ms;
-appbrowseractive/directtrue,renderer stoppedcleanly;
-no detected GPU hangs.

Limits:short generated video/UI fixture,not Netflix authentication/playback,
unique decoded video FPS,manual touchcomfort or long-session validation. Do
not equate the1920x1080canvas with Netflix video resolution. Baseline working
does not make Linux GPU route stable. Preserve this route before further
acceleration changes. Candidate next strategy:separate hardware decode from
Linux GPU compositing,provided Chrome/backend supports it;research and test
rather than claim compatibility. Kernel/Mesa draw reproduction remains valid.

Normal browser profile/sign-ins untouched. Both apps stopped,lease/awake
override cleared,GPUfalse verified. MainAPK unchanged;all work uncommitted.
