extends SceneTree
const Picker = preload("res://src/server_picker.gd")
class Welcome extends RefCounted:
	var saved: Dictionary = {}
	var found: Dictionary = {}
	func browse_mdns(): pass
	func clear_saved_servers(): pass
	func show_welcome_screen(_name): pass
	func select_saved_server(host): saved = host
	func select_discovered_server(host): found = host
	func pair_address(ip,port): return WelcomeScreen.pair_address(ip,port)
func _init(): call_deferred("run")
func run():
	var welcome := Welcome.new()
	var picker := Picker.new(welcome)
	var canvas := Control.new()
	canvas.size = Vector2(1920,1080)
	root.add_child(canvas)
	picker.build(canvas)
	canvas.get_child(0).visible = true
	var hosts: Array = []
	for i in 10: hosts.append({"id":i,"hostname":"Desktop %d" % i,"localaddress":"10.0.0.%d" % i,"https_port":47984})
	picker.refresh(hosts,0,false)
	assert(picker._grid.get_child_count()==8 and not picker._next.disabled)
	picker._grid.get_child(0).pressed.emit()
	assert(welcome.saved.id==0)
	picker._show_page(1)
	assert(picker._grid.get_child_count()==2 and picker._next.disabled)
	picker.set_discovered([{"ip":"10.0.0.0","port":47989},{"ip":"10.0.0.0","port":57989,"friendly_name":"Other host, same IP"}])
	assert(picker._entries.size()==11,"Deduplicate by address AND port, preserving different hosts on one PC")
	picker._grid.get_child(2).pressed.emit()
	assert(welcome.found.port==57989)
	for frame in 5: await process_frame
	for card in picker._grid.get_children():
		assert(card.get_global_rect().end.y<1080)
	picker.set_scanning(true)
	assert(picker._scan.disabled)
	picker.set_scanning(false)
	assert(not picker._scan.disabled)
	canvas.free()
	print("Server cards: paging, saved/discovered actions, custom ports and bounds passed")
	quit()
