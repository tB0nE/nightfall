extends SceneTree
const LibraryPanel = preload("res://src/pcvr_app_library.gd")
class Transport extends RefCounted:
	signal library_reply(value: Dictionary)
	var state := "watching"
	var library_available := true
	var requests: Array = []
	func request_library(action: String, key: String = "", offset: int = 0) -> bool:
		requests.append({"action":action,"key":key,"offset":offset})
		return true
class Welcome extends RefCounted:
	var transport := Transport.new()
	func get_xr_control(): return transport
class Main extends RefCounted:
	var welcome_screen := Welcome.new()
class UI extends RefCounted:
	var main := Main.new()
	func make_action_btn(text: String) -> Button:
		var button := Button.new(); button.text=text; return button
	func close_vr_apps(): pass
func _init():
	var ui := UI.new()
	var panel := LibraryPanel.new()
	root.add_child(panel);panel.setup(ui);panel.open_library()
	var transport = ui.main.welcome_screen.transport
	assert(transport.requests[0].action=="list")
	transport.library_reply.emit({"action":"list","offset":0,"total":2,"apps":[
		{"key":"steam:1","name":"Ready game","source":"Steam","ready":true,"vr":true},
		{"key":"steam:2","name":"Needs setup","source":"Steam","ready":false,"vr":true}]})
	assert(panel._grid.get_child_count()==2)
	panel._grid.get_child(0).pressed.emit()
	assert(transport.requests.back().action=="launch")
	panel.refresh_apps()
	transport.state="prepared"
	var count=transport.requests.size()
	panel._grid.get_child(0).pressed.emit()
	assert(transport.requests.size()==count)
	assert("Exit" in panel._status.text)
	transport.state="watching"
	panel._grid.get_child(1).pressed.emit()
	assert(transport.requests.size()==count and "Steam" in panel._status.text)
	transport.library_reply.emit({"action":"list","offset":4,"total":0,"apps":[]})
	assert(panel._grid.get_child_count()==2)
	transport.library_reply.emit({"action":"list","offset":0,"total":1,"apps":[
		{"key":"steam:3","name":"SteamVR game","source":"Steam","ready":false,"vr":true,"requires_steamvr":true}]})
	count=transport.requests.size()
	panel._grid.get_child(0).pressed.emit()
	assert(panel._runtime_prompt.visible and "requires SteamVR" in panel._runtime_label.text)
	assert(transport.requests.size()==count, "Opening the prompt must not launch or install anything")
	panel._close_runtime_prompt()
	assert(not panel._runtime_prompt.visible and panel._grid.visible)
	assert(transport.requests.size()==count, "Cancel must not install SteamVR")
	panel._grid.get_child(0).pressed.emit()
	panel._runtime_install.pressed.emit()
	assert(transport.requests.back().action=="install_steamvr" and transport.requests.back().key=="steam:3")
	assert(not panel._runtime_prompt.visible)
	panel.free()
	print("All pcvr_app_library tests passed")
	quit()
