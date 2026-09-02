class_name EnvironmentManager
extends RefCounted

# Experimental 3D-room path. The streamed screen remains an OpenXR
# composition layer; only this intentionally low-resolution world is sent
# through Godot's projection layer.

const ROOM_RENDER_SCALE := 0.5
const PSX_SCENE := "res://src/assets/environments/psx_cinema.glb"

var main: Node3D
var room_root: Node3D = null
var _saved_screen_transform := Transform3D.IDENTITY
var _saved_screen_size := Vector2.ZERO
var _holding_screen := false
var _room_anchor := Transform3D.IDENTITY
var _saved_subsampled_foveation := false
var _saved_subsampled_foveation_valid := false

func _init(owner: Node3D):
	main = owner

func cycle():
	main.environment_mode = (main.environment_mode + 1) % main.environment_labels.size()
	apply_current()
	main.state_manager.save_state()

func apply_current():
	if not main.is_xr_active:
		return
	var enabled = main.environment_mode > 0
	var interface = XRServer.find_interface("OpenXR")
	if enabled:
		if not _holding_screen:
			_saved_screen_transform = main.primary_screen.global_transform
			_saved_screen_size = main.primary_screen.mesh_size
			_holding_screen = true
			_room_anchor = _current_head_anchor()
			if interface and interface.has_method("get_foveation_with_subsampled_images"):
				_saved_subsampled_foveation = interface.get_foveation_with_subsampled_images()
				_saved_subsampled_foveation_valid = true
		main._hide_all_backgrounds()
		main.get_viewport().transparent_bg = false
		main.world_env.environment.background_mode = Environment.BG_COLOR
		main.world_env.environment.background_color = Color(0.008, 0.008, 0.012, 1)
		if interface:
			interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_OPAQUE
			if interface.has_method("set_submit_projection_layer"):
				interface.set_submit_projection_layer(true)
		if interface and interface.has_method("set_render_target_size_multiplier"):
			interface.set_render_target_size_multiplier(ROOM_RENDER_SCALE)
		# Godot cannot use subsampled foveation with the room projection
		# viewport's rendering features. Disable only that incompatible variant;
		# regular fixed foveation remains available.
		if interface and interface.has_method("set_foveation_with_subsampled_images"):
			interface.set_foveation_with_subsampled_images(false)
		_rebuild_room(main.environment_mode)
		_place_screen_for_room(main.environment_mode)
		main._log("[ENV] %s enabled: projection layer on at %.0f%% linear resolution" % [main.environment_labels[main.environment_mode], ROOM_RENDER_SCALE * 100.0])
	else:
		_destroy_room()
		if OS.get_name() == "Android" and RenderingServer.get_current_rendering_method() == "gl_compatibility" and interface and interface.has_method("set_submit_projection_layer"):
			interface.set_submit_projection_layer(false)
		if interface and interface.has_method("set_render_target_size_multiplier"):
			interface.set_render_target_size_multiplier(main._xr_base_target_multiplier)
		if _saved_subsampled_foveation_valid and interface and interface.has_method("set_foveation_with_subsampled_images"):
			interface.set_foveation_with_subsampled_images(_saved_subsampled_foveation)
		_saved_subsampled_foveation_valid = false
		main.get_viewport().scaling_3d_scale = main._xr_base_render_scale
		if _holding_screen and main.primary_screen:
			main.primary_screen.global_transform = _saved_screen_transform
			main.primary_screen.mesh_size = _saved_screen_size
			main.primary_screen.apply_curvature()
			_holding_screen = false
		main.settings_controller.apply_passthrough(main.passthrough_enabled)
		main._log("[ENV] 3D environment disabled; projectionless rendering restored")
	main._sync_comp_background()
	if main.comp:
		main.comp.update_cylinder_params()
	if main.ui_controller:
		main.ui_controller.update_environment_btn_state()

func _current_head_anchor() -> Transform3D:
	var yaw = main.xr_camera.global_rotation.y
	return Transform3D(Basis(Vector3.UP, yaw), main.xr_camera.global_position)

func process():
	# Loading host state and the startup recenter both happen asynchronously
	# after the room can first be selected. Rooms intentionally own/lock screen
	# placement, so restore the wall mount if either path moved it afterward.
	if main.environment_mode <= 0 or not _holding_screen or not main.primary_screen:
		return
	var desired = _room_screen_values(main.environment_mode)
	var expected_origin = _room_anchor.origin + _room_anchor.basis * Vector3(0, desired.y, desired.z)
	var expected_size = Vector2(desired.x, desired.x * (_saved_screen_size.y / maxf(_saved_screen_size.x, 0.001)))
	if main.primary_screen.global_position.distance_squared_to(expected_origin) > 0.000001 or not main.primary_screen.mesh_size.is_equal_approx(expected_size):
		_place_screen_for_room(main.environment_mode)
		if main.comp:
			main.comp.update_cylinder_params()

func _destroy_room():
	if room_root:
		room_root.queue_free()
		room_root = null

func _rebuild_room(mode: int):
	_destroy_room()
	room_root = Node3D.new()
	room_root.name = "Experimental3DEnvironment"
	main.xr_origin.add_child(room_root)
	room_root.global_transform = _room_anchor
	if mode == 2:
		_create_psx_cinema()
	else:
		_create_minimal_room()

func _create_minimal_room():
	# One BoxMesh, one unlit material, one draw per eye. Cull is disabled so
	# the inward view is visible without duplicating geometry.
	var room = MeshInstance3D.new()
	room.name = "MinimalRoom"
	var box = BoxMesh.new()
	box.size = Vector3(9.0, 4.4, 9.5)
	room.mesh = box
	room.position = Vector3(0, 0.8, -0.75)
	room.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(0.055, 0.058, 0.068, 1)
	material.roughness = 1.0
	room.material_override = material
	room_root.add_child(room)

func _create_psx_cinema():
	var packed = load(PSX_SCENE) as PackedScene
	if not packed:
		main._log("[ENV] PSX Cinema asset failed to load; using Minimal Room")
		_create_minimal_room()
		return
	var cinema = packed.instantiate()
	cinema.name = "PSXCinema"
	# Same model-space anchor and shipped 0.8 scale as Moonlight Android XR:
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

func _place_screen_for_room(mode: int):
	if not main.primary_screen:
		return
	var values = _room_screen_values(mode)
	var width = values.x
	var mount_y = values.y
	var wall_z = values.z
	var aspect = _saved_screen_size.y / maxf(_saved_screen_size.x, 0.001)
	main.primary_screen.mesh_size = Vector2(width, width * aspect)
	main.primary_screen.global_transform = Transform3D(
		_room_anchor.basis,
		_room_anchor.origin + _room_anchor.basis * Vector3(0, mount_y, wall_z)
	)
	main.primary_screen.apply_curvature()

func _room_screen_values(mode: int) -> Vector3:
	if mode == 2:
		return Vector3(14.4, 1.854, -12.28)
	return Vector3(4.5, 0.6, -5.4)
