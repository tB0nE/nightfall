# Multiple Monitors — Nightfall Client

> Branch: `multiple_monitors` (off `main` @ `f00c72d`)
> Scope: **client only.** Server-side compositing + manifest is a follow-up plan, not this branch.
> Audience note: this document is written for step-by-step mechanical execution. Every edit gives an exact
> "find this text / replace with this text" pair against the file as it exists **today** (before any commit
> in this plan runs), or full literal content for a new file. Follow commits in order — later commits assume
> earlier ones already landed. After each commit, run the "Verify" command(s) before moving on. If a "find"
> string does not match exactly (whitespace, tabs vs spaces), stop and re-read the file — do not guess.

## Context

Nightfall renders exactly one streamed screen in VR. The goal is to display several host monitors as
**independent, individually movable VR screens**, driven by a single decoded video frame that contains all
of them tiled together.

The eventual full design has the host (Sunshine/Apollo/Polaris) composite N monitors into one frame and send
a JSON manifest describing each monitor's rectangle. That requires patching three separate server codebases.
**This branch does the client only**, because the client half is independently useful: a wide virtual
display (Apollo+SudoVDA on Windows, `xrandr`/dummy driver on Linux) already produces one wide frame today,
and splitting it into N screens client-side is the entire user-facing win.

Three facts shape the plan:

1. **The tiling primitive already exists.** SBS Crop/Stretch in `src/shaders/stereo_screen.gdshader` and
   `src/shaders/yuv_display.gdshader` is literally `uv * scale + offset`. Generalising it to a `uv_region`
   uniform makes the existing SBS modes special cases.
2. **One decoder already feeds many surfaces.** `TextureUploader` (C++) owns one `ShaderMaterial` + shared
   `Texture2DRD` YUV planes; `CompositionLayerManager.bind_comp_yuv_textures()` already fans them out to
   three materials for stereo. N screens need no extra decode.
3. **The cost is coupling, not tiling.** `main.screen_mesh` (`main.gd:3`) is a hardcoded scene node
   referenced ~112 times across 11 files, with ~20 per-screen globals on `main.gd`. So Phase A is a
   behaviour-preserving refactor that lands *before* any multi-screen behaviour.

Non-goals for this branch: server patches, a VR rect editor, per-tile AI-3D, mid-session layout
renegotiation.

**All line numbers below refer to file state at the start of this branch** (the versions quoted in this
document). Re-verify with the quoted "find" string, not the line number, since earlier commits shift lines
in files touched more than once.

---

## Phase A — Extract `VRScreen` (behaviour-preserving, N=1)

**Strategy for a mechanical executor:** `src/vr_screen.gd` is written **once, in full**, in commit A1,
including every method it will ever need (even ones not wired up until later commits). Every commit after
A1 only *moves callers to point at it* and *deletes the now-duplicated old code* elsewhere — it never edits
`vr_screen.gd` again in Phase A. This avoids ever needing to re-locate an insertion point inside a file you
just created.

### A1 — Create `VRScreen` and attach it to the existing screen node

**New file: `src/vr_screen.gd`** — full content:

```gdscript
class_name VRScreen
extends MeshInstance3D

## One VR-space screen. In Phase A there is exactly one instance (the
## original main.tscn screen node); main.screen_mesh is an alias for it,
## and main.screens == [main.primary_screen] == [this].
##
## This script owns everything that today lives as a "one screen" global on
## main.gd: mesh size, curvature, corner handles, bezel, and (once A5 lands)
## this screen's own composition-layer nodes. Geometry/collision logic here
## is copied verbatim from src/screen_manager.gd with `main.X` -> `self.X`;
## behaviour at N=1 must be identical to before the refactor.

var main: Node3D
var monitor_id: StringName = &"m0"

# --- geometry state (was main._mesh_size / main.curvature / main.bezel_mesh / main.corner_handles) ---
var mesh_size: Vector2 = Vector2(2.24, 1.26)
var curvature: int = 2
var bezel_mesh: MeshInstance3D = null
var corner_handles: Array = []

# --- uv region into the decoded frame (Phase B). Identity = whole frame. ---
var uv_region: Vector4 = Vector4(0.0, 0.0, 1.0, 1.0)

# --- comp-layer state (was main.comp_cylinder / main._comp_cyl_* / main.comp_viewport / etc, moved in A5) ---
var comp_cylinder: Node3D = null
var comp_cylinder_left: Node3D = null
var comp_cylinder_right: Node3D = null
var comp_viewport: SubViewport = null
var comp_viewport_left: SubViewport = null
var comp_viewport_right: SubViewport = null
var comp_yuv_rect: ColorRect = null
var comp_yuv_rect_left: ColorRect = null
var comp_yuv_rect_right: ColorRect = null
var comp_bezel_rect: ColorRect = null
var comp_bezel_rect_left: ColorRect = null
var comp_bezel_rect_right: ColorRect = null
var comp_shader_mat: ShaderMaterial = null
var comp_shader_mat_left: ShaderMaterial = null
var comp_shader_mat_right: ShaderMaterial = null
var comp_stream_cursor: TextureRect = null
var comp_stream_cursor_circle: ColorRect = null
var comp_stream_cursor_left: TextureRect = null
var comp_stream_cursor_circle_left: ColorRect = null
var comp_stream_cursor_right: TextureRect = null
var comp_stream_cursor_circle_right: ColorRect = null
var comp_layer: Node3D = null
var comp_base_size: Vector2i = Vector2i(1920, 1080)
var _original_mat: Material = null

var _comp_cyl_center := Vector3.ZERO
var _comp_cyl_radius := 0.0
var _comp_cyl_central_angle := 0.0

@onready var grab_bar: MeshInstance3D = %ScreenGrabBar

func setup(p_main: Node3D, p_monitor_id: StringName = &"m0") -> void:
	main = p_main
	monitor_id = p_monitor_id

# ============================================================
# Geometry (moved from ScreenManager in A4; identical logic, `main.X` -> `self.X`)
# ============================================================

func get_cylinder_radius() -> float:
	if main.comp.in_use:
		var cam_to_screen = global_position - main.xr_camera.global_position
		var view_dist = cam_to_screen.length()
		if view_dist < 0.5:
			view_dist = 3.0
		if curvature == 1:
			return view_dist * 3.0
		elif curvature == 2:
			return view_dist * 2.0
		else:
			return view_dist * 100.0
	else:
		return 1000.0 if curvature == 0 else (10.0 if curvature == 1 else 4.0)

func create_corner_handles():
	var offsets = [
		Vector2(-0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(-0.5, -0.5),
		Vector2(0.5, -0.5),
	]
	var corner_ids = ["top-left", "top-right", "bottom-left", "bottom-right"]
	var ms = mesh_size
	var corner_size = ms.x * 0.027
	var col_size = ms.x * 0.067
	for i in range(4):
		var handle = MeshInstance3D.new()
		handle.name = "Corner%d" % i
		handle.set_meta(&"nf_role", &"corner")
		handle.set_meta(&"nf_corner_idx", i)
		var mat = StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1, 1, 1, 0)
		mat.albedo_texture = VRScreen._make_corner_texture(corner_ids[i])
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.render_priority = 127
		var corner_quad = QuadMesh.new()
		corner_quad.size = Vector2(corner_size, corner_size)
		corner_quad.orientation = PlaneMesh.FACE_Z
		handle.mesh = corner_quad
		handle.material_override = mat
		var area = Area3D.new()
		area.collision_layer = 2
		var shape = CollisionShape3D.new()
		var col = BoxShape3D.new()
		col.size = Vector3(col_size, col_size, 0.1)
		shape.shape = col
		shape.position = Vector3(offsets[i].x * col_size, offsets[i].y * col_size, 0)
		area.add_child(shape)
		handle.add_child(area)
		handle.position = Vector3(offsets[i].x * (ms.x + corner_size), offsets[i].y * (ms.y + corner_size), 0)
		add_child(handle)
		corner_handles.append(handle)

func update_corner_positions():
	var ms = mesh_size
	var radius = get_cylinder_radius()
	var half_angle = ms.x / radius * 0.5
	var edge_x = sin(half_angle) * radius
	var edge_z = -(cos(half_angle) * radius - radius)
	var offsets = [
		Vector2(-0.5, 0.5),
		Vector2(0.5, 0.5),
		Vector2(-0.5, -0.5),
		Vector2(0.5, -0.5),
	]
	var corner_size = ms.x * 0.027
	var col_size = ms.x * 0.067
	var grab_bar_off = ms.y * 0.119
	for i in range(4):
		var handle = corner_handles[i]
		if handle.mesh is QuadMesh:
			handle.mesh.size = Vector2(corner_size, corner_size)
		for child in handle.get_children():
			if child is Area3D:
				for c in child.get_children():
					if c is CollisionShape3D and c.shape is BoxShape3D:
						c.shape.size = Vector3(col_size, col_size, 0.1)
						c.position = Vector3(offsets[i].x * col_size, offsets[i].y * col_size, 0)
		var cy = offsets[i].y * (ms.y + corner_size)
		var a = half_angle if offsets[i].x > 0 else -half_angle
		var cx = edge_x if offsets[i].x > 0 else -edge_x
		if offsets[i].x > 0:
			cx += corner_size * 0.5
		else:
			cx -= corner_size * 0.5
		handle.position = Vector3(cx, cy, edge_z)
		handle.rotation.y = -a
	grab_bar.position.y = -ms.y / 2.0 - grab_bar_off
	if grab_bar.mesh is CylinderMesh:
		var grab_r = ms.x * 0.0045
		var grab_h = ms.x * 0.134
		grab_bar.mesh.top_radius = grab_r
		grab_bar.mesh.bottom_radius = grab_r
		grab_bar.mesh.height = grab_h
	var grab_area = grab_bar.get_node_or_null("Area3D")
	if grab_area:
		var grab_shape = grab_area.get_node_or_null("CollisionShape3D")
		if grab_shape and grab_shape.shape is BoxShape3D:
			grab_shape.shape.size = Vector3(ms.x * 0.134, ms.y * 0.079, 0.1)

func create_bezel():
	bezel_mesh = MeshInstance3D.new()
	bezel_mesh.name = "Bezel"
	var bezel_quad = QuadMesh.new()
	bezel_mesh.mesh = bezel_quad
	var bezel_mat = StandardMaterial3D.new()
	bezel_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bezel_mat.albedo_color = Color(0, 0, 0, 1)
	bezel_mesh.material_override = bezel_mat
	bezel_mesh.position = Vector3(0, 0, -0.005)
	add_child(bezel_mesh)
	update_bezel_size()

func update_bezel_size():
	if not bezel_mesh:
		return
	var ms = mesh_size
	var bezel_pad = 0.04
	var bezel_size = ms + Vector2(bezel_pad, bezel_pad)
	if curvature == 0:
		var bezel_quad = QuadMesh.new()
		bezel_quad.size = bezel_size
		bezel_mesh.mesh = bezel_quad
		bezel_mesh.position = Vector3(0, 0, -0.005)
	else:
		var radius = get_cylinder_radius()
		var subdivide = 32
		var v_subdivide = 16
		var angle = bezel_size.x / radius
		var verts = PackedVector3Array()
		var uvs = PackedVector2Array()
		var indices = PackedInt32Array()
		for j in range(subdivide + 1):
			for i in range(v_subdivide + 1):
				var t = float(j) / subdivide
				var u = float(i) / v_subdivide
				var a = -angle * 0.5 + angle * t
				var x = sin(a) * radius
				var z = -(cos(a) * radius - radius) - 0.005
				var y = (u - 0.5) * bezel_size.y
				verts.append(Vector3(x, y, z))
				uvs.append(Vector2(t, 1.0 - u))
		var cols = v_subdivide + 1
		for j in range(subdivide):
			for i in range(v_subdivide):
				var idx = j * cols + i
				indices.append(idx)
				indices.append(idx + 1)
				indices.append(idx + cols)
				indices.append(idx + 1)
				indices.append(idx + cols + 1)
				indices.append(idx + cols)
		var arr = []
		arr.resize(Mesh.ARRAY_MAX)
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_TEX_UV] = uvs
		arr[Mesh.ARRAY_INDEX] = indices
		var arr_mesh = ArrayMesh.new()
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		bezel_mesh.mesh = arr_mesh
		bezel_mesh.position = Vector3.ZERO

func apply_curvature():
	var ms = mesh_size
	if curvature == 0:
		var quad = QuadMesh.new()
		quad.size = ms
		mesh = quad
		update_shader_for_mesh()
		set_collision_flat()
		return
	var subdivide = 32
	var v_subdivide = 16
	var radius = get_cylinder_radius()
	var angle = ms.x / radius
	var verts = PackedVector3Array()
	var uvs = PackedVector2Array()
	var indices = PackedInt32Array()
	for j in range(subdivide + 1):
		for i in range(v_subdivide + 1):
			var t = float(j) / subdivide
			var u = float(i) / v_subdivide
			var a = -angle * 0.5 + angle * t
			var x = sin(a) * radius
			var z = -(cos(a) * radius - radius)
			var y = (u - 0.5) * ms.y
			verts.append(Vector3(x, y, z))
			uvs.append(Vector2(t, 1.0 - u))
	var cols = v_subdivide + 1
	for j in range(subdivide):
		for i in range(v_subdivide):
			var idx = j * cols + i
			indices.append(idx)
			indices.append(idx + 1)
			indices.append(idx + cols)
			indices.append(idx + 1)
			indices.append(idx + cols + 1)
			indices.append(idx + cols)
	var arr = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = indices
	var arr_mesh = ArrayMesh.new()
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh = arr_mesh
	update_shader_for_mesh()
	set_collision_curved(verts, indices)

func update_shader_for_mesh():
	set_collision_flat()
	update_corner_positions()
	if bezel_mesh:
		update_bezel_size()

func set_collision_flat():
	var col_shape = get_node_or_null("Area3D/CollisionShape3D")
	if not col_shape:
		return
	var box = BoxShape3D.new()
	box.size = Vector3(mesh_size.x, mesh_size.y, 0.01)
	col_shape.shape = box

func set_collision_curved(verts: PackedVector3Array, indices: PackedInt32Array):
	var col_shape = get_node_or_null("Area3D/CollisionShape3D")
	if not col_shape:
		return
	var faces = PackedVector3Array()
	for i in range(0, indices.size(), 3):
		faces.append(verts[indices[i]])
		faces.append(verts[indices[i + 1]])
		faces.append(verts[indices[i + 2]])
	var concave = ConcavePolygonShape3D.new()
	concave.set_faces(faces)
	col_shape.shape = concave

func resize_to_aspect(w: int, h: int):
	var aspect = float(w) / float(h)
	var new_w = mesh_size.x
	var new_h = new_w / aspect
	if new_h < 0.4:
		new_h = 0.4
		new_w = new_h * aspect
	mesh_size = Vector2(new_w, new_h)
	if curvature == 0:
		mesh.size = mesh_size
		set_collision_flat()
	else:
		apply_curvature()
	update_corner_positions()
	if bezel_mesh:
		update_bezel_size()

static func _make_corner_texture(corner: String, size: int = 128, thickness: int = 20, opacity: float = 0.08) -> ImageTexture:
	var img = Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var color = Color(1, 1, 1, opacity)
	var s = size
	var t = thickness
	var pad = 16
	match corner:
		"top-left":
			img.fill_rect(Rect2i(pad, pad, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(pad, pad + t, t, s - 2 * pad - t), color)
		"top-right":
			img.fill_rect(Rect2i(pad, pad, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(s - pad - t, pad + t, t, s - 2 * pad - t), color)
		"bottom-left":
			img.fill_rect(Rect2i(pad, s - pad - t, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(pad, pad, t, s - 2 * pad - t), color)
		"bottom-right":
			img.fill_rect(Rect2i(pad, s - pad - t, s - 2 * pad, t), color)
			img.fill_rect(Rect2i(s - pad - t, pad, t, s - 2 * pad - t), color)
	return ImageTexture.create_from_image(img)

# ============================================================
# Hit testing (moved from main.gd in D1; identical logic, `main.X` -> `self.X` / `main._comp_cyl_*` -> `self._comp_cyl_*`)
# ============================================================

func get_cylinder_normal_at(hit_point: Vector3) -> Vector3:
	if curvature == 0 or not comp_layer:
		return -global_transform.basis.z
	var screen_forward = -global_transform.basis.z
	if _comp_cyl_radius < 0.01:
		return screen_forward
	var cyl_center = global_position - screen_forward * _comp_cyl_radius
	var to_hit = hit_point - cyl_center
	to_hit.y = 0.0
	if to_hit.length() < 0.001:
		return screen_forward
	return to_hit.normalized()

func hit_point_to_uv(hit_point: Vector3) -> Vector2:
	var ms = mesh_size
	var local_pos = to_local(hit_point)
	var uv_x = 0.0
	var uv_y = clampf((ms.y * 0.5 - local_pos.y) / ms.y, 0.0, 1.0)
	if curvature == 0:
		uv_x = clampf((local_pos.x + ms.x * 0.5) / ms.x, 0.0, 1.0)
	elif main.comp and main.comp.in_use and _comp_cyl_radius > 0.01 and _comp_cyl_central_angle > 0.001:
		var cam_pos = main.xr_camera.global_position
		var ray_dir = (hit_point - cam_pos).normalized()
		var screen_right = global_transform.basis.x
		var screen_forward = -global_transform.basis.z
		var oc = cam_pos - _comp_cyl_center
		var oc_right = oc.dot(screen_right)
		var oc_fwd = oc.dot(screen_forward)
		var d_right = ray_dir.dot(screen_right)
		var d_fwd = ray_dir.dot(screen_forward)
		var a = d_right * d_right + d_fwd * d_fwd
		var b = 2.0 * (oc_right * d_right + oc_fwd * d_fwd)
		var c = oc_right * oc_right + oc_fwd * oc_fwd - _comp_cyl_radius * _comp_cyl_radius
		var disc = b * b - 4.0 * a * c
		if disc < 0.0:
			uv_x = 0.5
		else:
			var sqrt_disc = sqrt(disc)
			var t1 = (-b - sqrt_disc) / (2.0 * a)
			var t2 = (-b + sqrt_disc) / (2.0 * a)
			var t = t1 if t1 > 0.001 else t2
			if t > 0.0:
				var hit_world = cam_pos + ray_dir * t
				var hit_local = to_local(hit_world)
				uv_y = clampf((ms.y * 0.5 - hit_local.y) / ms.y, 0.0, 1.0)
				var hit_cyl = hit_world - _comp_cyl_center
				var hit_right = hit_cyl.dot(screen_right)
				var hit_fwd = hit_cyl.dot(screen_forward)
				var hit_angle = atan2(hit_right, hit_fwd)
				uv_x = clampf((hit_angle + _comp_cyl_central_angle * 0.5) / _comp_cyl_central_angle, 0.0, 1.0)
			else:
				uv_x = 0.5
	else:
		var radius = 10.0 if curvature == 1 else 4.0
		var total_angle = ms.x / radius
		var chord = clampf(local_pos.x / radius, -1.0, 1.0)
		uv_x = clampf((asin(chord) + total_angle * 0.5) / total_angle, 0.0, 1.0)
	return Vector2(uv_x, uv_y)
```

Note: `hit_point_to_uv` above intentionally drops the dead `var screen_up = ...` line that exists in the
original `main._hit_point_to_uv()` (`main.gd:320`) — it was never read. Everything else is a verbatim
line-for-line port.

**Steps:**

1. Write `src/vr_screen.gd` with the exact content above.
2. Attach the script to the existing screen node. Open `main.tscn` and find this exact block (currently at
   line 198):
   ```
   [node name="MeshInstance3D" type="MeshInstance3D" parent="." unique_id=1272066368]
   transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.5, -3)
   material_override = SubResource("ShaderMaterial_1")
   mesh = SubResource("QuadMesh_1")
   ```
   Add one `[ext_resource]` line near the top of the file, immediately after the existing
   `[ext_resource type="Script" ... path="res://main.gd" id="1_main"]` line:
   ```
   [ext_resource type="Script" path="res://src/vr_screen.gd" id="3_vr_screen"]
   ```
   Then add a `script = ExtResource("3_vr_screen")` line to the `MeshInstance3D` node block so it reads:
   ```
   [node name="MeshInstance3D" type="MeshInstance3D" parent="." unique_id=1272066368]
   script = ExtResource("3_vr_screen")
   transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1.5, -3)
   material_override = SubResource("ShaderMaterial_1")
   mesh = SubResource("QuadMesh_1")
   ```
3. **Also fix the missing `resource_local_to_scene` on `ShaderMaterial_1` now** (Risk #1 in this plan —
   doing it here costs nothing at N=1 and removes a footgun before C1 needs it). Find:
   ```
   [sub_resource type="ShaderMaterial" id="ShaderMaterial_1"]
   render_priority = 0
   shader = ExtResource("2_shader")
   shader_parameter/stereo_mode = 0
   ```
   Replace with:
   ```
   [sub_resource type="ShaderMaterial" id="ShaderMaterial_1"]
   resource_local_to_scene = true
   render_priority = 0
   shader = ExtResource("2_shader")
   shader_parameter/stereo_mode = 0
   ```
4. In `main.gd`, find (near the other per-screen declarations, currently `main.gd:146-148`):
   ```gdscript
   var corner_handles: Array = []
   var grabbed_corner_idx: int = -1
   var corner_anchor_world: Vector3 = Vector3.ZERO
   ```
   Replace with:
   ```gdscript
   var corner_handles: Array = []
   var grabbed_corner_idx: int = -1
   var corner_anchor_world: Vector3 = Vector3.ZERO
   var screens: Array[VRScreen] = []
   var primary_screen: VRScreen = null
   ```
   (`corner_handles`/`grabbed_corner_idx`/`corner_anchor_world` are left in place for now — A3 removes
   `corner_handles` as a duplicate once `VRScreen.corner_handles` is the live one.)
5. In `main.gd`, function `_init_ui()` (currently `main.gd:737-753`), find:
   ```gdscript
   func _init_ui():
   	virtual_keyboard = VirtualKeyboard.new(self)
   	add_child(virtual_keyboard)
   	virtual_keyboard.build()

   	%ScreenGrabBar.material_override = %ScreenGrabBar.material_override.duplicate()
   	_mesh_size = screen_mesh.mesh.size
   	screen_manager.create_corner_handles()
   	screen_manager.create_bezel()
   	_create_contact_dot()
   ```
   Replace with:
   ```gdscript
   func _init_ui():
   	virtual_keyboard = VirtualKeyboard.new(self)
   	add_child(virtual_keyboard)
   	virtual_keyboard.build()

   	screen_mesh.setup(self, &"m0")
   	screens = [screen_mesh]
   	primary_screen = screen_mesh
   	screen_mesh.grab_bar.material_override = screen_mesh.grab_bar.material_override.duplicate()
   	screen_mesh.mesh_size = screen_mesh.mesh.size
   	_mesh_size = screen_mesh.mesh_size
   	screen_manager.create_corner_handles()
   	screen_manager.create_bezel()
   	_create_contact_dot()
   ```
   (`_mesh_size` is still written here too, in parallel with `screen_mesh.mesh_size` — A3 makes it an alias
   and removes this duplication.)

**Verify:**
```bash
grep -c "class_name VRScreen" src/vr_screen.gd   # expect: 1
grep -n "vr_screen.gd" main.tscn                  # expect: 2 lines (ext_resource + script=)
grep -n "resource_local_to_scene = true" main.tscn | head -1  # expect: a match right above ShaderMaterial_1's other lines
```
Then run the app (desktop/editor is fine for this commit — no behavioural change yet) and confirm the
screen still renders, resizes, and the grab bar still works exactly as before. `screen_mesh` still IS the
node — `VRScreen extends MeshInstance3D` — so every existing `main.screen_mesh.xxx` reference elsewhere in
the codebase keeps compiling untouched at this point.

---

### A2 — Replace all 8 `%ScreenGrabBar` lookups with `screen_mesh.grab_bar`

Scene-unique names resolve against the node's owner scene. Today that still works because everything is one
scene (`main.tscn`); it will break in C1 once the screen subtree becomes its own `vr_screen.tscn`. Fixing it
now, while N=1, makes it trivially verifiable (behaviour must not change) and removes the risk from C1.

**8 exact edits:**

1. `main.gd` — already done in A1 step 5 above (`screen_mesh.grab_bar.material_override = ...`). No action here.

2. `src/screen_manager.gd`, function `update_corner_positions()`, find:
   ```gdscript
   	var grab_bar = main.get_node("%ScreenGrabBar")
   	grab_bar.position.y = -mesh_size.y / 2.0 - grab_bar_off
   ```
   Replace with:
   ```gdscript
   	var grab_bar = main.screen_mesh.grab_bar
   	grab_bar.position.y = -mesh_size.y / 2.0 - grab_bar_off
   ```
   (This whole function is deleted in A4 once `VRScreen.update_corner_positions()` from A1 is the live one —
   this edit only needs to survive until then, so keep it minimal.)

3. `src/composition_layer_manager.gd`, function `restore_screen_material()`, find:
   ```gdscript
   	var screen_bar = main.get_node_or_null("%ScreenGrabBar")
   	if screen_bar:
   		screen_bar.visible = true
   ```
   Replace with:
   ```gdscript
   	var screen_bar = main.screen_mesh.grab_bar
   	screen_bar.visible = true
   ```

4. `src/xr_interaction.gd`, function `handle_pointer_interaction()`, find:
   ```gdscript
   	main.get_node("%ScreenGrabBar").visible = true
   	for ch in main.corner_handles:
   ```
   Replace with:
   ```gdscript
   	main.screen_mesh.grab_bar.visible = true
   	for ch in main.corner_handles:
   ```

5. Same function, find:
   ```gdscript
   	if not main.grabbed_node and main.grabbed_corner_idx < 0:
   		_set_grab_bar_color(main.get_node("%ScreenGrabBar"), Color.WHITE, 0.05)
   ```
   Replace with:
   ```gdscript
   	if not main.grabbed_node and main.grabbed_corner_idx < 0:
   		_set_grab_bar_color(main.screen_mesh.grab_bar, Color.WHITE, 0.05)
   ```

6. Same function, find:
   ```gdscript
   		if parent == main.ui_panel_3d or (main.ui_visible and parent == main.get_node("%ScreenGrabBar")):
   ```
   Replace with:
   ```gdscript
   		if parent == main.ui_panel_3d or (main.ui_visible and parent == main.screen_mesh.grab_bar):
   ```

