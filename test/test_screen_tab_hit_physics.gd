extends SceneTree

func _init(): _run.call_deferred()

func _run():
	var world := Node3D.new()
	root.add_child(world)
	var mesh_size := Vector2(2.24, 1.26)
	var pages := [{"id": 1}, {"id": 2}, {"id": 3}, {"id": 4}]
	var rects := ScreenTabStrip.page_rects(pages, 2)
	for radius in [1.0, 3.0, 300.0]:
		var areas: Array[Area3D] = []
		for i in rects.size():
			var area := Area3D.new()
			area.collision_layer = 2
			area.collision_mask = 0
			area.monitoring = false
			area.set_meta(&"slot", i)
			var collision := CollisionShape3D.new()
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			shape.set_faces(ScreenTabStrip.hit_faces(rects[i], mesh_size, radius))
			collision.shape = shape
			area.add_child(collision)
			world.add_child(area)
			areas.append(area)
		for frame in range(3): await physics_frame
		var space := world.get_world_3d().direct_space_state
		for i in rects.size():
			for fraction in [0.1, 0.5, 0.9]:
				var arc_x: float = (rects[i].position.x + rects[i].size.x * fraction) * mesh_size.x
				var x: float = sin(arc_x / (radius + 0.003)) * (radius + 0.003)
				var y: float = mesh_size.y * 0.5 - rects[i].get_center().y * mesh_size.x
				var query := PhysicsRayQueryParameters3D.create(Vector3(x, y, 2), Vector3(x, y, -2), 2)
				query.collide_with_areas = true
				query.collide_with_bodies = false
				var hit := space.intersect_ray(query)
				assert(not hit.is_empty(), "Tab has an unclickable region")
				assert(hit.collider.get_meta(&"slot") == i, "Neighbouring tab intercepted the hit")
		for area in areas: area.free()
	# Source-menu rows overlap the video. The video has a 10 mm-thick
	# collider: verify the menu wins, not merely that it is hittable alone.
	var video := Area3D.new()
	video.collision_layer = 2
	var video_collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(mesh_size.x, mesh_size.y, 0.01)
	video_collision.shape = box
	video.add_child(video_collision)
	world.add_child(video)
	var menu := Area3D.new()
	menu.collision_layer = 2
	var menu_collision := CollisionShape3D.new()
	var menu_shape := ConcavePolygonShape3D.new()
	menu_shape.backface_collision = true
	var menu_rect := Rect2(0.12, -0.014, 0.31, 0.04)
	menu_shape.set_faces(ScreenTabStrip.hit_faces(menu_rect, mesh_size, 300.0))
	menu_collision.shape = menu_shape
	menu.add_child(menu_collision)
	world.add_child(menu)
	var backdrop := Area3D.new()
	backdrop.collision_layer = 2
	backdrop.position.z = -0.006
	var backdrop_collision := CollisionShape3D.new()
	var backdrop_shape := ConcavePolygonShape3D.new()
	backdrop_shape.backface_collision = true
	backdrop_shape.set_faces(ScreenTabStrip.hit_faces(Rect2(-0.46, -0.085, 0.92, 0.21), mesh_size, 300.0))
	backdrop_collision.shape = backdrop_shape
	backdrop.add_child(backdrop_collision)
	world.add_child(backdrop)
	for frame in range(3): await physics_frame
	var menu_point := Vector3(menu_rect.get_center().x * mesh_size.x,
		mesh_size.y * 0.5 - menu_rect.get_center().y * mesh_size.x, 0)
	var menu_query := PhysicsRayQueryParameters3D.create(menu_point + Vector3(0, 0, 2), menu_point + Vector3(0, 0, -2), 2)
	menu_query.collide_with_areas = true
	menu_query.collide_with_bodies = false
	var menu_hit := world.get_world_3d().direct_space_state.intersect_ray(menu_query)
	assert(not menu_hit.is_empty() and menu_hit.collider == menu, "Video/backdrop intercepted the source dropdown")
	# The background must still catch a gap without stealing actual buttons.
	menu_query.from = Vector3(0, mesh_size.y * 0.5 + 0.01, 2)
	menu_query.to = Vector3(0, mesh_size.y * 0.5 + 0.01, -2)
	var gap_hit := world.get_world_3d().direct_space_state.intersect_ray(menu_query)
	assert(not gap_hit.is_empty() and gap_hit.collider == backdrop, "Tab gap must retain hover")
	for radius in [1.0, 3.0, 300.0]:
		menu_shape.set_faces(ScreenTabStrip.hit_faces(menu_rect, mesh_size, radius))
		backdrop_shape.set_faces(ScreenTabStrip.hit_faces(Rect2(-0.46, -0.085, 0.92, 0.21), mesh_size, radius))
		for frame in range(3): await physics_frame
		for fraction in [0.1, 0.5, 0.9]:
			var arc: float = (menu_rect.position.x + menu_rect.size.x * fraction) * mesh_size.x
			var x: float = sin(arc / (radius + 0.003)) * (radius + 0.003)
			menu_query.from = Vector3(x, menu_point.y, 2)
			menu_query.to = Vector3(x, menu_point.y, -2)
			var curved_hit := world.get_world_3d().direct_space_state.intersect_ray(menu_query)
			assert(not curved_hit.is_empty() and curved_hit.collider == menu, "Backdrop swallowed a curved dropdown button")
	world.free()
	print("All screen tab physics ray tests passed")
	quit()
