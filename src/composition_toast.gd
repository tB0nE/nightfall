class_name CompositionToast
extends RefCounted

## A short message shown in front of the user for a few seconds, on its own
## composition layer so it appears above the stream screens (which are
## composition layers themselves; a projection-layer label would be hidden
## behind them). Used for hints such as how to leave controller mode.

const SIZE_PX := Vector2i(1100, 140)
const QUAD_SIZE := Vector2(0.55, 0.07)
const DISTANCE := 1.2
const DROP := 0.18
const SORT_ORDER := 999

var layer: Node3D = null
var viewport: SubViewport = null
var _label: Label = null
var _hide_at_msec := 0

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if layer:
		return
	layer = OpenXRCompositionLayerQuad.new()
	layer.name = "CompToastLayer"
	layer.set_sort_order(SORT_ORDER)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.set_quad_size(QUAD_SIZE)
	layer.visible = false
	xr_origin.add_child(layer)

	viewport = SubViewport.new()
	viewport.name = "CompToastViewport"
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.size = SIZE_PX
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	scene_root.add_child(viewport)

	var panel := PanelContainer.new()
	panel.anchors_preset = Control.PRESET_FULL_RECT
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.06, 0.09, 0.92)
	style.set_corner_radius_all(28)
	style.border_color = Color(0.49, 0.45, 1.0, 0.9)
	style.set_border_width_all(3)
	panel.add_theme_stylebox_override("panel", style)
	viewport.add_child(panel)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override("font_size", 40)
	_label.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	panel.add_child(_label)
	layer.set_layer_viewport(viewport)

## Shows `text` in front of `camera` for `seconds`.
func show(text: String, camera: Node3D, seconds: float = 4.0) -> void:
	if not layer or not camera:
		return
	_label.text = text
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# In front of the view, a little below its centre, level with the horizon.
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3(0, 0, -1)
	forward = forward.normalized()
	var pos := camera.global_position + forward * DISTANCE + Vector3(0, -DROP, 0)
	# -Z along `forward`, so the quad's front (+Z) faces the user.
	layer.global_transform = Transform3D(Basis.looking_at(forward, Vector3.UP), pos)
	layer.visible = true
	_hide_at_msec = Time.get_ticks_msec() + int(seconds * 1000.0)

func process() -> void:
	if layer and layer.visible and Time.get_ticks_msec() >= _hide_at_msec:
		layer.visible = false
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
