# Settings ownership

Nightfall separates settings into data, policy, persistence, presentation, and
runtime effects. New settings should follow these boundaries instead of adding
another field directly to `main.gd`.

## Data

- `src/app_settings.gd` owns app-wide preferences and their defaults.
- `src/host_settings.gd` owns scalar preferences for the selected host.
- `ScreenLayout`, `VRScreen`, and monitor preset types continue to own structured
  monitor layout and placement data.

Runtime modules and `main.gd` read these typed stores directly. Setting values
must not be mirrored as independent fields on the application coordinator.

## Platform policy

`src/settings_platform_policy.gd` owns side-effect-free platform availability
rules. Android-only AI-3D locks, GPU-priority availability, and native sharpen
choices must be queried through this policy rather than scattered `OS.get_name()`
checks in UI and persistence code.

## Persistence

`src/settings_persistence.gd` encodes the typed stores and owns compatibility
migrations for historical config formats. New formats write explicit app and host
schema versions. `StateManager` coordinates file and host selection around that
codec, while `ControllerMapper` owns its narrow controller-settings format.

## Presentation and effects

- `src/menu_schema.gd` describes the ordinary menu tabs, rows, options, and
  command routes without holding runtime renderer or stream objects.
- `src/ui_controller.gd` renders that schema, creates the specialized AI 3D and
  Monitors controls, and presents current values.
- `src/settings_controller.gd` handles user commands and applies runtime effects.
- Renderer, stream, depth, and screen modules own the effects themselves.

Keep specialized layouts imperative only when their structure genuinely changes
at runtime. AI 3D rearranges controls under Android policy, while Monitors mixes
option, action, and generated preset controls; the uniform tabs should remain in
the declarative schema.

## Next boundary

Move runtime setting effects behind narrower module APIs where they still reach
through `main`. The typed store remains data-only while those APIs own side
effects.
