# Settings ownership

Nightfall separates settings into data, policy, persistence, presentation, and
runtime effects. New settings should follow these boundaries instead of adding
another field directly to `main.gd`.

## Data

- `src/app_settings.gd` owns app-wide preferences and their defaults.
- `src/host_settings.gd` owns scalar preferences for the selected host.
- `ScreenLayout`, `VRScreen`, and monitor preset types continue to own structured
  monitor layout and placement data.

`main.gd` temporarily exposes compatibility properties for code that has not yet
been migrated. Those properties delegate to `AppSettings`; they must not gain
independent defaults or storage.

## Platform policy

`src/settings_platform_policy.gd` owns side-effect-free platform availability
rules. Android-only AI-3D locks, GPU-priority availability, and native sharpen
choices must be queried through this policy rather than scattered `OS.get_name()`
checks in UI and persistence code.

## Persistence

`src/state_manager.gd` currently serializes the typed stores and owns compatibility
migrations for historical config formats. New formats write explicit app and host
schema versions. The next extraction should move encoding and migrations into a
dedicated persistence codec while leaving runtime application in `StateManager`.

## Presentation and effects

- `src/ui_controller.gd` creates controls and presents current values.
- `src/settings_controller.gd` handles user commands and applies runtime effects.
- Renderer, stream, depth, and screen modules own the effects themselves.

The UI should eventually consume declarative option descriptions. A description
may identify a setting and command, but must not contain renderer or stream
objects.

## Migration order

1. Extract app/host config encoding and legacy migrations from `StateManager`.
2. Move controller-mapping persistence behind a narrow controller settings API.
3. Convert menu construction to declarative tab/row/option descriptions.
4. Replace remaining `main.gd` compatibility properties with direct typed-store
   dependencies.
