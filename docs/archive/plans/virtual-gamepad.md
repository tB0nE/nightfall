# Virtual Gamepad + Quest Controller Mapping

## Overview

Two major features:
1. **Virtual Gamepad** — floating 3D panel (like virtual keyboard) with Xbox controller layout; pointer-driven interaction sends controller events through the stream
2. **Quest Controller Mapping** — 3 modes (Off/Keyboard/Controller) that remap Quest Touch Plus inputs to stream input events, with per-game profiles

---

## Phase 1: Virtual Gamepad UI & Controller Events

### New file: `src/virtual_gamepad.gd`

`class_name VirtualGamepad extends Node3D`

**Architecture** — identical to `virtual_keyboard.gd`:
- `SubViewport` (2D) → `QuadMesh` + `StandardMaterial3D` + `Area3D` collision
- Viewport size: ~1200×700 (wider for controller layout)
- Mesh size: ~0.7m × 0.4m
- Position: below-left of screen (similar to keyboard position)
- Toggle: dedicated UI button + possibly hold both thumbsticks

**Xbox-style 2D layout** (inside SubViewport):

```
  LB         RB                       LT         RT
  [====]   [====]                   [====]   [====]

        [D-pad]       [Start][Back]        [ABXY]
         [^]           [>]  [<]            [Y]
       [<] [>]                              [X] [B]
         [v]                                [A]

   (L-stick)                           (R-stick)
    [  ◯  ]                             [  ◯  ]
```

**2D elements:**

| Element | Type | Behavior |
|---------|------|----------|
| Left thumbstick | Custom `Control` — circular touch zone, tracks drag position | Sends `left_stick_x/y` as short (-32767..32767) proportional to offset from center |
| Right thumbstick | Same as left | Sends `right_stick_x/y` |
| D-pad (U/D/L/R) | 4 `Button` nodes | Sets `UP_FLAG/DOWN_FLAG/LEFT_FLAG/RIGHT_FLAG` in button_flags |
| A/B/X/Y | 4 `Button` nodes | Sets `A_FLAG/B_FLAG/X_FLAG/Y_FLAG` in button_flags |
| LB/RB | 2 `Button` nodes | Sets `LB_FLAG/RB_FLAG` |
| LT/RT | 2 `Slider`-like vertical drag zones | Sends `left_trigger/right_trigger` as 0-255 |
| Start/Back | 2 `Button` nodes | Sets `PLAY_FLAG/BACK_FLAG` |
| L3/R3 | 2 `Button` nodes (center of thumbstick zones) | Sets `LS_CLK_FLAG/RS_CLK_FLAG` |

**Thumbstick interaction:**
- `handle_pointer(pixel_pos, clicking, was_clicking)` receives raycast hits
- On pointer down within thumbstick circle: record offset from center, compute normalized X/Y
- On pointer drag: update offset, send updated `send_controller_event` with new stick values
- On pointer up: reset to center (0,0)
- The thumbstick visual (a small filled circle) moves with the pointer

**Continuous controller state:**
- VirtualGamepad maintains `_button_flags: int`, `_left_trigger: int`, `_right_trigger: int`, `_left_stick: Vector2`, `_right_stick: Vector2`
- Any change triggers `_send_controller_state()` which calls `stream_backend.send_multi_controller_event(0, 1, _button_flags, _left_trigger, _right_trigger, _left_stick_x, _left_stick_y, _right_stick_x, _right_stick_y)`
- Uses `_process()` to continuously send state while any input is active (thumbstick dragged, button held, trigger held)

**Controller arrival:**
- On stream start, call `stream_backend.send_controller_arrival(0, 1, CTYPE_XBOX, all_button_flags, CCAP_ANALOG_TRIGGERS | CCAP_RUMBLE)` to declare the virtual gamepad to the host

### UI integration (`main.gd`):

- Add `var virtual_gamepad: VirtualGamepad` node
- Toggle via existing A button cycle (A now toggles: nothing → keyboard → gamepad → nothing) or dedicated UI button
- Position gamepad near keyboard position, offset below
- Connect `xr_interaction.gd` pointer hits to gamepad's `handle_pointer()` when gamepad visible
- When gamepad is active and visible, disable XR pointer mouse events (prevent double-input)

