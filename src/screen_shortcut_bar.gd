class_name ScreenShortcutBar
extends RefCounted

const ACTION_SBS: StringName = &"sbs"
const ACTION_PAD: StringName = &"pad"
const ACTION_MENU: StringName = &"menu"
const ACTION_KEYBOARD: StringName = &"keyboard"

const ACTIONS: Array[StringName] = [ACTION_SBS, ACTION_PAD, ACTION_MENU, ACTION_KEYBOARD]
const VISIBLE_ACTIONS: Array[StringName] = [ACTION_PAD, ACTION_KEYBOARD, ACTION_SBS, ACTION_MENU]
const ICONS := {
	ACTION_SBS: preload("res://src/assets/screen_shortcuts/sbs.svg"),
	ACTION_PAD: preload("res://src/assets/screen_shortcuts/pad.svg"),
	ACTION_MENU: preload("res://src/assets/screen_shortcuts/menu.svg"),
	ACTION_KEYBOARD: preload("res://src/assets/screen_shortcuts/keyboard.svg"),
}

# Use the screen grab bar's 0.05 idle opacity, with a stronger 0.25 icon
# hover and 0.40 while active/open. Active remains blue on hover so toggle
# state cannot be mistaken for a pointer-position effect.
const IDLE_COLOR := Color(1.0, 1.0, 1.0, 0.05)
const HOVER_COLOR := Color(1.0, 1.0, 1.0, 0.25)
const ACTIVE_COLOR := Color(0.32, 0.64, 1.0, 0.40)
const ACTIVE_HOVER_COLOR := ACTIVE_COLOR
const PRIMARY_BAR_COLOR := Color(0.55, 0.78, 1.0)

# All dimensions scale with screen width. The composition viewport uses the
# same normalized layout, so its visuals stay aligned with these hit targets.
const STRIP_WIDTH_RATIO := 0.36
const STRIP_HEIGHT_RATIO := 0.046
const BAR_WIDTH_RATIO := 0.134
const BAR_HEIGHT_RATIO := 0.009
const ICON_SIZE_RATIO := 0.036
const ICON_GAP_RATIO := 0.014
const HIT_SIZE_RATIO := 0.044
const COMP_VIEWPORT_SIZE := Vector2i(768, 98)
const HIDE_DELAY_SECONDS := 0.5

var main: Node3D
var hovered_action: StringName = &""
var revealed_screen: VRScreen = null
var _reveal_time_remaining := 0.0

func _init(owner: Node3D):
	main = owner

func setup_screen(screen: VRScreen) -> void:
	if not screen or not screen.shortcut_buttons.is_empty():
		return
	for action in VISIBLE_ACTIONS:
		var icon = MeshInstance3D.new()
		icon.name = "ScreenShortcut_%s" % String(action)
		icon.set_meta(&"nf_role", &"screen_shortcut")
		icon.set_meta(&"nf_action", action)

		var quad = QuadMesh.new()
		quad.orientation = PlaneMesh.FACE_Z
		icon.mesh = quad
		var material = StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_texture = ICONS[action]
		material.albedo_color = IDLE_COLOR
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.no_depth_test = true
		material.render_priority = 127
		icon.material_override = material

		# Keep interaction geometry separate from the rendered icon. In
		# projectionless mode the icon users see belongs to an OpenXR layer;
		# this direct screen-local Area3D is the corresponding physics target.
		var area = Area3D.new()
		area.name = "ScreenShortcutArea_%s" % String(action)
		area.set_meta(&"nf_role", &"screen_shortcut")
		area.set_meta(&"nf_action", action)
		area.collision_layer = 2
		var collision = CollisionShape3D.new()
		collision.name = "CollisionShape3D"
		collision.shape = BoxShape3D.new()
		area.add_child(collision)
		screen.add_child(icon)
		screen.add_child(area)
		screen.shortcut_buttons[action] = icon
		screen.shortcut_areas[action] = area
	screen.update_shortcut_positions()
	refresh_visuals(screen)

func populate_composition_viewport(screen: VRScreen, viewport: SubViewport) -> void:
	var root = Control.new()
	root.name = "ShortcutStrip"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	viewport.add_child(root)

	var world_width = STRIP_WIDTH_RATIO
	var world_height = STRIP_HEIGHT_RATIO
	var center_y = COMP_VIEWPORT_SIZE.y * 0.5
	var bar = PanelContainer.new()
	bar.name = "GrabBarPanel"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bar_w = BAR_WIDTH_RATIO / world_width * COMP_VIEWPORT_SIZE.x
	var bar_h = BAR_HEIGHT_RATIO / world_height * COMP_VIEWPORT_SIZE.y
	bar.position = Vector2((COMP_VIEWPORT_SIZE.x - bar_w) * 0.5, center_y - bar_h * 0.5)
	bar.size = Vector2(bar_w, bar_h)
	var bar_style = StyleBoxFlat.new()
	var bar_rgb = PRIMARY_BAR_COLOR if screen == main.primary_screen else Color.WHITE
	bar_style.bg_color = Color(bar_rgb.r, bar_rgb.g, bar_rgb.b, 0.05)
	bar_style.set_corner_radius_all(6)
	bar.add_theme_stylebox_override("panel", bar_style)
	root.add_child(bar)

	for action in VISIBLE_ACTIONS:
		var rect = TextureRect.new()
		rect.name = "ShortcutIcon_%s" % String(action)
		rect.texture = ICONS[action]
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var icon_px = ICON_SIZE_RATIO / world_height * COMP_VIEWPORT_SIZE.y
		var x_world = _action_x_ratio(action)
		var x_px = (x_world / world_width + 0.5) * COMP_VIEWPORT_SIZE.x
		rect.position = Vector2(x_px - icon_px * 0.5, center_y - icon_px * 0.5)
		rect.size = Vector2(icon_px, icon_px)
		rect.modulate = IDLE_COLOR
		root.add_child(rect)
		screen.comp_shortcut_icons[action] = rect
	refresh_visuals(screen)

