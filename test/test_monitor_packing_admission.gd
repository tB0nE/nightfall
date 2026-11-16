extends SceneTree

class UI extends RefCounted:
	var messages: Array = []
	func set_status(value): messages.append(value)
class Choice extends ScreenTabStrip:
	var accept := false
	var shown := 0
	func confirm_hevc(callback: Callable) -> void:
		shown += 1
		popup = "packing_confirmation"
		callback.call(accept)
class Sources extends RefCounted:
	var menu: Choice
	func menu_for_screen(_screen): return menu
class Controller extends RefCounted:
	var owner
	var hevc := true
	var changes := 0
	func is_codec_available(_value): return hevc
	func set_desktop_codec_choice(value, restart := true):
		assert(not restart, "Accepting must leave restart to the single monitor transaction")
		changes += 1
		owner.settings.codec_preference = value
class Owner extends Node3D:
	var settings := AppSettings.new()
	var current_host_id := 7
	var is_streaming := true
	var layout := ScreenLayout.single(Vector2i(2560,1440))
	var screens: Array[VRScreen] = []
	var primary_screen: VRScreen
	var resolutions := [Vector2i(2560,1440)]
	var device_is_quest2 := false
	var _staged_physical_count := 1
	var _staged_virtual_count := 0
	var settings_controller := Controller.new()
	var screen_sources := Sources.new()
	var ui_controller := UI.new()
class Manager extends StreamManager:
	var replies: Array = []
	var requests: Array = []
	var change_host := false
	func _packing_preview(options: Dictionary) -> Dictionary:
		requests.append(options.duplicate())
		if change_host: main.current_host_id += 1
		return replies.pop_front()

func _init(): call_deferred("run")
func run():
	var owner := Owner.new()
	root.add_child(owner)
	owner.layout.monitors[0].label = "DP-1"
	owner.layout.packing_budget_version = 1
	owner.settings.codec_preference = 0
	owner.settings.host.default_resolution_selected = true
	owner.settings.host.resolution_idx = 0
	owner.settings_controller.owner = owner
	var screen := VRScreen.new()
	owner.screens.append(screen)
	owner.primary_screen = screen
	owner.screen_sources.menu = Choice.new(owner, screen, RefCounted.new())
	var manager := Manager.new(owner)
	var fits := {"packing_budget_version":1,"packing_fits":true,"frame_size":[2560,2880]}
	var misses := {"packing_budget_version":1,"packing_fits":false,"frame_size":[2560,2880]}
	manager.replies = [fits]
	assert(await manager.admit_monitor_set(owner.layout, 1, "", screen))
	assert(await manager.admit_monitor_set(owner.layout, 1, "", screen, true))
	assert(manager.requests.size() == 1, "Consume exactly one unchanged preapproval")
	manager.replies = [misses, fits]
	assert(not await manager.admit_monitor_set(owner.layout, 2, "", screen))
	assert(owner.settings.codec_preference == 0 and owner.settings_controller.changes == 0)
	assert(owner.settings.host.virtual_display_count == 0 and screen.content_tabs.tabs.is_empty())
	owner.screen_sources.menu.accept = true
	manager.replies = [misses, fits]
	assert(await manager.admit_monitor_set(owner.layout, 2, "", screen))
	assert(owner.settings.codec_preference == 1 and owner.settings_controller.changes == 1)
	assert(await manager.admit_monitor_set(owner.layout, 2, "", screen, true))
	owner.settings.codec_preference = 0
	owner.settings_controller.hevc = false
	manager.replies = [misses]
	var shown: int = owner.screen_sources.menu.shown
	assert(not await manager.admit_monitor_set(owner.layout, 2, "", screen))
	assert(owner.screen_sources.menu.shown == shown, "Do not offer unsupported HEVC")
	owner.settings_controller.hevc = true
	manager.replies = [misses, misses]
	assert(not await manager.admit_monitor_set(owner.layout, 2, "", screen))
	assert(owner.screen_sources.menu.shown == shown, "HEVC must actually fit")
	manager.change_host = true
	manager.replies = [fits]
	assert(not await manager.admit_monitor_set(owner.layout, 1, "", screen), "Discard stale host replies")
	manager.change_host = false
	manager._capacity_check_at = 0
	owner.settings.codec_preference = 1
	manager.replies = [misses]
	assert(not manager.monitor_proposal_available(owner.layout,3,""), "HEVC no-fit choices must be disabled")
	manager._capacity_check_at = 0
	owner.settings.codec_preference = 0
	manager.replies = [misses,fits]
	assert(manager.monitor_proposal_available(owner.layout,3,""), "H.264 choices may offer a fitting HEVC alternative")
	manager._capacity_check_at = 0
	owner.settings.codec_preference = 1
	manager.replies = [fits]
	assert(manager.monitor_proposal_available(owner.layout,1,""), "Fitting resolutions remain enabled")
	screen.free()
	owner.free()
	print("All monitor admission, cancellation and stale-reply tests passed")
	quit()