7. Same function, find:
   ```gdscript
   		if parent == main.get_node("%ScreenGrabBar") and parent != main.grabbed_bar:
   ```
   Replace with:
   ```gdscript
   		if parent == main.screen_mesh.grab_bar and parent != main.grabbed_bar:
   ```

8. Same function, find:
   ```gdscript
   		elif parent == main.get_node("%ScreenGrabBar"):
   ```
   Replace with:
   ```gdscript
   		elif parent == main.screen_mesh.grab_bar:
   ```

**Verify:**
```bash
grep -rn '%ScreenGrabBar' src/ main.gd   # expect: ZERO matches
```
Run the app: grab-bar hover highlight, grab-to-move, and menu/keyboard grab-bar priority must all behave
exactly as before.

---

### A3 — Alias `main.*` per-screen fields to `primary_screen`

**Goal:** stop writing per-screen state onto `main` directly; read/write it through `primary_screen`
instead, via Godot 4 inline property syntax so every existing `main._mesh_size` / `main.curvature` /
`main.corner_handles` call site elsewhere in the codebase keeps compiling unchanged.

> ⚠️ **Guard every getter/setter against `primary_screen == null`.** `_init_ui()` (A1 step 5) sets
> `primary_screen = screen_mesh` partway through `_init_ui()`, and `_mesh_size` is written in that same
> function right after. Any getter called before that assignment must not crash.

1. In `main.gd`, find the existing field declaration (currently `main.gd:119`):
   ```gdscript
   var _mesh_size: Vector2 = Vector2(2.24, 1.26)
   ```
   Replace with:
   ```gdscript
   var _mesh_size: Vector2:
   	get: return primary_screen.mesh_size if primary_screen else Vector2(2.24, 1.26)
   	set(v):
   		if primary_screen: primary_screen.mesh_size = v
   ```

2. Find (currently `main.gd:111`):
   ```gdscript
   var curvature: int = 2
   ```
   Replace with:
   ```gdscript
   var curvature: int:
   	get: return primary_screen.curvature if primary_screen else 2
   	set(v):
   		if primary_screen: primary_screen.curvature = v
   ```

3. Find (currently `main.gd:110`):
   ```gdscript
   var bezel_mesh: MeshInstance3D
   ```
   Replace with:
   ```gdscript
   var bezel_mesh: MeshInstance3D:
   	get: return primary_screen.bezel_mesh if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.bezel_mesh = v
   ```

4. Find (currently `main.gd:146`, and remove the duplicate list — `VRScreen.corner_handles` is now the only
   one):
   ```gdscript
   var corner_handles: Array = []
   var grabbed_corner_idx: int = -1
   var corner_anchor_world: Vector3 = Vector3.ZERO
   var screens: Array[VRScreen] = []
   var primary_screen: VRScreen = null
   ```
   Replace with:
   ```gdscript
   var corner_handles: Array:
   	get: return primary_screen.corner_handles if primary_screen else []
   	set(v):
   		if primary_screen: primary_screen.corner_handles = v
   var grabbed_corner_idx: int = -1
   var grabbed_corner_screen: VRScreen = null
   var corner_anchor_world: Vector3 = Vector3.ZERO
   var screens: Array[VRScreen] = []
   var primary_screen: VRScreen = null
   ```

5. Find the comp-layer field block (currently `main.gd:166-197`):
   ```gdscript
   var comp_cylinder: Node3D = null
   var _comp_cyl_center := Vector3.ZERO
   var _comp_cyl_radius := 0.0
   var _comp_cyl_central_angle := 0.0
   var comp_cursor: Node3D = null
   var comp_ui: Node3D = null
   var comp_kb: Node3D = null
   var comp_cursor_viewport: SubViewport = null
   var left_comp_cursor_layer: Node3D = null
   var left_comp_cursor_viewport: SubViewport = null
   var comp_layer: Node3D = null
   var comp_viewport: SubViewport = null
   var comp_yuv_rect: ColorRect = null
   var comp_bezel_rect: ColorRect = null
   var comp_shader_mat: ShaderMaterial = null
   var comp_cylinder_left: Node3D = null
   var comp_cylinder_right: Node3D = null
   var comp_viewport_left: SubViewport = null
   var comp_viewport_right: SubViewport = null
   var comp_yuv_rect_left: ColorRect = null
   var comp_yuv_rect_right: ColorRect = null
   var comp_bezel_rect_left: ColorRect = null
   var comp_bezel_rect_right: ColorRect = null
   var comp_shader_mat_left: ShaderMaterial = null
   var comp_shader_mat_right: ShaderMaterial = null
   var comp_stream_cursor: TextureRect = null
   var comp_stream_cursor_circle: ColorRect = null
   var comp_stream_cursor_left: TextureRect = null
   var comp_stream_cursor_circle_left: ColorRect = null
   var comp_stream_cursor_right: TextureRect = null
   var comp_stream_cursor_circle_right: ColorRect = null
   var _screen_mesh_original_mat: Material = null
   ```
   Replace with (app-level fields kept plain; per-screen fields become aliases to `primary_screen`):
   ```gdscript
   var comp_cursor: Node3D = null
   var comp_ui: Node3D = null
   var comp_kb: Node3D = null
   var comp_cursor_viewport: SubViewport = null
   var left_comp_cursor_layer: Node3D = null
   var left_comp_cursor_viewport: SubViewport = null

   var comp_cylinder: Node3D:
   	get: return primary_screen.comp_cylinder if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_cylinder = v
   var _comp_cyl_center: Vector3:
   	get: return primary_screen._comp_cyl_center if primary_screen else Vector3.ZERO
   	set(v):
   		if primary_screen: primary_screen._comp_cyl_center = v
   var _comp_cyl_radius: float:
   	get: return primary_screen._comp_cyl_radius if primary_screen else 0.0
   	set(v):
   		if primary_screen: primary_screen._comp_cyl_radius = v
   var _comp_cyl_central_angle: float:
   	get: return primary_screen._comp_cyl_central_angle if primary_screen else 0.0
   	set(v):
   		if primary_screen: primary_screen._comp_cyl_central_angle = v
   var comp_layer: Node3D:
   	get: return primary_screen.comp_layer if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_layer = v
   var comp_viewport: SubViewport:
   	get: return primary_screen.comp_viewport if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_viewport = v
   var comp_yuv_rect: ColorRect:
   	get: return primary_screen.comp_yuv_rect if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_yuv_rect = v
   var comp_bezel_rect: ColorRect:
   	get: return primary_screen.comp_bezel_rect if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_bezel_rect = v
   var comp_shader_mat: ShaderMaterial:
   	get: return primary_screen.comp_shader_mat if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_shader_mat = v
   var comp_cylinder_left: Node3D:
   	get: return primary_screen.comp_cylinder_left if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_cylinder_left = v
   var comp_cylinder_right: Node3D:
   	get: return primary_screen.comp_cylinder_right if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_cylinder_right = v
   var comp_viewport_left: SubViewport:
   	get: return primary_screen.comp_viewport_left if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_viewport_left = v
   var comp_viewport_right: SubViewport:
   	get: return primary_screen.comp_viewport_right if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_viewport_right = v
   var comp_yuv_rect_left: ColorRect:
   	get: return primary_screen.comp_yuv_rect_left if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_yuv_rect_left = v
   var comp_yuv_rect_right: ColorRect:
   	get: return primary_screen.comp_yuv_rect_right if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_yuv_rect_right = v
   var comp_bezel_rect_left: ColorRect:
   	get: return primary_screen.comp_bezel_rect_left if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_bezel_rect_left = v
   var comp_bezel_rect_right: ColorRect:
   	get: return primary_screen.comp_bezel_rect_right if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_bezel_rect_right = v
   var comp_shader_mat_left: ShaderMaterial:
   	get: return primary_screen.comp_shader_mat_left if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_shader_mat_left = v
   var comp_shader_mat_right: ShaderMaterial:
   	get: return primary_screen.comp_shader_mat_right if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_shader_mat_right = v
   var comp_stream_cursor: TextureRect:
   	get: return primary_screen.comp_stream_cursor if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_stream_cursor = v
   var comp_stream_cursor_circle: ColorRect:
   	get: return primary_screen.comp_stream_cursor_circle if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_stream_cursor_circle = v
   var comp_stream_cursor_left: TextureRect:
   	get: return primary_screen.comp_stream_cursor_left if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_stream_cursor_left = v
   var comp_stream_cursor_circle_left: ColorRect:
   	get: return primary_screen.comp_stream_cursor_circle_left if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_stream_cursor_circle_left = v
   var comp_stream_cursor_right: TextureRect:
   	get: return primary_screen.comp_stream_cursor_right if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_stream_cursor_right = v
   var comp_stream_cursor_circle_right: ColorRect:
   	get: return primary_screen.comp_stream_cursor_circle_right if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen.comp_stream_cursor_circle_right = v
   var _screen_mesh_original_mat: Material:
   	get: return primary_screen._original_mat if primary_screen else null
   	set(v):
   		if primary_screen: primary_screen._original_mat = v
   ```

6. Find (currently `main.gd:277`):
   ```gdscript
   var _comp_base_size := Vector2i(1920, 1080)
   ```
   Replace with:
   ```gdscript
   var _comp_base_size: Vector2i:
   	get: return primary_screen.comp_base_size if primary_screen else Vector2i(1920, 1080)
   	set(v):
   		if primary_screen: primary_screen.comp_base_size = v
   ```