func begin_pointer_frame(delta: float = 0.0) -> void:
	hovered_action = &""
	if revealed_screen:
		_reveal_time_remaining = maxf(_reveal_time_remaining - maxf(delta, 0.0), 0.0)
		if _reveal_time_remaining <= 0.0:
			revealed_screen = null

func reveal_controls(screen: VRScreen) -> void:
	if screen:
		revealed_screen = screen
		_reveal_time_remaining = HIDE_DELAY_SECONDS

func controls_are_revealed(screen: VRScreen) -> bool:
	return screen != null and screen == revealed_screen

func set_hover(action: StringName) -> void:
	hovered_action = action

func invoke(action: StringName) -> void:
	match action:
		ACTION_SBS:
			# Match the menu SBS control: an explicit user selection takes
			# ownership from automatic SBS detection.
			main.auto_detect_enabled = false
			main.settings_controller.cycle_sbs_mode()
		ACTION_PAD:
			main.controller_mapper.check_toggle_ui()
		ACTION_MENU:
			main._toggle_ui()
		ACTION_KEYBOARD:
			main.virtual_keyboard.toggle()
		_:
			return
	main._log("[SHORTCUT] Activated %s from primary screen" % String(action))
	refresh_visuals(main.primary_screen)

func refresh_visuals(screen: VRScreen) -> void:
	if not screen:
		return
	var changed = false
	var show = screen == main.primary_screen and controls_are_revealed(screen)
	var bar_rgb = PRIMARY_BAR_COLOR if screen == main.primary_screen else Color.WHITE
	if screen.grab_bar and screen.grab_bar.material_override:
		var real_bar_color = screen.grab_bar.material_override.albedo_color
		var desired_real_bar = Color(bar_rgb.r, bar_rgb.g, bar_rgb.b, real_bar_color.a)
		if real_bar_color != desired_real_bar:
			screen.grab_bar.material_override.albedo_color = desired_real_bar
	if screen.comp_grab_bar_viewport:
		var bar = screen.comp_grab_bar_viewport.find_child("GrabBarPanel", true, false) as PanelContainer
		if bar:
			var style = bar.get_theme_stylebox("panel") as StyleBoxFlat
			if style:
				var desired_comp_bar = Color(bar_rgb.r, bar_rgb.g, bar_rgb.b, style.bg_color.a)
				if style.bg_color != desired_comp_bar:
					style = style.duplicate()
					style.bg_color = desired_comp_bar
					bar.add_theme_stylebox_override("panel", style)
					changed = true
	for action in VISIBLE_ACTIONS:
		var active = _is_active(action)
		var color: Color
		if active:
			color = ACTIVE_HOVER_COLOR if action == hovered_action else ACTIVE_COLOR
		else:
			color = HOVER_COLOR if action == hovered_action else IDLE_COLOR
		var icon = screen.shortcut_buttons.get(action) as MeshInstance3D
		if icon and icon.material_override:
			icon.visible = show
			if icon.material_override.albedo_color != color:
				icon.material_override.albedo_color = color
		var comp_icon = screen.comp_shortcut_icons.get(action) as TextureRect
		if comp_icon:
			if comp_icon.visible != show:
				comp_icon.visible = show
				changed = true
			if comp_icon.modulate != color:
				comp_icon.modulate = color
				changed = true
	if changed and screen.comp_grab_bar_viewport:
		# UPDATE_ALWAYS is intentional while the layer is visible; see
		# CompositionLayerManager.setup_screen().
		screen.comp_grab_bar_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func log_hit(screen: VRScreen, action: StringName, world_hit: Vector3) -> void:
	var area = screen.shortcut_areas.get(action) as Area3D
	var shape_size = Vector3.ZERO
	if area:
		var collision = area.get_node_or_null("CollisionShape3D") as CollisionShape3D
		if collision and collision.shape is BoxShape3D:
			shape_size = collision.shape.size
	main._log("[SHORTCUT] Hit %s local=%s target=%s size=%s" % [
		String(action),
		str(screen.to_local(world_hit)),
		str(area.position if area else Vector3.ZERO),
		str(shape_size),
	])

func _is_active(action: StringName) -> bool:
	match action:
		ACTION_SBS:
			return main.settings.host.sbs_mode > 0
		ACTION_PAD:
			return main.controller_mapper and main.controller_mapper.is_active()
		ACTION_MENU:
			return main.ui_visible
		ACTION_KEYBOARD:
			return main.virtual_keyboard and main.virtual_keyboard.visible
	return false

static func _action_x_ratio(action: StringName) -> float:
	var near = BAR_WIDTH_RATIO * 0.5 + ICON_GAP_RATIO + ICON_SIZE_RATIO * 0.5
	var step = ICON_SIZE_RATIO + ICON_GAP_RATIO
	match action:
		ACTION_PAD:
			return -near - step
		ACTION_KEYBOARD:
			return -near
		ACTION_SBS:
			return near
		ACTION_MENU:
			return near + step
	return 0.0
