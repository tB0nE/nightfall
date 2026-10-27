extends SceneTree

# Values from Vibepollo's src/crypto.h (crypto::PERM).
const VIEW_AND_LIST := 0x3000000  # PERM::_default: every client after the first
const ALL := 0x71F1F00  # PERM::_all
const VIEW_LAUNCH_MOUSE := 0x6000800

func _init():
	assert(HostPermissions.missing(-1).is_empty(), "Sunshine doesn't report permissions")
	assert(HostPermissions.missing(ALL).is_empty())
	assert(HostPermissions.explain(HostPermissions.missing(ALL)) == "")

	var limited := HostPermissions.missing(VIEW_AND_LIST)
	assert(limited == PackedStringArray(["launch apps", "mouse", "keyboard", "controller"]))
	assert(HostPermissions.blocks_launch(VIEW_AND_LIST))
	assert(HostPermissions.explain(limited).contains("launch apps, mouse, keyboard, controller"))
	assert(HostPermissions.missing(0).size() == 4, "a disabled client lacks everything")

	assert(not HostPermissions.blocks_launch(VIEW_LAUNCH_MOUSE))
	assert(HostPermissions.missing(VIEW_LAUNCH_MOUSE) == PackedStringArray(["keyboard", "controller"]))
	assert(not HostPermissions.blocks_launch(-1))
	print("All host_permissions tests passed")
	quit()
