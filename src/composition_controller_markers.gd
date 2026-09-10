class_name CompositionControllerMarkers
extends RefCounted

const QUAD_SIZE := Vector2(0.03, 0.03)
const IDLE_ALPHA := 0.16

var right_layer: Node3D = null
var right_viewport: SubViewport = null
var right_circle: ColorRect = null
var left_layer: Node3D = null
var left_viewport: SubViewport = null
var left_circle: ColorRect = null
var _right_rest_position := Vector3.ZERO
var _left_rest_position := Vector3.ZERO
var _right_rest_position_valid := false
var _left_rest_position_valid := false

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if right_layer or left_layer:
		return
	for side in [&"right", &"left"]:
		var layer := _make_layer("CompMarker%sLayer" % String(side).capitalize())
		xr_origin.add_child(layer)

		var viewport := _make_viewport("CompMarker%sViewport" % String(side).capitalize())
		scene_root.add_child(viewport)

		var circle := _make_circle()
		viewport.add_child(circle)
		layer.set_layer_viewport(viewport)

		if side == &"right":
			right_layer = layer
			right_viewport = viewport
			right_circle = circle
		else:
			left_layer = layer
			left_viewport = viewport
			left_circle = circle

func _make_layer(layer_name: String) -> Node3D:
	var layer = OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.set_sort_order(998)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.set_quad_size(QUAD_SIZE)
	layer.visible = false
	return layer

func _make_viewport(viewport_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.disable_3d = true
	viewport.transparent_bg = true
	viewport.size = Vector2i(64, 64)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport

func _make_circle() -> ColorRect:
	var circle := ColorRect.new()
	circle.name = "MarkerCircle"
	circle.anchors_preset = Control.PRESET_FULL_RECT
	circle.anchor_right = 1.0
	circle.anchor_bottom = 1.0
	circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = preload("res://src/shaders/circle_cursor.gdshader")
	circle.material = material
	circle.visible = true
	return circle

func capture_controller_positions(right_hand: XRController3D, left_hand: XRController3D) -> void:
	if right_hand:
		_right_rest_position = right_hand.global_position
		_right_rest_position_valid = true
	if left_hand:
		_left_rest_position = left_hand.global_position
		_left_rest_position_valid = true

func update(active: bool, camera_basis: Basis, right_hand: XRController3D,
		left_hand: XRController3D, right_resting: bool, left_resting: bool,
		using_hand_tracking: bool) -> void:
	if not right_layer and not left_layer:
		return
	if not active:
		for layer in [right_layer, left_layer]:
			_set_hidden(layer, true)
			if layer:
				_set_viewport_active(layer.get_layer_viewport(), false)
		return
	for layer in [right_layer, left_layer]:
		if layer:
			_set_viewport_active(layer.get_layer_viewport(), true)
	_update_one(right_layer, right_circle, right_hand, camera_basis,
		right_resting or using_hand_tracking, using_hand_tracking,
		_right_rest_position, _right_rest_position_valid)
	_update_one(left_layer, left_circle, left_hand, camera_basis,
		left_resting or using_hand_tracking, using_hand_tracking,
		_left_rest_position, _left_rest_position_valid)

func _update_one(layer: Node3D, circle: ColorRect, hand: XRController3D,
		camera_basis: Basis, should_show: bool, use_rest_position: bool,
		rest_position: Vector3, rest_position_valid: bool) -> void:
	if not layer or not hand:
		return
	if not should_show:
		_set_hidden(layer, true)
		return
	layer.global_transform.basis = camera_basis
	# XRController3D is repurposed with hand-joint transforms while hand
	# tracking is active. Keep the marker at the captured physical controller
	# position rather than following the user's hand.
	layer.global_position = rest_position if use_rest_position and rest_position_valid \
		else hand.global_position
	layer.set_quad_size(QUAD_SIZE)
	if circle and circle.material:
		circle.material.set_shader_parameter("alpha_mult", IDLE_ALPHA)
	layer.visible = true

func _set_hidden(layer: Node3D, hidden: bool) -> void:
	if not layer:
		return
	if hidden:
		layer.set_quad_size(Vector2(0.0001, 0.0001))
	elif not layer.visible:
		layer.visible = true

func _set_viewport_active(viewport: SubViewport, active: bool) -> void:
	if not viewport:
		return
	var wanted := SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	if viewport.render_target_update_mode != wanted:
		viewport.render_target_update_mode = wanted