---

## Phase 2: Quest Controller Mapping — Controller Mode

### Controller modes enum (in `main.gd` or new `src/controller_mapper.gd`):

```
enum ControllerMode {
    OFF = 0,        # Default — current XR pointer behavior
    KEYBOARD = 1,   # Thumbsticks → keys, buttons → keys
    CONTROLLER = 2, # Thumbsticks → analog, buttons → Xbox buttons
}
```

### New file: `src/controller_mapper.gd`

`class_name ControllerMapper extends Node`

**Responsibilities:**
- Reads Quest XR controller state every frame via `_process()`
- Converts to stream input events based on active mode and profile
- Manages mode switching
- Manages the "close to head" context switch in controller mode

**Mode switching:**
- Both thumbsticks clicked simultaneously (`primary_click` on both left and right hand) → cycle: OFF → KEYBOARD → CONTROLLER → OFF
- OR UI toggle button in settings panel
- Visual indicator: status bar shows mode (like codec display)
- Mode stored in `state_manager` for persistence

**Controller mode mapping (default profile):**

| Quest Input | Stream Output |
|-------------|---------------|
| Left thumbstick (`left_hand.get_vector2("primary")`) | `left_stick_x/y` |
| Right thumbstick (`right_hand.get_vector2("primary")`) | `right_stick_x/y` |
| Left trigger (`left_hand.get_float("trigger")`) | `left_trigger` (0-255) |
| Right trigger (`right_hand.get_float("trigger")`) | `right_trigger` (0-255) |
| Left grip (`left_hand.get_float("grip")`) | `LB_FLAG` (button, threshold 0.5) |
| Right grip (`right_hand.get_float("grip")`) | `RB_FLAG` (button, threshold 0.5) |
| Right A (`right_hand.is_button_pressed("ax_button")`) | `A_FLAG` |
| Right B (`right_hand.is_button_pressed("by_button")`) | `B_FLAG` |
| Left X (`left_hand.is_button_pressed("ax_button")`) | `X_FLAG` |
| Left Y (`left_hand.is_button_pressed("by_button")`) | `Y_FLAG` |
| Left menu (`left_hand.is_button_pressed("menu_button")`) | `BACK_FLAG` |
| Right system (`right_hand.is_button_pressed("menu_button")`) | `PLAY_FLAG` (Start) |
| Left thumbstick click | `LS_CLK_FLAG` |
| Right thumbstick click | `RS_CLK_FLAG` |

**Context switch — "close to head" D-pad mode:**

When either controller's position is within 0.15m of the headset (XROrigin3D.camera position):
- ABXY buttons remap to D-pad:
  - A → `DOWN_FLAG`, B → `RIGHT_FLAG`, X → `LEFT_FLAG`, Y → `UP_FLAG`
- LB/RB still work as shoulder buttons
- Triggers still work as triggers
- Thumbsticks still work as thumbsticks

Distance calculation:
```gdscript
var head_pos = xr_origin.camera.global_position
var left_pos = left_hand.global_position
var right_pos = right_hand.global_position
var close_to_head = (left_pos.distance_to(head_pos) < 0.15) or (right_pos.distance_to(head_pos) < 0.15)
```

Visual feedback: When close-to-head is active, status bar shows "D-PAD" indicator, and the virtual gamepad (if visible) highlights the D-pad section.

**Frame-by-frame controller event sending:**
```gdscript
func _process(delta):
    if not main.is_streaming or mode == OFF:
        return
    if mode == CONTROLLER:
        _send_controller_mode()
    elif mode == KEYBOARD:
        _send_keyboard_mode()

func _send_controller_mode():
    var button_flags = 0
    # ... read all inputs, build flags ...
    # thumbsticks from get_vector2("primary")
    # triggers from get_float("trigger") * 255
    main.stream_backend.send_multi_controller_event(0, 1, button_flags, lt, rt, lx, ly, rx, ry)
```

