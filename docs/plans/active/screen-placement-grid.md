# Screen placement grid

Status: Active — implementation and automated validation

Branch: `codex/screen-placement-grid`.

## Agreed behavior

- Replace screen-sized layout slots with a fine 3D lattice: flat, concentric
  cylinders, or concentric spheres. Curved grids derive their radius from the
  primary screen's current curvature, not the viewer's moving head.
- Primary movement remains free and carries the workspace rigidly. Resizing
  primary must not reposition other screens. Changing primary preserves all
  existing transforms; subsequent edits use the new reference.
- Secondary dragging is free while moving quickly. Slow movement engages snap;
  speed and position hysteresis prevent chatter. Releasing does not force a jump.
- Resize preserves aspect ratio and pins the opposite corner. The aspect-ratio
  constraint wins over landing both coordinates exactly on arbitrary grid points.
- Display the lattice only while arranging. Reuse scene rendering, with no new
  OpenXR composition layers and no host stream restarts for placement edits.
- Screens settings expose grid shape and spacing independently of host support.
- Named save/load presets follow after placement is validated. They should save
  grid settings, sizes, relative transforms and primary assignment. Restoring
  content/connections is a separate concern; do not automatically restore a layout
  at startup before the user chooses one.

## Implementation sequence

1. Pure forward/inverse grid geometry and slow-movement snap state, with tests.
2. Integrate secondary dragging, pinned-corner resizing and transient guide.
3. Screens-tab controls; retire fixed layout selection from the visible UI while
   retaining legacy preset readers for existing state compatibility.
4. Validate all three shapes, primary handover, rotated workspaces, mixed aspect
   ratios, grid-off/free placement, and existing screen/tab regressions.
5. Headset acceptance: snapping feel, curved alignment and guide readability.
6. Named layout editor/save/load UI after placement acceptance.

## Initial tuning

10 cm lattice spacing; 0.25 m/s snap entry and 0.45 m/s exit, 80 ms slow dwell,
65% cell transition threshold. These are initial feel settings, not guarantees.
Flat screen curvature uses the primary's distance captured at drag start as a
finite fallback radius for a curved placement grid. No head-following grid.

## Implemented first pass

- Fine forward/inverse flat/cylinder/sphere geometry, including radial shells.
- Velocity-gated snap with dwell and cell hysteresis; no forced release snap.
- Primary group movement retains the existing rigid workspace transform path.
- Pinned-corner resize preserves the displayed aspect ratio, including crop.
- Grid Shape and Grid Spacing (5/10/20 cm) popups on Screens. Monitor Apply is
  retained; fixed preset selection and the legacy Save/Remove controls are hidden.
- Placement-owned screens bypass legacy preset reflow; reconnect bookkeeping
  retains their transforms and radius using the existing host placement store.
- Curved snapped panels retain their shell radius so head movement does not
  independently reshape their surface. Changing the screen curvature resets this.
- A transient 495-dot scene guide is used where scene rendering is available.
  Projectionless Quest draws a 165-dot surface-projected guide in the existing
  controls atlas, with no extra layer or viewport. It is blue while moving
  freely and green when snapping engages. This is a projected positioning aid,
  not a stereoscopic volumetric grid on Quest.

## Remaining after first pass

- Headset acceptance/tuning of snap entry/exit, resizing and guide visibility.
- Named layout save/load UI (intentionally deferred until placement is accepted).
- Full scene/UI visual check on the host is deferred because previous
  gamescope/Vulkan checks reset this NVIDIA desktop. Use Quest acceptance and
  headless geometry/interaction regression checks for this pass.

## Automated validation (2026-11-17)

- Full unit runs at `build/verify/unit-20261117-144223/summary.json` and
  `build/verify/unit-20261117-144502/summary.json`: 220 Rust tests passed and
  the GDScript suite passed.
- Final integration run `build/verify/unit-20261117-144935/summary.json`:
  GDScript passed, 219 Rust tests passed; one unchanged multipath socket test
  failed with `AddrInUse`. Its isolated release-mode rerun passed (3.4 s).
