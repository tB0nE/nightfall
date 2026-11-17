# Controls and clipboard sharing

These instructions describe the current development preview. Default Quest
shortcuts assume the right controller is primary; changing Primary Hand moves
app shortcuts to that hand. PCVR games use their own bindings.

## Pointing and browser input

- Trigger clicks the item under the pointer. In a browser, trigger-drag scrolls
  the page like a touchscreen; it is not a desktop text-selection gesture.
- Grip normally sends right-click. The browser provides a text-edit context
  menu with Select All, Copy, Cut and Paste where applicable.
- Right thumbstick Y scrolls. Optional **Grip Scroll** replaces right-click
  with grip-drag scrolling; controller mapping must be off. It is off by default.
- B toggles the menu and A toggles the keyboard with the default primary hand.
- Right thumbstick click toggles SBS off/on using the last Stretch or Crop mode
  chosen in the menu. It does not cycle between Stretch and Crop.
- Point at grab bars or corner handles to move or resize screens. Browser
  controls appear above browser content when you point at that area.

Text selection by dragging is limited by the browser's touch behavior. For
editable fields, Select All and keyboard shortcuts are the most reliable path.

## Controller mapping on Quest

Click both thumbsticks, or use Mapping in the Control tab, to toggle mapping.
The activation help stays visible until you press a button to continue.

| Input | Gamepad action |
|---|---|
| Thumbsticks | Left/right sticks, including clicks |
| Triggers | Left/right triggers |
| Grips | Left/right bumpers |
| Left Menu | Select / Back normally; Start with the left alternate mapping active |

The right Meta/Horizon button belongs to Horizon OS and opens its system menu;
use the left Menu alternate mapping for Start.

The face-button layouts are:

| Layout | Left X / Y | Left alternate | Right A / B | Right alternate |
|---|---|---|---|---|
| PAD-HAND | D-pad Left / Right | D-pad Down / Up | A / B | X / Y |
| PAD-ABXY | X / Y | D-pad Down / Up | A / B | D-pad Right / Left |

Alternate Mode can be **Tilt**, **Head** or **None**. Tilt the relevant
controller outward, or bring it close to your head, to use that hand's
alternate mapping. The activation help describes the selected mode.

KBM maps the left stick to WASD, left trigger to Shift, left grip to Ctrl,
A to Space, B to R, X to E, Y to F and left Menu to Esc. Pointer control remains
available. System-reserved buttons may not reach Nightfall.

In gamepad mode, normal pointing is suppressed while playing; opening
Nightfall's menu or keyboard makes its UI available again.

## Steam Frame

The experimental Frame client uses physical face buttons, D-pad, bumpers and
stick clicks. View is Select / Back and Menu is Start. Press both grips to
toggle controller mapping. See the [Frame guide](steam-frame.md) for installation
and current package limitations.

## Virtual keyboard and trackpad

The virtual keyboard includes text-edit shortcuts and special keys such as
Insert. Point at the trackpad and click the trigger to activate relative mouse
movement. Trigger is left-click, grip is right-click, thumbstick Y scrolls and
right thumbstick click exits trackpad mode.

## Clipboard

Clipboard sharing transfers **plain text**, up to 64 KiB of UTF-8 text. It does
not transfer images, files or rich formatting, and it does not continuously
mirror everything copied on either device. It needs a compatible host clipboard
endpoint; update the managed host alongside Meteor when testing this feature.

To copy browser text into the desktop:

1. Focus the browser input and use **Select All**, then **Copy**, on Nightfall's
   keyboard, or use Ctrl+A and Ctrl+C on a connected keyboard.
2. Switch to the desktop tab and focus the destination input.
3. Use Nightfall's **Paste** shortcut or Ctrl+V on the connected keyboard.

For the reverse direction, copy in the desktop, then focus a browser input and
use Nightfall's Paste shortcut. Ctrl+X is also supported for editable content.

Choosing Paste from the PC application's own context menu does not request a
clipboard transfer from Nightfall: it can paste the PC's previous clipboard
instead. If sharing fails, verify the destination has focus and try the explicit
keyboard shortcuts. Browser text-selection gestures remain an area for improvement.

## PCVR

The wristwatch's screen button shows or hides the desktop; its gear opens PCVR
settings independently. Game input bindings are separate from Nightfall's
flat-game controller mapper. See the [game compatibility guide](game-compatibility.md)
for game-specific setup and known controller requirements.
