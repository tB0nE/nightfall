extends SceneTree

# vrcmd --dumpapps output captured on a Steam Frame (SteamOS 0.5.10).
const DUMPAPPS := """system.generated.eyetracking : eyetracking : 
system.generated.openxr.nightfall.nftest2b : Nightfall : 
system.generated.openxr.otherapp.nightfall : Other : 
steam.app.2717807926 : Nightfall : 
system.systemui : system.systemui : builtin
"""

func _init(): call_deferred("run")

func run():
	# Started outside Steam: the generated OpenXR key of this executable.
	assert(SteamVRRefreshPref.app_key(DUMPAPPS, "nftest2b", "") == "system.generated.openxr.nightfall.nftest2b")
	assert(SteamVRRefreshPref.app_key(DUMPAPPS, "NFTEST2B.x86_64", "") == "system.generated.openxr.nightfall.nftest2b",
		"Executable extension and case don't matter")
	assert(SteamVRRefreshPref.app_key(DUMPAPPS, "missing", "") == "", "Unknown executable: no key")
	# Launched by Steam: steam.app.<id>, only when SteamVR knows it.
	assert(SteamVRRefreshPref.app_key(DUMPAPPS, "nightfall", "2717807926") == "steam.app.2717807926")
	assert(SteamVRRefreshPref.app_key(DUMPAPPS, "nightfall", "1") == "")
	# vrcmd --settings-float prints key=value only when a value is stored.
	var path := "steam.app.2717807926.preferredRefreshRate"
	assert(is_equal_approx(SteamVRRefreshPref.stored_value("%s=90.000000\n" % path, path), 90.0))
	assert(SteamVRRefreshPref.stored_value("", path) < 0.0, "Unset: nothing printed")
	assert(SteamVRRefreshPref.stored_value("other.preferredRefreshRate=144.0", path) < 0.0)
	print("test_steamvr_refresh_pref: OK")
	quit()
