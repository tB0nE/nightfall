extends SceneTree

class Backend extends RefCounted:
	var scrolls: Array = []
	var positions: Array = []
	func send_scroll_event(clicks: int): scrolls.append(clicks)
	func send_mouse_position_event(x: int, y: int, ref_w: int, ref_h: int): positions.append(Vector2i(x, y))

class Layout extends RefCounted:
	func host_ref() -> Vector2i: return Vector2i(1920, 1080)

class FakeScreenSources extends RefCounted:
	func focused_browser(): return null
	func browser_for_screen(_screen): return null

class Owner extends Node3D:
	var settings := AppSettings.new()
	var is_xr_active := true
	var is_streaming := true
	var controller_mapper = null
	var virtual_keyboard = null
	var right_hand = null
	var stream_backend := Backend.new()
	var layout := Layout.new()
	var screen_sources := FakeScreenSources.new()
	var ui_visible := false
	var hand_raycast: RayCast3D = null
	var left_hand_raycast: RayCast3D = null

# Stands in for the raycast: the host pixel the pointer is on, or null.
class Interaction extends XRInteraction:
	var pointed = null
	func _stream_host_point(_raycast: RayCast3D) -> Variant: return pointed

func _init():
	var owner := Owner.new()
	_test_gamepad_does_not_scroll(owner)
	_test_mouse_follows_pointer(owner)
	owner.free()
	print("All pointer_input tests passed")
	quit()

# #60: only the Quest controller scrolls. (Godot can't connect a fake gamepad
# from a script, so the gamepad itself isn't simulated here.)
func _test_gamepad_does_not_scroll(owner: Owner) -> void:
	var interaction := Interaction.new(owner)
	interaction.handle_scroll()
	assert(owner.stream_backend.scrolls.is_empty(), "no Quest controller, no scroll")
	assert(XRInteraction.scroll_clicks(0.9) == 1)
	assert(XRInteraction.scroll_clicks(-0.9) == -1)
	assert(XRInteraction.scroll_clicks(0.4) == 0)

# #61: with the setting on, the host cursor follows the pointer without a click.
func _test_mouse_follows_pointer(owner: Owner) -> void:
	var interaction := Interaction.new(owner)
	var sent: Array = owner.stream_backend.positions
	interaction.pointed = Vector2i(100, 200)
	interaction._follow_pointer_with_mouse(null, false)
	assert(sent.is_empty(), "off by default")

	owner.settings.mouse_follows_pointer = true
	interaction._follow_pointer_with_mouse(null, false)
	assert(sent == [Vector2i(100, 200)])
	interaction._follow_pointer_with_mouse(null, false)
	assert(sent.size() == 1, "an unchanged pixel isn't resent")
	interaction.pointed = Vector2i(101, 200)
	interaction._follow_pointer_with_mouse(null, false)
	assert(sent.back() == Vector2i(101, 200))

	interaction.pointed = null
	interaction._follow_pointer_with_mouse(null, false)
	assert(sent.size() == 2, "off the screen sends nothing")
	interaction.pointed = Vector2i(5, 5)
	interaction._follow_pointer_with_mouse(null, true)
	assert(sent.size() == 2, "the trackpad, gamepad mode or a grab blocks it")
	owner.is_streaming = false
	interaction._follow_pointer_with_mouse(null, false)
	assert(sent.size() == 2, "nothing while not streaming")
	owner.is_streaming = true
	owner.settings.mouse_follows_pointer = false