7. In `_init_ui()` (edited in A1 step 5), the line `_mesh_size = screen_mesh.mesh_size` is now writing
   through the new setter into `primary_screen.mesh_size` — but `primary_screen` is assigned two lines
   above it in the same function, so ordering is already correct. Simplify: find
   ```gdscript
   	screen_mesh.mesh_size = screen_mesh.mesh.size
   	_mesh_size = screen_mesh.mesh_size
   ```
   Replace with:
   ```gdscript
   	_mesh_size = screen_mesh.mesh.size
   ```
   (Now there's exactly one write, through the alias, and it lands on `primary_screen.mesh_size` i.e.
   `screen_mesh.mesh_size` since they're the same object.)

8. `curvature`, edited via `cycle_curvature()` in `src/screen_manager.gd` — no change needed yet; it already
   reads/writes `main.curvature`, which now transparently routes to `primary_screen.curvature`. (A4 makes
   it fan out to all screens.)

**Verify:**
```bash
godot --headless --check-only . 2>&1 | grep -i error   # expect: no output
```
Run the app: identical visual and interactive behaviour to A2. Specifically test: resize via corner handle,
curvature cycle, bezel toggle, SBS toggle, entering/leaving comp-layer mode (Quest) — every one of these
touches a field that's now an alias.

---

### A4 — Move geometry methods onto `VRScreen`; `ScreenManager` becomes a fan-out coordinator

`VRScreen` already has `get_cylinder_radius`, `create_corner_handles`, `update_corner_positions`,
`create_bezel`, `update_bezel_size`, `apply_curvature`, `update_shader_for_mesh`, `set_collision_flat`,
`set_collision_curved`, `resize_to_aspect`, `_make_corner_texture` (from A1). Now delete the duplicate
bodies from `src/screen_manager.gd` and make every `ScreenManager` method delegate.

**Replace the entire contents of `src/screen_manager.gd`** with:

```gdscript
class_name ScreenManager
extends RefCounted

var main: Node3D

func _init(owner: Node3D):
	main = owner

func create_corner_handles():
	main.primary_screen.create_corner_handles()

func update_corner_positions():
	main.primary_screen.update_corner_positions()

func create_bezel():
	main.primary_screen.create_bezel()

func update_bezel_size():
	for s in main.screens:
		s.update_bezel_size()

func toggle_bezel():
	main.bezel_enabled = not main.bezel_enabled
	if main.bezel_mesh:
		main.bezel_mesh.visible = main.bezel_enabled if not main.comp.in_use else false
	main.ui_controller.update_option_btn(main._ui_bezel_btn, "On" if main.bezel_enabled else "Off")
	main.comp.update_bezel()
	main.state_manager.save_state()

func resize_screen_to_aspect(stream_w: int, stream_h: int):
	main.primary_screen.resize_to_aspect(stream_w, stream_h)
	if main.comp_layer and main.comp_layer is OpenXRCompositionLayerQuad:
		main.comp_layer.set_quad_size(main._mesh_size)

func cycle_curvature():
	main.curvature = (main.curvature + 1) % 3
	for s in main.screens:
		s.curvature = main.curvature
		s.apply_curvature()
	if main.comp.in_use:
		main.comp.switch_to_comp_layer()
	main.ui_controller.update_option_btn(main._ui_curve_btn, main.curvature_labels[main.curvature])
	main.state_manager.save_state()

func apply_curvature():
	for s in main.screens:
		s.apply_curvature()

func _get_cylinder_radius() -> float:
	return main.primary_screen.get_cylinder_radius()
```

Notes on this rewrite:
- `resize_screen_to_aspect` keeps the dead `comp_layer is OpenXRCompositionLayerQuad` branch as-is (Plan
  agent fact #4: `comp_layer` is never actually a Quad — only ever `comp_cylinder` — so this line never
  executes; it's harmless dead code carried forward unchanged, not worth removing in this commit).
- `cycle_curvature()` now fans out to **all** screens (this is the one place behaviour intentionally
  broadens ahead of N>1 — at N=1 it's identical, since `main.screens == [primary_screen]`).
- `_get_cylinder_radius()` is kept only as a compatibility shim for `xr_interaction.gd:775`
  (`main.screen_manager._get_cylinder_radius()`), which is fixed to call `VRScreen` directly in D3. Do not
  remove it before D3 lands.

**Verify:**
```bash
grep -n "func " src/screen_manager.gd   # expect exactly: create_corner_handles, update_corner_positions,
                                          # create_bezel, update_bezel_size, toggle_bezel,
                                          # resize_screen_to_aspect, cycle_curvature, apply_curvature,
                                          # _get_cylinder_radius — 9 functions, none of them containing
                                          # the old mesh-building loops.
```
Run the app: resize-by-corner, curvature cycling, bezel toggle all still behave identically (they now
execute on `VRScreen`, reached through `ScreenManager`'s one-line delegation).

---

### A5 — Move per-screen comp-layer nodes onto `VRScreen`; collapse the triplicated code

This is the largest mechanical commit in Phase A. `src/composition_layer_manager.gd` currently builds
`comp_cylinder`/`comp_viewport`/... directly on `main`, and writes the bezel/cylinder-param/YUV-bind logic
three times (mono / left / right). Because `VRScreen` already declares all the per-screen comp fields (A1),
and `main.*` now aliases to `primary_screen.*` (A3), **`CompositionLayerManager.setup()` can be rewritten to
build directly onto `main.primary_screen` with no behaviour change**, and the three
mono/left/right blocks collapse into one loop over a small per-triplet array.

**Replace the entire contents of `src/composition_layer_manager.gd`** with:

```gdscript
class_name CompositionLayerManager
extends RefCounted

var main
var available: bool = false
var in_use: bool = false

func _init(p_main):
	main = p_main
	available = ClassDB.class_exists("OpenXRCompositionLayerCylinder")

func get_screen_mesh_original_mat() -> Material:
	return main.primary_screen._original_mat

func get_cyl_params() -> Dictionary:
	var s = main.primary_screen
	return {"center": s._comp_cyl_center, "radius": s._comp_cyl_radius, "central_angle": s._comp_cyl_central_angle}

func get_shader_mats(s: VRScreen = null) -> Array:
	if s == null:
		s = main.primary_screen
	return [s.comp_shader_mat, s.comp_shader_mat_left, s.comp_shader_mat_right]

func get_stream_cursor_pair(index: int, s: VRScreen = null) -> Array:
	if s == null:
		s = main.primary_screen
	match index:
		0: return [s.comp_stream_cursor, s.comp_stream_cursor_circle]
		1: return [s.comp_stream_cursor_left, s.comp_stream_cursor_circle_left]
		_: return [s.comp_stream_cursor_right, s.comp_stream_cursor_circle_right]

## Builds every comp-layer node this screen owns. Called once per screen
## (today: once, for main.primary_screen, from setup()).
func setup_screen(s: VRScreen):
	if not available:
		return

	s.comp_cylinder = OpenXRCompositionLayerCylinder.new()
	s.comp_cylinder.name = "CompCylinderLayer_%s" % s.monitor_id
	s.comp_cylinder.set_sort_order(1)
	s.comp_cylinder.set_enable_hole_punch(false)
	s.comp_cylinder.set_alpha_blend(false)
	s.comp_cylinder.visible = false
	main.xr_origin.add_child(s.comp_cylinder)
	if s.comp_cylinder.is_natively_supported():
		main._log("[COMP] Cylinder layer natively supported (%s)" % s.monitor_id)
	else:
		main._log("[COMP] Cylinder layer NOT natively supported (%s)" % s.monitor_id)

	s.comp_viewport = SubViewport.new()
	s.comp_viewport.name = "CompViewport_%s" % s.monitor_id
	s.comp_viewport.disable_3d = true
	s.comp_viewport.transparent_bg = true
	s.comp_viewport.size = Vector2i(1920, 1080)
	s.comp_base_size = Vector2i(1920, 1080)
	s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(s.comp_viewport)

	s.comp_bezel_rect = _make_bezel_rect()
	s.comp_viewport.add_child(s.comp_bezel_rect)

	s.comp_yuv_rect = _make_yuv_rect()
	s.comp_shader_mat = ShaderMaterial.new()
	s.comp_shader_mat.shader = load("res://src/shaders/yuv_display.gdshader")
	s.comp_yuv_rect.material = s.comp_shader_mat
	s.comp_bezel_rect.add_child(s.comp_yuv_rect)

	s.comp_stream_cursor = _make_cursor_texture_rect()
	s.comp_bezel_rect.add_child(s.comp_stream_cursor)
	s.comp_stream_cursor_circle = _make_cursor_circle_rect()
	s.comp_bezel_rect.add_child(s.comp_stream_cursor_circle)

	s.comp_cylinder_left = OpenXRCompositionLayerCylinder.new()
	s.comp_cylinder_left.name = "CompCylinderLeft_%s" % s.monitor_id
	s.comp_cylinder_left.set_sort_order(1)
	s.comp_cylinder_left.set_enable_hole_punch(false)
	s.comp_cylinder_left.set_alpha_blend(false)
	s.comp_cylinder_left.set_eye_visibility(OpenXRCompositionLayer.EYE_VISIBILITY_LEFT)
	s.comp_cylinder_left.visible = false
	main.xr_origin.add_child(s.comp_cylinder_left)

	s.comp_cylinder_right = OpenXRCompositionLayerCylinder.new()
	s.comp_cylinder_right.name = "CompCylinderRight_%s" % s.monitor_id
	s.comp_cylinder_right.set_sort_order(1)
	s.comp_cylinder_right.set_enable_hole_punch(false)
	s.comp_cylinder_right.set_alpha_blend(false)
	s.comp_cylinder_right.set_eye_visibility(OpenXRCompositionLayer.EYE_VISIBILITY_RIGHT)
	s.comp_cylinder_right.visible = false
	main.xr_origin.add_child(s.comp_cylinder_right)

	s.comp_viewport_left = SubViewport.new()
	s.comp_viewport_left.name = "CompViewportLeft_%s" % s.monitor_id
	s.comp_viewport_left.disable_3d = true
	s.comp_viewport_left.transparent_bg = true
	s.comp_viewport_left.size = Vector2i(1920, 1080)
	s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(s.comp_viewport_left)

	s.comp_bezel_rect_left = _make_bezel_rect()
	s.comp_viewport_left.add_child(s.comp_bezel_rect_left)
	s.comp_yuv_rect_left = _make_yuv_rect()
	s.comp_shader_mat_left = ShaderMaterial.new()
	s.comp_shader_mat_left.shader = load("res://src/shaders/yuv_display.gdshader")
	s.comp_shader_mat_left.set_shader_parameter("eye_index", 1)
	s.comp_yuv_rect_left.material = s.comp_shader_mat_left
	s.comp_bezel_rect_left.add_child(s.comp_yuv_rect_left)
	s.comp_stream_cursor_left = _make_cursor_texture_rect()
	s.comp_bezel_rect_left.add_child(s.comp_stream_cursor_left)
	s.comp_stream_cursor_circle_left = _make_cursor_circle_rect()
	s.comp_bezel_rect_left.add_child(s.comp_stream_cursor_circle_left)

	s.comp_viewport_right = SubViewport.new()
	s.comp_viewport_right.name = "CompViewportRight_%s" % s.monitor_id
	s.comp_viewport_right.disable_3d = true
	s.comp_viewport_right.transparent_bg = true
	s.comp_viewport_right.size = Vector2i(1920, 1080)
	s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(s.comp_viewport_right)

	s.comp_bezel_rect_right = _make_bezel_rect()
	s.comp_viewport_right.add_child(s.comp_bezel_rect_right)
	s.comp_yuv_rect_right = _make_yuv_rect()
	s.comp_shader_mat_right = ShaderMaterial.new()
	s.comp_shader_mat_right.shader = load("res://src/shaders/yuv_display.gdshader")
	s.comp_shader_mat_right.set_shader_parameter("eye_index", 2)
	s.comp_yuv_rect_right.material = s.comp_shader_mat_right
	s.comp_bezel_rect_right.add_child(s.comp_yuv_rect_right)
	s.comp_stream_cursor_right = _make_cursor_texture_rect()
	s.comp_bezel_rect_right.add_child(s.comp_stream_cursor_right)
	s.comp_stream_cursor_circle_right = _make_cursor_circle_rect()
	s.comp_bezel_rect_right.add_child(s.comp_stream_cursor_circle_right)

	s.comp_cylinder_left.set_layer_viewport(s.comp_viewport_left)
	s.comp_cylinder_right.set_layer_viewport(s.comp_viewport_right)

	s.comp_layer = s.comp_cylinder
	s.comp_layer.set_layer_viewport(s.comp_viewport)
	main._log("[COMP] Per-screen comp layers created (%s)" % s.monitor_id)

func _make_bezel_rect() -> ColorRect:
	var r = ColorRect.new()
	r.name = "CompBezelRect"
	r.color = Color(0, 0, 0, 1)
	r.anchors_preset = 15
	r.anchor_right = 1.0
	r.anchor_bottom = 1.0
	r.grow_horizontal = 2
	r.grow_vertical = 2
	return r

func _make_yuv_rect() -> ColorRect:
	var r = ColorRect.new()
	r.name = "CompYuvRect"
	r.anchors_preset = 15
	r.anchor_right = 1.0
	r.anchor_bottom = 1.0
	r.grow_horizontal = 2
	r.grow_vertical = 2
	return r

func _make_cursor_texture_rect() -> TextureRect:
	var r = TextureRect.new()
	r.name = "CompStreamCursor"
	r.texture = load("res://src/assets/mouse_pointer_01.png")
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.visible = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r

func _make_cursor_circle_rect() -> ColorRect:
	var r = ColorRect.new()
	r.name = "CompStreamCursorCircle"
	r.visible = false
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat = ShaderMaterial.new()
	mat.shader = preload("res://src/shaders/circle_cursor.gdshader")
	r.material = mat
	return r

## App-level (not per-screen) layers: menu, keyboard, both hand cursors.
func setup():
	if not available:
		main._log("[COMP] OpenXRCompositionLayerCylinder not available")
		return

	setup_screen(main.primary_screen)

	main.comp_ui = OpenXRCompositionLayerQuad.new()
	main.comp_ui.name = "CompUILayer"
	main.comp_ui.set_sort_order(3)
	main.comp_ui.set_enable_hole_punch(false)
	main.comp_ui.set_alpha_blend(true)
	main.comp_ui.set_quad_size(main._ui_mesh_size)
	main.comp_ui.visible = false
	main.xr_origin.add_child(main.comp_ui)
	main.comp_ui.set_layer_viewport(main.ui_viewport)
	main._log("[COMP] UI composition layer created")

	main.comp_cursor = OpenXRCompositionLayerQuad.new()
	main.comp_cursor.name = "CompCursorLayer"
	main.comp_cursor.set_sort_order(4)
	main.comp_cursor.set_enable_hole_punch(false)
	main.comp_cursor.set_alpha_blend(true)
	main.comp_cursor.set_quad_size(Vector2(0.04, 0.04))
	main.comp_cursor.visible = false
	main.xr_origin.add_child(main.comp_cursor)

	main.comp_cursor_viewport = SubViewport.new()
	main.comp_cursor_viewport.name = "CompCursorViewport"
	main.comp_cursor_viewport.disable_3d = true
	main.comp_cursor_viewport.transparent_bg = true
	main.comp_cursor_viewport.size = Vector2i(40, 64)
	main.comp_cursor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(main.comp_cursor_viewport)

	var pointer_tex = TextureRect.new()
	pointer_tex.name = "PointerTexture"
	pointer_tex.anchors_preset = 15
	pointer_tex.anchor_right = 1.0
	pointer_tex.anchor_bottom = 1.0
	pointer_tex.expand_mode = 1
	pointer_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pointer_tex.texture = load("res://src/assets/mouse_pointer_01.png")
	main.comp_cursor_viewport.add_child(pointer_tex)

	var circle = ColorRect.new()
	circle.name = "CircleTexture"
	circle.anchors_preset = 15
	circle.anchor_right = 1.0
	circle.anchor_bottom = 1.0
	var circle_mat = ShaderMaterial.new()
	circle_mat.shader = preload("res://src/shaders/circle_cursor.gdshader")
	circle.material = circle_mat
	circle.visible = false
	main.comp_cursor_viewport.add_child(circle)

	main.comp_cursor.set_layer_viewport(main.comp_cursor_viewport)
	main._log("[COMP] Cursor composition layer created")

	main.left_comp_cursor_layer = OpenXRCompositionLayerQuad.new()
	main.left_comp_cursor_layer.name = "LeftCompCursorLayer"
	main.left_comp_cursor_layer.set_sort_order(4)
	main.left_comp_cursor_layer.set_enable_hole_punch(false)
	main.left_comp_cursor_layer.set_alpha_blend(true)
	main.left_comp_cursor_layer.set_quad_size(Vector2(0.035, 0.035))
	main.left_comp_cursor_layer.visible = false
	main.xr_origin.add_child(main.left_comp_cursor_layer)

	main.left_comp_cursor_viewport = SubViewport.new()
	main.left_comp_cursor_viewport.name = "LeftCompCursorViewport"
	main.left_comp_cursor_viewport.disable_3d = true
	main.left_comp_cursor_viewport.transparent_bg = true
	main.left_comp_cursor_viewport.size = Vector2i(256, 256)
	main.left_comp_cursor_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	main.add_child(main.left_comp_cursor_viewport)

	var left_circle = ColorRect.new()
	left_circle.name = "CircleTexture"
	left_circle.anchors_preset = 15
	left_circle.anchor_right = 1.0
	left_circle.anchor_bottom = 1.0
	var left_circle_mat = ShaderMaterial.new()
	left_circle_mat.shader = preload("res://src/shaders/circle_cursor.gdshader")
	left_circle.material = left_circle_mat
	main.left_comp_cursor_viewport.add_child(left_circle)

	main.left_comp_cursor_layer.set_layer_viewport(main.left_comp_cursor_viewport)
	main._log("[COMP] Left cursor composition layer created")

	main.comp_kb = OpenXRCompositionLayerQuad.new()
	main.comp_kb.name = "CompKBLayer"
	main.comp_kb.set_sort_order(2)
	main.comp_kb.set_enable_hole_punch(false)
	main.comp_kb.set_alpha_blend(true)
	main.comp_kb.set_quad_size(main.virtual_keyboard.mesh_size)
	main.comp_kb.visible = false
	main.xr_origin.add_child(main.comp_kb)
	main.comp_kb.set_layer_viewport(main.virtual_keyboard.viewport)
	main._log("[COMP] Keyboard composition layer created")

	available = true
	if main.primary_screen.comp_cylinder.is_natively_supported():
		main._log("[COMP] Composition layer cylinder natively supported")
	else:
		main._log("[COMP] Composition layer cylinder NOT natively supported (using fallback mesh)")

func connect_welcome_texture():
	if not available:
		return
	for mat in get_shader_mats():
		if mat:
			mat.set_shader_parameter("main_texture", main.welcome_viewport.get_texture())
			mat.set_shader_parameter("yuv_mode", 0)
	main.primary_screen.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

## Applies bezel padding + cylinder aspect for one screen's mono/left/right viewport triplet.
func _update_bezel_for(s: VRScreen):
	var base_w = s.comp_base_size.x
	var base_h = s.comp_base_size.y
	var triplet = [
		{"bezel": s.comp_bezel_rect, "yuv": s.comp_yuv_rect, "vp": s.comp_viewport, "cyl": s.comp_cylinder},
		{"bezel": s.comp_bezel_rect_left, "yuv": s.comp_yuv_rect_left, "vp": s.comp_viewport_left, "cyl": s.comp_cylinder_left},
		{"bezel": s.comp_bezel_rect_right, "yuv": s.comp_yuv_rect_right, "vp": s.comp_viewport_right, "cyl": s.comp_cylinder_right},
	]
	if main.bezel_enabled and in_use:
		var px = 8
		var bezel_x = s.mesh_size.x * (1.0 + float(px * 2) / float(base_w))
		var bezel_y = s.mesh_size.y * (1.0 + float(px * 2) / float(base_h))
		for t in triplet:
			if not t.bezel:
				continue
			t.bezel.color = Color(0, 0, 0, 1)
			t.bezel.anchors_preset = 15
			t.bezel.offset_left = 0
			t.bezel.offset_top = 0
			t.bezel.offset_right = 0
			t.bezel.offset_bottom = 0
			t.yuv.offset_left = px
			t.yuv.offset_top = px
			t.yuv.offset_right = -px
			t.yuv.offset_bottom = -px
			t.yuv.anchor_left = 0.0
			t.yuv.anchor_top = 0.0
			t.yuv.anchor_right = 1.0
			t.yuv.anchor_bottom = 1.0
			t.yuv.anchors_preset = 0
			t.vp.size = Vector2i(base_w + px * 2, base_h + px * 2)
			if t.cyl and t.cyl.visible:
				t.cyl.set_aspect_ratio(bezel_x / bezel_y)
	else:
		for t in triplet:
			if not t.bezel:
				continue
			t.bezel.color = Color(0, 0, 0, 0)
			t.bezel.anchors_preset = 15
			t.bezel.offset_left = 0
			t.bezel.offset_top = 0
			t.bezel.offset_right = 0
			t.bezel.offset_bottom = 0
			t.yuv.offset_left = 0
			t.yuv.offset_top = 0
			t.yuv.offset_right = 0
			t.yuv.offset_bottom = 0
			t.yuv.anchors_preset = 15
			t.vp.size = Vector2i(base_w, base_h)
			if t.cyl and t.cyl.visible:
				t.cyl.set_aspect_ratio(s.mesh_size.x / s.mesh_size.y)

func update_bezel():
	if not main.primary_screen or not main.primary_screen.comp_yuv_rect:
		return
	for s in main.screens:
		_update_bezel_for(s)

func _update_cylinder_params_for(s: VRScreen):
	if not s.comp_cylinder and not s.comp_cylinder_left:
		return
	var cam_to_screen = s.global_position - main.xr_camera.global_position
	var view_dist = cam_to_screen.length()
	if view_dist < 0.5:
		view_dist = 3.0
	var radius = view_dist * 100.0
	if s.curvature == 1:
		radius = view_dist * 3.0
	elif s.curvature == 2:
		radius = view_dist * 2.0
	var screen_forward = -s.global_transform.basis.z
	var central_angle = s.mesh_size.x / radius
	var aspect = s.mesh_size.x / s.mesh_size.y
	s._comp_cyl_radius = radius
	s._comp_cyl_central_angle = central_angle
	s._comp_cyl_center = s.global_position - screen_forward * radius
	for cyl in [s.comp_cylinder, s.comp_cylinder_left, s.comp_cylinder_right]:
		if cyl and cyl.visible:
			cyl.set_radius(radius)
			cyl.set_central_angle(central_angle)
			cyl.set_aspect_ratio(aspect)
			cyl.global_position = s.global_position - screen_forward * radius
			cyl.global_rotation = s.global_rotation

func update_cylinder_params():
	for s in main.screens:
		_update_cylinder_params_for(s)

var _transparent_mat: StandardMaterial3D = null

func make_screen_transparent():
	if _transparent_mat == null:
		_transparent_mat = StandardMaterial3D.new()
		_transparent_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_transparent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_transparent_mat.albedo_color = Color(0, 0, 0, 0)
	for s in main.screens:
		if s._original_mat == null:
			s._original_mat = s.material_override
		s.material_override = _transparent_mat

func make_ui_transparent():
	main.ui_panel_3d.visible = false

func make_kb_transparent():
	if not main.virtual_keyboard:
		return
	main.virtual_keyboard.mesh_instance.visible = false

func restore_screen_material():
	for s in main.screens:
		if s._original_mat != null:
			s.material_override = s._original_mat
			s._original_mat = null
		s.grab_bar.visible = true

func restore_ui_material():
	main.ui_panel_3d.visible = main.ui_visible

func restore_kb_material():
	if main.virtual_keyboard:
		main.virtual_keyboard.mesh_instance.visible = main.virtual_keyboard.visible

func bind_yuv_textures():
	var mat = main.stream_backend.get_shader_material()
	if not mat:
		main._log("[YUV] No shader material from stream backend, using SubViewport path")
		var stream_tex = main.stream_viewport.get_texture()
		if not in_use and main.primary_screen.material_override is ShaderMaterial:
			main.primary_screen.material_override.set_shader_parameter("main_texture", stream_tex)
			main.primary_screen.material_override.set_shader_parameter("yuv_mode", 0)
		bind_fallback_texture(stream_tex)
		return
	var tex_y = mat.get_shader_parameter("tex_y")
	var tex_u = mat.get_shader_parameter("tex_u")
	var tex_v = mat.get_shader_parameter("tex_v")
	var is_nv12_rd = mat.get_shader_parameter("is_nv12_rd")
	var is_semi_planar = mat.get_shader_parameter("is_semi_planar")
	var cmt = mat.get_shader_parameter("color_matrix_type")
	var cr = mat.get_shader_parameter("color_range")
	if tex_y:
		var yuv_mode_val = 0
		if is_nv12_rd:
			yuv_mode_val = 1
		elif is_semi_planar:
			yuv_mode_val = 2
		else:
			yuv_mode_val = 3
		if not in_use and main.primary_screen.material_override is ShaderMaterial:
			main.primary_screen.material_override.set_shader_parameter("tex_y", tex_y)
			main.primary_screen.material_override.set_shader_parameter("tex_u", tex_u)
			main.primary_screen.material_override.set_shader_parameter("tex_v", tex_v)
			main.primary_screen.material_override.set_shader_parameter("color_matrix_type", cmt)
			main.primary_screen.material_override.set_shader_parameter("color_range", cr)
			main.primary_screen.material_override.set_shader_parameter("yuv_mode", yuv_mode_val)
		main._log("[YUV] Direct YUV binding: mode=%d nv12_rd=%s semi_planar=%s" % [yuv_mode_val, str(is_nv12_rd), str(is_semi_planar)])
		bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode_val, cmt, cr)
	else:
		var stream_tex = main.stream_viewport.get_texture()
		if not in_use and main.primary_screen.material_override is ShaderMaterial:
			main.primary_screen.material_override.set_shader_parameter("main_texture", stream_tex)
			main.primary_screen.material_override.set_shader_parameter("yuv_mode", 0)
		bind_fallback_texture(stream_tex)

func bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode: int, cmt, cr):
	for s in main.screens:
		for mat in get_shader_mats(s):
			if not mat:
				continue
			mat.set_shader_parameter("tex_y", tex_y)
			mat.set_shader_parameter("tex_u", tex_u)
			mat.set_shader_parameter("tex_v", tex_v)
			mat.set_shader_parameter("yuv_mode", yuv_mode)
			mat.set_shader_parameter("color_matrix_type", cmt)
			mat.set_shader_parameter("color_range", cr)
	main._log("[COMP] YUV textures bound to composition layer shader (mode=%d)" % yuv_mode)

func bind_fallback_texture(stream_tex):
	for s in main.screens:
		for mat in get_shader_mats(s):
			if not mat:
				continue
			mat.set_shader_parameter("main_texture", stream_tex)
			mat.set_shader_parameter("yuv_mode", 0)

func switch_to_comp_layer():
	if not available:
		in_use = false
		main._log("[COMP] Not available, using mesh rendering")
		return
	var stereo = main.settings_controller.get_stereo_mode() if main.settings_controller else 0
	if stereo > 0:
		switch_to_stereo_comp_layer()
		return
	in_use = true
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var s = main.primary_screen
	if s.comp_cylinder_left: s.comp_cylinder_left.visible = false
	if s.comp_cylinder_right: s.comp_cylinder_right.visible = false
	if s.comp_viewport_left: s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if s.comp_viewport_right: s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if s.comp_cylinder:
		s.comp_layer = s.comp_cylinder
		s.comp_layer.set_layer_viewport(s.comp_viewport)
		s.comp_layer.visible = true
		update_cylinder_params()
		main._log("[COMP] Switched to composition layer (cylinder, curv=%d)" % s.curvature)
	else:
		s.comp_layer.set_layer_viewport(s.comp_viewport)
		s.comp_layer.visible = true
		main._log("[COMP] Switched to composition layer (quad fallback)")
	s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	s.comp_shader_mat.set_shader_parameter("stereo_mode", 0)
	main.settings_controller.apply_filter()
	make_screen_transparent()
	for scr in main.screens:
		if scr.bezel_mesh:
			scr.bezel_mesh.visible = false
	update_bezel()

func switch_to_stereo_comp_layer():
	if not available:
		in_use = false
		main._log("[COMP] Not available, cannot use stereo comp layer")
		return
	in_use = true
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var s = main.primary_screen
	if s.comp_cylinder: s.comp_cylinder.visible = false
	s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var stereo = main.settings_controller.get_stereo_mode()
	s.comp_cylinder_left.visible = true
	s.comp_cylinder_right.visible = true
	s.comp_cylinder_left.set_layer_viewport(s.comp_viewport_left)
	s.comp_cylinder_right.set_layer_viewport(s.comp_viewport_right)
	s.comp_shader_mat_left.set_shader_parameter("stereo_mode", stereo)
	s.comp_shader_mat_left.set_shader_parameter("eye_index", 1)
	s.comp_shader_mat_right.set_shader_parameter("stereo_mode", stereo)
	s.comp_shader_mat_right.set_shader_parameter("eye_index", 2)
	s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	make_screen_transparent()
	if s.bezel_mesh:
		s.bezel_mesh.visible = false
	update_cylinder_params()
	update_bezel()
	if main.is_streaming:
		bind_yuv_textures()
	main._log("[COMP] Switched to stereo composition layer (mode=%d)" % stereo)

func switch_to_mesh_rendering():
	in_use = false
	main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if main.is_streaming else SubViewport.UPDATE_DISABLED
	var s = main.primary_screen
	if s.comp_cylinder: s.comp_cylinder.visible = false
	if s.comp_cylinder_left: s.comp_cylinder_left.visible = false
	if s.comp_cylinder_right: s.comp_cylinder_right.visible = false
	if main.comp_ui: main.comp_ui.visible = false
	if main.comp_kb: main.comp_kb.visible = false
	if main.comp_cursor: main.comp_cursor.visible = false
	if main.left_comp_cursor_layer: main.left_comp_cursor_layer.visible = false
	if s.comp_viewport:
		s.comp_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if s.comp_viewport_left:
		s.comp_viewport_left.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if s.comp_viewport_right:
		s.comp_viewport_right.render_target_update_mode = SubViewport.UPDATE_DISABLED
	restore_screen_material()
	restore_ui_material()
	restore_kb_material()
	if s.bezel_mesh:
		s.bezel_mesh.visible = main.bezel_enabled
	update_bezel()
	if main.is_streaming:
		main.stream_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var mat = s.material_override
		main._log("[MESH] material type=%s" % str(mat.get_class()) if mat else "[MESH] material is null")
		mat.set_shader_parameter("main_texture", main.stream_viewport.get_texture())
		mat.set_shader_parameter("yuv_mode", 0)
		bind_yuv_textures()
		var mode = main.settings_controller.get_stereo_mode()
		mat.set_shader_parameter("stereo_mode", mode)
		mat.set_shader_parameter("filter_mode", main.smooth_mode)
		mat.set_shader_parameter("sharpen", float(main.sharpen_mode) * 0.016)
		main._log("[MESH] stereo=%d yuv_mode=%d filter=%d sharpen=%.3f" % [mode, mat.get_shader_parameter("yuv_mode"), main.smooth_mode, float(main.sharpen_mode) * 0.016])

func update_layer_size():
	update_cylinder_params()

func clear_yuv_textures():
	for s in main.screens:
		for mat in get_shader_mats(s):
			if not mat:
				continue
			mat.set_shader_parameter("tex_y", null)
			mat.set_shader_parameter("tex_u", null)
			mat.set_shader_parameter("tex_v", null)
			mat.set_shader_parameter("yuv_mode", 0)
			mat.set_shader_parameter("main_texture", null)
			mat.set_shader_parameter("stereo_mode", 0)
			mat.set_shader_parameter("depth_texture", null)

static func set_grab_bar_color(viewport: SubViewport, color: Color):
	if not viewport:
		return
	var bar = viewport.find_child("CompGrabBar", true, false) as PanelContainer
	if not bar:
		return
	var style = bar.get_theme_stylebox("panel") as StyleBoxFlat
	if not style or is_equal_approx(style.bg_color.a, color.a):
		return
	style = style.duplicate()
	style.bg_color = Color(1, 1, 1, color.a)
	bar.add_theme_stylebox_override("panel", style)
```

Notes:
- `make_screen_transparent()` / `restore_screen_material()` now loop `main.screens`, which is `[primary_screen]`
  at N=1 — identical behaviour, but the per-screen `_original_mat` (renamed from
  `_screen_mesh_original_mat` since it now lives per-`VRScreen`) is tracked correctly per screen once N>1.
- The C++/GDScript boundary (`bind_yuv_textures`) is unchanged in shape — it still reads one shared
  `ShaderMaterial` from `TextureUploader` and fans it out; the fan-out loop just now iterates `main.screens`
  instead of a fixed 3-element array.
- This is also where Risk #5 (per-frame rebind cost) will later be fixed (C3) — not in this commit. Do not
  add the RID dirty-guard here; keep this commit a pure move.

**Verify:**
```bash
grep -c "func setup_screen" src/composition_layer_manager.gd   # expect: 1
grep -n "comp_shader_mat_left\|comp_shader_mat_right" main.gd  # expect: ZERO matches (all now alias getters only, no direct field on main outside the alias block from A3)
```
Run on Quest (or with `OpenXRCompositionLayerCylinder` available): comp-layer mode entry/exit, stereo
toggle, bezel toggle, filter/sharpen sliders must all look identical to before this commit.

---

### A6 — Single `_anchor_to_primary()` helper

Do **not** convert `UIPanel3D` to `VRPanelBase` in this branch (see Context). Just collapse the three
duplicated offset blocks in `main.gd`.

1. In `main.gd`, find (currently `main.gd:1251-1265`):
   ```gdscript
   func _set_ui_position():
   	if not is_xr_active:
   		return
   	if _ui_has_saved_offset:
   		ui_panel_3d.global_position = screen_mesh.global_position + screen_mesh.global_transform.basis * _ui_saved_offset
   		ui_panel_3d.rotation.y = screen_mesh.global_rotation.y + _ui_saved_rot_y
   		ui_panel_3d.rotation.x = _ui_saved_rot_x
   	else:
   		var offset = Vector3(-1.0, -0.5, 0.8)
   		ui_panel_3d.global_position = screen_mesh.global_position + screen_mesh.global_transform.basis * offset
   		var cam_pos = xr_camera.global_position
   		var to_cam = (cam_pos - ui_panel_3d.global_position).normalized()
   		ui_panel_3d.rotation.y = atan2(to_cam.x, to_cam.z)
   		ui_panel_3d.rotation.x = -0.15
   		_save_ui_offset()
   ```
   Replace with:
   ```gdscript
   func _anchor_to_primary(node: Node3D, offset: Vector3, rot_y: float, rot_x: float):
   	node.global_position = primary_screen.global_position + primary_screen.global_transform.basis * offset
   	node.rotation.y = primary_screen.global_rotation.y + rot_y
   	node.rotation.x = rot_x

   func _set_ui_position():
   	if not is_xr_active:
   		return
   	if _ui_has_saved_offset:
   		_anchor_to_primary(ui_panel_3d, _ui_saved_offset, _ui_saved_rot_y, _ui_saved_rot_x)
   	else:
   		var offset = Vector3(-1.0, -0.5, 0.8)
   		ui_panel_3d.global_position = primary_screen.global_position + primary_screen.global_transform.basis * offset
   		var cam_pos = xr_camera.global_position
   		var to_cam = (cam_pos - ui_panel_3d.global_position).normalized()
   		ui_panel_3d.rotation.y = atan2(to_cam.x, to_cam.z)
   		ui_panel_3d.rotation.x = -0.15
   		_save_ui_offset()
   ```

2. Find (currently `main.gd:1267-1272`):
   ```gdscript
   func _save_ui_offset():
   	var scr_basis = screen_mesh.global_transform.basis.inverse()
   	_ui_saved_offset = scr_basis * (ui_panel_3d.global_position - screen_mesh.global_position)
   	_ui_saved_rot_y = ui_panel_3d.rotation.y - screen_mesh.global_rotation.y
   	_ui_saved_rot_x = ui_panel_3d.rotation.x
   	_ui_has_saved_offset = true
   ```
   Replace with:
   ```gdscript
   func _save_ui_offset():
   	var scr_basis = primary_screen.global_transform.basis.inverse()
   	_ui_saved_offset = scr_basis * (ui_panel_3d.global_position - primary_screen.global_position)
   	_ui_saved_rot_y = ui_panel_3d.rotation.y - primary_screen.global_rotation.y
   	_ui_saved_rot_x = ui_panel_3d.rotation.x
   	_ui_has_saved_offset = true
   ```

3. Find (currently `main.gd:1274-1291`, inside `_set_ui_visible()`):
   ```gdscript
   	if is_xr_active and vis:
   		if _ui_has_saved_offset:
   			ui_panel_3d.global_position = screen_mesh.global_position + screen_mesh.global_transform.basis * _ui_saved_offset
   			ui_panel_3d.rotation.y = screen_mesh.global_rotation.y + _ui_saved_rot_y
   			ui_panel_3d.rotation.x = _ui_saved_rot_x
   		else:
   			var offset = Vector3(-1.0, -0.5, 0.8)
   			ui_panel_3d.global_position = screen_mesh.global_position + screen_mesh.global_transform.basis * offset
   			var cam_pos = xr_camera.global_position
   			var to_cam = (cam_pos - ui_panel_3d.global_position).normalized()
   			ui_panel_3d.rotation.y = atan2(to_cam.x, to_cam.z)
   			ui_panel_3d.rotation.x = -0.15
   			_save_ui_offset()
   	elif is_xr_active:
   		_save_ui_offset()
   ```
   Replace with:
   ```gdscript
   	if is_xr_active and vis:
   		if _ui_has_saved_offset:
   			_anchor_to_primary(ui_panel_3d, _ui_saved_offset, _ui_saved_rot_y, _ui_saved_rot_x)
   		else:
   			var offset = Vector3(-1.0, -0.5, 0.8)
   			ui_panel_3d.global_position = primary_screen.global_position + primary_screen.global_transform.basis * offset
   			var cam_pos = xr_camera.global_position
   			var to_cam = (cam_pos - ui_panel_3d.global_position).normalized()
   			ui_panel_3d.rotation.y = atan2(to_cam.x, to_cam.z)
   			ui_panel_3d.rotation.x = -0.15
   			_save_ui_offset()
   	elif is_xr_active:
   		_save_ui_offset()
   ```

4. In `src/vr_panel_base.gd`, find:
   ```gdscript
   func _save_offset():
   	var scr_basis = main.screen_mesh.global_transform.basis.inverse()
   	_saved_offset = scr_basis * (global_position - main.screen_mesh.global_position)
   	_saved_rot_y = rotation.y - main.screen_mesh.global_rotation.y
   	_saved_rot_x = rotation.x
   	_has_saved_offset = true
   ```
   Replace with:
   ```gdscript
   func _save_offset():
   	var scr_basis = main.primary_screen.global_transform.basis.inverse()
   	_saved_offset = scr_basis * (global_position - main.primary_screen.global_position)
   	_saved_rot_y = rotation.y - main.primary_screen.global_rotation.y
   	_saved_rot_x = rotation.x
   	_has_saved_offset = true
   ```

5. Same file, find:
   ```gdscript
   func toggle():
   	var new_vis = not visible
   	if new_vis:
   		if _has_saved_offset:
   			global_position = main.screen_mesh.global_position + main.screen_mesh.global_transform.basis * _saved_offset
   			rotation.y = main.screen_mesh.global_rotation.y + _saved_rot_y
   			rotation.x = _saved_rot_x
   		else:
   ```
   Replace with:
   ```gdscript
   func toggle():
   	var new_vis = not visible
   	if new_vis:
   		if _has_saved_offset:
   			global_position = main.primary_screen.global_position + main.primary_screen.global_transform.basis * _saved_offset
   			rotation.y = main.primary_screen.global_rotation.y + _saved_rot_y
   			rotation.x = _saved_rot_x
   		else:
   ```

6. In `src/virtual_keyboard.gd`, find `_place_default()` (currently `:474-480`):
   ```gdscript
   func _place_default():
   	var offset = Vector3(0, -0.7, 0.6)
   	global_position = main.screen_mesh.global_position + main.screen_mesh.global_transform.basis * offset
   	var cam_pos = main.xr_camera.global_position
   	var to_cam = (cam_pos - global_position).normalized()
   	rotation.y = atan2(to_cam.x, to_cam.z)
   	rotation.x = -PI / 4.0
   ```
   Replace with:
   ```gdscript
   func _place_default():
   	var offset = Vector3(0, -0.7, 0.6)
   	global_position = main.primary_screen.global_position + main.primary_screen.global_transform.basis * offset
   	var cam_pos = main.xr_camera.global_position
   	var to_cam = (cam_pos - global_position).normalized()
   	rotation.y = atan2(to_cam.x, to_cam.z)
   	rotation.x = -PI / 4.0
   ```

**Verify:**
```bash
grep -rn "screen_mesh" src/vr_panel_base.gd src/virtual_keyboard.gd   # expect: ZERO matches
```
Run the app: open menu, open keyboard, reposition screen, confirm both panels still anchor and re-appear at
the same saved offsets as before.

---

### A7 — Pointer target resolver + corner-collision-follows-visibility fix

**New file: `src/pointer_target.gd`** — full content:

```gdscript
class_name PointerTarget

## Resolves a raycast collider to {role, screen, node, corner_idx}.
## role is read from nf_role metadata set at construction time on screen
## parts (screen_manager.gd -> vr_screen.gd), panels (vr_panel_base.gd), and
## the grab bar (vr_screen.gd). "screen" is found by climbing to the nearest
## VRScreen ancestor -- null for panels, which is the correct answer.
static func resolve(collider: Node) -> Dictionary:
	if collider == null:
		return {"role": &"", "screen": null, "node": null, "corner_idx": -1}
	var node: Node = collider.get_parent()
	if node == null:
		return {"role": &"", "screen": null, "node": null, "corner_idx": -1}
	var screen: VRScreen = null
	var n: Node = node
	while n != null:
		if n is VRScreen:
			screen = n
			break
		n = n.get_parent()
	return {
		"role": node.get_meta(&"nf_role", &""),
		"screen": screen,
		"node": node,
		"corner_idx": node.get_meta(&"nf_corner_idx", -1),
	}
```

**Set `nf_role` metadata at construction:**

1. In `src/vr_screen.gd`, the `@onready var grab_bar` line — grab bar and the screen itself both need a
   role. Find:
   ```gdscript
   @onready var grab_bar: MeshInstance3D = %ScreenGrabBar
   ```
   Replace with:
   ```gdscript
   @onready var grab_bar: MeshInstance3D = %ScreenGrabBar

   func _ready() -> void:
   	set_meta(&"nf_role", &"screen")
   	grab_bar.set_meta(&"nf_role", &"grab_bar")
   ```
   (`create_corner_handles()` in the same file already sets `nf_role`/`nf_corner_idx` on each corner handle
   — done in A1, no change needed here.)

2. In `main.tscn`, find the `UIPanel3D` node block:
   ```
   [node name="UIPanel3D" type="MeshInstance3D" parent="." unique_id=1883258044]
   unique_name_in_owner = true
   ```
   This node has no script, so metadata must be set at runtime instead. In `main.gd`, function `_init_ui()`
   (already edited twice above), append one more line right after `_create_contact_dot()`:
   ```gdscript
   	_create_contact_dot()
   	ui_panel_3d.set_meta(&"nf_role", &"panel")
   ```

3. In `src/vr_panel_base.gd`, function `_setup_mesh()`, find:
   ```gdscript
   	mesh_instance.set_surface_override_material(0, tex_mat)
   	mesh_instance.extra_cull_margin = 10.0
   	add_child(mesh_instance)
   ```
   Replace with:
   ```gdscript
   	mesh_instance.set_surface_override_material(0, tex_mat)
   	mesh_instance.extra_cull_margin = 10.0
   	mesh_instance.set_meta(&"nf_role", &"panel")
   	add_child(mesh_instance)
   ```

**Rewrite `handle_pointer_interaction()`'s dispatch in `src/xr_interaction.gd`.** This function is long;
only the identity-comparison chain changes. Every other line (grab-bar color updates, cursor drawing, hand
tracking prep at the top) is untouched. The exact edits:

1. Find (the click-start UV capture near the top):
   ```gdscript
   		var col = active_raycast.get_collider() if active_raycast.is_colliding() else null
   		if col and col.get_parent() == main.screen_mesh:
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = main._hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   			if main.settings_controller.get_stereo_mode() >= 3:
   				var shift = _compute_parallax_shift(uv_x)
   				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   			_pinch_start_pos = Vector2(uv_x * main.stream_viewport.size.x, uv.y * main.stream_viewport.size.y)
   			_click_pending_release = true
   ```
   Replace with:
   ```gdscript
   		var col = active_raycast.get_collider() if active_raycast.is_colliding() else null
   		var t0 = PointerTarget.resolve(col) if col else {"role": &""}
   		if t0.role == &"screen":
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = t0.screen.hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   			if main.settings_controller.get_stereo_mode() >= 3:
   				var shift = _compute_parallax_shift(uv_x)
   				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   			_pinch_start_pos = Vector2(uv_x * main.stream_viewport.size.x, uv.y * main.stream_viewport.size.y)
   			_pinch_start_screen = t0.screen
   			_click_pending_release = true
   ```
   (`_pinch_start_screen` is declared and used starting D2 — declare the var now so this compiles; add near
   the top of `xr_interaction.gd` next to `var _pinch_start_pos: Vector2 = Vector2.ZERO`:
   `var _pinch_start_screen: VRScreen = null`.)

2. Find (grip/right-click block):
   ```gdscript
   			var col = active_raycast.get_collider() if active_raycast.is_colliding() else null
   			if col and col.get_parent() == main.screen_mesh:
   				var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   				var uv = main._hit_point_to_uv(hit_pos)
   				var uv_x = uv.x
   				var uv_y = uv.y
   ```
   Replace with:
   ```gdscript
   			var col = active_raycast.get_collider() if active_raycast.is_colliding() else null
   			var t1 = PointerTarget.resolve(col) if col else {"role": &""}
   			if t1.role == &"screen":
   				var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   				var uv = t1.screen.hit_point_to_uv(hit_pos)
   				var uv_x = uv.x
   				var uv_y = uv.y
   ```

3. Find the corner-handle visibility reset:
   ```gdscript
   	main.get_node("%ScreenGrabBar")  # already replaced with main.screen_mesh.grab_bar in A2 -- see below
   ```
   (this was already handled in A2 — no further change here for the `.visible = true` line itself.)

4. Find the cursor-target block:
   ```gdscript
   		var raw_hit = active_raycast.get_collision_point()
   		var _col = active_raycast.get_collider()
   		var _par = _col.get_parent() if _col else null
   		on_screen = (_par == main.screen_mesh)
   ```
   Replace with:
   ```gdscript
   		var raw_hit = active_raycast.get_collision_point()
   		var _col = active_raycast.get_collider()
   		var t_hover = PointerTarget.resolve(_col) if _col else {"role": &""}
   		on_screen = (t_hover.role == &"screen")
   ```

5. Find the main dispatch chain (this is the big one). Find:
   ```gdscript
   	if active_raycast.is_colliding():
   		var collider = active_raycast.get_collider()
   		var parent = collider.get_parent()
   		pointer_on_ui = false
   		if parent == main.ui_panel_3d or (main.ui_visible and parent == main.screen_mesh.grab_bar):
   			pointer_on_ui = true
   		if main.virtual_keyboard and main.virtual_keyboard.visible and parent == main.virtual_keyboard.mesh_instance:
   			pointer_on_ui = true

   		if parent == main.screen_mesh.grab_bar and parent != main.grabbed_bar:
   			_set_grab_bar_color(parent, Color.WHITE, 0.15)

   		is_now_clicking = _is_now_clicking()

   		var hit_ui = false
   		if main.ui_visible and main.ui_panel_3d and main.ui_panel_3d.visible:
   			var area = main.ui_panel_3d.get_node_or_null("Area3D")
   			if area and area.monitoring and parent == main.ui_panel_3d:
   				hit_ui = true

   		if parent == main.ui_panel_3d or hit_ui:
   ```
   Replace with:
   ```gdscript
   	if active_raycast.is_colliding():
   		var collider = active_raycast.get_collider()
   		var parent = collider.get_parent()
   		var t = PointerTarget.resolve(collider)
   		pointer_on_ui = false
   		if t.role == &"panel" and parent == main.ui_panel_3d:
   			pointer_on_ui = true
   		if t.role == &"grab_bar" and main.ui_visible and parent == main.screen_mesh.grab_bar:
   			pointer_on_ui = true
   		if main.virtual_keyboard and main.virtual_keyboard.visible and t.role == &"panel" and parent == main.virtual_keyboard.mesh_instance:
   			pointer_on_ui = true

   		if t.role == &"grab_bar" and parent != main.grabbed_bar:
   			_set_grab_bar_color(parent, Color.WHITE, 0.15)

   		is_now_clicking = _is_now_clicking()

   		var hit_ui = false
   		if main.ui_visible and main.ui_panel_3d and main.ui_panel_3d.visible:
   			var area = main.ui_panel_3d.get_node_or_null("Area3D")
   			if area and area.monitoring and t.role == &"panel" and parent == main.ui_panel_3d:
   				hit_ui = true

   		if (t.role == &"panel" and parent == main.ui_panel_3d) or hit_ui:
   ```

6. Find:
   ```gdscript
   		if main.virtual_keyboard and main.virtual_keyboard.visible and parent == main.virtual_keyboard.mesh_instance:
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var local_pos = main.virtual_keyboard.mesh_instance.to_local(hit_pos)
   ```
   Replace with:
   ```gdscript
   		if main.virtual_keyboard and main.virtual_keyboard.visible and t.role == &"panel" and parent == main.virtual_keyboard.mesh_instance:
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var local_pos = main.virtual_keyboard.mesh_instance.to_local(hit_pos)
   ```

7. Find:
   ```gdscript
   		elif parent == main.screen_mesh and not main.is_streaming:
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = main._hit_point_to_uv(hit_pos)
   			var wv = main.welcome_viewport
   ```
   Replace with:
   ```gdscript
   		elif t.role == &"screen" and not main.is_streaming:
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = t.screen.hit_point_to_uv(hit_pos)
   			var wv = main.welcome_viewport
   ```

8. Find:
   ```gdscript
   		elif parent == main.screen_mesh and main.is_streaming:
   			if main.virtual_keyboard and main.virtual_keyboard.trackpad_active:
   				return
   			if main.controller_mapper and main.controller_mapper.is_active() and main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD:
   				return
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = main._hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   ```
   Replace with:
   ```gdscript
   		elif t.role == &"screen" and main.is_streaming:
   			if main.virtual_keyboard and main.virtual_keyboard.trackpad_active:
   				return
   			if main.controller_mapper and main.controller_mapper.is_active() and main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD:
   				return
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = t.screen.hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   ```
   (D2 replaces the `host_x`/`host_y` computation a few lines below this — leave it as
   `int(uv_x * main.stream_viewport.size.x)` for now; this commit only changes target *identification*, not
   the mouse-mapping math.)

9. Find:
   ```gdscript
   		var corner_idx = _get_corner_index(parent)
   		if corner_idx >= 0:
   			parent.visible = true
   ```
   Replace with:
   ```gdscript
   		if t.role == &"corner":
   			var corner_idx = t.corner_idx
   			parent.visible = true
   ```

10. Find:
    ```gdscript
    		elif parent == main.screen_mesh.grab_bar:
    			if is_now_clicking and not main.grabbed_node and main.grabbed_corner_idx < 0:
    ```
    Replace with:
    ```gdscript
    		elif t.role == &"grab_bar":
    			if is_now_clicking and not main.grabbed_node and main.grabbed_corner_idx < 0:
    ```

11. Delete `_get_corner_index()` entirely (now dead — `t.corner_idx` from `PointerTarget` replaces it). Find:
    ```gdscript
    func _get_corner_index(node: Node) -> int:
    	for i in range(main.corner_handles.size()):
    		if node == main.corner_handles[i]:
    			return i
    	return -1

    ```
    Replace with: *(nothing — delete these 6 lines including the trailing blank line)*

12. `_is_hand_on_screen()` and `_is_hand_on_ui()` — find:
    ```gdscript
    func _is_hand_on_screen(hand: String) -> bool:
    	var rc = main.hand_raycast if hand == "right" else main.left_hand_raycast
    	if not rc or not rc.is_colliding():
    		return false
    	var col = rc.get_collider()
    	if not col:
    		return false
    	var p = col.get_parent()
    	return p == main.screen_mesh or p == main.ui_panel_3d or (main.virtual_keyboard and main.virtual_keyboard.visible and p == main.virtual_keyboard.mesh_instance)

    func _is_hand_on_ui(hnd: String) -> bool:
    	var rc = main.hand_raycast if hnd == "right" else main.left_hand_raycast
    	if not rc or not rc.is_colliding():
    		return false
    	var col = rc.get_collider()
    	if not col:
    		return false
    	var p = col.get_parent()
    	return p == main.ui_panel_3d or (main.virtual_keyboard and main.virtual_keyboard.visible and p == main.virtual_keyboard.mesh_instance)
    ```
    Replace with:
    ```gdscript
    func _is_hand_on_screen(hand: String) -> bool:
    	var rc = main.hand_raycast if hand == "right" else main.left_hand_raycast
    	if not rc or not rc.is_colliding():
    		return false
    	var t = PointerTarget.resolve(rc.get_collider())
    	if t.role == &"screen":
    		return true
    	return t.role == &"panel"

    func _is_hand_on_ui(hnd: String) -> bool:
    	var rc = main.hand_raycast if hnd == "right" else main.left_hand_raycast
    	if not rc or not rc.is_colliding():
    		return false
    	return PointerTarget.resolve(rc.get_collider()).role == &"panel"
    ```

13. `_process_other_hand_ui()` — find:
    ```gdscript
    	var parent = col.get_parent()
    	if parent != main.ui_panel_3d and not (main.virtual_keyboard and main.virtual_keyboard.visible and parent == main.virtual_keyboard.mesh_instance):
    		_hide_other_hand_ui()
    		return
    ```
    Replace with:
    ```gdscript
    	var parent = col.get_parent()
    	var t_other = PointerTarget.resolve(col)
    	if t_other.role != &"panel":
    		_hide_other_hand_ui()
    		return
    ```

14. **Fix the invisible-corner-still-monitoring bug**, found in the same corner-visibility block used in
    edit 9's surrounding code (`main.gd:213-217` equivalent — actually in `xr_interaction.gd`, the block
    right after `main.screen_mesh.grab_bar.visible = true`). Find:
    ```gdscript
    	main.screen_mesh.grab_bar.visible = true
    	for ch in main.corner_handles:
    		ch.visible = false

    	if main.grabbed_corner_idx >= 0:
    		main.corner_handles[main.grabbed_corner_idx].visible = true
    ```
    Replace with:
    ```gdscript
    	main.screen_mesh.grab_bar.visible = true
    	for ch in main.corner_handles:
    		ch.visible = false
    		var ch_area = ch.get_node_or_null("Area3D")
    		if ch_area:
    			ch_area.monitoring = false
    			ch_area.monitorable = false

    	if main.grabbed_corner_idx >= 0:
    		var gh = main.corner_handles[main.grabbed_corner_idx]
    		gh.visible = true
    		var gh_area = gh.get_node_or_null("Area3D")
    		if gh_area:
    			gh_area.monitoring = true
    			gh_area.monitorable = true
    ```
    And where corners are shown on hover (edit 9's `parent.visible = true` line), also re-enable
    monitoring. Find:
    ```gdscript
    		if t.role == &"corner":
    			var corner_idx = t.corner_idx
    			parent.visible = true
    ```
    Replace with:
    ```gdscript
    		if t.role == &"corner":
    			var corner_idx = t.corner_idx
    			parent.visible = true
    			var p_area = parent.get_node_or_null("Area3D")
    			if p_area:
    				p_area.monitoring = true
    				p_area.monitorable = true
    ```
    This is safe today at N=1 because the corner that was already being raycast against (to reach this
    branch at all) obviously already had `monitoring == true` — this just stops the OTHER 3 corners from
    continuing to eat rays while hidden, which was previously silently true and only becomes a visible bug
    once a second screen's geometry can be nearby (C1+).

**Verify:**
```bash
grep -c "_get_corner_index" src/xr_interaction.gd    # expect: 0
grep -c "class_name PointerTarget" src/pointer_target.gd  # expect: 1
godot --headless --check-only . 2>&1 | grep -i error  # expect: no output
```
Run the app: every interaction must be unchanged — screen click/drag, right-click, corner resize, grab bar
drag, menu clicks (primary and secondary hand), keyboard clicks and its internal trackpad, welcome-screen
clicks. This is the highest-risk commit in Phase A; test thoroughly before moving to Phase B.

---

### A8 — Delete migrated aliases

Now that every call site from A1-A7 goes through `screens`/`primary_screen`/`VRScreen` methods directly,
confirm nothing still reads the old `main.*` alias properties added in A3, then delete the alias property
blocks and keep only `main.screen_mesh` (which is not an alias — it is still the literal `@onready var
screen_mesh = $MeshInstance3D`, i.e. the same node as `primary_screen`).

1. Run, from the repo root:
   ```bash
   grep -rn "main\._mesh_size\|main\.curvature\b\|main\.bezel_mesh\|main\.corner_handles\|main\.comp_cylinder\b\|main\._comp_cyl_\|main\.comp_layer\b\|main\.comp_viewport\b\|main\.comp_yuv_rect\b\|main\.comp_bezel_rect\b\|main\.comp_shader_mat\b\|main\.comp_cylinder_left\|main\.comp_cylinder_right\|main\.comp_viewport_left\|main\.comp_viewport_right\|main\.comp_yuv_rect_left\|main\.comp_yuv_rect_right\|main\.comp_bezel_rect_left\|main\.comp_bezel_rect_right\|main\.comp_shader_mat_left\|main\.comp_shader_mat_right\|main\.comp_stream_cursor\|main\._screen_mesh_original_mat\|main\._comp_base_size" src/ main.gd
   ```
   Every remaining hit is either (a) inside `main.gd` itself (the alias getter/setter bodies from A3 — keep
   those), or (b) a call site that legitimately still wants "the primary screen's X" via the alias (fine to
   leave as-is; the alias is not wrong, just no longer load-bearing for future N-screen work since D-phase
   code should prefer `screen.mesh_size` etc. directly). **Do not delete an alias if any hit remains outside
   `main.gd`'s own getter/setter body** — that means a caller still depends on it; leave the alias in place
   and move on. This step is a cleanup pass, not a hard requirement — skip any alias with a remaining
   external caller rather than breaking the build.
2. For every alias with **zero** external callers, delete its `get:`/`set:` block from `main.gd` and the
   corresponding var entirely.

**Verify:**
```bash
godot --headless --check-only . 2>&1 | grep -i error   # expect: no output
```
Run the full manual test matrix from A7's verify step once more, end to end, as the Phase A exit gate.

---

## Phase B — Layout model + shader UV regions

### B1 — `src/screen_layout.gd`

**New file, full content:**

```gdscript
class_name ScreenLayout
extends RefCounted

## Manifest-shaped layout describing how the encoded frame splits into N
## VR screens, and where each maps in the host's virtual-desktop coordinate
## space. Two rects per monitor because the future server-composited case
## has a packed canvas whose geometry differs from the real desktop; the
## client-split case (this branch) simply satisfies desktop_rect ==
## frame_rect, so no code anywhere needs to special-case which produced it.

class MonitorSpec:
	extends RefCounted
	var id: StringName = &""          # stable; NEVER re-derive from index
	var label: String = ""
	var enabled: bool = true
	var is_primary: bool = false
	var frame_rect: Rect2i = Rect2i()    # px within the ENCODED FRAME
	var desktop_rect: Rect2i = Rect2i()  # px in HOST VIRTUAL-DESKTOP coords
	var hint: Dictionary = {}

	func to_dict() -> Dictionary:
		return {
			"id": String(id),
			"label": label,
			"enabled": enabled,
			"is_primary": is_primary,
			"frame_rect": [frame_rect.position.x, frame_rect.position.y, frame_rect.size.x, frame_rect.size.y],
			"desktop_rect": [desktop_rect.position.x, desktop_rect.position.y, desktop_rect.size.x, desktop_rect.size.y],
			"hint": hint,
		}

	static func from_dict(d: Dictionary) -> MonitorSpec:
		var m := MonitorSpec.new()
		m.id = StringName(d.get("id", ""))
		m.label = d.get("label", "")
		m.enabled = d.get("enabled", true)
		m.is_primary = d.get("is_primary", false)
		var fr: Array = d.get("frame_rect", [0, 0, 0, 0])
		m.frame_rect = Rect2i(fr[0], fr[1], fr[2], fr[3])
		var dr: Array = d.get("desktop_rect", fr)
		m.desktop_rect = Rect2i(dr[0], dr[1], dr[2], dr[3])
		m.hint = d.get("hint", {})
		return m

var version: int = 1
var source: StringName = &"client_split"   # later: &"host_manifest"
var frame_size: Vector2i = Vector2i.ZERO
var desktop_bounds: Rect2i = Rect2i()
var monitors: Array[MonitorSpec] = []

func to_dict() -> Dictionary:
	var mons := []
	for m in monitors:
		mons.append(m.to_dict())
	return {
		"version": version,
		"source": String(source),
		"frame_size": [frame_size.x, frame_size.y],
		"desktop_bounds": [desktop_bounds.position.x, desktop_bounds.position.y, desktop_bounds.size.x, desktop_bounds.size.y],
		"monitors": mons,
	}

static func from_dict(d: Dictionary) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.version = d.get("version", 1)
	l.source = StringName(d.get("source", "client_split"))
	var fs: Array = d.get("frame_size", [1920, 1080])
	l.frame_size = Vector2i(fs[0], fs[1])
	var db: Array = d.get("desktop_bounds", [0, 0, fs[0], fs[1]])
	l.desktop_bounds = Rect2i(db[0], db[1], db[2], db[3])
	l.monitors = []
	for md in d.get("monitors", []):
		l.monitors.append(MonitorSpec.from_dict(md))
	return l

## Identity layout: one monitor filling the whole frame. This is what N=1
## uses, so N=1 goes through the exact same code path as N>1 from commit 1.
static func single(frame: Vector2i) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.frame_size = frame
	l.desktop_bounds = Rect2i(0, 0, frame.x, frame.y)
	var m := MonitorSpec.new()
	m.id = &"m0"
	m.label = "Display"
	m.enabled = true
	m.is_primary = true
	m.frame_rect = Rect2i(0, 0, frame.x, frame.y)
	m.desktop_rect = m.frame_rect
	l.monitors = [m]
	return l

## Even horizontal split into n equal-width monitors, left to right.
static func split_h(frame: Vector2i, n: int) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.frame_size = frame
	l.desktop_bounds = Rect2i(0, 0, frame.x, frame.y)
	var w := int(frame.x / float(n))
	for i in range(n):
		var m := MonitorSpec.new()
		m.id = StringName("m%d" % i)
		m.label = "Display %d" % (i + 1)
		m.enabled = true
		m.is_primary = (i == 0)
		var x := i * w
		var this_w := w if i < n - 1 else (frame.x - x)   # last tile absorbs rounding remainder
		m.frame_rect = Rect2i(x, 0, this_w, frame.y)
		m.desktop_rect = m.frame_rect
		l.monitors.append(m)
	return l

func get_primary() -> MonitorSpec:
	for m in monitors:
		if m.is_primary and m.enabled:
			return m
	for m in monitors:
		if m.enabled:
			return m
	return null

func enabled_monitors() -> Array[MonitorSpec]:
	var out: Array[MonitorSpec] = []
	for m in monitors:
		if m.enabled:
			out.append(m)
	return out

## "" if valid, else a human-readable reason. Callers must treat any
## non-empty string as "do not apply this layout".
func validate(frame: Vector2i) -> String:
	if monitors.is_empty():
		return "layout has no monitors"
	var enabled := enabled_monitors()
	if enabled.is_empty():
		return "layout has no enabled monitors"
	var primary_count := 0
	for m in enabled:
		if m.is_primary:
			primary_count += 1
		if m.frame_rect.size.x < 64 or m.frame_rect.size.y < 64:
			return "monitor %s frame_rect too small (%dx%d)" % [String(m.id), m.frame_rect.size.x, m.frame_rect.size.y]
		var frame_bounds := Rect2i(0, 0, frame.x, frame.y)
		if not frame_bounds.encloses(m.frame_rect):
			return "monitor %s frame_rect %s outside frame %s" % [String(m.id), str(m.frame_rect), str(frame_bounds)]
	if primary_count != 1:
		return "expected exactly 1 primary monitor, found %d" % primary_count
	if desktop_bounds.size.x > 32767 or desktop_bounds.size.y > 32767:
		return "desktop_bounds %s exceeds int16 range used by LiSendMousePositionEvent" % str(desktop_bounds.size)
	return ""

## Proportional remap when the stream resolution changes but the aspect
## ratio is unchanged (see "Mid-session resolution change" below). Caller
## must re-run validate() on the result before applying it.
func rescale_to(new_frame: Vector2i) -> ScreenLayout:
	var l := ScreenLayout.new()
	l.version = version
	l.source = source
	l.frame_size = new_frame
	var sx := float(new_frame.x) / float(frame_size.x) if frame_size.x > 0 else 1.0
	var sy := float(new_frame.y) / float(frame_size.y) if frame_size.y > 0 else 1.0
	l.desktop_bounds = Rect2i(
		desktop_bounds.position.x, desktop_bounds.position.y,
		int(desktop_bounds.size.x * sx), int(desktop_bounds.size.y * sy)
	)
	for m in monitors:
		var nm := MonitorSpec.new()
		nm.id = m.id
		nm.label = m.label
		nm.enabled = m.enabled
		nm.is_primary = m.is_primary
		nm.frame_rect = Rect2i(
			int(m.frame_rect.position.x * sx), int(m.frame_rect.position.y * sy),
			int(m.frame_rect.size.x * sx), int(m.frame_rect.size.y * sy)
		)
		nm.desktop_rect = Rect2i(
			int(m.desktop_rect.position.x * sx), int(m.desktop_rect.position.y * sy),
			int(m.desktop_rect.size.x * sx), int(m.desktop_rect.size.y * sy)
		)
		nm.hint = m.hint
		l.monitors.append(nm)
	return l

## The uv_region shader uniform for one monitor: xy = offset, zw = scale,
## both normalized 0..1 against frame_size.
func uv_region_for(m: MonitorSpec) -> Vector4:
	return Vector4(
		float(m.frame_rect.position.x) / float(frame_size.x),
		float(m.frame_rect.position.y) / float(frame_size.y),
		float(m.frame_rect.size.x) / float(frame_size.x),
		float(m.frame_rect.size.y) / float(frame_size.y),
	)

## Maps a screen-local UV (0..1 across that monitor's own tile) to an
## absolute point in host virtual-desktop pixel coordinates. This is the
## single source of truth for mouse mapping (Phase D2).
func uv_to_host_point(m: MonitorSpec, uv: Vector2) -> Vector2i:
	return Vector2i(
		m.desktop_rect.position.x + int(uv.x * m.desktop_rect.size.x),
		m.desktop_rect.position.y + int(uv.y * m.desktop_rect.size.y),
	)

## The reference width/height to pass as ref_w/ref_h to
## send_mouse_position_event alongside uv_to_host_point's result.
func host_ref() -> Vector2i:
	return desktop_bounds.size
```

### B2 — `uv_region` in both shaders

**Replace the entire contents of `src/shaders/stereo_screen.gdshader`** with:

```glsl
shader_type spatial;
render_mode unshaded;

uniform sampler2D main_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D depth_texture : hint_default_white, filter_linear_mipmap;
uniform int stereo_mode = 0;
uniform float convergence = 0.5;
uniform float balance_shift = 0.5;
uniform int filter_mode = 0;
uniform float sharpen = 0.0;

uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_u : filter_linear, repeat_disable;
uniform sampler2D tex_v : filter_linear, repeat_disable;
uniform int yuv_mode = 0;
uniform int color_matrix_type = 1;
uniform int color_range = 0;
uniform float blur_scale = 1.0;

// xy = offset into the encoded frame (0..1), zw = this tile's size (0..1).
// Identity (0,0,1,1) reproduces pre-multi-monitor behaviour exactly.
uniform vec4 uv_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 tile_inset = vec2(0.002);

vec3 yuv_to_rgb(vec2 uv) {
	float y_raw = texture(tex_y, uv).r;
	float u_raw = 0.5;
	float v_raw = 0.5;

	if (yuv_mode == 1) {
		ivec2 tex_size = textureSize(tex_u, 0);
		int cx = int(uv.x * float(tex_size.x / 2));
		int cy = int(uv.y * float(tex_size.y));
		cx = clamp(cx, 0, tex_size.x / 2 - 1);
		cy = clamp(cy, 0, tex_size.y - 1);
		u_raw = texelFetch(tex_u, ivec2(cx * 2, cy), 0).r;
		v_raw = texelFetch(tex_u, ivec2(cx * 2 + 1, cy), 0).r;
	} else if (yuv_mode == 2) {
		vec2 uv_val = texture(tex_u, uv).rg;
		u_raw = uv_val.r;
		v_raw = uv_val.g;
	} else if (yuv_mode == 3) {
		u_raw = texture(tex_u, uv).r;
		v_raw = texture(tex_v, uv).r;
	}

	float y, u, v;

	if (color_range == 0) {
		y = (y_raw - 16.0/255.0) * (255.0/219.0);
		u = (u_raw - 128.0/255.0) * (255.0/224.0);
		v = (v_raw - 128.0/255.0) * (255.0/224.0);
	} else {
		y = y_raw;
		u = u_raw - 0.5;
		v = v_raw - 0.5;
	}

	vec3 rgb = vec3(0.0);

	if (color_matrix_type == 1) {
		rgb.r = y + 1.5748 * v;
		rgb.g = y - 0.1873 * u - 0.4681 * v;
		rgb.b = y + 1.8556 * u;
	} else if (color_matrix_type == 2) {
		rgb.r = y + 1.4746 * v;
		rgb.g = y - 0.16455 * u - 0.57135 * v;
		rgb.b = y + 1.8814 * u;
	} else {
		rgb.r = y + 1.402 * v;
		rgb.g = y - 0.344136 * u - 0.714136 * v;
		rgb.b = y + 1.772 * u;
	}

	return rgb;
}

vec3 srgb_to_linear(vec3 c) {
	return pow(c, vec3(2.2));
}

// Maps a tile-local coordinate (0..1 across THIS monitor) into the encoded
// frame (0..1 across the whole decoded texture). tile_inset preserves the
// original 0.2% edge guard, now measured in tile-local units.
vec2 to_frame_uv(vec2 t) {
	return uv_region.xy + clamp(t, tile_inset, vec2(1.0) - tile_inset) * uv_region.zw;
}

// Clamps an already-frame-space UV to stay within this tile's region, with
// a half-texel inset so linear filtering never samples the neighbouring
// monitor's pixels across the seam.
vec2 clamp_to_region(vec2 f) {
	vec2 ts = (yuv_mode > 0) ? vec2(textureSize(tex_y, 0)) : vec2(textureSize(main_texture, 0));
	vec2 guard = 0.5 / ts;
	return clamp(f, uv_region.xy + guard, uv_region.xy + uv_region.zw - guard);
}

// Single choke point for every stream read. Every filter tap in
// cas_sharpen_stream() and filtered_stream() routes through this, so all of
// them get tile-clamped for free.
vec3 sample_stream(vec2 uv) {
	uv = clamp_to_region(uv);
	if (yuv_mode > 0) {
		return srgb_to_linear(yuv_to_rgb(uv));
	}
	return texture(main_texture, uv).rgb;
}

vec3 cas_sharpen_stream(vec2 uv, float strength) {
	vec2 texel = 1.0 / vec2(textureSize(tex_y, 0)) * blur_scale;

	vec3 c = sample_stream(uv);
	vec3 n = sample_stream(uv + vec2( 0.0, -texel.y));
	vec3 w = sample_stream(uv + vec2(-texel.x,  0.0));
	vec3 e = sample_stream(uv + vec2( texel.x,  0.0));
	vec3 s = sample_stream(uv + vec2( 0.0,  texel.y));

	vec3 mn = min(c, min(n, min(w, min(e, s))));
	vec3 mx = max(c, max(n, max(w, max(e, s))));
	vec3 range = mx - mn;

	vec3 peak = max(mx, vec3(0.0001));
	vec3 weight = vec3(strength) * clamp((peak - range) / peak, vec3(0.0), vec3(1.0));

	vec3 avg = (n + w + e + s) * 0.25;
	return c + weight * (c - avg);
}

// filtered_stream() now handles BOTH yuv and rgb via sample_stream(), so
// the old separate cas_sharpen_rgb() / rgb branch of filtered_stream() are
// deleted -- they used to bypass clamp_to_region entirely, which would have
// bled across tile seams.
vec3 filtered_stream(vec2 uv) {
	vec3 original = sample_stream(uv);

	if (filter_mode == 0 && sharpen <= 0.0) {
		return original;
	}

	vec2 texel = (yuv_mode > 0)
		? 1.0 / vec2(textureSize(tex_y, 0)) * blur_scale
		: 1.0 / vec2(textureSize(main_texture, 0)) * blur_scale;

	if (filter_mode > 0) {
		float s = float(filter_mode) * 4.0;
		vec3 blurred = original * 4.0;
		blurred += sample_stream(uv + vec2(-1.0, -1.0) * texel * s);
		blurred += sample_stream(uv + vec2( 1.0, -1.0) * texel * s);
		blurred += sample_stream(uv + vec2(-1.0,  1.0) * texel * s);
		blurred += sample_stream(uv + vec2( 1.0,  1.0) * texel * s);
		blurred += sample_stream(uv + vec2(-1.0,  0.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 1.0,  0.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 0.0, -1.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 0.0,  1.0) * texel * s) * 2.0;
		blurred /= 16.0;
		if (sharpen > 0.0) {
			return blurred + sharpen * (original - blurred);
		}
		return blurred;
	}

	return cas_sharpen_stream(uv, sharpen);
}

void fragment() {
	vec2 tile_uv = UV;

	if (stereo_mode == 1) {
		tile_uv = (int(VIEW_INDEX) == 0)
			? vec2(tile_uv.x * 0.5, tile_uv.y)
			: vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y);
	} else if (stereo_mode == 2) {
		tile_uv = (int(VIEW_INDEX) == 0)
			? vec2(tile_uv.x * 0.5, tile_uv.y * 0.5 + 0.25)
			: vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y * 0.5 + 0.25);
	}

	vec2 uv = to_frame_uv(tile_uv);

	if (stereo_mode == 0 || stereo_mode == 1 || stereo_mode == 2) {
		ALBEDO = filtered_stream(uv);
	}
	else if (stereo_mode == 3 || stereo_mode == 4) {
		vec2 depth_texel = 1.0 / vec2(textureSize(depth_texture, 0));
		float parallax = 0.042;
		float half_parallax = parallax * 0.5;

		vec2 depth_uv = uv - vec2(half_parallax, 0.0);
		depth_uv = clamp(depth_uv, vec2(0.0), vec2(1.0));
		float depth = texture(depth_texture, depth_uv).r;

		float depth_diff = clamp(depth - convergence, -convergence, 1.0 - convergence);

		float dist_from_convergence = abs(depth - convergence);
		float zone_radius = 0.70;
		float fade_multiplier = smoothstep(0.0, zone_radius, dist_from_convergence);
		depth_diff *= fade_multiplier;

		float shift = parallax * depth_diff;

		bool is_left = (int(VIEW_INDEX) == 0);
		float eye_sign = is_left ? -1.0 : 1.0;

		if ((depth - convergence) < 0.0) {
			shift *= is_left ? balance_shift : (1.0 - balance_shift);
		} else {
			shift *= is_left ? (1.0 - balance_shift) : balance_shift;
		}

		float edge_width = 3.0 * depth_texel.x;
		float depth_left = texture(depth_texture, vec2(edge_width, 0.5)).r;
		float depth_right = texture(depth_texture, vec2(1.0 - edge_width, 0.5)).r;
		float max_edge_shift = max(abs(depth_left - convergence), abs(depth_right - convergence));
		float max_shift_possible = parallax * max_edge_shift;
		float vignette_bias = (convergence - 0.5) * 0.3;
		float vignette_start = mix(0.7 - vignette_bias, 1.0 - vignette_bias, clamp(max_shift_possible / 0.05, 0.0, 1.0));

		float h_dist = abs(uv.x - 0.5) * 2.0;
		float vignette = 1.0 - smoothstep(vignette_start, 1.0, pow(h_dist, 1.5));

		shift *= vignette;

		vec2 src_uv = vec2(clamp(uv.x - shift * eye_sign, 0.0, 1.0), uv.y);
		ALBEDO = filtered_stream(src_uv);
	}
}
```

Key differences from the original, all intentional:
- `uv_region`/`tile_inset` uniforms added; `to_frame_uv()`/`clamp_to_region()` added.
- The old `vec2 uv = clamp(UV, vec2(0.002), vec2(0.998));` (edge guard on the *whole texture*) is now
  `to_frame_uv(tile_uv)` (edge guard on the *tile*, then mapped into frame space) — at
  `uv_region = (0,0,1,1)` these produce byte-identical results.
- `cas_sharpen_rgb()` and the RGB branch of `filtered_stream()` are deleted; `sample_stream()` already
  handled `yuv_mode == 0` (the original line 82 `return texture(main_texture, uv).rgb;`), so
  `filtered_stream()` collapses to one code path with texel size selected by `yuv_mode`.
- SBS modes 1/2 now compose the eye-split **before** `to_frame_uv`, on `tile_uv`, so a tile's own SBS still
  works (this is untested territory for N>1 — see "SBS when N>1" below, which restricts it to primary in
  the UI, but the shader itself supports it per-tile with no extra work).
- DIBR (mode 3/4) is otherwise untouched; `depth_uv`/vignette math still operates on frame-space `uv`, which
  is correct only when depth is bound per-tile (Phase C4) — until C4 lands, DIBR + N>1 is not a supported
  combination (see Feature-interaction decisions).

**Replace the entire contents of `src/shaders/yuv_display.gdshader`** with:

```glsl
shader_type canvas_item;

uniform sampler2D tex_y : filter_linear, repeat_disable;
uniform sampler2D tex_u : filter_linear, repeat_disable;
uniform sampler2D tex_v : filter_linear, repeat_disable;
uniform int yuv_mode = 0;
uniform int color_matrix_type = 1;
uniform int color_range = 0;
uniform sampler2D main_texture : source_color, filter_linear, repeat_disable;
uniform int filter_mode = 0;
uniform float sharpen = 0.0;
uniform float blur_scale = 1.0;
uniform int stereo_mode = 0;
uniform int eye_index = 0;
uniform sampler2D depth_texture : hint_default_white, filter_linear, repeat_disable;
uniform float convergence = 0.5;
uniform float balance_shift = 0.5;

uniform vec4 uv_region = vec4(0.0, 0.0, 1.0, 1.0);
uniform vec2 tile_inset = vec2(0.002);

vec3 yuv_to_rgb(vec2 uv) {
	if (color_matrix_type == 3) {
		// RGBA passthrough - data was converted from BGRA in C++
		return texture(tex_y, uv).rgb;
	}

	float y_raw = texture(tex_y, uv).r;
	float u_raw = 0.5;
	float v_raw = 0.5;

	if (yuv_mode == 1) {
		ivec2 tex_size = textureSize(tex_u, 0);
		int cx = int(uv.x * float(tex_size.x / 2));
		int cy = int(uv.y * float(tex_size.y));
		cx = clamp(cx, 0, tex_size.x / 2 - 1);
		cy = clamp(cy, 0, tex_size.y - 1);
		u_raw = texelFetch(tex_u, ivec2(cx * 2, cy), 0).r;
		v_raw = texelFetch(tex_u, ivec2(cx * 2 + 1, cy), 0).r;
	} else if (yuv_mode == 2) {
		vec2 uv_val = texture(tex_u, uv).rg;
		u_raw = uv_val.r;
		v_raw = uv_val.g;
	} else if (yuv_mode == 3) {
		u_raw = texture(tex_u, uv).r;
		v_raw = texture(tex_v, uv).r;
	}

	float y, u, v;

	if (color_range == 0) {
		y = (y_raw - 16.0/255.0) * (255.0/219.0);
		u = (u_raw - 128.0/255.0) * (255.0/224.0);
		v = (v_raw - 128.0/255.0) * (255.0/224.0);
	} else {
		y = y_raw;
		u = u_raw - 0.5;
		v = v_raw - 0.5;
	}

	vec3 rgb = vec3(0.0);

	if (color_matrix_type == 1) {
		rgb.r = y + 1.5748 * v;
		rgb.g = y - 0.1873 * u - 0.4681 * v;
		rgb.b = y + 1.8556 * u;
	} else if (color_matrix_type == 2) {
		rgb.r = y + 1.4746 * v;
		rgb.g = y - 0.16455 * u - 0.57135 * v;
		rgb.b = y + 1.8814 * u;
	} else {
		rgb.r = y + 1.402 * v;
		rgb.g = y - 0.344136 * u - 0.714136 * v;
		rgb.b = y + 1.772 * u;
	}

	return rgb;
}

vec2 to_frame_uv(vec2 t) {
	return uv_region.xy + clamp(t, tile_inset, vec2(1.0) - tile_inset) * uv_region.zw;
}

vec2 clamp_to_region(vec2 f) {
	vec2 ts = (yuv_mode > 0) ? vec2(textureSize(tex_y, 0)) : vec2(textureSize(main_texture, 0));
	vec2 guard = 0.5 / ts;
	return clamp(f, uv_region.xy + guard, uv_region.xy + uv_region.zw - guard);
}

vec3 sample_stream(vec2 uv) {
	uv = clamp_to_region(uv);
	if (yuv_mode > 0) {
		return yuv_to_rgb(uv);
	}
	return texture(main_texture, uv).rgb;
}

vec3 filtered_stream(vec2 uv) {
	vec3 original = sample_stream(uv);
	if (filter_mode == 0 && sharpen <= 0.0) {
		return original;
	}
	vec2 texel = 1.0 / vec2(textureSize(tex_y, 0)) * blur_scale;
	if (yuv_mode == 0) {
		texel = 1.0 / vec2(textureSize(main_texture, 0)) * blur_scale;
	}
	if (filter_mode > 0) {
		float s = float(filter_mode) * 0.3;
		vec3 blurred = original * 4.0;
		blurred += sample_stream(uv + vec2(-1.0, -1.0) * texel * s);
		blurred += sample_stream(uv + vec2( 1.0, -1.0) * texel * s);
		blurred += sample_stream(uv + vec2(-1.0,  1.0) * texel * s);
		blurred += sample_stream(uv + vec2( 1.0,  1.0) * texel * s);
		blurred += sample_stream(uv + vec2(-1.0,  0.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 1.0,  0.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 0.0, -1.0) * texel * s) * 2.0;
		blurred += sample_stream(uv + vec2( 0.0,  1.0) * texel * s) * 2.0;
		blurred /= 16.0;
		if (sharpen > 0.0) {
			return blurred + sharpen * (original - blurred);
		}
		return blurred;
	}
	vec3 n = sample_stream(uv + vec2( 0.0, -texel.y));
	vec3 w = sample_stream(uv + vec2(-texel.x,  0.0));
	vec3 e = sample_stream(uv + vec2( texel.x,  0.0));
	vec3 s = sample_stream(uv + vec2( 0.0,  texel.y));
	vec3 mn = min(original, min(n, min(w, min(e, s))));
	vec3 mx = max(original, max(n, max(w, max(e, s))));
	vec3 range = mx - mn;
	vec3 peak = max(mx, vec3(0.0001));
	vec3 weight = vec3(sharpen) * clamp((peak - range) / peak, vec3(0.0), vec3(1.0));
	vec3 avg = (n + w + e + s) * 0.25;
	return original + weight * (original - avg);
}

void fragment() {
	vec2 tile_uv = UV;

	if (stereo_mode == 1) {
		tile_uv = (eye_index == 1) ? vec2(tile_uv.x * 0.5, tile_uv.y) : vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y);
	} else if (stereo_mode == 2) {
		tile_uv = (eye_index == 1) ? vec2(tile_uv.x * 0.5, tile_uv.y * 0.5 + 0.25) : vec2(tile_uv.x * 0.5 + 0.5, tile_uv.y * 0.5 + 0.25);
	}

	vec2 uv = to_frame_uv(tile_uv);

	if (stereo_mode >= 3) {
		vec2 depth_texel = 1.0 / vec2(textureSize(depth_texture, 0));
		float parallax = 0.042;
		float half_parallax = parallax * 0.5;

		vec2 depth_uv = uv - vec2(half_parallax, 0.0);
		depth_uv = clamp(depth_uv, vec2(0.0), vec2(1.0));
		float depth = texture(depth_texture, depth_uv).r;

		float depth_diff = clamp(depth - convergence, -convergence, 1.0 - convergence);
		float dist_from_convergence = abs(depth - convergence);
		float zone_radius = 0.70;
		float fade_multiplier = smoothstep(0.0, zone_radius, dist_from_convergence);
		depth_diff *= fade_multiplier;

		float shift = parallax * depth_diff;
		bool is_left = (eye_index == 1);
		float eye_sign = is_left ? -1.0 : 1.0;

		if ((depth - convergence) < 0.0) {
			shift *= is_left ? balance_shift : (1.0 - balance_shift);
		} else {
			shift *= is_left ? (1.0 - balance_shift) : balance_shift;
		}

		float edge_width = 3.0 * depth_texel.x;
		float depth_left = texture(depth_texture, vec2(edge_width, 0.5)).r;
		float depth_right = texture(depth_texture, vec2(1.0 - edge_width, 0.5)).r;
		float max_edge_shift = max(abs(depth_left - convergence), abs(depth_right - convergence));
		float max_shift_possible = parallax * max_edge_shift;
		float vignette_bias = (convergence - 0.5) * 0.3;
		float vignette_start = mix(0.7 - vignette_bias, 1.0 - vignette_bias, clamp(max_shift_possible / 0.05, 0.0, 1.0));

		float h_dist = abs(uv.x - 0.5) * 2.0;
		float vignette = 1.0 - smoothstep(vignette_start, 1.0, pow(h_dist, 1.5));

		shift *= vignette;

		uv = vec2(clamp(uv.x - shift * eye_sign, 0.0, 1.0), uv.y);
	}

	if (filter_mode > 0 || sharpen > 0.0) {
		vec3 col = filtered_stream(uv);
		COLOR = vec4(col, 1.0);
	} else if (yuv_mode > 0) {
		COLOR = vec4(yuv_to_rgb(clamp_to_region(uv)), 1.0);
	} else {
		COLOR = texture(main_texture, clamp_to_region(uv));
	}
}
```

Same pattern as the spatial shader: `uv_region`/`tile_inset` added, `to_frame_uv()`/`clamp_to_region()`
added, and the two direct-sample fallback branches at the end of `fragment()` (`yuv_to_rgb(uv)` and
`texture(main_texture, uv)`) now route through `clamp_to_region()` — in the original these bypassed the
clamp entirely (Plan agent finding: `yuv_display.gdshader:183` `COLOR = vec4(yuv_to_rgb(uv), 1.0)` skipped
the edge guard).

**Verify:**
```bash
godot --headless --check-only . 2>&1 | grep -i "shader\|error"   # expect: no shader compile errors
```
Since `uv_region` defaults to `(0,0,1,1)` and `tile_inset` defaults to `(0.002,0.002)`, no GDScript needs
to change yet for this commit to be a no-op visually. Run the app and confirm the stream, SBS Stretch/Crop,
and AI-3D all look pixel-identical to before this commit.

### B3 — Unify `blur_scale`, then make it per-tile

There are **three** writers today and they disagree: `src/stream_manager.gd:194-196` uses the actual
decoded width; `src/settings_controller.gd:206` and `main.gd:1168` both use the *requested*
`host_resolution.x`. Since `apply_filter()` runs from `switch_to_comp_layer()`
(`composition_layer_manager.gd:600` in the pre-refactor file), the comp path effectively always uses the
requested width — a pre-existing bug, fixed here as a side effect of unifying.

1. In `main.gd`, add one new helper. Find (near `_get_steady_hit`, currently around `main.gd:279`):
   ```gdscript
   func _get_steady_hit(raw: Vector3) -> Vector3:
   ```
   Insert immediately **before** this line:
   ```gdscript
   func get_blur_scale(s: VRScreen) -> float:
   	if _xr_render_width <= 0:
   		return 1.0
   	return (s.uv_region.z * float(stream_viewport.size.x)) / float(_xr_render_width)

   func _get_steady_hit(raw: Vector3) -> Vector3:
   ```

2. In `src/stream_manager.gd`, function `resize_stream_viewport()`, find:
   ```gdscript
   	main.screen_manager.resize_screen_to_aspect(w, h)
   	if main._xr_render_width > 0 and main.screen_mesh.material_override is ShaderMaterial:
   		var scale = float(w) / float(main._xr_render_width)
   		main.screen_mesh.material_override.set_shader_parameter("blur_scale", scale)
   	main._log("[STREAM] Viewport resized to %dx%d (blur_scale=%.2f)" % [w, h, float(w) / float(main._xr_render_width) if main._xr_render_width > 0 else 1.0])
   ```
   Replace with:
   ```gdscript
   	main.screen_manager.resize_screen_to_aspect(w, h)
   	if main.screen_mesh.material_override is ShaderMaterial:
   		main.screen_mesh.material_override.set_shader_parameter("blur_scale", main.get_blur_scale(main.primary_screen))
   	main._log("[STREAM] Viewport resized to %dx%d (blur_scale=%.2f)" % [w, h, main.get_blur_scale(main.primary_screen)])
   ```

3. In `src/settings_controller.gd`, function `apply_filter()`, find:
   ```gdscript
   func apply_filter():
   	if not main.is_xr_active:
   		return
   	var filter_val = main.smooth_mode
   	var sharp_val = float(main.sharpen_mode) * 0.5
   	var blur_scale_val = float(main.host_resolution.x) / float(main._xr_render_width) if main._xr_render_width > 0 else 1.0
   	var mat = main.screen_mesh.material_override
   	if mat and mat is ShaderMaterial:
   		mat.set_shader_parameter("filter_mode", filter_val)
   		mat.set_shader_parameter("sharpen", sharp_val)
   		mat.set_shader_parameter("blur_scale", blur_scale_val)
   	var comp_mats = [main.comp_shader_mat, main.comp_shader_mat_left, main.comp_shader_mat_right]
   	for cm in comp_mats:
   		if cm:
   			cm.set_shader_parameter("filter_mode", filter_val)
   			cm.set_shader_parameter("sharpen", sharp_val)
   			cm.set_shader_parameter("blur_scale", blur_scale_val)
   ```
   Replace with:
   ```gdscript
   func apply_filter():
   	if not main.is_xr_active:
   		return
   	var filter_val = main.smooth_mode
   	var sharp_val = float(main.sharpen_mode) * 0.5
   	var mat = main.screen_mesh.material_override
   	if mat and mat is ShaderMaterial:
   		mat.set_shader_parameter("filter_mode", filter_val)
   		mat.set_shader_parameter("sharpen", sharp_val)
   		mat.set_shader_parameter("blur_scale", main.get_blur_scale(main.primary_screen))
   	for s in main.screens:
   		for cm in main.comp.get_shader_mats(s):
   			if cm:
   				cm.set_shader_parameter("filter_mode", filter_val)
   				cm.set_shader_parameter("sharpen", sharp_val)
   				cm.set_shader_parameter("blur_scale", main.get_blur_scale(s))
   ```

4. In `main.gd`, function `_process_stats()`, find:
   ```gdscript
   	if comp.in_use:
   		var cur_filter = smooth_mode
   		var cur_sharpen = float(sharpen_mode) * 0.5
   		var cur_blur_scale = float(host_resolution.x) / float(_xr_render_width) if _xr_render_width > 0 else 1.0
   		if cur_filter != _cached_filter_mode or cur_sharpen != _cached_sharpen or cur_blur_scale != _cached_blur_scale:
   ```
   Replace with:
   ```gdscript
   	if comp.in_use:
   		var cur_filter = smooth_mode
   		var cur_sharpen = float(sharpen_mode) * 0.5
   		var cur_blur_scale = get_blur_scale(primary_screen)
   		if cur_filter != _cached_filter_mode or cur_sharpen != _cached_sharpen or cur_blur_scale != _cached_blur_scale:
   ```

5. `comp_base_size` is already per-`VRScreen` since A3/A5 (`s.comp_base_size`). Wire it to the monitor's
   tile size once a real layout exists — this happens naturally in C1/C2 when `resize_stream_viewport()` is
   made layout-aware; no separate action needed in B3.

**Verify:**
```bash
grep -rn "host_resolution.x) / float(main._xr_render_width\|host_resolution.x) / float(_xr_render_width" src/ main.gd
# expect: ZERO matches -- every blur_scale computation now goes through get_blur_scale()
```
Run the app: cycle through Blur (0-50%) and Sharpen sliders at a couple of resolutions; the blur amount
should look the same as before this commit (since at N=1, `get_blur_scale()` reduces to `stream_w /
_xr_render_width`, which is what `stream_manager.gd` already used — the fix specifically corrects
`settings_controller.gd`'s and `main.gd`'s stale-request-width readings to match).

---

## Phase C — N screens rendering

### C1 — `res://src/vr_screen.tscn` + instancing (mesh path first)

**Do this on Linux/PCVR first** (`./build.sh --appimage`, mesh path only — no layer budget, no swapchains,
faster iteration than an APK install).

1. Extract the screen subtree into its own scene file. In the Godot editor: select the `MeshInstance3D`
   node (the one with `VRScreen` attached) in `main.tscn`, right-click → **Save Branch as Scene**, save as
   `res://src/vr_screen.tscn`. This keeps `%ScreenGrabBar`'s `unique_name_in_owner` flag intact, now scoped
   to `vr_screen.tscn`'s own root — the whole point of doing A2 first is that no code anywhere depends on
   `%ScreenGrabBar` resolving through `main`'s scene anymore, so this extraction is safe.
2. Back in `main.tscn`, the node is now an instance of `vr_screen.tscn` rather than an inline node — verify
   its `script` is still `vr_screen.gd` (Godot keeps the script when you "Save Branch as Scene" since the
   script lives on the instanced scene's root, not on the referencing node).
3. **Verify the `ShaderMaterial_1` local-to-scene fix survived** (set in A1 step 3) — open `vr_screen.tscn`
   as text and confirm `resource_local_to_scene = true` is still present on its `ShaderMaterial`
   sub-resource. If the editor stripped it during the branch-save, re-add it now, plus add a defensive
   runtime duplicate as a second line of defense. In `src/vr_screen.gd`, find:
   ```gdscript
   func _ready() -> void:
   	set_meta(&"nf_role", &"screen")
   	grab_bar.set_meta(&"nf_role", &"grab_bar")
   ```
   Replace with:
   ```gdscript
   func _ready() -> void:
   	set_meta(&"nf_role", &"screen")
   	grab_bar.set_meta(&"nf_role", &"grab_bar")
   	if material_override:
   		material_override = material_override.duplicate()
   ```
4. In `main.gd`, add screen instancing helpers. Find `func _init_ui():` and, **after** the whole function
   body (i.e. immediately before the next `func` declaration, which is `func _init_stream_backend():`),
   insert:
   ```gdscript
   const VR_SCREEN_SCENE := preload("res://src/vr_screen.tscn")
   const MAX_SCREENS := 4

   func add_screen(monitor_id: StringName) -> VRScreen:
   	if screens.size() >= MAX_SCREENS:
   		_log("[SCREEN] Refusing to add screen %s: MAX_SCREENS=%d reached" % [String(monitor_id), MAX_SCREENS])
   		return null
   	var s: VRScreen = VR_SCREEN_SCENE.instantiate()
   	add_child(s)
   	s.setup(self, monitor_id)
   	s.mesh_size = primary_screen.mesh_size if primary_screen else Vector2(2.24, 1.26)
   	s.curvature = primary_screen.curvature if primary_screen else 2
   	screen_manager.create_corner_handles_for(s)
   	screen_manager.create_bezel_for(s)
   	if comp.available:
   		comp.setup_screen(s)
   	screens.append(s)
   	_log("[SCREEN] Added screen %s (total=%d)" % [String(monitor_id), screens.size()])
   	return s

   func remove_screen(monitor_id: StringName) -> void:
   	for i in range(screens.size()):
   		if screens[i].monitor_id == monitor_id:
   			var s = screens[i]
   			if s == primary_screen:
   				_log("[SCREEN] Refusing to remove the primary screen %s" % String(monitor_id))
   				return
   			screens.remove_at(i)
   			s.queue_free()
   			_log("[SCREEN] Removed screen %s (total=%d)" % [String(monitor_id), screens.size()])
   			return
   ```
   This references `screen_manager.create_corner_handles_for(s)` / `create_bezel_for(s)`, added next.
5. In `src/screen_manager.gd`, add the per-screen variants (the existing `create_corner_handles()` /
   `create_bezel()` delegate to `main.primary_screen` — these new ones take an explicit screen). Find:
   ```gdscript
   func create_corner_handles():
   	main.primary_screen.create_corner_handles()
   ```
   Replace with:
   ```gdscript
   func create_corner_handles():
   	main.primary_screen.create_corner_handles()

   func create_corner_handles_for(s: VRScreen):
   	s.create_corner_handles()
   ```
6. Find:
   ```gdscript
   func create_bezel():
   	main.primary_screen.create_bezel()
   ```
   Replace with:
   ```gdscript
   func create_bezel():
   	main.primary_screen.create_bezel()

   func create_bezel_for(s: VRScreen):
   	s.create_bezel()
   ```

**Verify:**
```bash
ls src/vr_screen.tscn   # expect: exists
grep -n "resource_local_to_scene" src/vr_screen.tscn   # expect: at least 1 match
```
Manual test: with `main.screens.size() == 1` still (nothing calls `add_screen` yet), the app must behave
identically to end of Phase B. This commit only proves the extraction compiles and runs — layout-driven
instancing lands in C2/E.

### C2 — Per-screen composition layers (Quest)

`setup_screen()` (written in A5) already builds a full mono + stereo-pair comp-layer roster for whichever
screen it's given. Two changes here: (1) make the stereo pair **lazy** (only the primary screen gets one,
and only when SBS/AI-3D is actually on) to reclaim the swapchain budget non-primary screens need; (2) size
each screen's comp viewport to its own tile once a real layout exists (this second part is what the E-phase
layout application actually calls — record the hook now).

1. In `src/composition_layer_manager.gd`, function `setup_screen()`, the stereo-pair block currently always
   runs. Wrap it in a parameter. Find the function signature:
   ```gdscript
   func setup_screen(s: VRScreen):
   	if not available:
   		return
   ```
   Replace with:
   ```gdscript
   func setup_screen(s: VRScreen, with_stereo: bool = true):
   	if not available:
   		return
   ```
2. Find the point where the stereo-pair construction begins (right after the mono cursor rects are added,
   before `s.comp_cylinder_left = OpenXRCompositionLayerCylinder.new()`):
   ```gdscript
   	s.comp_stream_cursor_circle = _make_cursor_circle_rect()
   	s.comp_bezel_rect.add_child(s.comp_stream_cursor_circle)

   	s.comp_cylinder_left = OpenXRCompositionLayerCylinder.new()
   ```
   Replace with:
   ```gdscript
   	s.comp_stream_cursor_circle = _make_cursor_circle_rect()
   	s.comp_bezel_rect.add_child(s.comp_stream_cursor_circle)

   	s.comp_layer = s.comp_cylinder
   	s.comp_layer.set_layer_viewport(s.comp_viewport)
   	main._log("[COMP] Per-screen mono comp layer created (%s)" % s.monitor_id)

   	if not with_stereo:
   		return

   	s.comp_cylinder_left = OpenXRCompositionLayerCylinder.new()
   ```
3. Find the end of the function (the old finishing lines, now duplicated by the early-return above — remove
   the duplicate):
   ```gdscript
   	s.comp_cylinder_left.set_layer_viewport(s.comp_viewport_left)
   	s.comp_cylinder_right.set_layer_viewport(s.comp_viewport_right)

   	s.comp_layer = s.comp_cylinder
   	s.comp_layer.set_layer_viewport(s.comp_viewport)
   	main._log("[COMP] Per-screen comp layers created (%s)" % s.monitor_id)
   ```
   Replace with:
   ```gdscript
   	s.comp_cylinder_left.set_layer_viewport(s.comp_viewport_left)
   	s.comp_cylinder_right.set_layer_viewport(s.comp_viewport_right)
   	main._log("[COMP] Per-screen stereo comp layers created (%s)" % s.monitor_id)
   ```
4. Update the two callers of `setup_screen()` to say explicitly whether they want stereo. In `setup()`, find:
   ```gdscript
   	setup_screen(main.primary_screen)
   ```
   Replace with:
   ```gdscript
   	setup_screen(main.primary_screen, true)
   ```
   In `main.gd`'s `add_screen()` (added in C1), find:
   ```gdscript
   	if comp.available:
   		comp.setup_screen(s)
   ```
   Replace with:
   ```gdscript
   	if comp.available:
   		comp.setup_screen(s, false)
   ```
   (Non-primary screens never get a stereo pair in this branch — see "SBS when N>1" below. If a future
   commit lets a non-primary screen become primary, `setup_screen(s, true)` must be (re)called for it at
   that point; note this as a follow-up, not handled by this plan.)
5. **Budget log.** In `main.gd`'s `add_screen()`, after `_log("[SCREEN] Added screen ...")`, add:
   ```gdscript
   	var layer_count = screens.size() + 5  # N screens + UI + KB + 2 cursors + Godot's own projection layer
   	_log("[COMP] screens=%d layers=%d" % [screens.size(), layer_count])
   ```
6. **Graceful per-screen fallback.** In `add_screen()`, after `comp.setup_screen(s, false)`, add a check:
   ```gdscript
   	if comp.available and s.comp_cylinder and not s.comp_cylinder.is_natively_supported():
   		_log("[COMP] Screen %s cylinder not natively supported, falling back to mesh rendering for this screen" % String(monitor_id))
   ```
   (A full per-screen mesh-fallback *rendering path* is a larger change than this plan covers in one
   commit — this log line is the observability hook; treat an actual fallback renderer for a single screen
   as a fast-follow if this case is hit in practice on real hardware.)
7. **Per-tile comp viewport sizing.** This is exercised once E-phase applies a real `ScreenLayout`; the hook
   is `VRScreen.comp_base_size` (already present since A1) — `_update_bezel_for()` (A5) already reads
   `s.comp_base_size`, so setting `s.comp_base_size = monitor.frame_rect.size` from the layout-apply code in
   E1/E2 is sufficient. No additional change needed in this file.

**Verify:**
```bash
grep -n "func setup_screen" src/composition_layer_manager.gd   # expect: with_stereo parameter present
```
On Quest: confirm stereo (SBS/AI-3D) toggling on the primary screen still works exactly as before (this is
the load-bearing regression risk of this commit — the lazy stereo pair must still build correctly the first
time SBS is turned on for the primary). Read `user://debug.log` for the new `[COMP] screens=N layers=N+5`
line.

### C3 — Dirty-guard the per-frame YUV rebind

1. In `src/composition_layer_manager.gd`, add cache fields near the top of the class:
   ```gdscript
   var available: bool = false
   var in_use: bool = false
   ```
   Replace with:
   ```gdscript
   var available: bool = false
   var in_use: bool = false
   var _last_bind_rids: Array = []
   var _last_bind_mode: Array = [0, 1, 0]  # [yuv_mode, color_matrix_type, color_range]
   ```
2. In `bind_yuv_textures()`, find the branch that has real YUV textures:
   ```gdscript
   	if tex_y:
   		var yuv_mode_val = 0
   		if is_nv12_rd:
   			yuv_mode_val = 1
   		elif is_semi_planar:
   			yuv_mode_val = 2
   		else:
   			yuv_mode_val = 3
   		if not in_use and main.primary_screen.material_override is ShaderMaterial:
   ```
   Replace with:
   ```gdscript
   	if tex_y:
   		var yuv_mode_val = 0
   		if is_nv12_rd:
   			yuv_mode_val = 1
   		elif is_semi_planar:
   			yuv_mode_val = 2
   		else:
   			yuv_mode_val = 3
   		var rids = [tex_y.get_rid(), (tex_u.get_rid() if tex_u else RID()), (tex_v.get_rid() if tex_v else RID())]
   		var mode_tuple = [yuv_mode_val, cmt, cr]
   		var unchanged = (rids == _last_bind_rids and mode_tuple == _last_bind_mode)
   		if not in_use and main.primary_screen.material_override is ShaderMaterial:
   ```
3. Immediately before the call to `bind_comp_yuv_textures(...)` at the end of that branch, find:
   ```gdscript
   		main._log("[YUV] Direct YUV binding: mode=%d nv12_rd=%s semi_planar=%s" % [yuv_mode_val, str(is_nv12_rd), str(is_semi_planar)])
   		bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode_val, cmt, cr)
   ```
   Replace with:
   ```gdscript
   		if not unchanged:
   			main._log("[YUV] Direct YUV binding: mode=%d nv12_rd=%s semi_planar=%s" % [yuv_mode_val, str(is_nv12_rd), str(is_semi_planar)])
   			bind_comp_yuv_textures(tex_y, tex_u, tex_v, yuv_mode_val, cmt, cr)
   			_last_bind_rids = rids
   			_last_bind_mode = mode_tuple
   ```
   `Texture2DRD` RIDs change when the C++ `TextureUploader` reallocates on a decoder reconfigure (resolution
   change, HW upgrade, codec switch), so RID comparison is the correct invalidation trigger — it is *not*
   comparing frame content, only "did the texture objects themselves change", which happens far less than
   once per frame.

**Verify:**
```bash
grep -c "_last_bind_rids" src/composition_layer_manager.gd   # expect: >= 3
```
Run the app and confirm the stream still updates every frame visually (this guard must never suppress the
*content* update — only the redundant `set_shader_parameter` calls that re-set the same RID). A good manual
test: trigger a mid-stream resolution change (cycle Resolution in settings while connected) and confirm the
`[YUV] Direct YUV binding` log line reappears exactly once at that point, not every frame.

### C4 — Per-tile depth source

In `src/depth_estimator.gd`, function `bind_stream_texture()` (or equivalent — locate by searching for
`screen_mesh.material_override` / `comp_viewport` in that file), find the lines that choose the source
viewport:
```gdscript
	# (existing code binds main.comp_viewport or main.screen_mesh's viewport texture)
```
Replace any reference to `main.comp_viewport` with `main.primary_screen.comp_viewport`, and any reference to
`main.screen_mesh` (for the mesh-path texture source) with `main.primary_screen`. Since C2 already sizes
each screen's `comp_viewport` to its own tile via `comp_base_size`, this alone makes depth estimation
correct per-tile with no other change — depth is computed from whatever image is in the primary screen's
own viewport, which after E-phase layout application only contains that screen's tile.

**Verify:** AI-3D toggle with a single screen must look identical to before Phase C. This cannot be
meaningfully tested with N>1 until E-phase lands a real layout — defer the N>1 AI-3D check to the Phase E
verification matrix (and note the "AI-3D when N>1" feature-interaction decision below, which restricts it
to primary-only regardless).

---

## Phase D — Interaction

### D1 — Wire `VRScreen` to a `MonitorSpec`, and introduce `main.layout`

`VRScreen.hit_point_to_uv()` and `VRScreen.get_cylinder_normal_at()` already exist (written in A1). This
commit adds the missing link between a screen and *which monitor of the layout it displays*, and introduces
`main.layout` as the live `ScreenLayout` — the thing D2's mouse mapping and E's UI both read and write.

1. In `src/vr_screen.gd`, find the `uv_region` field:
   ```gdscript
   # --- uv region into the decoded frame (Phase B). Identity = whole frame. ---
   var uv_region: Vector4 = Vector4(0.0, 0.0, 1.0, 1.0)
   ```
   Replace with:
   ```gdscript
   # --- uv region into the decoded frame (Phase B). Identity = whole frame. ---
   var uv_region: Vector4 = Vector4(0.0, 0.0, 1.0, 1.0)
   var monitor: ScreenLayout.MonitorSpec = null

   ## Applies a MonitorSpec: uv_region for the shaders, comp_base_size for the
   ## comp-layer viewport, and remembers the spec itself for mouse mapping.
   func apply_monitor(m: ScreenLayout.MonitorSpec, frame_size: Vector2i):
   	monitor = m
   	uv_region = Vector4(
   		float(m.frame_rect.position.x) / float(frame_size.x),
   		float(m.frame_rect.position.y) / float(frame_size.y),
   		float(m.frame_rect.size.x) / float(frame_size.x),
   		float(m.frame_rect.size.y) / float(frame_size.y),
   	)
   	comp_base_size = m.frame_rect.size
   	if material_override is ShaderMaterial:
   		material_override.set_shader_parameter("uv_region", uv_region)
   	for mat in [comp_shader_mat, comp_shader_mat_left, comp_shader_mat_right]:
   		if mat:
   			mat.set_shader_parameter("uv_region", uv_region)
   ```

2. In `main.gd`, add the `layout` field next to `screens`/`primary_screen` (edited in A1 step 4). Find:
   ```gdscript
   var screens: Array[VRScreen] = []
   var primary_screen: VRScreen = null
   ```
   Replace with:
   ```gdscript
   var screens: Array[VRScreen] = []
   var primary_screen: VRScreen = null
   var layout: ScreenLayout = null
   ```

3. In `_init_ui()`, find (edited in A1 step 5 / A3 step 7):
   ```gdscript
   	screen_mesh.setup(self, &"m0")
   	screens = [screen_mesh]
   	primary_screen = screen_mesh
   ```
   Replace with:
   ```gdscript
   	screen_mesh.setup(self, &"m0")
   	screens = [screen_mesh]
   	primary_screen = screen_mesh
   	layout = ScreenLayout.single(Vector2i(1920, 1080))
   	primary_screen.apply_monitor(layout.get_primary(), layout.frame_size)
   ```

4. Turn `main._hit_point_to_uv()` and `main._get_cylinder_normal_at()` into shims (the real logic lives on
   `VRScreen` since A1; anything still calling the `main.` versions — chiefly `_update_cursor_layer()`, fixed
   properly in D5 — keeps working in the meantime). Find:
   ```gdscript
   func _get_cylinder_normal_at(hit_point: Vector3) -> Vector3:
   	if curvature == 0 or not comp_layer:
   		return -screen_mesh.global_transform.basis.z
   	var screen_forward = -screen_mesh.global_transform.basis.z
   	if _comp_cyl_radius < 0.01:
   		return screen_forward
   	var cyl_center = screen_mesh.global_position - screen_forward * _comp_cyl_radius
   	var to_hit = hit_point - cyl_center
   	to_hit.y = 0.0
   	if to_hit.length() < 0.001:
   		return screen_forward
   	return to_hit.normalized()

   func _hit_point_to_uv(hit_point: Vector3) -> Vector2:
   	var ms = _mesh_size
   	var local_pos = screen_mesh.to_local(hit_point)
   	var uv_x = 0.0
   	var uv_y = clampf((ms.y * 0.5 - local_pos.y) / ms.y, 0.0, 1.0)
   	if curvature == 0:
   		uv_x = clampf((local_pos.x + ms.x * 0.5) / ms.x, 0.0, 1.0)
   	elif comp and comp.in_use and _comp_cyl_radius > 0.01 and _comp_cyl_central_angle > 0.001:
   		var cam_pos = xr_camera.global_position
   		var ray_dir = (hit_point - cam_pos).normalized()
   		var screen_right = screen_mesh.global_transform.basis.x
   		var screen_forward = -screen_mesh.global_transform.basis.z
   		var screen_up = screen_mesh.global_transform.basis.y
   		var oc = cam_pos - _comp_cyl_center
   		var oc_right = oc.dot(screen_right)
   		var oc_fwd = oc.dot(screen_forward)
   		var d_right = ray_dir.dot(screen_right)
   		var d_fwd = ray_dir.dot(screen_forward)
   		var a = d_right * d_right + d_fwd * d_fwd
   		var b = 2.0 * (oc_right * d_right + oc_fwd * d_fwd)
   		var c = oc_right * oc_right + oc_fwd * oc_fwd - _comp_cyl_radius * _comp_cyl_radius
   		var disc = b * b - 4.0 * a * c
   		if disc < 0.0:
   			uv_x = 0.5
   		else:
   			var sqrt_disc = sqrt(disc)
   			var t1 = (-b - sqrt_disc) / (2.0 * a)
   			var t2 = (-b + sqrt_disc) / (2.0 * a)
   			var t = t1 if t1 > 0.001 else t2
   			if t > 0.0:
   				var hit_world = cam_pos + ray_dir * t
   				var hit_local = screen_mesh.to_local(hit_world)
   				uv_y = clampf((ms.y * 0.5 - hit_local.y) / ms.y, 0.0, 1.0)
   				var hit_cyl = hit_world - _comp_cyl_center
   				var hit_right = hit_cyl.dot(screen_right)
   				var hit_fwd = hit_cyl.dot(screen_forward)
   				var hit_angle = atan2(hit_right, hit_fwd)
   				uv_x = clampf((hit_angle + _comp_cyl_central_angle * 0.5) / _comp_cyl_central_angle, 0.0, 1.0)
   			else:
   				uv_x = 0.5
   	else:
   		var radius = 10.0 if curvature == 1 else 4.0
   		var total_angle = ms.x / radius
   		var chord = clampf(local_pos.x / radius, -1.0, 1.0)
   		uv_x = clampf((asin(chord) + total_angle * 0.5) / total_angle, 0.0, 1.0)
   	return Vector2(uv_x, uv_y)
   ```
   Replace with:
   ```gdscript
   func _get_cylinder_normal_at(hit_point: Vector3) -> Vector3:
   	return primary_screen.get_cylinder_normal_at(hit_point)

   func _hit_point_to_uv(hit_point: Vector3) -> Vector2:
   	return primary_screen.hit_point_to_uv(hit_point)
   ```

**Verify:**
```bash
grep -n "func hit_point_to_uv\|func get_cylinder_normal_at" src/vr_screen.gd main.gd
# expect: real bodies in vr_screen.gd, one-line delegations in main.gd
```
Run the app: identical behaviour to end of Phase C — this commit only adds plumbing (`monitor`,
`main.layout`), it doesn't change any call site's *result* yet.

### D2 — Tile→desktop mouse mapping

All host-mouse-position call sites currently multiply a tile-local UV by `main.stream_viewport.size` — the
whole encoded frame, which is only correct at N=1. Route them through `main.layout` instead.

1. In `src/xr_interaction.gd`, the pinch-start block (already partially rewritten in A7 step 1). Find:
   ```gdscript
   		var t0 = PointerTarget.resolve(col) if col else {"role": &""}
   		if t0.role == &"screen":
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = t0.screen.hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   			if main.settings_controller.get_stereo_mode() >= 3:
   				var shift = _compute_parallax_shift(uv_x)
   				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   			_pinch_start_pos = Vector2(uv_x * main.stream_viewport.size.x, uv.y * main.stream_viewport.size.y)
   			_pinch_start_screen = t0.screen
   			_click_pending_release = true
   ```
   Replace with:
   ```gdscript
   		var t0 = PointerTarget.resolve(col) if col else {"role": &""}
   		if t0.role == &"screen":
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = t0.screen.hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   			if main.settings_controller.get_stereo_mode() >= 3:
   				var shift = _compute_parallax_shift(uv_x)
   				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   			_pinch_start_pos = Vector2(main.layout.uv_to_host_point(t0.screen.monitor, Vector2(uv_x, uv.y)))
   			_pinch_start_screen = t0.screen
   			_click_pending_release = true
   ```

2. The grip/right-click block (partially rewritten in A7 step 2). Find:
   ```gdscript
   			var t1 = PointerTarget.resolve(col) if col else {"role": &""}
   			if t1.role == &"screen":
   				var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   				var uv = t1.screen.hit_point_to_uv(hit_pos)
   				var uv_x = uv.x
   				var uv_y = uv.y
   				if main.settings_controller.get_stereo_mode() >= 3:
   					var shift = _compute_parallax_shift(uv_x)
   					uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   				var host_x = int(uv_x * main.stream_viewport.size.x)
   				var host_y = int(uv_y * main.stream_viewport.size.y)
   				main.stream_backend.send_mouse_position_event(host_x, host_y, main.stream_viewport.size.x, main.stream_viewport.size.y)
   ```
   Replace with:
   ```gdscript
   			var t1 = PointerTarget.resolve(col) if col else {"role": &""}
   			if t1.role == &"screen":
   				var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   				var uv = t1.screen.hit_point_to_uv(hit_pos)
   				var uv_x = uv.x
   				var uv_y = uv.y
   				if main.settings_controller.get_stereo_mode() >= 3:
   					var shift = _compute_parallax_shift(uv_x)
   					uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   				var host_pt = main.layout.uv_to_host_point(t1.screen.monitor, Vector2(uv_x, uv_y))
   				var ref = main.layout.host_ref()
   				main.stream_backend.send_mouse_position_event(host_pt.x, host_pt.y, ref.x, ref.y)
   ```

3. The main screen-streaming dispatch block (partially rewritten in A7 step 8). Find:
   ```gdscript
   		elif t.role == &"screen" and main.is_streaming:
   			if main.virtual_keyboard and main.virtual_keyboard.trackpad_active:
   				return
   			if main.controller_mapper and main.controller_mapper.is_active() and main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD:
   				return
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = t.screen.hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   			var uv_y = uv.y
   			if main.settings_controller.get_stereo_mode() >= 3:
   				var shift = _compute_parallax_shift(uv_x)
   				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   			var host_x = int(uv_x * main.stream_viewport.size.x)
   			var host_y = int(uv_y * main.stream_viewport.size.y)

   			if main.is_xr_active:
   				if is_now_clicking:
   					var hold_time = Time.get_ticks_msec() - _pinch_start_time
   					var dist = (Vector2(host_x, host_y) - _pinch_start_pos).length()
   					if hold_time > 150 or dist > 15:
   						main.stream_backend.send_mouse_position_event(host_x, host_y, main.stream_viewport.size.x, main.stream_viewport.size.y)
   						if not main.was_clicking:
   							main.stream_backend.send_mouse_button_event(7, 1)
   							main.was_clicking = true
   				elif main.was_clicking:
   					main.stream_backend.send_mouse_button_event(8, 1)
   					main.was_clicking = false
   					_click_pending_release = false
   				elif _click_pending_release:
   					main.stream_backend.send_mouse_position_event(int(_pinch_start_pos.x), int(_pinch_start_pos.y), main.stream_viewport.size.x, main.stream_viewport.size.y)
   					main.stream_backend.send_mouse_button_event(7, 1)
   					main.stream_backend.send_mouse_button_event(8, 1)
   					_click_pending_release = false
   			else:
   				if is_now_clicking and not main.was_clicking:
   					main.stream_backend.send_mouse_position_event(host_x, host_y, main.stream_viewport.size.x, main.stream_viewport.size.y)
   					main.suppress_input_frames = 3
   					main.input_handler.capture_stream_mouse()
   					main.was_clicking = true
   			return
   ```
   Replace with:
   ```gdscript
   		elif t.role == &"screen" and main.is_streaming:
   			if main.virtual_keyboard and main.virtual_keyboard.trackpad_active:
   				return
   			if main.controller_mapper and main.controller_mapper.is_active() and main.controller_mapper.ctrl_type == ControllerMapper.CtrlType.GAMEPAD:
   				return
   			var hit_pos = main._get_steady_hit(active_raycast.get_collision_point())
   			var uv = t.screen.hit_point_to_uv(hit_pos)
   			var uv_x = uv.x
   			var uv_y = uv.y
   			if main.settings_controller.get_stereo_mode() >= 3:
   				var shift = _compute_parallax_shift(uv_x)
   				uv_x = clampf(uv_x + shift + 0.0075, 0.0, 1.0)
   			var host_pt = main.layout.uv_to_host_point(t.screen.monitor, Vector2(uv_x, uv_y))
   			var ref = main.layout.host_ref()

   			if main.is_xr_active:
   				if is_now_clicking:
   					var hold_time = Time.get_ticks_msec() - _pinch_start_time
   					var dist = Vector2(host_pt).distance_to(_pinch_start_pos)
   					if hold_time > 150 or dist > 15:
   						main.stream_backend.send_mouse_position_event(host_pt.x, host_pt.y, ref.x, ref.y)
   						if not main.was_clicking:
   							main.stream_backend.send_mouse_button_event(7, 1)
   							main.was_clicking = true
   				elif main.was_clicking:
   					main.stream_backend.send_mouse_button_event(8, 1)
   					main.was_clicking = false
   					_click_pending_release = false
   				elif _click_pending_release:
   					if _pinch_start_screen == t.screen:
   						main.stream_backend.send_mouse_position_event(int(_pinch_start_pos.x), int(_pinch_start_pos.y), ref.x, ref.y)
   						main.stream_backend.send_mouse_button_event(7, 1)
   						main.stream_backend.send_mouse_button_event(8, 1)
   					_click_pending_release = false
   			else:
   				if is_now_clicking and not main.was_clicking:
   					main.stream_backend.send_mouse_position_event(host_pt.x, host_pt.y, ref.x, ref.y)
   					main.suppress_input_frames = 3
   					main.input_handler.capture_stream_mouse()
   					main.was_clicking = true
   			return
   ```
   The `if _pinch_start_screen == t.screen:` guard is the fix noted in the plan: a tap that started on one
   screen and whose release-time raycast resolves to a *different* screen is cancelled instead of replaying
   a stale position on the wrong monitor.

4. **Keep `main.layout` in sync with the actual stream resolution.** In `src/stream_manager.gd`, function
   `resize_stream_viewport()`, find:
   ```gdscript
   	main.screen_manager.resize_screen_to_aspect(w, h)
   ```
   Replace with:
   ```gdscript
   	var new_frame = Vector2i(w, h)
   	if main.layout.frame_size != new_frame:
   		var old_aspect = float(main.layout.frame_size.x) / float(main.layout.frame_size.y) if main.layout.frame_size.y > 0 else 1.0
   		var new_aspect = float(w) / float(h) if h > 0 else 1.0
   		if absf(old_aspect - new_aspect) < 0.01:
   			var rescaled = main.layout.rescale_to(new_frame)
   			if rescaled.validate(new_frame) == "":
   				main.layout = rescaled
   				main.primary_screen.apply_monitor(main.layout.get_primary(), main.layout.frame_size)
   			else:
   				main._log("[LAYOUT] Rescale produced an invalid layout, resetting to single()")
   				main.layout = ScreenLayout.single(new_frame)
   				main.primary_screen.apply_monitor(main.layout.get_primary(), main.layout.frame_size)
   		else:
   			main._log("[LAYOUT] Stream aspect changed (%.3f -> %.3f), resetting display layout to single()" % [old_aspect, new_aspect])
   			main.layout = ScreenLayout.single(new_frame)
   			main.primary_screen.apply_monitor(main.layout.get_primary(), main.layout.frame_size)
   			main._ui_status_label.text = "Display layout reset: stream resolution changed"
   	main.screen_manager.resize_screen_to_aspect(w, h)
   ```
   This is the "Mid-session resolution change" behaviour: same aspect rescales losslessly (screens/handles
   untouched beyond aspect-preserving resize); different aspect collapses to a single full-frame screen and
   tells the user why, rather than silently mapping the mouse incorrectly. Per the note in "Never rebuild
   inside `update_stats()`" below, this call chain runs from `update_stats()` (`stream_manager.gd:326-342`,
   which calls `resize_stream_viewport()` only when `vw`/`vh` actually differ from the current viewport
   size) — that existing guard already prevents this from running every frame, so no additional
   `_layout_dirty` flag is needed for the *single*-screen path added here. If E2's multi-screen layout-apply
   logic ever needs to defer node creation/deletion out of this call stack, add that guard there instead —
   the mapping/rescale logic above is safe to run inline because it never frees or creates a `VRScreen`.

**Verify:**
```bash
grep -n "main.stream_viewport.size.x\|main.stream_viewport.size.y" src/xr_interaction.gd
# expect: ZERO matches remaining in the mouse-position call sites (other unrelated uses, e.g. in the
# welcome-screen / non-streaming UV path, are untouched -- only host_x/host_y computations change)
```
Run the app end to end: click-drag on the stream, right-click, tap-to-click (XR), and non-XR desktop click
must all still land the mouse at the same host position as before this commit (at N=1,
`layout.uv_to_host_point()` reduces to exactly `uv * stream_viewport.size`, since `desktop_rect ==
Rect2i(0,0,w,h)`). Then test a live resolution change while connected (cycle the Resolution setting) and
confirm mouse mapping keeps working immediately after — this is the regression this commit must not
introduce.

### D3 — Per-screen corner resize

1. In `src/vr_screen.gd`, add corner-resize methods (an exception to "vr_screen.gd is written once" — this
   is new functionality the class needs, not a rename). Find the `resize_to_aspect()` method and insert
   immediately after it:
   ```gdscript
   var _corner_resize_started: bool = false
   var _corner_start_width: float = 0.0
   var _corner_start_hit_x: float = 0.0

   func begin_corner_resize():
   	_corner_resize_started = false

   ## Returns true while still resizing (call every frame the corner is held).
   func apply_corner_resize(ray_origin: Vector3, ray_dir: Vector3, tile_aspect: float) -> bool:
   	var plane_normal = -global_transform.basis.z
   	var plane_point = global_position
   	var denom = ray_dir.dot(plane_normal)
   	if absf(denom) < 0.0001:
   		return true
   	var t = (plane_point - ray_origin).dot(plane_normal) / denom
   	if t < 0:
   		return true
   	var hit_world = ray_origin + ray_dir * t
   	var local_hit = to_local(hit_world)

   	if not _corner_resize_started:
   		_corner_resize_started = true
   		_corner_start_width = mesh_size.x
   		_corner_start_hit_x = local_hit.x
   		return true

   	return true
   ```
   This is intentionally a thin shell for now — the actual width/height math below still needs the caller's
   `grabbed_corner_idx` (which corner, for sign) and stays in `xr_interaction.gd` since that is where
   `main.grabbed_corner_idx` already lives. Replace the body above with the full version:
   ```gdscript
   func apply_corner_resize(ray_origin: Vector3, ray_dir: Vector3, corner_idx: int, tile_aspect: float) -> void:
   	var plane_normal = -global_transform.basis.z
   	var plane_point = global_position
   	var denom = ray_dir.dot(plane_normal)
   	if absf(denom) < 0.0001:
   		return
   	var t = (plane_point - ray_origin).dot(plane_normal) / denom
   	if t < 0:
   		return
   	var hit_world = ray_origin + ray_dir * t
   	var local_hit = to_local(hit_world)

   	if not _corner_resize_started:
   		_corner_resize_started = true
   		_corner_start_width = mesh_size.x
   		_corner_start_hit_x = local_hit.x
   		return

   	var sign = -1.0 if corner_idx in [0, 2] else 1.0
   	var new_w: float
   	if curvature == 0:
   		var dx = local_hit.x - _corner_start_hit_x
   		new_w = _corner_start_width + dx * sign * 2.0
   	else:
   		var radius = get_cylinder_radius()
   		var start_a = asin(clampf(_corner_start_hit_x / radius, -1.0, 1.0))
   		var cur_a = asin(clampf(local_hit.x / radius, -1.0, 1.0))
   		var da = cur_a - start_a
   		new_w = _corner_start_width + da * radius * sign * 2.0
   	new_w = maxf(new_w, 0.6)
   	var new_h = new_w / tile_aspect
   	if new_h < 0.4:
   		new_h = 0.4
   		new_w = new_h * tile_aspect

   	mesh_size = Vector2(new_w, new_h)
   	if curvature == 0:
   		mesh.size = mesh_size
   		set_collision_flat()
   	else:
   		apply_curvature()

   	update_corner_positions()
   	update_bezel_size()

   func end_corner_resize():
   	_corner_resize_started = false
   ```
   (Delete the earlier thin-shell `begin_corner_resize`/`apply_corner_resize(ray_origin, ray_dir,
   tile_aspect)` pair you just wrote in the previous step before adding this full version — they are the
   same insertion point; this is one continuous edit, shown in two steps only to explain the shape before
   giving the final body. The **final state** of `src/vr_screen.gd` after this commit has exactly one
   `apply_corner_resize(ray_origin, ray_dir, corner_idx, tile_aspect)` method, one `begin_corner_resize()`,
   and one `end_corner_resize()` — not both versions.)

2. In `src/xr_interaction.gd`, replace `handle_corner_resize()` entirely. Find:
   ```gdscript
   func handle_corner_resize():
   	if main.grabbed_corner_idx < 0:
   		return
   	var active_raycast = get_active_raycast()
   	var ray_origin = active_raycast.global_position
   	var ray_dir = -active_raycast.global_transform.basis.z

   	var plane_normal = -main.screen_mesh.global_transform.basis.z
   	var plane_point = main.screen_mesh.global_position
   	var denom = ray_dir.dot(plane_normal)
   	if absf(denom) < 0.0001:
   		return
   	var t = (plane_point - ray_origin).dot(plane_normal) / denom
   	if t < 0:
   		return
   	var hit_world = ray_origin + ray_dir * t

   	var local_hit = main.screen_mesh.to_local(hit_world)

   	if not _corner_resize_started:
   		_corner_resize_started = true
   		_corner_start_width = main._mesh_size.x
   		_corner_start_hit_x = local_hit.x
   		return

   	var sv = main.stream_viewport.size
   	var aspect = float(sv.x) / float(sv.y) if sv.y > 0 else 16.0 / 9.0
   	var sign = -1.0 if main.grabbed_corner_idx in [0, 2] else 1.0
   	var new_w: float
   	if main.curvature == 0:
   		var dx = local_hit.x - _corner_start_hit_x
   		new_w = _corner_start_width + dx * sign * 2.0
   	else:
   		var radius = main.screen_manager._get_cylinder_radius()
   		var start_a = asin(clampf(_corner_start_hit_x / radius, -1.0, 1.0))
   		var cur_a = asin(clampf(local_hit.x / radius, -1.0, 1.0))
   		var da = cur_a - start_a
   		new_w = _corner_start_width + da * radius * sign * 2.0
   	new_w = maxf(new_w, 0.6)
   	var new_h = new_w / aspect
   	if new_h < 0.4:
   		new_h = 0.4
   		new_w = new_h * aspect

   	main._mesh_size = Vector2(new_w, new_h)
   	if main.curvature == 0:
   		main.screen_mesh.mesh.size = Vector2(new_w, new_h)
   	else:
   		main.screen_manager.apply_curvature()

   	var col_shape = main.screen_mesh.get_node_or_null("Area3D/CollisionShape3D")
   	if col_shape:
   		if main.curvature == 0:
   			var box = BoxShape3D.new()
   			box.size = Vector3(new_w, new_h, 0.01)
   			col_shape.shape = box
   		else:
   			var mesh = main.screen_mesh.mesh
   			if mesh is ArrayMesh and mesh.get_surface_count() > 0:
   				var arrays = mesh.surface_get_arrays(0)
   				var verts = arrays[Mesh.ARRAY_VERTEX]
   				var indices = arrays[Mesh.ARRAY_INDEX]
   				var faces = PackedVector3Array()
   				for i in range(0, indices.size(), 3):
   					faces.append(verts[indices[i]])
   					faces.append(verts[indices[i + 1]])
   					faces.append(verts[indices[i + 2]])
   				var concave = ConcavePolygonShape3D.new()
   				concave.set_faces(faces)
   				col_shape.shape = concave

   	main.screen_manager.update_corner_positions()
   	main.screen_manager.update_bezel_size()
   	main.comp.update_layer_size()

   	var still_clicking = _is_now_clicking()
   	if not still_clicking:
   		var handle = main.corner_handles[main.grabbed_corner_idx]
   		_set_corner_color(handle, Color.WHITE, 0.05)
   		main.grabbed_corner_idx = -1
   		_corner_resize_started = false
   		main.state_manager.save_state()
   ```
   Replace with:
   ```gdscript
   func handle_corner_resize():
   	if main.grabbed_corner_idx < 0 or not main.grabbed_corner_screen:
   		return
   	var s = main.grabbed_corner_screen
   	var active_raycast = get_active_raycast()
   	var ray_origin = active_raycast.global_position
   	var ray_dir = -active_raycast.global_transform.basis.z
   	var tile_aspect = float(s.monitor.frame_rect.size.x) / float(s.monitor.frame_rect.size.y) if s.monitor and s.monitor.frame_rect.size.y > 0 else 16.0 / 9.0

   	if not _corner_resize_started:
   		s.begin_corner_resize()
   		_corner_resize_started = true
   	s.apply_corner_resize(ray_origin, ray_dir, main.grabbed_corner_idx, tile_aspect)

   	main.comp.update_layer_size()

   	var still_clicking = _is_now_clicking()
   	if not still_clicking:
   		var handle = s.corner_handles[main.grabbed_corner_idx]
   		_set_corner_color(handle, Color.WHITE, 0.05)
   		main.grabbed_corner_idx = -1
   		main.grabbed_corner_screen = null
   		_corner_resize_started = false
   		s.end_corner_resize()
   		main.state_manager.save_state()
   ```
   This deletes the duplicated collision-rebuild block (now `VRScreen.set_collision_flat/curved`, called
   inside `apply_corner_resize()`), fixes the aspect bug (was `main.stream_viewport.size` — the whole
   frame — now `s.monitor.frame_rect.size` — the tile), and drops the now-redundant `_corner_start_width` /
   `_corner_start_hit_x` fields from `xr_interaction.gd` (they moved onto `VRScreen`, set (in A1's list
   `main.gd:146` block edited in A3 step 4) — remove the two now-unused declarations from
   `xr_interaction.gd`'s top-of-file vars):
   ```gdscript
   var _corner_resize_started: bool = false
   var _corner_start_width: float = 0.0
   var _corner_start_hit_x: float = 0.0
   ```
   Replace with:
   ```gdscript
   var _corner_resize_started: bool = false
   ```
   (`_corner_resize_started` stays here too — it's used as a simple "did we just start" flag by the caller;
   `VRScreen`'s own `_corner_resize_started` field is the source of truth for the per-screen start position.)

3. Set `grabbed_corner_screen` where the corner grab begins. In `src/xr_interaction.gd`, find (in
   `handle_pointer_interaction()`, the corner-handle branch fixed in A7 step 9/14):
   ```gdscript
   		if t.role == &"corner":
   			var corner_idx = t.corner_idx
   			parent.visible = true
   			var p_area = parent.get_node_or_null("Area3D")
   			if p_area:
   				p_area.monitoring = true
   				p_area.monitorable = true
   			if is_now_clicking and main.grabbed_corner_idx < 0 and not main.grabbed_node:
   				main.grabbed_corner_idx = corner_idx
   				var opposite_idx = 3 - corner_idx
   				var opposite = main.corner_handles[opposite_idx]
   				main.corner_anchor_world = opposite.global_position
   				_set_corner_color(parent, Color.WHITE, 0.4)
   				main.was_clicking = true
   			elif main.grabbed_corner_idx < 0 and corner_idx != main.grabbed_corner_idx:
   				_set_corner_color(parent, Color.WHITE, 0.15)
   			return
   ```
   Replace with:
   ```gdscript
   		if t.role == &"corner":
   			var corner_idx = t.corner_idx
   			parent.visible = true
   			var p_area = parent.get_node_or_null("Area3D")
   			if p_area:
   				p_area.monitoring = true
   				p_area.monitorable = true
   			if is_now_clicking and main.grabbed_corner_idx < 0 and not main.grabbed_node:
   				main.grabbed_corner_idx = corner_idx
   				main.grabbed_corner_screen = t.screen
   				var opposite_idx = 3 - corner_idx
   				var opposite = t.screen.corner_handles[opposite_idx]
   				main.corner_anchor_world = opposite.global_position
   				_set_corner_color(parent, Color.WHITE, 0.4)
   				main.was_clicking = true
   			elif main.grabbed_corner_idx < 0 and corner_idx != main.grabbed_corner_idx:
   				_set_corner_color(parent, Color.WHITE, 0.15)
   			return
   ```

4. `handle_grab()` — only the comp-cylinder-refresh special case needs a screen-aware check. Find:
   ```gdscript
   	if main.grabbed_node == main.screen_mesh:
   		if main.comp_cylinder and main.comp_cylinder.visible:
   			main.comp.update_cylinder_params()
   		if main.comp_cylinder_left and main.comp_cylinder_left.visible:
   			main.comp.update_cylinder_params()
   ```
   (this pattern appears twice in the function, before and after the pitch/rotation block) — replace **both**
   occurrences with:
   ```gdscript
   	if main.grabbed_node is VRScreen:
   		main.comp.update_cylinder_params()
   ```
   (`update_cylinder_params()` already loops `main.screens` since A5, so this is correct regardless of which
   screen was grabbed — no need to single out `grabbed_node`'s own cylinder.)

**Verify:**
```bash
grep -n "main.stream_viewport.size" src/xr_interaction.gd | grep -i corner   # expect: 0 (corner resize no longer reads frame size)
grep -c "_corner_start_width\|_corner_start_hit_x" src/xr_interaction.gd     # expect: 0
```
Run the app: corner-drag resize on the (only) screen must behave identically to before this commit — same
aspect lock, same minimum size clamps, same first-frame-doesn't-jump behaviour (from the
`_corner_resize_started` gate, preserved). Grab-and-move the screen and confirm the comp cylinder still
follows correctly on Quest.

### D4 — Primary screen re-anchoring

There is no UI to change the primary screen in this branch (E1 only exposes enable/disable and preset
selection, with monitor 0 always primary) — this commit exists so the mechanism is correct for E1's "set
primary" button and for any future work, and so it's exercised by at least the unit test in Verification.

1. In `main.gd`, add a `set_primary_screen()` method. Insert it directly after `_anchor_to_primary()`
   (added in A6):
   ```gdscript
   func set_primary_screen(s: VRScreen) -> void:
   	if s == primary_screen or not screens.has(s):
   		return
   	var panels: Array = [ui_panel_3d]
   	if virtual_keyboard:
   		panels.append(virtual_keyboard)
   	var world_transforms := {}
   	for p in panels:
   		world_transforms[p] = p.global_transform
   	primary_screen = s
   	for p in panels:
   		p.global_transform = world_transforms[p]
   		if p == ui_panel_3d:
   			_save_ui_offset()
   		elif p.has_method("_save_offset"):
   			p._save_offset()
   	state_manager.save_state()
   ```
   This captures each panel's world transform *before* `primary_screen` changes, restores that exact
   transform after (so nothing visibly teleports), then re-derives the saved offset in the new primary's
   local basis via the existing `_save_offset()`/`_save_ui_offset()` methods (A6) — so the next
   `toggle()`/`_set_ui_position()` call anchors correctly to the new primary from then on.

**Verify:**
```bash
grep -c "func set_primary_screen" main.gd   # expect: 1
```
No UI calls this yet in this branch (E1 leaves monitor 0 as permanently primary) — verify only that it
compiles and, if you want to sanity-check it manually, temporarily call
`main.set_primary_screen(main.screens[1])` from a debug key binding after E1 lands and confirm the menu and
keyboard do not jump when it fires.

### D5 — Per-screen cursor layer

In `main.gd`, function `_update_cursor_layer()`, the only change is *which screen* the cursor logic
considers "the" screen — from `screen_mesh` (always primary) to whatever `PointerTarget` resolves the
active raycast to.

1. Find:
   ```gdscript
   	if active_raycast.is_colliding():
   		var hit_point = _get_steady_hit(active_raycast.get_collision_point())
   		var col = active_raycast.get_collider()
   		var par = col.get_parent() if col else null
   		on_screen = (par == screen_mesh)
   		use_in_stream = is_streaming and on_screen and not pad_on_screen and not tp_capturing
   ```
   Replace with:
   ```gdscript
   	var hovered_screen: VRScreen = null
   	if active_raycast.is_colliding():
   		var hit_point = _get_steady_hit(active_raycast.get_collision_point())
   		var col = active_raycast.get_collider()
   		var t = PointerTarget.resolve(col) if col else {"role": &""}
   		on_screen = (t.role == &"screen")
   		hovered_screen = t.screen if on_screen else null
   		use_in_stream = is_streaming and on_screen and not pad_on_screen and not tp_capturing
   ```
2. Find (the `use_in_stream and on_screen` branch that draws the stream cursor):
   ```gdscript
   		elif use_in_stream and on_screen:
   			var uv = _hit_point_to_uv(hit_point)
   			var bezel_px = 8 if bezel_enabled else 0
   			var base_w = _comp_base_size.x
   			var base_h = _comp_base_size.y
   			var cursor_px = 48
   			var cx = bezel_px + uv.x * base_w
   			var cy = bezel_px + uv.y * base_h
   			comp_cursor.visible = false
   			_show_stream_cursor(comp_stream_cursor, comp_stream_cursor_circle, cx, cy, cursor_px)
   			if stereo > 0:
   				var left_cx = cx
   				if stereo >= 3:
   					left_cx += 0.015 * base_w
   				_show_stream_cursor(comp_stream_cursor_left, comp_stream_cursor_circle_left, left_cx, cy, cursor_px)
   				_show_stream_cursor(comp_stream_cursor_right, comp_stream_cursor_circle_right, cx, cy, cursor_px)
   			else:
   				_hide_stream_cursor(comp_stream_cursor_left, comp_stream_cursor_circle_left)
   				_hide_stream_cursor(comp_stream_cursor_right, comp_stream_cursor_circle_right)
   ```
   Replace with:
   ```gdscript
   		elif use_in_stream and on_screen:
   			var uv = hovered_screen.hit_point_to_uv(hit_point)
   			var bezel_px = 8 if bezel_enabled else 0
   			var base_w = hovered_screen.comp_base_size.x
   			var base_h = hovered_screen.comp_base_size.y
   			var cursor_px = 48
   			var cx = bezel_px + uv.x * base_w
   			var cy = bezel_px + uv.y * base_h
   			comp_cursor.visible = false
   			_show_stream_cursor(hovered_screen.comp_stream_cursor, hovered_screen.comp_stream_cursor_circle, cx, cy, cursor_px)
   			if stereo > 0 and hovered_screen == primary_screen:
   				var left_cx = cx
   				if stereo >= 3:
   					left_cx += 0.015 * base_w
   				_show_stream_cursor(hovered_screen.comp_stream_cursor_left, hovered_screen.comp_stream_cursor_circle_left, left_cx, cy, cursor_px)
   				_show_stream_cursor(hovered_screen.comp_stream_cursor_right, hovered_screen.comp_stream_cursor_circle_right, cx, cy, cursor_px)
   			else:
   				_hide_stream_cursor(hovered_screen.comp_stream_cursor_left, hovered_screen.comp_stream_cursor_circle_left)
   				_hide_stream_cursor(hovered_screen.comp_stream_cursor_right, hovered_screen.comp_stream_cursor_circle_right)
   ```
   (The `stereo > 0 and hovered_screen == primary_screen` guard matters because non-primary screens never
   get a stereo comp-layer pair per C2 — their `comp_stream_cursor_left/right` are always `null`, and
   `_show_stream_cursor(null, null, ...)` would otherwise be called pointlessly.)

3. `_hide_all_stream_cursors()` must clear every screen's cursors, not just the primary's. Find:
   ```gdscript
   func _hide_all_stream_cursors():
   	_hide_stream_cursor(comp_stream_cursor, comp_stream_cursor_circle)
   	_hide_stream_cursor(comp_stream_cursor_left, comp_stream_cursor_circle_left)
   	_hide_stream_cursor(comp_stream_cursor_right, comp_stream_cursor_circle_right)
   ```
   Replace with:
   ```gdscript
   func _hide_all_stream_cursors():
   	for s in screens:
   		_hide_stream_cursor(s.comp_stream_cursor, s.comp_stream_cursor_circle)
   		_hide_stream_cursor(s.comp_stream_cursor_left, s.comp_stream_cursor_circle_left)
   		_hide_stream_cursor(s.comp_stream_cursor_right, s.comp_stream_cursor_circle_right)
   ```

**Verify:**
```bash
grep -n "par == screen_mesh" main.gd   # expect: 0 remaining in _update_cursor_layer
```
Run on Quest: primary-screen cursor (circle/pointer mode, both SBS on and off) must look identical to
before this commit. This cannot be fully exercised for a second screen until E1 lands a real multi-monitor
layout — note it in the Phase E verification matrix.

---

## Phase E — UI + persistence

### E1 — Display tab: monitor controls

Add a third row to `_tab_display`, following the exact pattern of `disp_row1`/`disp_row2` (built with
`make_option_btn()` / `update_option_btn()` from `ui_controller.gd`).

1. In `main.gd`, add four button fields next to the existing display-tab ones. Find:
   ```gdscript
   var _ui_curve_btn: Button
   var _ui_bezel_btn: Button
   ```
   Replace with:
   ```gdscript
   var _ui_curve_btn: Button
   var _ui_bezel_btn: Button
   var _ui_monitors_btn: Button
   var _ui_edit_mon_btn: Button
   var _ui_mon_enabled_btn: Button
   var _ui_mon_primary_btn: Button
   ```
   (`_ui_primary_btn`, already declared for controller primary-*hand*, is untouched — `_ui_mon_primary_btn`
   is a distinct field to avoid the name collision.)

2. Add the monitor-editing state that these buttons operate on. In `main.gd`, near `var layout: ScreenLayout
   = null` (added in D1), add:
   ```gdscript
   var monitor_presets: Array = ["1", "2-up", "3-up", "2+1"]
   var _edit_monitor_idx: int = 0
   ```

3. In `src/ui_controller.gd`, function `build_ui()`, find the end of `disp_row2` (right after the last
   button is added to it, before `_tab_stream = VBoxContainer.new()` begins):
   ```gdscript
   	main._ui_curve_btn = make_option_btn("Curve", "Flat")
   	disp_row2.add_child(main._ui_curve_btn)
   	main._ui_sharpen_btn = make_option_btn("Sharpen", "0%")
   	disp_row2.add_child(main._ui_sharpen_btn)
   	main._ui_render_btn = make_option_btn("Blur", "0%")
   	disp_row2.add_child(main._ui_render_btn)
   	main._ui_bg_btn = make_option_btn("Background", "Black")
   	disp_row2.add_child(main._ui_bg_btn)

   	_tab_stream = VBoxContainer.new()
   ```
   Replace with:
   ```gdscript
   	main._ui_curve_btn = make_option_btn("Curve", "Flat")
   	disp_row2.add_child(main._ui_curve_btn)
   	main._ui_sharpen_btn = make_option_btn("Sharpen", "0%")
   	disp_row2.add_child(main._ui_sharpen_btn)
   	main._ui_render_btn = make_option_btn("Blur", "0%")
   	disp_row2.add_child(main._ui_render_btn)
   	main._ui_bg_btn = make_option_btn("Background", "Black")
   	disp_row2.add_child(main._ui_bg_btn)

   	var disp_gap2 = Control.new()
   	disp_gap2.custom_minimum_size = Vector2(0, 20)
   	disp_gap2.mouse_filter = Control.MOUSE_FILTER_IGNORE
   	_tab_display.add_child(disp_gap2)

   	var disp_row3 = HBoxContainer.new()
   	disp_row3.name = "DispRow3"
   	disp_row3.add_theme_constant_override("separation", 12)
   	disp_row3.alignment = BoxContainer.ALIGNMENT_CENTER
   	disp_row3.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
   	disp_row3.size_flags_vertical = Control.SIZE_SHRINK_CENTER
   	disp_row3.mouse_filter = Control.MOUSE_FILTER_IGNORE
   	_tab_display.add_child(disp_row3)

   	main._ui_monitors_btn = make_option_btn("Monitors", "1")
   	disp_row3.add_child(main._ui_monitors_btn)
   	main._ui_edit_mon_btn = make_option_btn("Edit", "1")
   	disp_row3.add_child(main._ui_edit_mon_btn)
   	main._ui_mon_enabled_btn = make_option_btn("Enabled", "On")
   	disp_row3.add_child(main._ui_mon_enabled_btn)
   	main._ui_mon_primary_btn = make_option_btn("Primary", "Yes")
   	disp_row3.add_child(main._ui_mon_primary_btn)

   	_tab_stream = VBoxContainer.new()
   ```

4. Wire button presses. Find the existing signal-connection block (where `_ui_curve_btn.button_down.connect`
   or similar lives — search for `main._ui_bezel_btn.button_down.connect`), and add four more lines
   immediately after it:
   ```gdscript
   	main._ui_monitors_btn.button_down.connect(func(): main.settings_controller.cycle_monitor_preset())
   	main._ui_edit_mon_btn.button_down.connect(func(): main.settings_controller.cycle_edit_monitor())
   	main._ui_mon_enabled_btn.button_down.connect(func(): main.settings_controller.toggle_edit_monitor_enabled())
   	main._ui_mon_primary_btn.button_down.connect(func(): main.settings_controller.set_edit_monitor_primary())
   ```

5. Add an update function, following the `update_mic_btn_state()`-style pattern (greyed-out-when-disabled
   button seen elsewhere in this codebase). In `src/ui_controller.gd`, add:
   ```gdscript
   func update_monitor_btns():
   	if not main._ui_monitors_btn:
   		return
   	var preset_idx = main.monitor_presets.find(str(main.layout.monitors.size())) if main.layout.monitors.size() <= 2 else -1
   	update_option_btn(main._ui_monitors_btn, str(main.layout.monitors.size()))
   	main._edit_monitor_idx = clampi(main._edit_monitor_idx, 0, main.layout.monitors.size() - 1)
   	var m = main.layout.monitors[main._edit_monitor_idx]
   	update_option_btn(main._ui_edit_mon_btn, str(main._edit_monitor_idx + 1))
   	update_option_btn(main._ui_mon_enabled_btn, "On" if m.enabled else "Off")
   	update_option_btn(main._ui_mon_primary_btn, "Yes" if m.is_primary else "No")
   	main._ui_mon_enabled_btn.disabled = m.is_primary   # can't disable the primary monitor
   	main._ui_mon_primary_btn.disabled = not m.enabled  # can't make a disabled monitor primary
   ```

6. In `src/settings_controller.gd`, add the four handlers plus the layout-apply function they share. Insert
   at the end of the file (after `toggle_hand_tracking()`):
   ```gdscript
   func apply_screen_layout(new_layout: ScreenLayout):
   	var err = new_layout.validate(new_layout.frame_size)
   	if err != "":
   		main._log("[LAYOUT] Refusing invalid layout: %s" % err)
   		return
   	# Remove screens for monitors no longer present.
   	var wanted_ids: Array = []
   	for m in new_layout.enabled_monitors():
   		wanted_ids.append(m.id)
   	for s in main.screens.duplicate():
   		if not wanted_ids.has(s.monitor_id):
   			main.remove_screen(s.monitor_id)
   	# Add/update screens for each enabled monitor.
   	var new_primary: VRScreen = null
   	for m in new_layout.enabled_monitors():
   		var existing: VRScreen = null
   		for s in main.screens:
   			if s.monitor_id == m.id:
   				existing = s
   				break
   		var s = existing if existing else main.add_screen(m.id)
   		if s == null:
   			continue
   		s.apply_monitor(m, new_layout.frame_size)
   		if m.is_primary:
   			new_primary = s
   	main.layout = new_layout
   	if new_primary and new_primary != main.primary_screen:
   		main.set_primary_screen(new_primary)
   	main.screen_manager.resize_screen_to_aspect(new_layout.frame_size.x, new_layout.frame_size.y)
   	main.ui_controller.update_monitor_btns()
   	main.state_manager.save_state()

   func cycle_monitor_preset():
   	var frame = main.layout.frame_size
   	var count = main.layout.enabled_monitors().size()
   	var next_layout: ScreenLayout
   	match count:
   		1: next_layout = ScreenLayout.split_h(frame, 2)
   		2: next_layout = ScreenLayout.split_h(frame, 3)
   		_: next_layout = ScreenLayout.single(frame)
   	apply_screen_layout(next_layout)

   func cycle_edit_monitor():
   	if main.layout.monitors.is_empty():
   		return
   	main._edit_monitor_idx = (main._edit_monitor_idx + 1) % main.layout.monitors.size()
   	main.ui_controller.update_monitor_btns()

   func toggle_edit_monitor_enabled():
   	if main._edit_monitor_idx >= main.layout.monitors.size():
   		return
   	var m = main.layout.monitors[main._edit_monitor_idx]
   	if m.is_primary:
   		return  # cannot disable the primary monitor
   	m.enabled = not m.enabled
   	if not m.enabled:
   		var still_has_primary = false
   		for mm in main.layout.monitors:
   			if mm.enabled and mm.is_primary:
   				still_has_primary = true
   		if not still_has_primary:
   			for mm in main.layout.monitors:
   				if mm.enabled:
   					mm.is_primary = true
   					break
   	apply_screen_layout(main.layout)

   func set_edit_monitor_primary():
   	if main._edit_monitor_idx >= main.layout.monitors.size():
   		return
   	var target = main.layout.monitors[main._edit_monitor_idx]
   	if not target.enabled:
   		return
   	for m in main.layout.monitors:
   		m.is_primary = (m == target)
   	apply_screen_layout(main.layout)
   ```
   Note `apply_screen_layout()` mutates `main.layout.monitors[i]` in place for the enable/primary toggles
   (matching `MonitorSpec`'s reference semantics as a `RefCounted`), then re-validates and re-applies the
   whole layout through the single code path also used by preset switching — there is exactly one place
   that creates/frees `VRScreen`s and rebinds `uv_region`/`comp_base_size`.

7. Wire `update_monitor_btns()` into the existing sync pass. In `src/state_manager.gd`, function
   `sync_ui_to_settings()`, find:
   ```gdscript
   		if main.controller_mapper:
   			main.ui_controller.update_btn_toggle_btn()
   			main.ui_controller.update_primary_btn()
   ```
   Replace with:
   ```gdscript
   		if main.controller_mapper:
   			main.ui_controller.update_btn_toggle_btn()
   			main.ui_controller.update_primary_btn()
   		main.ui_controller.update_monitor_btns()
   ```

**No VR rect editor in this branch.** "Custom" layouts (arbitrary rects, not a preset) are out of scope —
if you need one, load `user://layout.json` (same `ScreenLayout.to_dict()`/`from_dict()` schema used for
persistence in E2) and call `apply_screen_layout()` with it; there is no in-VR authoring UI for that file in
this plan.

**Verify:**
```bash
godot --headless --check-only . 2>&1 | grep -i error   # expect: no output
```
Manual test on the mesh path (Linux) first: cycle Monitors through 1 → 2-up → 3-up → 1; confirm the correct
number of `VRScreen` instances exist (`main.screens.size()`), each showing a different slice of the stream
(use the synthetic quadrant test image from the Verification section below to see this clearly), and that
clicking on each screen's tile drives the mouse to the correct half/third of the host desktop. Then repeat
on Quest with the comp-layer path.

### E2 — Persistence

Layout is host-specific, so it goes in `save_host_state()`/`load_host_state()` (keyed by IP), not
`app_state.cfg`.

1. In `src/state_manager.gd`, function `save_host_state()`, find:
   ```gdscript
   	save.set_value(ip, "double_h", main.double_h)
   	save.save("user://host_state.cfg")
   ```
   Replace with:
   ```gdscript
   	save.set_value(ip, "double_h", main.double_h)
   	save.set_value(ip, "screen_layout", JSON.stringify(main.layout.to_dict()))
   	var placements := []
   	for s in main.screens:
   		placements.append({
   			"id": String(s.monitor_id),
   			"pos": [s.position.x, s.position.y, s.position.z],
   			"rot": [s.rotation.x, s.rotation.y, s.rotation.z],
   			"size": [s.mesh_size.x, s.mesh_size.y],
   			"curvature": s.curvature,
   		})
   	save.set_value(ip, "screen_placements", JSON.stringify(placements))
   	save.save("user://host_state.cfg")
   ```
   **Key placements by `monitor_id`, never by index** — this is why the dictionary above stores `"id"`
   explicitly rather than relying on array position; E2 step 2's loader reads it back by matching `id`.

2. In `src/state_manager.gd`, function `load_host_state()`, find the end of the function:
   ```gdscript
   	main.settings_controller.apply_stereo()
   	if main.depth_estimator:
   		main.depth_estimator.set_enabled(main.settings_controller.get_stereo_mode() >= 3)
   	main.settings_controller.apply_stereo()
   ```
   Replace with:
   ```gdscript
   	main.settings_controller.apply_stereo()
   	if main.depth_estimator:
   		main.depth_estimator.set_enabled(main.settings_controller.get_stereo_mode() >= 3)
   	main.settings_controller.apply_stereo()

   	var layout_json = save.get_value(ip, "screen_layout", "")
   	var loaded_layout: ScreenLayout = null
   	if not layout_json.is_empty():
   		var parsed = JSON.parse_string(layout_json)
   		if parsed is Dictionary:
   			var candidate = ScreenLayout.from_dict(parsed)
   			if candidate.validate(candidate.frame_size) == "":
   				loaded_layout = candidate
   			else:
   				main._log("[LAYOUT] Saved layout failed validation, using single()")
   	if loaded_layout == null:
   		loaded_layout = ScreenLayout.single(main.layout.frame_size if main.layout else Vector2i(1920, 1080))
   	main.settings_controller.apply_screen_layout(loaded_layout)

   	var placements_json = save.get_value(ip, "screen_placements", "")
   	if not placements_json.is_empty():
   		var placements = JSON.parse_string(placements_json)
   		if placements is Array:
   			for entry in placements:
   				var mid = StringName(entry.get("id", ""))
   				for s in main.screens:
   					if s.monitor_id == mid:
   						var pos = entry.get("pos", [0, 0, 0])
   						var rot = entry.get("rot", [0, 0, 0])
   						var size = entry.get("size", [s.mesh_size.x, s.mesh_size.y])
   						s.position = Vector3(pos[0], pos[1], pos[2])
   						s.rotation = Vector3(rot[0], rot[1], rot[2])
   						s.mesh_size = Vector2(size[0], size[1])
   						s.curvature = entry.get("curvature", s.curvature)
   						s.apply_curvature()
   						break
   ```
   Load order matches the plan: `from_dict` → `validate(frame_size)` → fall back to `single()` on failure
   (never `rescale_to()` at load time — the live frame size is only known once streaming actually starts;
   D2's `resize_stream_viewport()` rescale path is what reconciles a saved layout against the frame that
   ultimately arrives). Placement restoration only touches screens that survived `apply_screen_layout()`
   (i.e. only enabled monitors get a `VRScreen` at all), and is a no-op for anyone whose `id` isn't found.

3. **JSON strings inside `ConfigFile`, not nested Dictionaries.** This is why `to_dict()`/`from_dict()` in
   `screen_layout.gd` (B1) return/accept plain `Dictionary`/`Array`/`String`/`int` values only — `ConfigFile`
   can technically serialize nested Dictionaries directly via `set_value`, but doing so uses Godot's binary
   Variant encoding, which is not the same bytes as the future host-manifest JSON wire format. Storing the
   `JSON.stringify()` result as a plain string means the exact same parser
   (`JSON.parse_string()`/`ScreenLayout.from_dict()`) handles both the local save file and, later, a
   manifest received from a patched host — a free round-trip test of the wire format every time a user
   launches the app with a saved layout.

**Verify:**
```bash
grep -n "screen_layout\|screen_placements" src/state_manager.gd   # expect: both keys appear in save + load
```
Manual test: set a 2-up layout, drag one of the two screens to a new position, disconnect and quit the app
entirely, relaunch, reconnect to the same host. Confirm: the 2-up layout is restored, the dragged screen is
back at the position you left it, and the *other* (untouched) screen is still at its original position.
Then edit `user://host_state.cfg` by hand (it's a plain-text `ConfigFile`) and corrupt the `screen_layout`
JSON string — relaunch and confirm the app falls back to a single full-frame screen instead of crashing.

---

## Feature-interaction decisions

- **SBS when N>1 → primary-only, already true by construction.** `apply_stereo()`
  (`settings_controller.gd`) and `switch_to_comp_layer()`/`switch_to_stereo_comp_layer()`
  (`composition_layer_manager.gd`, rewritten in A5/C2) only ever write the `stereo_mode` shader parameter
  onto `main.primary_screen`'s materials — no code path in this plan sets it on any other screen's
  `comp_shader_mat`, and non-primary screens never get a left/right stereo pair at all (C2's lazy creation).
  So a non-primary screen's `stereo_mode` uniform simply stays at its shader default (`0`) for the whole
  session. The only thing worth adding is a status message: in `src/settings_controller.gd`, function
  `cycle_sbs_mode()`, find:
  ```gdscript
  func cycle_sbs_mode():
  	main.sbs_mode = (main.sbs_mode + 1) % 3
  	_save_setting(main._ui_sbs_btn, sbs_labels[main.sbs_mode])
  	main.ui_controller.update_3d_btn_state()
  	apply_stereo()
  ```
  Replace with:
  ```gdscript
  func cycle_sbs_mode():
  	main.sbs_mode = (main.sbs_mode + 1) % 3
  	_save_setting(main._ui_sbs_btn, sbs_labels[main.sbs_mode])
  	main.ui_controller.update_3d_btn_state()
  	apply_stereo()
  	if main.sbs_mode > 0 and main.screens.size() > 1:
  		main._ui_status_label.text = "SBS applies to primary screen only"
  ```

- **AI-3D when N>1 → primary-only, and nearly free.** Once C4 binds depth estimation to
  `primary_screen.comp_viewport` (already sized to just that screen's tile), the depth map is automatically
  correct for the primary tile at zero extra inference cost — no per-screen depth models. On the **mesh
  path** (Linux), where there is no per-tile comp viewport to sample, grey out the 3D-AI button whenever
  `screens.size() > 1`. In `src/ui_controller.gd`, locate `update_3d_btn_state()` and find its existing
  disable condition (search for `_ui_3d_btn.disabled =`); add `or main.screens.size() > 1` to whatever
  boolean expression already gates it, e.g.:
  ```gdscript
  main._ui_3d_btn.disabled = (OS.get_name() != "Android") or main.screens.size() > 1
  ```
  (adjust to match the exact existing condition rather than replacing it wholesale — the point is to `or`
  in the new clause, not to drop the existing Android-only gate).

- **Curvature → per-screen storage, global editing in v1.** Already implemented as designed: `VRScreen.curvature`
  is the storage (A1), `ScreenManager.cycle_curvature()` (A4) fans a single UI action out to every screen in
  `main.screens`. No further work needed — this is a statement of what already landed, included here so the
  design intent (why curvature isn't a single `main`-level int) is documented alongside the other
  interaction decisions.

- **Mid-session resolution change → fully implemented in D2** (`stream_manager.resize_stream_viewport()`):
  same aspect rescales the layout losslessly; different aspect resets to `ScreenLayout.single()` and posts
  a status message. Nothing further needed here.

---

## Risks, ranked, and where each is closed by this plan

1. **Shared `ShaderMaterial` across instanced screens** (C1). Closed by: `resource_local_to_scene = true` on
   `ShaderMaterial_1` (A1 step 3, re-verified in C1 step 3) **and** a runtime `material_override.duplicate()`
   in `VRScreen._ready()` (C1 step 3) as a second line of defense. Verify with:
   ```bash
   grep -c "resource_local_to_scene = true" src/vr_screen.tscn   # expect: >= 1
   ```

2. **Corner-handle collision from adjacent screens** (A7 step 14, D3). Closed by making `Area3D.monitoring`
   follow `.visible` on every corner handle, instead of leaving all 4×N corner colliders permanently
   `monitoring = true`.

3. **Comp-layer count / swapchain memory on Quest** (C2). Closed by: lazy stereo pair (only primary, only
   when SBS/AI-3D active), `MAX_SCREENS = 4` hard cap (C1), and the `[COMP] screens=N layers=N+5` budget log
   line — read `user://debug.log` on real hardware and confirm layer count stays under the runtime's
   `maxLayerCount` (typically 16 on Quest) at your target N.

4. **Seam bleed from filter taps** (B2). Closed by funnelling every texture read through
   `sample_stream()` → `clamp_to_region()` in both shaders, and by deleting the two RGB-path functions that
   used to bypass the clamp entirely. Verify with the synthetic quadrant/magenta-border test image described
   below, at max blur/sharpen settings (where the bleed would be most visible).

5. **Per-frame rebind cost at N screens** (C3). Closed by the RID-comparison dirty-guard in
   `bind_yuv_textures()`.

6. **`short` overflow** at desktop bounds ≥ 32768 px (`input_bridge.cpp:17`, `LiSendMousePositionEvent`
   casts to `short`). Closed by `ScreenLayout.validate()`'s explicit `desktop_bounds.size.x/y > 32767` check
   (B1) — any layout that would overflow is rejected before it's ever applied.

7. **Host reference-plane assumption.** Not closable purely client-side: Sunshine/Apollo/Polaris map
   `LiSendMousePositionEvent`'s reference plane onto whatever display they captured, and there is no
   resolution negotiation in the protocol — the launch response echoes back the *requested* width/height
   (`computer_manager.cpp`), and the *actual* negotiated dimensions only surface later via
   `_cb_decoder_setup`, discovered by GDScript polling in `update_stats()`. If the requested stream
   resolution's aspect doesn't match the host's actual captured display, the host letterboxes and absolute
   positioning is off — this is already true today for a single screen; tiling just makes any residual error
   visibly asymmetric across monitors instead of uniformly wrong. Mitigation implemented: D2's
   aspect-change-triggers-reset logic, so at least the failure mode is "layout resets and tells you why"
   rather than "mouse silently lands on the wrong monitor."

8. **`primary_screen == null` during `_ready()`.** Closed by guarding every A3 alias getter/setter with `if
   primary_screen else <default>` — verify no getter was written without the guard:
   ```bash
   grep -A2 "^var .*:$" main.gd | grep -B2 "get: return primary_screen" | grep -c "if primary_screen"
   ```

9. **`main.gd` growth.** A8 is a cleanup pass, not a hard requirement — it only deletes aliases with zero
   remaining external callers. Accept that some aliases may still be load-bearing scaffolding at the end of
   this branch; do not force-delete an alias that still has a caller just to hit a line-count goal.

---

## Verification strategy

### Without a headset

`main.gd`'s `_ready()` hard-quits when OpenXR isn't initialized (`if not interface or not
interface.is_initialized(): ... get_tree().quit()`). Add an escape hatch: find that block and wrap the quit
in a check for a command-line flag, e.g.
```gdscript
	var interface = XRServer.find_interface("OpenXR")
	if not interface or not interface.is_initialized():
		if "--nf-no-xr" in OS.get_cmdline_user_args():
			_log("[XR] --nf-no-xr set, continuing without OpenXR for desktop testing")
			return
		_log("[XR] OpenXR not available - cannot run without VR runtime")
		if not Engine.is_editor_hint():
			get_tree().quit()
		return
```
This is a **debug-only convenience**, not part of the shipped feature — treat it as scaffolding you may
strip before merging, or gate it behind a build flag if the project has one. With it, run
`godot --path . -- --nf-no-xr` and exercise: layout math (`ScreenLayout`), shader correctness (bind a test
image via the welcome-viewport path), tile→desktop mouse mapping, corner resize, grab, and the persistence
round-trip — all without a headset, since `xr_interaction.get_active_raycast()` already falls back to
`main.mouse_raycast` when `is_xr_active` is false.

### Unit tests

No test framework exists for GDScript in this repo (`test/` is C++-only). Add
`test/test_screen_layout.gd`, run via `godot --headless --script test/test_screen_layout.gd`, using plain
`assert()`:
```gdscript
extends SceneTree

func _init():
	_test_single_identity()
	_test_split_h()
	_test_validate_catches_short_overflow()
	_test_round_trip()
	print("All screen_layout tests passed")
	quit()

func _test_single_identity():
	var l = ScreenLayout.single(Vector2i(1920, 1080))
	assert(l.validate(l.frame_size) == "")
	assert(l.monitors.size() == 1)
	assert(l.uv_region_for(l.monitors[0]) == Vector4(0, 0, 1, 1))

func _test_split_h():
	var l = ScreenLayout.split_h(Vector2i(3840, 1080), 2)
	assert(l.validate(l.frame_size) == "")
	assert(l.monitors.size() == 2)
	assert(l.monitors[0].frame_rect.size.x + l.monitors[1].frame_rect.size.x == 3840)

func _test_validate_catches_short_overflow():
	var l = ScreenLayout.single(Vector2i(1920, 1080))
	l.desktop_bounds.size = Vector2i(40000, 1080)
	assert(l.validate(l.frame_size) != "")

func _test_round_trip():
	var l = ScreenLayout.split_h(Vector2i(2560, 1080), 2)
	var d = l.to_dict()
	var json = JSON.stringify(d)
	var back = ScreenLayout.from_dict(JSON.parse_string(json))
	assert(back.monitors.size() == l.monitors.size())
	assert(back.monitors[0].frame_rect == l.monitors[0].frame_rect)
```

### Shader test with no live stream

Bind a synthetic test image through the existing welcome-viewport path
(`CompositionLayerManager.connect_welcome_texture()`, which already sets `yuv_mode = 0` and binds
`welcome_viewport.get_texture()`). Generate an image with numbered quadrants and a 1px magenta border at
every intended tile seam and at the outer frame edge — e.g. add a temporary debug function:
```gdscript
func _make_seam_test_image(size: Vector2i, tiles_x: int) -> ImageTexture:
	var img = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var colors = [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW]
	var tile_w = size.x / tiles_x
	for x in range(size.x):
		for y in range(size.y):
			var tile_idx = x / tile_w
			img.set_pixel(x, y, colors[tile_idx % colors.size()])
	for i in range(1, tiles_x):
		var seam_x = i * tile_w
		img.fill_rect(Rect2i(seam_x - 1, 0, 2, size.y), Color.MAGENTA)
	img.fill_rect(Rect2i(0, 0, size.x, 1), Color.MAGENTA)
	img.fill_rect(Rect2i(0, size.y - 1, size.x, 1), Color.MAGENTA)
	img.fill_rect(Rect2i(0, 0, 1, size.y), Color.MAGENTA)
	img.fill_rect(Rect2i(size.x - 1, 0, 1, size.y), Color.MAGENTA)
	return ImageTexture.create_from_image(img)
```
Bind it as `welcome_viewport`'s content (or directly as `main_texture` on the primary screen's material for
a quicker check), apply a 2-up or 3-up layout, and inspect each tile:
- Magenta visible **inside** a tile (not at its true edge) ⇒ seam bleed — `clamp_to_region()` guard too
  loose.
- Magenta **missing** at the frame's true outer edge ⇒ over-clamping.
- Repeat at every `smooth_mode` (0-5) and `sharpen_mode` (0-5) — the blur kernel taps `± texel *
  filter_mode * 4.0`, so bleed is most visible at high filter settings, not at 0.

### Getting a wide virtual display for real-stream testing

Cheapest first: **no wide display at all** — take a normal 1920×1080 desktop, apply a 2-up preset splitting
it into two 960-wide tiles. Every code path is exercised (uv_region, seams, per-tile mouse mapping — the
cursor landing correctly on each half is direct proof), only screen real estate is missing. Then, if a wider
canvas is needed:
- Linux headless: `xserver-xorg-video-dummy` with `Virtual 3840 1080` in the X config (most reliable, no
  physical monitor needed).
- Linux with hardware: `xrandr --newmode` + `--addmode` for a custom wide mode, or `xrandr --setmonitor` to
  present two physical outputs as one wide logical monitor.
- Linux nested: `Xephyr -screen 3840x1080` or `weston --width=3840 --height=1080`, with Sunshine/Apollo's
  `output_name` pointed at it.
- Windows: Apollo + SudoVDA at 3840×1080 (this branch's eventual first-class target per the Follow-up
  section).

### Platform-specific fast loops

- **Linux PCVR** (mesh path): `./build.sh --appimage`, no APK install — the fastest iteration loop for
  Phases A/B/D/E. Monado's `simulated` HMD driver (`P_OVERRIDE_ACTIVE_CONFIG=simulated`) gives a real OpenXR
  session with no physical headset, rendering to a debug window, and exercises `is_xr_active = true` code
  paths that the `--nf-no-xr` flag above cannot.
- **Quest** (comp-layer path, Phase C): required for layer-count and swapchain-memory validation, and for
  MediaCodec HEVC decode-dimension limits — **verify a 3840×1080 stream actually decodes before committing
  to a 3-up 1440p (5760×1440) preset**; this is a hardware limit this plan cannot work around, only detect
  and log.

### Minimum test matrix

| Case | Linux mesh | Quest comp |
|---|---|---|
| N=1 identity layout | pixel-identical to pre-refactor | pixel-identical |
| N=2 half-split of 1920×1080 | seams, per-tile mouse | + 2nd cylinder |
| N=2 of 3840×1080 | — | decode limits |
| N=3 of 5760×1080 | — | layer budget (`[COMP] screens=3 layers=8`) |
| SBS on with N=2 | primary only, status message | + 1 layer |
| AI-3D on with N=2 | button disabled | primary tile only |
| Resolution change, same aspect | layout rescales, placements kept | same |
| Resolution change, aspect differs | collapses to 1, status message | same |
| Disable monitor 2 | node freed, no leaked layer | swapchain released |
| Restart app | placements restored by id | same |
| Corrupted `screen_layout` JSON | falls back to `single()`, no crash | same |

---

## Follow-up (not this branch)

**Server-side compositing + manifest**, target **Polaris** first (smallest codebase, macOS/Linux). The
client built by this plan is already manifest-shaped, so the server phase needs:

- Host: capture N monitors, pack into one canvas, emit `<NfLayout>{json}</NfLayout>` in the launch XML
  using the exact `ScreenLayout.to_dict()` schema (B1), and advertise capability via a
  `ServerCodecModeSupport` bit — precedent: the shipped RAW-codec work advertises `0x10000` at
  `stream_manager.gd:137` and decodes an SCM bit at `stream_manager.gd:101`.
- Host: map `LiSendMousePositionEvent` reference-plane coordinates onto the union of captured displays
  (i.e. onto `desktop_bounds`, not the packed canvas).
- Client: ~5 lines in `computer_manager.cpp`'s `_on_launch_request_completed`, next to the existing
  `sessionUrl0` parse, using the already-present `_extract_xml_value()` helper, feeding
  `ScreenLayout.from_dict()` with `source = &"host_manifest"`. No other client change — `apply_screen_layout()`
  (E1) doesn't care whether the layout it receives came from a UI preset or a parsed manifest.
