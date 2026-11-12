# Screen crop, colour-key passthrough and standby placement

Branch: `codex/screen-crop-key-and-placement`, based on the existing
`feat/remember-screen-arrangement` commit 7003bdd. That arrangement work is retained.

## Controls and scope

Temporary controls are in Settings → Display (a four-button row, including the
existing High Refresh Rates). The user plans a broader menu redesign later.

- Crop: Off, 21:9, 4:3, 16:9, 16:10, 32:9. Centre-crops each desktop/browser
  screen to the chosen aspect. It does not detect black bars automatically,
  change a host resolution or restart a stream. The physical mesh shrinks by
  the cropped proportions, preserving the visible content's scale. Welcome
  content is exempt. Cropping an already matching source is an identity.
- Colour Key: Off, Green (RGB 0/255/0), Blue (0/0/255), Magenta (255/0/255).
  Applies to desktop/browser images only, not PCVR. Turning it on also enables
  passthrough when supported. Toggling it off leaves passthrough under the
  existing manual control. Custom RGB picking is a future UI extension.
- Key Tolerance: Low, Medium, High, with a narrow soft edge to accommodate
  compression. Similar colours within the content are necessarily removed too.

AppSettings owns/persists the controls, reset_display restores Off/Off/Medium.
New strings are explicitly present as English fallbacks in every locale, matching
existing preview-feature entries. Translating them remains future editorial work.

## Rendering and input

`ScreenImageOptions` computes centred, normalized crops; native and legacy shaders
apply the same crop to colour/depth/warp coordinates. Depth inference still sees
its original full primary image: no model/input or Meteor protocol changes.
Input remapping affects host positions, click-release/chord paths and browser
input; visual pointer coordinates remain in the displayed screen's own space.

Android's direct GLES/OES path adds crop/key uniforms and existing OpenXR quad/
cylinder layers opt into straight-alpha compositing for keying. Secondary native
screens carry their own display crop. Existing legacy canvas shaders preserve
alpha, and legacy composition layers enable blending only while keying. Spatial
materials switch to explicit alpha shader variants only while keying, leaving
the default opaque spatial path intact. Depth debug views remain opaque. No extra
composition layers or full-resolution copy pass are introduced. HDR and complex
SBS combinations need visual confirmation; plain SDR desktop/browser use is the
first test target.

## Standby positioning

Screen arrangements save application coordinates; they are not physical room
anchors. OpenXR may change those coordinates when tracking resumes. The previous
app did not consume the supplied `poseInPreviousSpace` transform.

The extension's existing CORE-registered clock wrapper now also records reference
space changes without consuming them (Godot still handles the event). A timestamped
queue delivers changes when their OpenXR change time has arrived. The app filters
by its active play-area space and applies the inverse origin delta to workspace
screens, menu, keyboard and remembered inactive monitor placements. XR origin,
head/controller tracking and the streamed PCVR environment are not moved.

This uses `world_from_tracking * old_from_new.inverse() * tracking_from_world`,
including XR world scale, to preserve physical placement without guessing from a
changed head orientation. Interaction state is cancelled after correction.

If OpenXR reports poseValid=false, or a non-finite transform, exact compensation
cannot be computed. The app logs that explicitly instead of guessing and moving
the workspace. Persistent spatial anchors/room relocalization would be the next
step if the user's headset routinely loses the old room origin. New sessions and
new rooms also need separate anchor policy; this is not persistent room mapping.

References:
- https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrEventDataReferenceSpaceChangePending.html
- https://docs.godotengine.org/en/4.6/tutorials/xr/openxr_settings.html
- https://virtualrealcockpit.com/manual/07 (matching key colours with Virtual Desktop)

## Verification and remaining visual checks

- Pure tests cover crop proportions, pointer endpoints, persistence/reset and
  a translated/rotated tracking origin under a non-identity application origin.
- Native release extension builds; four native fragment variants pass glslang.
- Full verification: `build/verify/unit-20261111-223600/summary.json`: 197 Rust
  tests and GDScript suite pass (plus a targeted regression test for the final source-aspect selection tweak).
- A release-optimized DEV APK is built as `Nightfall-Android-arm64-v8a-dev.apk`.
  Refresh it after any final changes. No headset was detected during preparation.

User checks once deployed:
1. Stream a centred black-bar pattern/game, select 21:9 and 4:3; confirm no
   stream restart, correct shape and pointer/click alignment, then return Off.
2. Use solid green desktop or browser content, enable Green; inspect room
   visibility and edge tolerance. Check AI 3D off/on and a browser separately.
3. Leave the screen somewhere distinctive, remove/re-wear the headset after a
   few minutes, and check its physical position. Export a log if it still jumps;
   `[PLACEMENT]` distinguishes a reported delta from an unlocatable old origin.

## Follow-up: shadow fringes and Screens tab (2026-11-12)

The first headset test left green window borders/shadows. Absolute RGB distance
missed darkened key colours. Keying now separates hue from brightness, gates
neutral/near-black pixels to preserve ordinary content, and removes excess key
colour from visible soft edges (despill). Low/Medium/High control hue tolerance
and the minimum saturation that is removed. Fully black shadows carry no key
colour information and cannot be identified reliably; disabling host window
shadows remains an option if those remain visible.

The same `src/shaders/chroma_key.gdshaderinc` is used by Godot and embedded by
CMake into the native GLES source; this avoids separate algorithms drifting.
No extra texture samples, layers or image passes are introduced.

Removed the unused Open Browser / Close Browser / Browser Res row, its status
label and the read-only Browsers count button from Screens. Monitor/preset/grid
logic still includes active browsers; browser opening and screen/tab management
remain available through the welcome screen and screen menus. The user plans a
broader screen-management redesign later.

Validation:
- `build/verify/unit-20261112-002114/summary.json`: 197 Rust tests, GDScript pass.
- `test/test_chroma_key_shader.py` renders the actual shared GLSL in llvmpipe,
  requiring software EGL. Sixteen cases pass, including shadowed green/blue/
  magenta, neutral colours, existing alpha, monotonic tolerance and despill.
  Run with `.build-cache/model-tester-venv/bin/python test/test_chroma_key_shader.py`.
- All four expanded native SDR/HDR/Picture shader variants compile with glslang.
- `build/verify/screens-menu-layout/summary.json`: headless Godot confirms the
  Screens grab bar is visible and ends at y=595 inside the 682px viewport.
  This checks layout geometry, not headset appearance/comfort.
- Updated release-optimized DEV APK installed in place on the Quest 3 and launched
  (PID 10251). All allocated ELF sections in the APK match the new native build.