- New geometry tests exercise forward/inverse transforms, rotated anchors,
  all four pinned resize corners on flat/curved screens, multiple aspect ratios,
  radius feedback, snap hysteresis/fast escape, settings persistence, primary
  handover and reuse of the existing controls viewport for the projected guide.
- Optimized release-signed DEV APK built and installed in place. The final APK
  is `Nightfall-Android-arm64-v8a-dev.apk`; app data and pairings were retained.

## User acceptance checklist

1. Screens: switch Grid Shape between Flat, Cylinder and Sphere; changing it
   should not immediately move any existing screen.
2. Drag a secondary screen quickly, then slow down: free motion should become
   a stable snap. Move forward/back to test neighbouring depth shells.
3. Resize each corner: the opposite corner should stay fixed and content must
   preserve its ratio. Try both flat and curved screen settings.
4. Move the primary: the whole arrangement follows. Change which screen is
   primary: nothing moves until you manipulate a screen again.
5. Try 5/10/20 cm spacing and Grid Mode off. Monitor creation/Apply and browser
   tabs must continue to work. Named save/load remains the next phase.

- Quest startup/UI-viewport check passed:
  `build/verify/quest-20261117-145206/summary.json` (OpenXR active, menu 1.22 m
  away). This is a startup check, not a rendering-performance measurement.
- A separate attempt to capture the Screens popup could not reconnect to the
  dev bridge after relaunch; it produced no popup screenshot. Nightfall was
  stopped and simulated headset presence was released in cleanup. User acceptance
  is still required for the in-headset guide and popup presentation.

## First headset feedback: viewer-facing placement

- User confirmed the connection failure was saved Windows host settings/pairing,
  not a placement-grid failure. No host/service or pairing changes were made.
- Grid shell tangents can point away from the actual viewer. Dragged screens now
  face the headset position; snapped panels quantize yaw/pitch in the anchor's
  frame using the lattice spacing (1–5 degree angular increments). Orientation
  is only adjusted while arranging, not continuously as the user moves their head.
- Primary drag faces the viewer before computing the workspace's rigid group
  transform, so the secondary screens follow consistently.
- Raised-screen grab bars/corners are prioritized over nearby video colliders
  and transparent tab-hover backdrops, matching the existing compositor ordering.
  Actual menu/button targets remain protected. A physics regression reproduces
  a grab bar behind the primary video and checks that exclusions clear afterward.
- Newly created monitor nodes retain default placement rather than calling
  restore_placement() with an old monitor ID. Existing nodes stay put; explicit
  host-state loading is unchanged. Named saved layouts remain deferred.

Validation of viewer-facing follow-up: full unit check
`build/verify/unit-20261117-152441/summary.json` passed (220 Rust tests and all
GDScript checks). The optimized DEV APK was rebuilt and installed in place.
The raised-bar physics test also verifies transparent own-tab hover fallback
and restoration of ordinary video targeting when the bar moves away.

## Second headset feedback: primary tilt, height and corner alignment

Feedback (16:11): the primary should tilt again (lying down) and carry the
grid with it; it felt stuck at one height; its corners should lie on grid
points so other screens can be lined up against it. Scaling every screen with
the primary is undecided; nothing implemented.

- **Primary tilt:** the primary follows the hand's pitch again, as before the
  grid (`handle_grab()`); only secondaries are turned to face the viewer. The
  grid is anchored to the primary's transform, so tilting it tilts the grid
  and the rigid group move.
- **Height:** no clamp exists in code. The 15:25 build re-faced the primary
  toward the viewer every frame during a drag; that is removed. Confirm in the
  headset that vertical movement is free again.