**Important**: When controller mode is active, the XR pointer (mouse simulation) must be disabled to prevent double-input. This means:
- `xr_interaction.gd` checks `controller_mapper.mode != OFF` before sending mouse events
- Grip no longer right-clicks, trigger no longer left-clicks
- Thumbsticks no longer scroll

**Haptic feedback** (bonus, wire up existing signals):
- Connect `StreamConnection.controller_rumble` → `Input.start_joy_vibration()`
- This requires adding `controller_rumble` signal relay to `NightfallStream` (currently missing)

---

## Phase 3: Quest Controller Mapping — Keyboard Mode

**Default keyboard profile:**

| Quest Input | Stream Key |
|-------------|-----------|
| Left thumbstick up/down/left/right | W/S/A/D |
| Right thumbstick up/down/left/right | Arrow keys |
| Right A | 1 |
| Right B | 2 |
| Left X | 3 |
| Left Y | 4 |
| Left trigger | Left Shift |
| Right trigger | Space |
| Left grip | Ctrl |
| Right grip | Tab |
| Left menu | Esc |
| Right system | Enter |

**Implementation:**
- Thumbstick values: treat as 4 digital directions (threshold 0.5)
- Each direction maps to a key down/up event
- When thumbstick crosses threshold in a direction: send key down
- When thumbstick returns below threshold: send key up
- Track which directions are currently active to avoid repeated down events

```gdscript
var _active_key_dirs: Dictionary = {}  # "left_up" -> true

func _send_keyboard_mode():
    # Left thumbstick → WASD
    var lv = left_hand.get_vector2("primary")
    _handle_thumbstick_key(lv.y < -0.5, "left_up", KEY_W)
    _handle_thumbstick_key(lv.y > 0.5, "left_down", KEY_S)
    _handle_thumbstick_key(lv.x < -0.5, "left_left", KEY_A)
    _handle_thumbstick_key(lv.x > 0.5, "left_right", KEY_D)
    # Right thumbstick → arrows
    var rv = right_hand.get_vector2("primary")
    _handle_thumbstick_key(rv.y < -0.5, "right_up", KEY_UP)
    _handle_thumbstick_key(rv.y > 0.5, "right_down", KEY_DOWN)
    _handle_thumbstick_key(rv.x < -0.5, "right_left", KEY_LEFT)
    _handle_thumbstick_key(rv.x > 0.5, "right_right", KEY_RIGHT)
    # Buttons, triggers, grips → key events
    # ...

func _handle_thumbstick_key(active: bool, dir_id: String, keycode: int):
    if active and not _active_key_dirs.get(dir_id, false):
        main.stream_backend.send_keyboard_event(keycode, 3, 0)  # KA_DOWN
        _active_key_dirs[dir_id] = true
    elif not active and _active_key_dirs.get(dir_id, false):
        main.stream_backend.send_keyboard_event(keycode, 4, 0)  # KA_UP
        _active_key_dirs[dir_id] = false
```

---

## Phase 4: Profile System

### Storage: `user://controller_profiles.cfg`

```
[default_controller]
left_stick = primary
right_stick = primary
left_trigger = trigger
right_trigger = trigger
left_grip = lb
right_grip = rb
right_a = a
right_b = b
left_x = x
left_y = y
left_menu = back
right_menu = start
close_to_head_dp = true
close_to_head_dist = 0.15

[default_keyboard]
left_stick_up = KEY_W
left_stick_down = KEY_S
left_stick_left = KEY_A
left_stick_right = KEY_D
right_stick_up = KEY_UP
right_stick_down = KEY_DOWN
right_stick_left = KEY_LEFT
right_stick_right = KEY_RIGHT
right_a = KEY_1
right_b = KEY_2
left_x = KEY_3
left_y = KEY_4
left_trigger = KEY_SHIFT
right_trigger = KEY_SPACE
left_grip = KEY_CTRL
right_grip = KEY_TAB
left_menu = KEY_ESCAPE
right_menu = KEY_ENTER

[fortnite_keyboard]
left_stick_up = KEY_W
; ... etc
```

