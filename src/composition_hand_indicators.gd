class_name CompositionHandIndicators
extends RefCounted

const QUAD_SIZE := 0.32
const VIEWPORT_SIZE := Vector2i(256, 256)

var right_layer: Node3D = null
var right_triangle: ColorRect = null
var left_layer: Node3D = null
var left_triangle: ColorRect = null

func setup(scene_root: Node, xr_origin: Node3D) -> void:
	if right_layer or left_layer:
		return
	for side in [&"right", &"left"]:
		var layer := _make_layer("CompHand%sLayer" % String(side).capitalize())
		xr_origin.add_child(layer)

		var viewport := _make_viewport("CompHand%sViewport" % String(side).capitalize())
		scene_root.add_child(viewport)

		var triangle := _make_triangle()
		viewport.add_child(triangle)
		layer.set_layer_viewport(viewport)

		if side == &"right":
			right_layer = layer
			right_triangle = triangle
		else:
			left_layer = layer
			left_triangle = triangle

func _make_layer(layer_name: String) -> Node3D:
	var layer = OpenXRCompositionLayerQuad.new()
	layer.name = layer_name
	layer.set_sort_order(998)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.set_quad_size(Vector2(QUAD_SIZE, QUAD_SIZE))
	layer.visible = false
	return layer

func _make_viewport(viewport_name: String) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.disable_3d = true
	viewport.transparent_bg = true
	# The triangle shader's smoothstep antialiasing needs enough pixels to
	# blend cleanly on a 0.32 m quad; 64x64 appeared visibly blocky on-device.
	viewport.size = VIEWPORT_SIZE
	viewport.msaa_2d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport

func _make_triangle() -> ColorRect:
	var triangle := ColorRect.new()
	triangle.name = "CompHandTriangle"
	triangle.anchors_preset = Control.PRESET_FULL_RECT
	triangle.anchor_right = 1.0
	triangle.anchor_bottom = 1.0
	triangle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := ShaderMaterial.new()
	material.shader = preload("res://src/shaders/inverted_triangle.gdshader")
	triangle.material = material
	triangle.visible = true
	return triangle

func update(active: bool, camera_position: Vector3) -> void:
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
	_update_one(right_layer, right_triangle,
		XRServer.get_tracker("/user/hand_tracker/right"), camera_position)
	_update_one(left_layer, left_triangle,
		XRServer.get_tracker("/user/hand_tracker/left"), camera_position)

func _update_one(layer: Node3D, triangle: ColorRect, tracker: XRHandTracker,
		camera_position: Vector3) -> void:
	if not layer or not triangle:
		return
	if not tracker or not (tracker is XRHandTracker):
		_set_hidden(layer, true)
		return
	const TRACKED := XRHandTracker.HAND_JOINT_FLAG_POSITION_TRACKED
	var wrist_ok := (tracker.get_hand_joint_flags(XRHandTracker.HAND_JOINT_WRIST) & TRACKED) != 0
	var index_ok := (tracker.get_hand_joint_flags(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL) & TRACKED) != 0
	var pinky_ok := (tracker.get_hand_joint_flags(
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL) & TRACKED) != 0
	if not (wrist_ok and index_ok and pinky_ok):
		_set_hidden(layer, true)
		return

	var wrist_pos := tracker.get_hand_joint_transform(XRHandTracker.HAND_JOINT_WRIST).origin
	var index_pos := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_INDEX_FINGER_PHALANX_PROXIMAL).origin
	var pinky_pos := tracker.get_hand_joint_transform(
		XRHandTracker.HAND_JOINT_PINKY_FINGER_PHALANX_PROXIMAL).origin
	var to_index := index_pos - wrist_pos
	var to_pinky := pinky_pos - wrist_pos
	if to_index.length_squared() < 0.0001 or to_pinky.length_squared() < 0.0001:
		_set_hidden(layer, true)
		return

	# Build the quad plane from wrist-to-knuckle directions. Checking the
	# normalized cross product makes degeneracy independent of hand size.
	var x_axis := to_index.normalized()
	var raw_normal := x_axis.cross(to_pinky.normalized())
	if raw_normal.length_squared() < 0.0004:
		_set_hidden(layer, true)
		return
	raw_normal = raw_normal.normalized()
	var z_axis := raw_normal if raw_normal.dot(camera_position - wrist_pos) >= 0.0 else -raw_normal
	var y_axis := z_axis.cross(x_axis).normalized()
	x_axis = y_axis.cross(z_axis)

	layer.global_transform = Transform3D(Basis(x_axis, y_axis, z_axis), wrist_pos)
	layer.set_quad_size(Vector2(QUAD_SIZE, QUAD_SIZE))
	layer.visible = true

	# Project the real joints into the quad. The V sign intentionally matches
	# the compositor texture orientation established during device testing.
	var center_uv := Vector2(0.5, 0.5)
	var index_uv := Vector2(x_axis.dot(to_index), -y_axis.dot(to_index)) / QUAD_SIZE + center_uv
	var pinky_uv := Vector2(x_axis.dot(to_pinky), -y_axis.dot(to_pinky)) / QUAD_SIZE + center_uv
	var material: ShaderMaterial = triangle.material
	material.set_shader_parameter("point_a", index_uv)
	material.set_shader_parameter("point_b", center_uv)
	material.set_shader_parameter("point_c", pinky_uv)

func _set_hidden(layer: Node3D, hidden: bool) -> void:
	if not layer:
		return
	# Preserve the swapchain by shrinking the world-space quad instead of
	# repeatedly toggling composition-layer visibility.
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
