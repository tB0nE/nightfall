# Capacity-aware options and tab dragging

Checkpoint baseline: Nightfall `b899073`, companion Vibepollo `062efa0a`.

## Capacity

Use the same host preview as admission to mark unavailable virtual resolutions
and physical additions. H.264 choices remain enabled if HEVC can accommodate
that choice, because selection will offer the existing codec confirmation.
Under HEVC/AV1, a no-fit choice is disabled. Check the smallest custom virtual
mode before disabling virtual creation entirely. Cache by host/layout/codec and
resolution profile, reject stale results, and retain final admission as authority.
Browser tabs do not use the desktop codec canvas budget.

## Drag interaction

Trigger/pinch press on a tab starts a pending gesture. A short release selects
normally; travel beyond a threshold starts dragging. Drop on another screen to
transfer; drop in empty space to detach onto a free grid cell. A single-tab
source disappears when transferred; its content remains alive. Dropping a lone
screen's tab into empty space moves the existing screen. Cancel on tracking or
focus loss, source changes, disconnect, or an invalid destination. Never leak a
trigger press into stream/browser content. Reuse the controls atlas for feedback.

Moves preserve tab resolution/crop preferences and monitor identity. They do not
create/delete virtual outputs, change capture selections, or restart the host.
Keep four visible screens and eight browser pages per screen. If the primary
surface becomes empty, promote the destination through the existing retirement
and inference-ownership lifecycle before removing that surface.

## Browser transfer constraints

Android WebViews are created using a Presentation's display context and their
callbacks own that Session. Reparenting the existing WebView across virtual
displays is unsafe. The first transfer implementation must save navigation state
and recreate the page in the destination Session, acknowledging the transfer
before removing source metadata. This can reload the page and interrupt media;
ordinary same-screen tab switches retain the existing ten-minute cache. Preserve
shared website cookies and browser storage. Never transfer a live fullscreen
custom view or mutate two Sessions outside Android's UI thread.

## Verification

Test fit matrices and stale results; monitor transfers and source replacement;
last-tab transfer without disconnect; browser identity remapping and history;
failed transfer rollback; screen/tab limits; click-versus-drag threshold and
release consumption; tracking cancellation. Build release-optimized DEV and run
bounded Quest checks. Final drag comfort and placement need headset acceptance.

## Implemented checkpoint — 2026-11-15

- Capacity results are fetched asynchronously using the existing codec budget
  preview. Virtual preset/custom creation buttons and physical additions use
  those results; H.264 remains selectable where the HEVC confirmation can help.
  The smallest supported custom mode determines whether virtual creation can
  remain available. Browser rendering is excluded from that codec budget.
- Cache invalidation includes host/layout/codec/profile. Results are refreshed,
  stale replies discarded, and repeated toolbar checks are throttled to avoid
  doing full workspace serialization on every pointer frame. Final admission
  still runs before host changes.
- `TabDragState` distinguishes ordinary release-to-select from movement beyond
  a 25 mm / 1.5%-of-screen-width threshold. Trigger or pinch owns the gesture
  until release; tracking cancellation clears it. Other UI targets are not
  treated as empty-space drops. Source feedback uses the existing controls atlas.
- Source operations transfer physical/virtual/browser tabs, preserve tab
  preferences, detach onto the grid, and reposition an already-singular screen.
  Four-screen and eight-tab destination limits are enforced. Empty source
  surfaces are removed by instance, avoiding collisions between monitor IDs.
- Primary promotion uses the existing render/inference retirement lifecycle.
  Compositor consumers detach before the old Android surface closes. Neither
  tab moves nor detachment create/delete host displays or restart the stream.
- Android browser transfers execute on the UI thread, save navigation state,
  assign a destination-local page identity, and recreate the WebView using the
  destination Presentation context. Cookies/storage remain in the same app
  profile. Fullscreen custom views cannot transfer; leave fullscreen first.
  Cross-screen browser transfers can reload media; normal tab switches retain
  the existing cache. Completed transfer acknowledgements survive app standby.
- Secondary browser tab operations now also work without a desktop connection.

Verification:
- All 73 GDScript scripts passed, including gesture thresholds/cancellation,
  monitor merge/detach, last-tab source removal, limits, preference preservation,
  browser-only eligibility and capacity availability policy.
- Two isolated Android tests passed on Quest 3: destination display/navigation
  restoration, and source preservation when cancelled or destination is full.
  These use `app.nightfall.quest.instrumented`, local pages only, and are
  correctness tests rather than performance measurements.
- Release-optimized DEV APK built; ordinary signing/data/pairings retained.
- Full-app source-lifecycle smoke found the browser-only eligibility issue above.
  After that fix, the retry was blocked before starting by the paused headset
  app. Do not claim that the entire real XR drag path has passed acceptance.
  Raw evidence: `build/verify/tab-dragging/browser-merge-smoke.json`.

Manual acceptance: drag a browser/physical/virtual tab onto another screen;
merge a one-tab screen; drag a tab into empty space; repeat at the four-screen
limit. Check pointer feel, selection, grid placement, crop/resolution retention,
stream continuity and AI 3D on the primary. Test browser-only use as well as an
active desktop/PCVR session. Leave fullscreen before transferring a video page.

The user confirmed the interaction and secondary-screen fixes work as intended.
The changes are committed following that acceptance. No push or PR was requested.

### Secondary monitor presentation correction

User acceptance found that virtual tabs moved/created on secondary surfaces
could show cropped browser pixels or black while the same tab worked on primary.
Native secondary selection previously excluded any registered browser provider,
even an inactive/suspended one. Native eligibility, secondary submission and
legacy-layer retirement now distinguish current browser ownership from a retained
provider. The legacy YUV cache also tracks recipient screen/material identities,
selected tabs and provider generations, not just decoder texture IDs. Monitor
geometry selection explicitly invalidates/rebinds decoder textures so a static
frame cannot leave the previous browser image attached.

All 74 GDScript scripts pass, including a new secondary-surface regression test
for inactive provider ownership, active/closing browser isolation, virtual crop,
legacy-layer retirement, static-texture source changes and new screen materials.
The release-optimized DEV APK was rebuilt for in-place headset installation.
User visual acceptance passed: creating and dragging virtual monitor tabs onto
secondary screens and switching content now work as intended.
