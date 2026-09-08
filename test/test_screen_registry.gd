extends SceneTree

func _init():
	_test_membership_and_limit()
	_test_primary_guards()
	print("All screen_registry tests passed")
	quit()

func _test_membership_and_limit() -> void:
	var registry := ScreenRegistry.new()
	var initial := VRScreen.new()
	var created: Array[VRScreen] = [initial]
	registry.initialize(initial)
	assert(registry.screens == [initial])
	for index in ScreenRegistry.MAX_SCREENS - 1:
		var screen := VRScreen.new()
		created.append(screen)
		assert(registry.add(screen), "screen %d should fit" % index)
	assert(not registry.can_add())
	var overflow := VRScreen.new()
	created.append(overflow)
	assert(not registry.add(overflow))
	assert(not registry.add(initial))
	_free_all(created)

func _test_primary_guards() -> void:
	var registry := ScreenRegistry.new()
	var initial := VRScreen.new()
	var secondary := VRScreen.new()
	var unknown := VRScreen.new()
	registry.initialize(initial)
	assert(registry.add(secondary))
	assert(not registry.remove(initial))
	assert(not registry.set_primary(unknown))
	assert(registry.set_primary(secondary))
	assert(registry.primary == secondary)
	assert(registry.remove(initial))
	assert(registry.screens == [secondary])
	_free_all([initial, secondary, unknown])

func _free_all(nodes: Array) -> void:
	for node in nodes:
		node.free()
