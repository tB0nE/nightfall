class_name EnvironmentManager
extends RefCounted

# 3D rooms around the screen, chosen as a Background (passthrough off). The
# streamed screen stays an OpenXR composition layer at full sharpness; only
# the room goes through Godot's projection layer, at half resolution, so the
# GPU stays free for the video and the depth model. The room owns the screen's
# placement while it shows, and gives the user's placement back afterwards.
# Ported from the 3d-environments experiment (6358933).

const ROOM_RENDER_SCALE := 0.5
const CINEMA := &"cinema"
const CINEMA_SCENE := "res://src/assets/environments/psx_cinema.glb"

var main: Node3D
var room: StringName = &""
var room_root: Node3D = null
var _saved_screen_transform := Transform3D.IDENTITY
var _saved_screen_size := Vector2.ZERO
var _holding_screen := false
var _room_anchor := Transform3D.IDENTITY
var _saved_subsampled_foveation := false
var _saved_subsampled_foveation_valid := false

func _init(owner: Node3D):
	main = owner

## The room a Background index selects: rooms follow Black and the particle
## backgrounds.
static func room_for_background(bg_mode: int, particle_backgrounds: int) -> StringName:
	return CINEMA if bg_mode == particle_backgrounds + 1 else &""

## True while a room has moved the screen onto its wall; that placement must
## not be saved as the user's own.
func is_holding_screen() -> bool:
	return _holding_screen

## Shows `next` (&"" for none). The caller decides backgrounds and passthrough.
func apply(next: StringName) -> void:
	if not main.is_xr_active or (next == room and (next == &"") == (room_root == null)):
		return
	room = next
	if next == &"":
		_disable()
	else:
		_enable()
	if main.comp:
		main.comp.update_cylinder_params()

func _enable() -> void:
	var interface = XRServer.find_interface("OpenXR")
	if not _holding_screen:
		_saved_screen_transform = main.primary_screen.global_transform
		_saved_screen_size = main.primary_screen.mesh_size
		_holding_screen = true
		_room_anchor = _current_head_anchor()
		if interface and interface.has_method("get_foveation_with_subsampled_images"):
			_saved_subsampled_foveation = interface.get_foveation_with_subsampled_images()
			_saved_subsampled_foveation_valid = true
	main.get_viewport().transparent_bg = false
	main.world_env.environment.background_mode = Environment.BG_COLOR
	main.world_env.environment.background_color = Color(0.008, 0.008, 0.012, 1)
	if interface:
		interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
		if interface.has_method("set_submit_projection_layer"):
			interface.set_submit_projection_layer(true)
		if interface.has_method("set_render_target_size_multiplier"):
			interface.set_render_target_size_multiplier(ROOM_RENDER_SCALE)
		# Godot can't use subsampled foveation with the room's projection
		# viewport; regular fixed foveation stays available.
		if interface.has_method("set_foveation_with_subsampled_images"):
			interface.set_foveation_with_subsampled_images(false)
	_rebuild_room()
	_place_screen()
	main._log("[ENV] %s on: projection layer at %.0f%% resolution" % [room, ROOM_RENDER_SCALE * 100.0])

func _disable() -> void:
	_destroy_room()
	var interface = XRServer.find_interface("OpenXR")
	if interface:
		if OS.get_name() == "Android" and RenderingServer.get_current_rendering_method() == "gl_compatibility" \
				and interface.has_method("set_submit_projection_layer"):
			interface.set_submit_projection_layer(false)
		if interface.has_method("set_render_target_size_multiplier"):
			interface.set_render_target_size_multiplier(main._xr_base_target_multiplier)
		if _saved_subsampled_foveation_valid and interface.has_method("set_foveation_with_subsampled_images"):
			interface.set_foveation_with_subsampled_images(_saved_subsampled_foveation)
	_saved_subsampled_foveation_valid = false
	main.get_viewport().scaling_3d_scale = main._xr_base_render_scale
	if _holding_screen and main.primary_screen:
		main.primary_screen.global_transform = _saved_screen_transform
		main.primary_screen.mesh_size = _saved_screen_size
		main.primary_screen.apply_curvature()
	_holding_screen = false
	main._log("[ENV] Room off; projectionless rendering restored")

