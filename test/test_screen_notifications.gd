extends SceneTree
class Presentation extends RefCounted:
	var requests := 0
	func request_stats_overlay_update(): requests += 1
class Renderer extends RefCounted:
	var visible := false
	var message_height := 0
	func set_overlay_message_height(value): message_height = value
	func set_overlay_visible(value): visible = value
class Screen extends Node3D:
	var comp_bezel_rect := Control.new()
	var comp_bezel_rect_left := Control.new()
	var comp_bezel_rect_right := Control.new()
	var comp_viewport := SubViewport.new()
	var comp_viewport_left := SubViewport.new()
	var comp_viewport_right := SubViewport.new()
	func _init():
		var views = [comp_viewport,comp_viewport_left,comp_viewport_right]
		var bezels = [comp_bezel_rect,comp_bezel_rect_left,comp_bezel_rect_right]
		for i in 3:
			views[i].size = Vector2i(1920,1080)
			add_child(views[i])
			views[i].add_child(bezels[i])
class Owner extends Node3D:
	var settings := AppSettings.new()
	var primary_screen: Screen
	var is_streaming := true
	var video_presentation := Presentation.new()
	var comp: CompositionLayerManager
	func _log(_text): pass
func _init(): call_deferred("run")
func run():
	var owner := Owner.new()
	root.add_child(owner)
	owner.primary_screen = Screen.new()
	owner.add_child(owner.primary_screen)
	owner.settings.performance_overlay_enabled = false
	owner.comp = CompositionLayerManager.new(owner)
	owner.comp.setup_stats_overlay()
	var toast := CompositionToast.new()
	toast.setup(owner, null)
	var native := NativeXrRendererManager.new(owner)
	var renderer := Renderer.new()
	native.renderer = renderer
	native.active = true
	native.stream_started = true
	var count := owner.get_child_count()
	toast.show("Controller mode on",null,ControllerMapper.MODE_ENABLED_HINT_SECONDS)
	assert(toast._persistent and toast._hide_at_msec == 0)
	toast.process()
	assert(owner.comp.screen_message_visible)
	assert(owner.get_child_count() == count, "Notifications must not allocate XR layers or viewports")
	assert(owner.find_child("CompToastLayer",true,false) == null)
	assert(owner.comp.screen_message_visible)
	native.request_stats_overlay_update()
	assert(renderer.visible, "Native renderer must show notification with stats off")
	assert(renderer.message_height == 184)
	assert(native._stats_upload_delay == 1)
	assert(not owner.comp._stats_background.visible)
	assert(owner.comp._screen_message_panel.position == CompositionLayerManager.MESSAGE_REGION.position + (CompositionLayerManager.MESSAGE_REGION.size - owner.comp._message_panel_size())*0.5)
	var panel_style: StyleBoxFlat = owner.comp._screen_message_panel.get_theme_stylebox("panel")
	assert(panel_style.corner_radius_top_left == 28 and panel_style.border_width_left == 3)
	assert(panel_style.border_color == Color(0.49,0.45,1.0,0.9))
	assert(owner.comp._screen_message_label.get_theme_font_size("font_size") == 40)
	assert(owner.comp.stats_rects.size() == 3)
	for target in owner.comp.stats_rects:
		assert(not target.rect.visible and target.message_rect.visible)
		assert(target.message_rect.get_rect().get_center().is_equal_approx(Vector2(target.viewport.size)*0.5))
		assert(target.message_rect.texture.region == CompositionLayerManager.MESSAGE_REGION)
	owner.settings.performance_overlay_enabled = true
	owner.comp.update_stats_text("Stats stay visible")
	owner.comp.set_stats_visible(true)
	assert(owner.comp._stats_background.visible and owner.comp._screen_message_panel.visible)
	owner.settings.performance_overlay_enabled = false
	native.set_stats_visible(false)
	assert(renderer.visible, "Turning stats off must retain an active notification")
	owner.settings.performance_overlay_enabled = true
	assert(owner.comp._screen_message_panel.position.y == 648)
	assert(owner.comp.stats_label.text == "Stats stay visible")
	for frame in 5: await process_frame
	assert(owner.comp._screen_message_panel.size == owner.comp._message_panel_size())
	assert(CompositionLayerManager.MESSAGE_REGION.end.y < CompositionLayerManager.SCREEN_OVERLAY_SIZE.y, "Border must have transparent atlas padding below it")
	var text_bounds: Rect2 = owner.comp._screen_message_label.get_rect()
	assert(Rect2(Vector2.ZERO, CompositionLayerManager.MESSAGE_REGION.size).encloses(text_bounds), "Wrapped message text must fit inside captured panel")
	var next := Screen.new()
	owner.add_child(next)
	owner.primary_screen = next
	toast.process()
	assert(owner.comp.stats_rects[0].rect.get_parent() == next.comp_bezel_rect)
	toast._hide_at_msec = Time.get_ticks_msec()-1
	toast.process()
	assert(not owner.comp.screen_message_visible)
	assert(owner.comp._stats_background.visible)
	owner.settings.performance_overlay_enabled = false
	owner.comp.set_stats_visible(false)
	native.set_stats_visible(false)
	assert(not renderer.visible, "No stats and no message must disable native overlay")
	assert(renderer.message_height == 0)
	assert(not owner.comp._stats_background.visible)
	for target in owner.comp.stats_rects: assert(not target.rect.visible)
	assert(owner.comp.stats_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED)
	owner.free()
	print("Screen notifications: no XR layer, stats coexistence, primary transfer and expiry passed")
	quit()
