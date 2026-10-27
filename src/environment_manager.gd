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
# The user's own room: a .glb picked in Settings > Import Room. It's only a
# backdrop: it can't know where a screen belongs, so the screen stays where
# the user put it and the room stands on the floor around them.
const CUSTOM := &"custom"
const CUSTOM_PATH := "user://rooms/custom.glb"
# Rooms beyond this are refused; the room competes with depth for the GPU.
const CUSTOM_MAX_TRIANGLES := 300000

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
	if bg_mode == particle_backgrounds + 1:
		return CINEMA
	if bg_mode == particle_backgrounds + 2:
		return CUSTOM
	return &""

static func has_custom_room() -> bool:
	return FileAccess.file_exists(CUSTOM_PATH)

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
	if not _saved_subsampled_foveation_valid and interface and interface.has_method("get_foveation_with_subsampled_images"):
		_saved_subsampled_foveation = interface.get_foveation_with_subsampled_images()
		_saved_subsampled_foveation_valid = true
	if room == CINEMA and not _holding_screen:
		_saved_screen_transform = main.primary_screen.global_transform
		_saved_screen_size = main.primary_screen.mesh_size
		_holding_screen = true
		_room_anchor = _current_head_anchor()
	elif room != CINEMA:
		_release_screen()
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
	if room != CINEMA:
		_room_anchor = _floor_anchor()
	_rebuild_room()
	if room == CINEMA:
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
	_release_screen()
	main._log("[ENV] Room off; projectionless rendering restored")

## The centre button: turns the room to where the user is looking, and for
## the cinema puts the screen back on its wall there.
func recenter() -> void:
	if room == &"" or room_root == null:
		return
	_room_anchor = _current_head_anchor() if room == CINEMA else _floor_anchor()
	room_root.global_transform = _room_anchor
	if _holding_screen:
		_place_screen()
	if main.comp:
		main.comp.update_cylinder_params()

# Gives the user's own screen placement back after the cinema held it.
func _release_screen() -> void:
	if _holding_screen and main.primary_screen:
		main.primary_screen.global_transform = _saved_screen_transform
		main.primary_screen.mesh_size = _saved_screen_size
		main.primary_screen.apply_curvature()
	_holding_screen = false

# Facing the way the user looks, on the floor beneath them.
func _floor_anchor() -> Transform3D:
	var head := _current_head_anchor()
	return Transform3D(head.basis, Vector3(head.origin.x, main.xr_origin.global_position.y, head.origin.z))

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
	elif room == CUSTOM:
		_create_custom_room()
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

func _create_custom_room():
	var scene := load_custom_room(CUSTOM_PATH)
	if scene.has("error"):
		main._log("[ENV] Your room not shown: %s" % scene.error)
		if main.ui_controller:
			main.ui_controller.set_status("Your room: %s" % scene.error)
		return
	var custom: Node3D = scene.node
	custom.name = "YourRoom"
	room_root.add_child(custom)
	_make_room_unlit(custom)
	# Stand it on the floor, centred on the user.
	var bounds := scene.bounds as AABB
	custom.position = Vector3(-bounds.get_center().x, -bounds.position.y, -bounds.get_center().z)

## Loads a .glb into {node, bounds, triangles}, or {error}.
static func load_custom_room(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"error": "no room imported yet (Settings > Import Room)"}
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_file(path, state) != OK:
		return {"error": "the .glb couldn't be read"}
	var node = document.generate_scene(state)
	if not node is Node3D:
		if node:
			node.free()
		return {"error": "the .glb has no 3D scene"}
	var counted := _measure(node, Transform3D.IDENTITY)
	if counted.triangles > CUSTOM_MAX_TRIANGLES:
		node.free()
		return {"error": "too detailed (%d triangles; the limit is %d)" % [counted.triangles, CUSTOM_MAX_TRIANGLES]}
	if counted.bounds == null:
		node.free()
		return {"error": "the .glb has no meshes"}
	return {"node": node, "bounds": counted.bounds, "triangles": counted.triangles}

# Triangle count and bounds (in the root's space) of every mesh under `node`.
static func _measure(node: Node, parent: Transform3D) -> Dictionary:
	var result := {"triangles": 0, "bounds": null}
	var transform: Transform3D = parent * node.transform if node is Node3D else parent
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var indices = arrays[Mesh.ARRAY_INDEX]
			var vertices = arrays[Mesh.ARRAY_VERTEX]
			result.triangles += (indices.size() if indices else (vertices.size() if vertices else 0)) / 3
		result.bounds = transform * mesh.get_aabb()
	for child in node.get_children():
		var inner := _measure(child, transform)
		result.triangles += inner.triangles
		if inner.bounds != null:
			result.bounds = inner.bounds if result.bounds == null else (result.bounds as AABB).merge(inner.bounds)
	return result

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