- **Corners on the grid:** `ScreenPlacementGrid.lattice()` fits a whole number
  of steps into the primary's half-width and half-height, from its real corner
  (including the curved edge's depth). All four primary corners lie on grid
  points, and spacing stays within half a step of the chosen value. Secondaries
  snap the corner nearest the primary, so edges can line up.
- **Fix found by the new corner test:** snapping a curved secondary set its
  `placement_radius`, which moved its own corner. The next frame's raw sample
  then jumped, read as fast motion, and released the snap, so curved secondaries
  chattered between snapped and free. The controller now samples the raw corner
  from the offset captured at drag start (with the screen's own radius); the
  pin solve still uses the real corner.

Validation (2026-11-17): `test_screen_placement_grid.gd` and the full GDScript
suite pass. The dev APK (`0.9.1-preview.2-dev`) is installed on the Quest 3 in
place. Headset acceptance pending.

## Third headset feedback: one surface, screens shaped by it

Feedback (2026-11-17): on the sphere grid the sphere should shape the screens,
as if they were laid on its surface and slid across it. No spheres within
spheres: one sphere, with the screens adhering to it, so for example eight
lower-resolution screens can curve around the viewer. The cylinder should also
be one surface, so screens just line up next to each other.

- **One surface:** cylinder and sphere grids have no radial depth any more.
  Their radius is the primary's distance from the viewer when the grid takes
  effect, so the surface curves around the viewer. Dragging a screen moves it
  over the surface; push/pull depth is ignored there. Flat grids keep the depth
  shells.
- **Sphere screens are latitude/longitude patches.** A screen covers a
  rectangle of longitude and latitude, so it narrows towards the top above the
  equator, like the surface. Same-sized screens therefore tile with no gaps,
  row above row. Each screen stores `surface`, `surface_lat` (its centre's
  latitude) and `placement_radius`, which are saved with the arrangement.
- **Rendering:** on Quest a sphere screen is an OpenXR equirect2 band: a
  `SphereLayers` child of its cylinder layer in the Godot path, and curvature 3
  in the native renderer. A band wholly above or below the equator needs the
  new engine patch `godot-4.7-equirect-bands.patch`, because stock Godot only
  accepts bands that straddle the equator. The controls atlas (tabs, grab bar,
  corners) is a band of the same sphere. Collision, the pointer's UV mapping,
  corners and the grab bar follow the patch, in `vr_screen.gd`.
- **Cylinder screens** all share the grid's axis and radius, and a flat screen
  on the cylinder grid curves with it.
- **Snapping:** the corner nearest the primary snaps to the lattice in surface
  coordinates (arc metres). The lattice runs through the primary's corners.
- **Primary:** it becomes a patch of the surface too, and still carries the
  arrangement when moved or tilted. Releasing it re-centres the surface only
  while no other screen is on it. Resizing on a surface keeps the pinned
  corner's surface position; a primary resized on the sphere may sit off the
  equator, and the anchor frame accounts for that.
- **Changing shape or grid mode** lays every grid screen onto the new surface
  where it is.

Validation (2026-11-17): new tests cover the following, and the full GDScript
suite passes:
- points lie on the sphere, and angles round-trip;
- side-by-side and stacked screens share corners exactly;
- a screen narrows above the equator;
- pointer UV mapping;
- the equirect pose;
- cylinder screens share the axis.

Still open:
- whether the Quest runtime draws off-equator bands;
- comfort and feel in the headset;
- new screens still get default slot positions, which leave gaps.

## Fourth headset feedback: no stretching off the middle (2026-11-18)

Feedback: sphere screens above and below the primary looked stretched
vertically. On the cylinder, rows above and below should tilt towards the
viewer.

Both grids are now one capsule (`ScreenPlacementGrid`, `straight` argument):
- **Middle:** a straight cylinder section of half-height `straight`. On the
  cylinder grid that's the primary's half-height. On the sphere grid there is
  no straight section.
- **Caps:** sphere caps of the same radius, centred on the axis at
  ±`straight`. Rows on a cap tilt towards the viewer.
- **Mercator spacing:** on the caps, grid height is Mercator metres,
  `y = R·asinh(tan(lat))`. A screen is a rectangle in those coordinates, so it
  keeps its aspect ratio and gets smaller (87% at 30°, 71% at 45°) instead of
  stretching. Columns still share longitudes, so edges still meet.

How screens use it:
- Each screen stores `surface_y`, `surface_on_cap`, `surface_cap` and
  `surface_lat` (the latitude of its own frame).
- The patch latitudes come from these and the current size.
- Cap screens are drawn as sphere bands of their cap. Straight-section screens
  are drawn as cylinder layers on the shared axis.
- A screen part-way across the join is drawn according to where its centre is.

## Fifth headset feedback: face the viewer, squash more, lock, Original (2026-11-18)

Feedback on the capsule:
- Rows above and below the primary didn't tilt towards the viewer. Edge-centred
  caps only tilt by the arc angle from the join, about 11° for the first row.
- Mercator spacing still looked vertically long.

What changed:
- **Rows above and below:** they now lie on one sphere centred on the viewer's
  point of the axis, with radius `sqrt(R² + straight²)`. It passes through the
  straight section's top and bottom edges, so the middle row and the rows
  above and below still meet, with a fold at the join. Every screen on it faces
  the viewer.
- **Row spacing:** rows are spaced like a flat wall seen from its centre,
  `lat = atan(tan φ0 + (|y| - straight) · Rs / R²)`, with scale 1 at the join.
  Screens away from the middle are squashed by `cos(lat) / cos(φ0)` on top of
  shrinking (15% extra at 30°).
- **Shapes:** Flat is gone. The choices are Original (the slot layout from
  main: `_grid_screen_transforms`, live slot snapping, hand tilt for every
  screen), Cylinder and Sphere. A saved shape 0 now means Original.
- **Lock Screens** (Screens tab, `secondary_screens_locked`): secondaries hide
  their grab bar, shortcuts and corners, and those collision shapes are turned
  off (`VRScreen.sync_controls_lock`), so they stop catching the pointer
  through a screen stacked over them. The primary still moves everything.

Follow-up (same day):
- Lock Screens works as intended in the headset.
- Squash doubled: `d(lat)/dy ∝ cos³(lat)` (the integral of sec³, inverted by
  Newton's method). The extra squash is now `(cos lat / cos φ0)²`, about 25%
  at 30°.
- Screens tab rows:
  - top: Monitors, Virtual, Browsers, Apply;
  - bottom: Grid Mode, Grid Shape, Grid Spacing, Lock Screen.
- Squash set to 20% at 30°:
  - `dy/d(lat)` is a blend of sec² and sec³ (`SQUASH_BLEND = 0.4667`);
  - the squash is `1 / (a·sec + (1 − a)·sec²)` with φ0 = 0.
- Tab drag (`TabDragPreview`, driven from `XRInteraction._update_tab_preview`):
  - a copy of the tab's label follows the pointer;
  - over empty space, a yellow outline shows where the dropped screen will
    appear (`ScreenSources.drop_preview` → `ScreenPlacementController.preview`,
    which matches `adhere()`);
  - in projectionless mode both are composition layers, and the outline is a
    sphere band on the sphere part of the grid; otherwise they are meshes.
- The dragged tab's label now rides on the cursor layer, so it needs no layer
  of its own:
  - `CompositionPointerLayers.show_drag` draws the pointer dot with the label
    below it, at the drag point, including over empty space;
  - `main._update_cursor_layer` takes that path while
    `XRInteraction.tab_drag_title()` is set;
  - under GLES it falls back to the ordinary cursor, because resizing the
    cursor target rebuilds its swapchain there.
- The outline is still its own layer, but only while a tab is dragged.

### Tab drop on surface grids, and the drag label under GLES (2026-11-18)

- The Quest renders with `gl_compatibility` (projectionless), so the first
  cursor-layer label was switched off there and never showed. `show_drag()`
  now resizes the cursor target once when a drag starts and `end_drag()`
  restores it when it ends: two swapchain rebuilds per drag, never per frame.
- On Cylinder and Sphere grids a dropped tab no longer uses the Original slot
  search. `ScreenPlacementController.drop_centre()` casts the pointer ray onto
  the surface, snaps the corner nearest the primary to the fine lattice (as
  dragging does), and if that overlaps a screen picks the nearest spot edge to
  edge with one. The outline (`surface_preview()`) and the drop
  (`place_dropped()`) use the same spot.

### Screens tab, sixth layout (2026-11-18)

The Monitors, Virtual and Browsers count buttons are gone: counts are set from
the bars above each screen. Top row: Grid Mode, Grid Shape, Grid Spacing.
Bottom row: Lock Screen. Apply is hidden too (counts apply from the bars),
with Save/Remove, until named presets come back.

### The + Add menu and click-to-place (2026-11-19)

- Menu: Add Screen, Add Tab, Modify Screen (the old Tab resolution), Make
  Primary (hidden on the primary). Each Add opens Browser / Virtual Monitor /
  Physical Monitor. Virtual: Default (match the host), 16:9 ›, 21:9 ›, 4:3 ›,
  Custom. Physical lists the host's monitors by name.
- Add Screen enters placement mode (`ScreenSources.placement`): the yellow
  outline, at the primary's height and the new screen's aspect, follows the
  pointer with its label on the cursor. Trigger places, grip cancels.
- A browser is placed at once. A monitor only exists after the host restarts,
  so its spot waits in `_pending_placements` and `apply_screen_layout()` hands
  the new screen to `claim_pending_placement()` (physical by id, virtual in
  order).
- "Use headset AI-3D" is left out until it is clear whether two depth
  sources can already run at once.

### Vertical virtual monitors and Grid Curve (2026-11-20)

- The virtual monitor menu has "Vertical Orientation: On/Off" above Custom.
  On turns every listed size and ratio on its side (9:16, 9:21, 3:4), and a
  vertical Default names the host size turned (Default itself only means the
  host's landscape size).
- Screens tab: "Grid Curve" slider, 0–100%, disabled for Original. 0% is the
  surface centred on the viewer; 100% shrinks its radius to
  `TIGHTEST_CURVE` (0.4) of the viewing distance. `set_curve()` keeps the
  primary in place and every screen at its grid position (arc metres), so the
  arrangement bends in rather than moving. The slider previews live.

### Curve range, sphere ambient, one grid through resizes (2026-11-20)

- Grid Curve's old 40% is the new 100% (`TIGHTEST_CURVE` 0.76), in 1% steps.
- The ambient glow on a sphere grid is a larger band of the primary's sphere
  (`SphereLayers` on the ambient layer), not a cylinder.
- `keep_grid(change)` notes every screen's grid position, runs the change,
  and lays the screens back on the surface. Used by `resize_to_aspect()`
  (stream/virtual size changes), a primary corner resize (the cylinder
  grid's middle row is the primary's height) and the Flat/Curved switch,
  which on surface grids no longer zeroes `placement_radius` or snaps
  screens back to Original slots — that was the out-of-sync grid.

### Flat panels on the surface, gentler Grid Curve (2026-11-22)

- Curve now sets each screen's own shape on a cylinder or sphere grid; the
  grid only says where it goes and which way it faces. Curved follows the
  surface as before. Flat and Slight Curve (its own radius, twice the
  surface's, `SLIGHT_PANEL_FACTOR`) are panels moved in towards the surface's
  centre by `ScreenPlacementGrid.panel_inset()`, just far enough that their
  left and right edges lie on the rays through their footprint's edges, so
  side-by-side panels still meet, angled. On the sphere caps a flat
  rectangle can't match its lat/long patch; it is inset to fit inside it both
  ways, leaving small wedge gaps.
- Placement still works on the surface: `VRScreen.surface_pose()` is the
  place behind the panel (the node pose minus `surface_inset`, which is set
  when the screen is placed and saved with it), and `grid_corner_point()` is
  the footprint's corner for the lattice and pinned resizes. `on_cap()` is
  "on a sphere cap" (placement); `on_sphere()` now means "drawn as a sphere
  patch" (a Curved screen on a cap).
- Grid Curve 0% matches a Slight Curve screen: radius 3× the viewing
  distance (`LOOSEST_CURVE`), down to `TIGHTEST_CURVE` 0.76 at 100%, with
  curvature (1/radius) changing evenly along the slider.
- Grid Spacing moved to Advanced Settings → Display.
- The ambient glow has a fixed sort order (0), below every screen. It used
  the primary's distance-based order minus one, set only when the screen
  moved, while the native renderer recomputes the primary's every frame:
  leaning back dropped the screen below its own glow.
