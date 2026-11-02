# Minimal Mesa/KGSL shader-draw failure alongside Quest XR

> Activity-reporting correction (2026-11-02): earlier claims that Horizon was
> blocking launches are not established. The test reporter selected the last
> resumed activity across multiple displays, often the taskbar even when
> Nightfall was resumed. Reporter corrected; a plain GPU-experiment-off launch
> reached XR-ready in ~2.65s. GPU hangs remain independently confirmed.


2026-11-02; unresolved. Experimental GPU browser remains disabled.

## Reproducer and result

The local generated test is:
`tools/experiments/browser-quest-linux/run-minimal-gpu-xr-probe.py --draw`.
It has a 70-second on-device watchdog and independent kernel-log monitor.
Each GPU phase attempts 120 frames paced at 60/s, about two seconds.
Use host `/usr/bin/python3`, the Android SDK adb on PATH, and ADB set to that
binary. It requires the optimized Browser Lab companion built in this branch.

The guest script creates a private 32x32 GLES3 pbuffer, clears it, draws one
constant-red triangle using gl_VertexID (no uploaded vertex buffer), checks a
centre pixel and a background pixel, then destroys the context. There is no
X server, browser, media decode, imported image, external pixel buffer, Surface
handoff or AI inference in the probe. The rest of Horizon OS still runs.

Observed comparison:

| Phase | Result |
| --- | --- |
| Same private pbuffer, clears only, standalone | 120 frames correct |
| Clears only with Nightfall XR welcome active | 120 frames correct |
| Triangle standalone | 120 frames correct in 2.0s |
| Triangle with Nightfall XR welcome active | GPU hang; centre-pixel mismatch after driver recovery |

Triangle artifact:
`.build-cache/browser-quest-linux/minimal-gpu-xr-20261102T204039Z.json`.
Corresponding `-kernel.txt`: device time 21:40:47.106, context46 timestamp1,
process `/usr/bin/python3 /tmp/probe-minimal-gpu-clear.py --draw`.
First timestamp suggests the first submission, but the original probe did not
record the first failed frame index. Do not claim an exact frame from that
artifact; numeric failing-pixel/frame diagnostics are added locally afterward.

Nightfall preconditions recorded `[XR viewport enabled=true, browser=false,
streaming=false]`. No preference changes are needed for this probe. Kernel
monitor stopped both apps on detection. GPU config remained false. These are
short correctness tests; they do not establish longer-session stability.

## Relevant environment and limits

- Quest 3, Adreno 740v3 / chip0x43050b00.
- Ubuntu ARM64 userspace under PRoot, not a full VM.
- App-private Mesa fork pinned at eb3e7fd4f009cab04b1482aad4843c0bde28a786.
- The probe uses matched Mesa/VA library bundle and the corrected allocation
  ABI adapter (legacy alloc -> GPUOBJ_ALLOC/INFO, preserving FORCE_32BIT).
- The app-private DRM shim is also preloaded, as in the browser path. The
  test therefore does not prove unmodified upstream Mesa has the same fault.
- Driver FD740v3, proprietary Android renderer elsewhere in the XR session.
- No root, kernel, global graphics library or SELinux changes.

## Source audit findings

Xvfb's XFillRectangle is a GLAMOR shader/instanced-draw path, not equivalent
to a GPU clear. The earlier description "Xvfb alone is the failing component"
was too narrow: this new reproduction does not need Xvfb at all.

CPU/GPU resource waits and KGSL BO fence tracking already exist in this Mesa
source. The CPU preparation function's KGSL-specific implicit-sync no-op
must not be read without the common fd_bo_cpu_prep implementation, which
flushes and waits tracked fences first. No missing-wait patch was made.

KGSL command GPU address plus offset was compared to the same fork's Turnip
submission code; both construct a resolved GPU address with zero offset for
ordinary IB commands. No offset patch was made from speculation. Qualcomm's
public kernel source is a reference, not proof it exactly matches Quest's
installed kernel:
https://github.com/qualcomm-linux/kgsl/blob/gfx-kernel.le.0.0/kgsl_drawobj.c

The FS early-preamble reset workaround exists in the GLES driver already.
Context restore and shader setup/emission should be examined against this
small repro before further full-browser flag experiments.

## Next investigation

1. Capture generated shader and command-state diagnostics from the passing
   standalone case; compare the shader-draw submission with the passing clear.
2. Check KGSL context scheduling/restore and shader-state initialization when
   mixed with vendor XR contexts. Preserve distinction between shader
   preambles, context restore preambles and kernel preemption.
3. Only test a focused driver change supported by the audit, using this
   tiny comparison first. No Chrome/Xvfb/video stress until it passes.
4. Startup-only Xvfb mode is prepared but not run; its priority is now lower
   because the shader-only repro is substantially smaller.

No confirmed driver fix. Do not re-enable normal GPU browser mode.


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