**Profile selection UI:**
- New row in settings panel (or separate panel accessible via settings)
- "Ctrl Mode" option button: Off / Keyboard / Controller
- "KBD Profile" option button: Default / Custom1 / Custom2 / + New
- "PAD Profile" option button: Default / Custom1 / Custom2 / + New
- "+ New" opens a mapping screen

**Mapping screen** (future enhancement, not in initial implementation):
- Full-screen 3D panel showing Quest controller diagram
- User presses a Quest button, then presses the target key/button on virtual keyboard
- Saves to profile

**Initial scope**: Default profiles only (hardcoded). Custom profile creation is a follow-up.

### State persistence:

In `state_manager.gd`:
```gdscript
save.set_value("controller", "mode", main.controller_mode)
save.set_value("controller", "keyboard_profile", main.keyboard_profile_name)
save.set_value("controller", "controller_profile", main.controller_profile_name)
```

In `host_state.cfg` (per-host):
```gdscript
save.set_value(ip, "controller_mode", main.controller_mode)
save.set_value(ip, "keyboard_profile", main.keyboard_profile_name)
save.set_value(ip, "controller_profile", main.controller_profile_name)
```

---

## Phase 5: Polish & Bug Fixes

### Controller arrival events

In `main.gd` on stream start:
```gdscript
var all_flags = 0x1000|0x2000|0x4000|0x8000|0x0001|0x0002|0x0004|0x0008|0x0100|0x0200|0x0010|0x0020|0x0040|0x0080|0x0400
stream_backend.send_controller_arrival(0, 1, 1, all_flags, 0x01|0x02)  # Xbox type, analog triggers + rumble
```

### Haptic feedback wiring

Wire the existing `controller_rumble` / `controller_trigger_rumble` signals from `StreamConnection` through `NightfallStream` to GDScript:
- `NightfallStream` needs to relay `controller_rumble` and `controller_trigger_rumble` signals
- GDScript connects to these and calls `Input.start_joy_vibration(device, low/255.0, high/255.0, 0.1)`
- For Quest controllers: use `XRController3D.trigger_haptic_pulse()` or OpenXR haptic action

### Input handler fixes

Fix the existing `input_handler.gd` issues:
- Add D-pad mapping (`JOY_BUTTON_DPAD_UP` → `UP_FLAG`, etc.)
- Fix `JOY_BUTTON_START` → `PLAY_FLAG` (0x0010) not 0x0800
- Fix `JOY_BUTTON_BACK` → `BACK_FLAG` (0x0020) not SPECIAL_FLAG

---

## File Changes Summary

| File | Action |
|------|--------|
| `src/virtual_gamepad.gd` | **NEW** — Virtual gamepad 3D panel with SubViewport, Xbox layout, draggable thumbsticks |
| `src/controller_mapper.gd` | **NEW** — Quest controller mode manager, reads XR input, sends stream events |
| `main.gd` | Add virtual_gamepad node, controller_mapper node, mode toggle, state persistence |
| `src/xr_interaction.gd` | Gate XR pointer events when controller mode active; add gamepad pointer handling |
| `src/stream_backend.gd` | Add `send_controller_arrival()` facade method |
| `src/state_manager.gd` | Persist controller mode + profile names |
| `src/ui_controller.gd` | Add controller mode toggle + profile selector buttons to settings panel |
| `src/settings_controller.gd` | Add cycle methods for controller mode and profile selection |
| `addons/nightfall-stream/src/nightfall_stream.cpp` | Relay `controller_rumble` / `controller_trigger_rumble` signals |
| `addons/nightfall-stream/src/nightfall_stream.h` | Signal handler declarations |
| `src/input_handler.gd` | Fix D-pad, Start, Back button mappings |

---

## Build Order

1. **Phase 1** — Virtual Gamepad (standalone, testable immediately)
2. **Phase 2** — Controller mode (requires gate on XR pointer, testable with any game)
3. **Phase 3** — Keyboard mode (simple key mapping, testable immediately)
4. **Phase 4** — Profile system (persistence + UI, default profiles hardcoded)
5. **Phase 5** — Polish (arrival events, haptics, input_handler fixes)

Each phase is independently testable and deployable.
