extends SceneTree

class Handover extends RefCounted:
	enum State { IDLE, ACTIVE }
	var state := State.IDLE

class Owner extends Node3D:
	var pcvr_handover := Handover.new()
	var is_streaming := false
	var welcome_screen
	var pcvr_test := BackendOwner.new()
	var display_refresh_rate := 72.0

class BackendOwner extends RefCounted:
	var backend := Backend.new()

class Backend extends RefCounted:
	func get_test_status() -> Dictionary: return {"pcvr_post_processing_supported": true}

class ControlState extends RefCounted:
	var state := "idle"

class MenuHarness extends UIController:
	func switch_tab(tab: int): _current_tab = tab

func _initialize() -> void:
	var owner := Owner.new()
	owner.welcome_screen = WelcomeScreen.new(owner)
	var control := ControlState.new()
	owner.welcome_screen._xr_control = control
	var ui := MenuHarness.new(owner)
	var link := Button.new()
	var rounded := StyleBoxFlat.new()
	rounded.set_corner_radius_all(12)
	for state in ["normal", "hover", "pressed"]: link.add_theme_stylebox_override(state, rounded)
	UIController.square_toolbar_button(link)
	assert(link.size_flags_vertical == Control.SIZE_FILL)
	for state in ["normal", "hover", "pressed"]:
		assert(link.get_theme_stylebox(state).corner_radius_top_left == 0)
		assert(link.get_theme_stylebox(state).corner_radius_bottom_right == 0)
	ui._pcvr_link = link
	ui.refresh_pcvr_menu()
	assert(not link.visible)
	owner.pcvr_handover.state = Handover.State.ACTIVE
	ui.refresh_pcvr_menu()
	assert(link.visible and link.text == "PCVR")
	ui._current_tab = UIController.PCVR_PAGE
	ui.refresh_pcvr_menu()
	assert(link.visible and link.text == "Desktop", "Always allow returning from PCVR settings")
	owner.is_streaming = true
	ui.refresh_pcvr_menu()
	assert(link.visible and link.text == "Desktop")
	ui._current_tab = 0
	owner.pcvr_handover.state = Handover.State.IDLE
	ui.refresh_pcvr_menu()
	assert(not link.visible)
	# Depth-only Meteor is insufficient; an authenticated XR watch enables setup.
	owner.is_streaming = true
	ui.refresh_pcvr_menu()
	assert(not link.visible)
	control.state = "watching"
	ui.refresh_pcvr_menu()
	assert(link.visible and link.text == "PCVR")
	assert(link.get_theme_color("font_color").a < 1.0)
	ui.toggle_pcvr_page()
	assert(ui._current_tab == UIController.PCVR_PAGE)
	var info := Label.new()
	var status := Label.new()
	var exit_button := Button.new()
	ui._pcvr_info = info
	ui._pcvr_status = status
	ui._pcvr_exit_btn = exit_button
	ui.refresh_pcvr_menu()
	assert(link.text == "Desktop" and info.text.contains("Ready for XR"))
	assert(status.text == "No XR session running" and not exit_button.visible)
	owner.pcvr_handover.state = Handover.State.ACTIVE
	ui.refresh_pcvr_menu()
	assert(exit_button.visible and link.get_theme_color("font_color").g == 1.0)
	owner.pcvr_handover.state = Handover.State.IDLE
	control.state = "failed"
	ui.refresh_pcvr_menu()
	assert(not link.visible and ui._current_tab == 0)
	control.state = "watching"
	owner.is_streaming = false
	assert(not owner.welcome_screen.xr_settings_available())
	info.free()
	status.free()
	exit_button.free()
	link.free()
	owner.free()
	print("All pcvr_menu tests passed")
	quit()
