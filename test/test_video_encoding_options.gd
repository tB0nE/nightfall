extends SceneTree

class UI extends RefCounted:
	func refresh_bitrate_limits(): pass
	func update_codec_btn(): pass
	func update_option_btn(_button, _text): pass
class State extends RefCounted:
	func save_state(): pass
class Owner extends Node3D:
	var settings := AppSettings.new()
	var bitrates := [5,10,15,20,30,40,50,60,80,100,120]
	var state_manager := State.new()
	var ui_controller := UI.new()
	var _ui_bitrate_btn: Button
class Controller extends SettingsController:
	func is_codec_available(idx: int) -> bool: return idx in [0, 1]
	func set_codec(value: int): main.settings.codec_preference = value
	func _schedule_stream_restart(_debounce_seconds: float = 0.8, _reconnect_delay: float = 0.0, _end_host_session: bool = false, _restart_info: Dictionary = {}): pass

func _init():
	assert(VideoEncodingOptions.wire_index(5) == 0)
	assert(VideoEncodingOptions.wire_name(5) == "h264")
	assert(VideoEncodingOptions.maximum_bitrate(0) == 150)
	assert(VideoEncodingOptions.maximum_bitrate(5) == 500)
	assert(VideoEncodingOptions.maximum_bitrate(1) == 200)
	var owner := Owner.new()
	var c := Controller.new(owner)
	owner.settings.host.bitrate_mbps = 120
	c.set_desktop_codec_choice(5)
	assert(c.desktop_codec_choice() == 5 and owner.settings.codec_preference == 0)
	c.set_bitrate_mbps(400)
	c.set_desktop_codec_choice(1)
	assert(owner.settings.host.bitrate_mbps == 120)
	c.set_bitrate_mbps(145)
	c.set_desktop_codec_choice(5)
	assert(owner.settings.host.bitrate_mbps == 400, "Each codec has its own desktop bitrate")
	c.set_desktop_codec_choice(0)
	assert(owner.settings.host.bitrate_mbps == 150)
	c.set_desktop_codec_choice(5)
	assert(owner.settings.host.bitrate_mbps == 400)
	c.set_desktop_codec_choice(2)
	assert(c.desktop_codec_choice() == 5, "Unavailable AV1 must not be selected")
	var xr := PCVRStreamSettings.new(true)
	xr.set_bitrate(137)
	xr.select_codec(5)
	xr.set_bitrate(420)
	xr.select_codec(1)
	assert(xr.bitrate_mbps == 137)
	xr.select_codec(5)
	assert(xr.bitrate_mbps == 420)
	var path := "user://codec-profiles-test.cfg"
	assert(xr.save_to(path) == OK)
	var loaded := PCVRStreamSettings.new(true)
	loaded.load_from(path)
	assert(loaded.codec_choice == 5 and loaded.bitrate_mbps == 420)
	assert(owner.settings.host.bitrate_mbps == 400, "XR preferences do not overwrite desktop preferences")
	c.toggle_extended_bitrate_limits()
	assert(VideoEncodingOptions.maximum_bitrate(0) == 300)
	assert(VideoEncodingOptions.maximum_bitrate(5) == 1000)
	assert(VideoEncodingOptions.maximum_bitrate(1) == 400 and VideoEncodingOptions.maximum_bitrate(2) == 400)
	c.set_bitrate_mbps(950)
	assert(owner.settings.host.bitrate_mbps == 950)
	xr.set_bitrate(1000)
	assert(xr.save_to(path) == OK)
	loaded.load_from(path)
	assert(loaded.bitrate_mbps == 1000, "Extended PCVR rates must survive a reload")
	var config := ConfigFile.new()
	SettingsPersistence.write_app(config,owner.settings)
	var restored := AppSettings.new()
	SettingsPersistence.read_app(config,restored,false,[0])
	assert(restored.extended_bitrate_limits and VideoEncodingOptions.extended_limits)
	c.toggle_extended_bitrate_limits()
	assert(VideoEncodingOptions.maximum_bitrate(5) == 500 and owner.settings.host.bitrate_mbps == 500)
	loaded.load_from(path)
	assert(loaded.bitrate_mbps == 500, "Disabling the option clamps saved PCVR rates")
	DirAccess.remove_absolute(path)
	assert(DefaultStreamResolution.packed_frame(Vector2i(1920,1080),Vector2i(3840,1080),Vector2i(1920,1080)) == Vector2i(3840,1080))
	assert(DefaultStreamResolution.packed_frame(Vector2i(1280,720),Vector2i(3840,1080),Vector2i(1920,1080)) == Vector2i(2560,720))
	owner.free()
	print("All video encoding option tests passed")
	quit()
