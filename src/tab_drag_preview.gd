class_name TabDragPreview
extends RefCounted

## While a content tab is dragged: over empty space a yellow outline shows
## where its screen will appear, and a copy of its label follows the pointer.
## Projectionless Quest rendering draws only composition layers: there the
## outline is one layer that exists only during a drag (warped with the grid
## surface like the screens), and the label rides on the cursor layer
## (CompositionPointerLayers.show_drag()). Otherwise both are plain meshes.

const OUTLINE_COLOR := Color(1.0, 0.82, 0.1, 0.95)
const LABEL_SIZE := Vector2i(640, 112)
## The label's width as a fraction of its distance from the viewer.
const LABEL_WIDTH_PER_METRE := 0.13

var main: Node3D
var _outline_layer: OpenXRCompositionLayerCylinder
var _outline_viewport: SubViewport
var _outline_canvas: OutlineCanvas
var _outline_mesh: MeshInstance3D
var _label_viewport: SubViewport
var _label: Label
var _label_mesh: MeshInstance3D

class OutlineCanvas extends Control:
	func _draw() -> void:
		var line := maxf(size.x * 0.008, 4.0)
		draw_rect(Rect2(Vector2.ZERO, size), Color(OUTLINE_COLOR, 0.1))
		draw_rect(Rect2(Vector2.ONE * line * 0.5, size - Vector2.ONE * line), OUTLINE_COLOR, false, line)

func _init(owner: Node3D) -> void:
	main = owner

func _ensure() -> void:
	if is_instance_valid(_outline_viewport): return
	_outline_viewport = _viewport("TabDropOutlineViewport", Vector2i(1024, 576))
	_outline_canvas = OutlineCanvas.new()
	_outline_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_outline_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_outline_viewport.add_child(_outline_canvas)
	_label_viewport = _viewport("TabDragLabelViewport", LABEL_SIZE)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.92)
	style.border_color = OUTLINE_COLOR
	style.set_border_width_all(4)
	style.set_corner_radius_all(18)
	style.content_margin_left = 24
	style.content_margin_right = 24
	panel.add_theme_stylebox_override("panel", style)
	_label_viewport.add_child(panel)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_label.add_theme_font_size_override("font_size", 44)
	_label.add_theme_color_override("font_color", Color.WHITE)
	panel.add_child(_label)
	var origin: Node3D = main.get("xr_origin")
	if origin != null and ClassDB.class_exists("OpenXRCompositionLayerCylinder"):
		_outline_layer = OpenXRCompositionLayerCylinder.new()
		_outline_layer.name = "TabDropOutlineLayer"
		_outline_layer.set_sort_order(997)
		_outline_layer.set_enable_hole_punch(false)
		_outline_layer.set_alpha_blend(true)
		_outline_layer.visible = false
		origin.add_child(_outline_layer)
		_outline_layer.set_layer_viewport(_outline_viewport)
	_outline_mesh = _mesh("TabDropOutlineMesh", _outline_viewport)
	_label_mesh = _mesh("TabDragLabelMesh", _label_viewport)

func _viewport(node_name: String, size: Vector2i) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = node_name
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.size = size
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(viewport)
	return viewport

func _mesh(node_name: String, viewport: SubViewport) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = node_name
	mesh.mesh = QuadMesh.new()
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 120
	material.albedo_texture = viewport.get_texture()
	mesh.material_override = material
	mesh.visible = false
	main.add_child(mesh)
	return mesh

func _layers_in_use() -> bool:
	return main.get("comp") != null and main.comp.in_use and is_instance_valid(_outline_layer)

## title: the dragged tab's label; point: where the pointer is; placement:
## ScreenPlacementController.preview() for a drop there, or empty for none.
func update(title: String, point: Vector3, placement: Dictionary) -> void:
	_ensure()
	var layers := _layers_in_use()
	_show_label(title, point, layers)
	_show_outline(placement, layers)

func hide() -> void:
	for node in [_outline_layer, _outline_mesh, _label_mesh]:
		if is_instance_valid(node): node.visible = false
	if is_instance_valid(_outline_layer): SphereLayers.sync(_outline_layer, false, Transform3D.IDENTITY, 1.0, 0.0, 0.0, 0.0, 997)

func _show_label(title: String, point: Vector3, layers: bool) -> void:
	_label.text = title
	var camera: Node3D = main.get("xr_camera")
	var camera_position := camera.global_position if is_instance_valid(camera) else Vector3.ZERO
	var distance := maxf(point.distance_to(camera_position), 0.3)
	var width := distance * LABEL_WIDTH_PER_METRE
	var size := Vector2(width, width * LABEL_SIZE.y / LABEL_SIZE.x)
	# Just above the pointer and a little nearer, so it never hides the drop point.
	var position := point.lerp(camera_position, 0.06) + Vector3.UP * size.y * 0.9
	var away := position - camera_position
	var basis := Basis.looking_at(away if away.length() > 0.01 else Vector3.FORWARD, Vector3.UP)
	var pose := Transform3D(basis, position)
	if layers:
		_label_mesh.visible = false # The cursor layer carries it.
		return
	(_label_mesh.mesh as QuadMesh).size = size
	_label_mesh.global_transform = pose
	_label_mesh.visible = true

func _show_outline(placement: Dictionary, layers: bool) -> void:
	if placement.is_empty():
		if is_instance_valid(_outline_layer):
			_outline_layer.visible = false
		_outline_mesh.visible = false
		return
	var size: Vector2 = placement.size
	var wanted := Vector2i(1024, clampi(roundi(1024.0 * size.y / maxf(size.x, 0.01)), 64, 2048))
	if _outline_viewport.size != wanted:
		_outline_viewport.size = wanted
		_outline_canvas.queue_redraw()
	var screen: Transform3D = placement.screen
	if not layers:
		(_outline_mesh.mesh as QuadMesh).size = size
		_outline_mesh.global_transform = screen
		_outline_mesh.visible = true
		if is_instance_valid(_outline_layer): _outline_layer.visible = false
		return
	_outline_mesh.visible = false
	var radius: float = placement.radius
	_outline_layer.visible = true
	_outline_layer.set_radius(radius)
	_outline_layer.set_central_angle(size.x / maxf(radius, 0.01))
	_outline_layer.set_aspect_ratio(size.x / maxf(size.y, 0.01))
	_outline_layer.global_transform = Transform3D(screen.basis, screen.origin + screen.basis.z.normalized() * radius)
	if placement.kind == &"sphere":
		SphereLayers.sync(_outline_layer, true, placement.frame, radius, placement.horizontal, placement.upper, placement.lower, 997)
	else:
		SphereLayers.sync(_outline_layer, false, Transform3D.IDENTITY, radius, 0.0, 0.0, 0.0, 997)
