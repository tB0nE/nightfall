class_name ControllerLayout
extends RefCounted

# Works out which raw Godot axis is which stick/trigger for a physical pad on
# Android, and the host controller type to announce for it.
#
# Godot's Android joypad driver numbers a pad's axes by sorting the Android
# axis IDs it reports, then applies the "Default Android Gamepad" mapping,
# which assumes raw axis 4/5 are the left/right triggers. That only holds for
# pads that report LTRIGGER/RTRIGGER plus Z/RZ for the right stick. Pads that
# report GAS/BRAKE (GAS sorts first, so the triggers swap), or put the
# triggers on Z/RZ or RX/RY, come out with swapped or missing triggers
# (GitHub #37, #34). GamepadInfo.java reports the real axis IDs; this builds a
# corrected Godot mapping from them, following the axis rules
# moonlight-android uses.

# android.view.MotionEvent axis IDs.
const AXIS_X := 0
const AXIS_Y := 1
const AXIS_Z := 11
const AXIS_RX := 12
const AXIS_RY := 13
const AXIS_RZ := 14
const AXIS_LTRIGGER := 17
const AXIS_RTRIGGER := 18
const AXIS_GAS := 22
const AXIS_BRAKE := 23

# moonlight-common-c LI_CTYPE_*.
const CTYPE_UNKNOWN := 0
const CTYPE_XBOX := 1
const CTYPE_PS := 2
const CTYPE_NINTENDO := 3

const VENDOR_MICROSOFT := 0x045e
const VENDOR_SONY := 0x054c
const VENDOR_NINTENDO := 0x057e

# Buttons and hat as GodotInputHandler.getGodotButton() numbers them. The
# default Android mapping leaves out guide (b5) and the d-pad buttons, so
# pads that report the d-pad as keys instead of a hat had a dead d-pad.
# b15-b20 (digital L2/R2, Share, C/Z, BUTTON_1) are mapped only so they
# reach InputHandler's per-pad input log; none is forwarded to the host,
# since on most pads b15/b16 are just the digital half of the triggers.
const BUTTON_BINDINGS := "a:b0,b:b1,x:b2,y:b3,back:b4,guide:b5,start:b6," \
	+ "leftstick:b7,rightstick:b8,leftshoulder:b9,rightshoulder:b10," \
	+ "dpup:b11,dpdown:b12,dpleft:b13,dpright:b14," \
	+ "dpup:h0.1,dpright:h0.2,dpdown:h0.4,dpleft:h0.8," \
	+ "misc1:b15,paddle1:b16,paddle2:b17,paddle3:b18,paddle4:b19,touchpad:b20"

var name: String = ""
var vendor: int = 0
var product: int = 0
# Raw Godot axis index for each role, -1 when the pad has no such axis.
var left_x: int = -1
var left_y: int = -1
var right_x: int = -1
var right_y: int = -1
var left_trigger: int = -1
var right_trigger: int = -1
# True when a trigger sits on a centred axis (-1 at rest), so its value needs
# rescaling from -1..1 to 0..1. Godot only does that off Android.
var left_trigger_centered: bool = false
var right_trigger_centered: bool = false
var android_axes: Array = []

# info: one entry of GamepadInfo.describe()'s JSON array.
static func from_android_info(info: Dictionary) -> ControllerLayout:
	var layout := ControllerLayout.new()
	layout.name = str(info.get("name", ""))
	layout.vendor = int(info.get("vendor", 0))
	layout.product = int(info.get("product", 0))
	var index_of := {}
	var min_of := {}
	var axes: Array = info.get("axes", [])
	for i in axes.size():
		var axis_id := int(axes[i].get("id", -1))
		layout.android_axes.append(axis_id)
		index_of[axis_id] = i
		min_of[axis_id] = float(axes[i].get("min", 0.0))

	layout.left_x = index_of.get(AXIS_X, -1)
	layout.left_y = index_of.get(AXIS_Y, -1)

	var has_z_rz := index_of.has(AXIS_Z) and index_of.has(AXIS_RZ)
	var has_rx_ry := index_of.has(AXIS_RX) and index_of.has(AXIS_RY)
	var stick := [AXIS_Z, AXIS_RZ] if has_z_rz else ([AXIS_RX, AXIS_RY] if has_rx_ry else [])
	var triggers := []
	if index_of.has(AXIS_LTRIGGER) or index_of.has(AXIS_RTRIGGER):
		triggers = [AXIS_LTRIGGER, AXIS_RTRIGGER]
	elif index_of.has(AXIS_BRAKE) or index_of.has(AXIS_GAS):
		triggers = [AXIS_BRAKE, AXIS_GAS]
	elif has_z_rz and has_rx_ry:
		# No dedicated trigger axes: one pair is the right stick, the other
		# the triggers. Sony pads put the triggers on RX/RY; Xbox-style pads
		# on Android's generic key layout put them on Z/RZ.
		if layout.vendor == VENDOR_SONY:
			stick = [AXIS_Z, AXIS_RZ]
			triggers = [AXIS_RX, AXIS_RY]
		else:
			stick = [AXIS_RX, AXIS_RY]
			triggers = [AXIS_Z, AXIS_RZ]
	if not stick.is_empty():
		layout.right_x = index_of.get(stick[0], -1)
		layout.right_y = index_of.get(stick[1], -1)
	if not triggers.is_empty():
		layout.left_trigger = index_of.get(triggers[0], -1)
		layout.right_trigger = index_of.get(triggers[1], -1)
		layout.left_trigger_centered = min_of.get(triggers[0], 0.0) < 0.0
		layout.right_trigger_centered = min_of.get(triggers[1], 0.0) < 0.0
	return layout

# A Godot joypad mapping line for Input.add_joy_mapping(). guid must be
# Input.get_joy_guid() for the device (on Android, derived from its name).
func to_godot_mapping(guid: String) -> String:
	var parts: PackedStringArray = [guid, name.replace(",", " ")]
	for pair in [["leftx", left_x], ["lefty", left_y], ["rightx", right_x],
			["righty", right_y], ["lefttrigger", left_trigger], ["righttrigger", right_trigger]]:
		if pair[1] >= 0:
			parts.append("%s:a%d" % pair)
	parts.append(BUTTON_BINDINGS)
	parts.append("platform:Android")
	return ",".join(parts)

func describe() -> String:
	return "%s [%04x:%04x] android_axes=%s lx=%d ly=%d rx=%d ry=%d lt=%d%s rt=%d%s" % [
		name, vendor, product, str(android_axes), left_x, left_y, right_x, right_y,
		left_trigger, "~" if left_trigger_centered else "",
		right_trigger, "~" if right_trigger_centered else "",
	]

# Normalises a mapped trigger reading to 0..1.
static func trigger_value(raw: float, centered: bool) -> float:
	return clampf((raw + 1.0) * 0.5 if centered else raw, 0.0, 1.0)

static func controller_type(vendor_id: int, pad_name: String) -> int:
	var lowered := pad_name.to_lower()
	if vendor_id == VENDOR_SONY or lowered.contains("dualshock") or lowered.contains("dualsense") \
			or lowered.contains("ps4") or lowered.contains("ps5") or lowered == "wireless controller":
		return CTYPE_PS
	if vendor_id == VENDOR_NINTENDO or lowered.contains("nintendo") or lowered.contains("pro controller"):
		return CTYPE_NINTENDO
	return CTYPE_XBOX
