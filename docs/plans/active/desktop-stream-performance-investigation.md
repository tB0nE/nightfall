# Desktop stream regression investigation — 2026-10-24

The user reported Roblox desktop streaming through Meteor performing normally
at 1440p/90 Hz but around 80 app FPS at 120 Hz, with local or Meteor depth. They
only noticed this with Nightfall's settings menu open; closed-menu performance
has not yet been compared. Turning passthrough off caused the whole headset to
reboot, not merely an application crash.

## Evidence and fixes

- The connected headset's live logs begin after reboot. The crash buffer is
  empty, Android exit history has no matching recent app crash, and no usable
  tombstone or last-kernel-log DropBox entry was retained. Boot reason only says
  `reboot`; pstore is permission denied. No confirmed graphics-driver diagnosis.
- Automatic XR discovery checked configuration and enumerated hosts every
  rendered frame after retry elapsed, even with an established watcher. It now
  returns early for a live control connection and throttles discovery retries.
- Visible settings refreshed PCVR controls every frame and unconditionally
  reapplied the PCVR toolbar theme override. Theme updates now occur only when
  the color changes; periodic status refresh is limited to four times a second.
  Explicit setting changes still refresh immediately. Unchanged option values
  skip redundant updates.
- These are demonstrated avoidable CPU/UI costs, not measured proof of the
  entire FPS regression. No depth resolution or inference quality was reduced.
- Performance logs now include app FPS, process/physics time, native-renderer
  activity, depth-warp GPU time, requested display rate/render cap, menu,
  passthrough, background, screen count and PCVR state. Process time is not a
  measurement of total GPU frame time; warp GPU time covers only the depth pass.
- Passthrough toggles flush state checkpoints before and after the transition,
  improving persistent diagnostics for a subsequent reboot. No speculative
  passthrough lifecycle change has been applied without a crash record.

## Next headset comparison

Enable Stats, keep stream/model/ambient settings constant, compare 120 Hz with
menu closed and open, then export diagnostics. Compare with 90 Hz as control.
If reproducible, record whether passthrough-off reboots with AI 3D off and which
background was selected. Obtain the previous/current persistent app log via
Download Log before repeated app restarts rotate it away.

The optimized DEV APK with these fixes was built for Quest testing. The full
GDScript suite passed before deployment; added regressions cover active-watcher
discovery suppression and unchanged-menu theme invalidation. Runtime FPS and
the reboot remain to be confirmed by headset testing.

## Follow-up: confirmed performance and pointer recovery

The user confirmed the updated build easily reaches 120 app FPS again. Export
`Nightfall-diagnostics-20261024-153007.txt` also records sustained 120 app FPS.
This does not imply every incoming video frame was presented: video-update FPS
is tracked separately and sometimes lower.

After a short headset removal at 15:26:13–15:26:16, trigger presses repeatedly
activated the primary screen's SBS shortcut. Every recorded hit used exactly the
same local coordinates through 15:26:47. Thus the log supports a stale/fixed ray
target, rather than arbitrary controller buttons being remapped to SBS. It does
not include enough controller-pose telemetry to prove the underlying runtime
tracking failure.

Pointer recovery now rejects inactive/untracked controller poses, suppresses
pointer dispatch while the application is paused, and requires trigger/grip
release after interruption before accepting pointer clicks. Controller rays are
reattached to their controller transforms on resume to clear a stale hand-aim
world transform. The secondary menu pointer also requires valid tracking.
Regression tests cover tracking loss, held input across resume, rearming after
release and an untracked XR controller. Full GDScript tests passed; headset
recovery remains to be retested.
