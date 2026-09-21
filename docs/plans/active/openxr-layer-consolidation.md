# OpenXR layer consolidation

## Goal

Keep Quest's submitted OpenXR layer count below its 16-layer limit without hiding corner resize controls when the menu or keyboard opens. Preserve existing input targets, tooltip behavior, hand/controller cues, and performance.

## Changes

1. Draw each screen's four corner brackets into one transparent, screen-aligned curved composition layer. Keep the four independent physics targets and opacity values. Remove the temporary menu/keyboard corner suppression. The grab bar remains separate.
2. Draw the tooltip in a transparent strip of the menu viewport, above the existing menu body. Preserve its physical position, 45% opacity, 0.55-second initial delay, immediate replacement and dismissal, and all existing menu hit targets. Remove its standalone viewport, mesh, and composition layer.
3. Continue using at most one pointing ray per side for controllers or hands. A hand ray and parked-controller dot may coexist; they mark different positions. Audit inactive indicators for unnecessary layer submission without reintroducing rapid swapchain churn.
4. Blend the existing stats texture into both eyes of the native video output after the warp, rather than submitting a separate native stats composition layer. Keep legacy in-screen stats unchanged.

## Verification

- Run GDScript tests, including tooltip/input tests; build a release APK using `BUILD.md`.
- On-headset, check the welcome screen and stream with flat/curved screens, resize targets, menu and keyboard, ambient, hand tracking, stats, and standby/resume.
- Confirm no `XR_ERROR_LAYER_LIMIT_EXCEEDED` in the former 17-layer case and no noticeable frame-time regression from the larger transparent corner texture.

## Working assumptions

Corner and tooltip consolidation come first and should save four layers in the failing scenario. The active worktree's existing uncommitted changes are retained. Native stats is included even though it was not involved in the welcome-screen failure.
