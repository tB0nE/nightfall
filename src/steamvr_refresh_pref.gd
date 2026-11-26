class_name SteamVRRefreshPref
extends RefCounted

## SteamVR on Linux only offers an app the refresh rate stored for it (per-app
## "Refresh Rate Override"; 72 Hz on the Steam Frame until the user sets one).
## Steam apps can ship a vrpreferences.json, but SteamVR reads that only from a
## Steam install folder, so a Nightfall started any other way is stuck at 72 Hz
## and every stream above that is capped.
##
## When that happens and the user has not chosen a rate for Nightfall, store
## the wanted rate for Nightfall's own SteamVR app key with SteamVR's vrcmd.
## SteamVR switches the display live. A rate the user already set is never
## changed.

const SETTING := "preferredRefreshRate"

## vrcmd next to the active OpenXR runtime's vrclient.so, or "" when the runtime
## is not SteamVR or vrcmd is missing.
static func vrcmd_path() -> String:
	var config := OS.get_environment("XDG_CONFIG_HOME")
	if config.is_empty():
		config = OS.get_environment("HOME").path_join(".config")
	var json_path := config.path_join("openxr/1/active_runtime.json")
	if not FileAccess.file_exists(json_path):
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	var runtime: Dictionary = parsed.get("runtime", {})
	if not runtime.get("VALVE_runtime_is_steamvr", false) and str(runtime.get("name", "")) != "SteamVR":
		return ""
	var library := str(runtime.get("library_path", ""))
	if library.is_empty():
		return ""
	if not library.is_absolute_path():
		# The runtime file is usually a symlink into SteamVR; relative paths
		# are relative to the real file.
		var out: Array = []
		var real := json_path
		if OS.execute("readlink", ["-f", json_path], out) == 0 and not out.is_empty():
			real = str(out[0]).strip_edges()
		library = real.get_base_dir().path_join(library)
	var vrcmd := library.get_base_dir().path_join("vrcmd")
	return vrcmd if FileAccess.file_exists(vrcmd) else ""

## The app key SteamVR uses for this process, picked from `vrcmd --dumpapps`
## output: steam.app.<id> when Steam launched us, otherwise
## system.generated.openxr.<app>.<executable>.
static func app_key(dumpapps: String, executable: String, steam_app_id: String) -> String:
	var keys: Array[String] = []
	for line in dumpapps.split("\n"):
		var key := line.split(" : ")[0].strip_edges()
		if not key.is_empty():
			keys.append(key)
	if not steam_app_id.is_empty():
		var steam_key := "steam.app." + steam_app_id
		return steam_key if keys.has(steam_key) else ""
	var names := [executable.to_lower(), executable.get_basename().to_lower()]
	for key in keys:
		if not key.begins_with("system.generated.openxr."):
			continue
		for name in names:
			if not name.is_empty() and key.to_lower().ends_with("." + name):
				return key
	return ""

## The stored value from `vrcmd --settings-float <key>.<setting>` output, or
## -1 when the user has not set one (vrcmd then prints no "key=value" line).
static func stored_value(output: String, setting_path: String) -> float:
	for line in output.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with(setting_path + "="):
			return trimmed.trim_prefix(setting_path + "=").to_float()
	return -1.0

static func _vrcmd(vrcmd: String, args: PackedStringArray) -> String:
	var out: Array = []
	var env_args := PackedStringArray(["LD_LIBRARY_PATH=" + vrcmd.get_base_dir(), vrcmd])
	env_args.append_array(args)
	OS.execute("env", env_args, out, true)
	return "\n".join(out)

## Blocking (a few vrcmd calls); run it off the main thread. Returns a line for
## the log.
static func ensure(target_hz: float) -> String:
	var vrcmd := vrcmd_path()
	if vrcmd.is_empty():
		return "SteamVR's vrcmd not found; set Nightfall's refresh rate in SteamVR Settings > Video > Per-Application Video Settings"
	var executable := OS.get_executable_path().get_file()
	var key := app_key(_vrcmd(vrcmd, ["--dumpapps"]), executable, OS.get_environment("SteamAppId"))
	if key.is_empty():
		return "Couldn't find Nightfall's SteamVR app key; refresh rate left as is"
	var path := key + "." + SETTING
	var stored := stored_value(_vrcmd(vrcmd, ["--settings-float", path]), path)
	if stored > 0.0:
		return "SteamVR has %.0fHz stored for %s (user choice); leaving it" % [stored, key]
	var target := int(round(target_hz))
	_vrcmd(vrcmd, ["--set-settings-float", path, str(target)])
	var now := stored_value(_vrcmd(vrcmd, ["--settings-float", path]), path)
	if absf(now - target) < 0.6:
		return "No refresh rate stored for %s; set %dHz (SteamVR switches live)" % [key, target]
	return "Setting %s to %dHz didn't stick" % [path, target]