func _current_head_anchor() -> Transform3D:
	var yaw = main.xr_camera.global_rotation.y
	return Transform3D(Basis(Vector3.UP, yaw), main.xr_camera.global_position)

func process():
	# Loading host state and the startup recenter both happen asynchronously
	# after the room can first be selected; put the screen back on the wall
	# if either moved it.
	if room == &"" or not _holding_screen or not main.primary_screen:
		return
	var desired = _screen_values()
	var expected_origin = _room_anchor.origin + _room_anchor.basis * Vector3(0, desired.y, desired.z)
	var expected_size = Vector2(desired.x, desired.x * (_saved_screen_size.y / maxf(_saved_screen_size.x, 0.001)))
	if main.primary_screen.global_position.distance_squared_to(expected_origin) > 0.000001 or not main.primary_screen.mesh_size.is_equal_approx(expected_size):
		_place_screen()
		if main.comp:
			main.comp.update_cylinder_params()

func _destroy_room():
	if room_root:
		room_root.queue_free()
		room_root = null

func _rebuild_room():
	_destroy_room()
	room_root = Node3D.new()
	room_root.name = "Environment3D"
	main.xr_origin.add_child(room_root)
	room_root.global_transform = _room_anchor
	if room == CINEMA:
		_create_cinema()
	else:
		_create_minimal_room()

# The fallback: one BoxMesh, one unlit material, one draw per eye. Cull is
# disabled so the inward view is visible without duplicating geometry.
func _create_minimal_room():
	var box_room = MeshInstance3D.new()
	box_room.name = "MinimalRoom"
	var box = BoxMesh.new()
	box.size = Vector3(9.0, 4.4, 9.5)
	box_room.mesh = box
	box_room.position = Vector3(0, 0.8, -0.75)
	box_room.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.055, 0.058, 0.068, 1)
	box_room.material_override = material
	room_root.add_child(box_room)

func _create_cinema():
	var packed = load(CINEMA_SCENE) as PackedScene
	if not packed:
		main._log("[ENV] Cinema asset failed to load; using the minimal room")
		_create_minimal_room()
		return
	var cinema = packed.instantiate()
	cinema.name = "Cinema"
	# Same model-space anchor and 0.8 scale as Moonlight Android XR:
	# output = (model - [0, -0.9875, -12]) * 0.8.
	cinema.scale = Vector3.ONE * 0.8
	cinema.position = Vector3(0, 0.79, 9.6)
	room_root.add_child(cinema)
	_make_room_unlit(cinema)

func _make_room_unlit(node: Node):
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mesh_instance.mesh:
			for surface in range(mesh_instance.mesh.get_surface_count()):
				var source = mesh_instance.get_active_material(surface) as BaseMaterial3D
				if source:
					var material = source.duplicate() as BaseMaterial3D
					material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
					material.cull_mode = BaseMaterial3D.CULL_DISABLED
					mesh_instance.set_surface_override_material(surface, material)
	for child in node.get_children():
		_make_room_unlit(child)

func _place_screen():
	if not main.primary_screen:
		return
	var values = _screen_values()
	var aspect = _saved_screen_size.y / maxf(_saved_screen_size.x, 0.001)
	main.primary_screen.mesh_size = Vector2(values.x, values.x * aspect)
	main.primary_screen.global_transform = Transform3D(
		_room_anchor.basis,
		_room_anchor.origin + _room_anchor.basis * Vector3(0, values.y, values.z)
	)
	main.primary_screen.apply_curvature()

# Screen width, mount height and wall distance for the current room.
func _screen_values() -> Vector3:
	if room == CINEMA:
		return Vector3(14.4, 1.854, -12.28)
	return Vector3(4.5, 0.6, -5.4)
