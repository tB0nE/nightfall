extends SceneTree

func _init():
	var panels := CompositionPanelLayers.new()
	var pointers := CompositionPointerLayers.new()
	var viewport := SubViewport.new()
	var menu := panels._make_panel_layer("Menu", panels.UI_SORT_ORDER, Vector2.ONE, viewport)
	var keyboard := panels._make_panel_layer("Keyboard", panels.KEYBOARD_SORT_ORDER, Vector2.ONE, viewport)
	var cursor := pointers._make_layer("Cursor", Vector2(.04,.04))
	assert(cursor.get_sort_order() > menu.get_sort_order())
	assert(cursor.get_sort_order() > keyboard.get_sort_order())
	menu.free()
	keyboard.free()
	cursor.free()
	viewport.free()
	print("All composition_layer_order tests passed")
	quit()
