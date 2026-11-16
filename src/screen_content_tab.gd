class_name ScreenContentTab
extends RefCounted

const STREAM: StringName = &"stream"
const BROWSER: StringName = &"browser"
const LOCAL_MEDIA: StringName = &"local_media"
const KINDS: Array[StringName] = [STREAM, BROWSER, LOCAL_MEDIA]
const MEDIA_SOURCES: Array[StringName] = [&"file", &"smb", &"plex", &"jellyfin"]

var id: StringName = &""
var kind: StringName = STREAM
var title: String = ""
# Locators only: credentials belong in provider-owned secure storage.
var locator: Dictionary = {}
var keep_audio_playing: bool = false
var muted: bool = false
## Session-local presentation preferences. ZERO/-1 inherit the app defaults.
## These belong to content, never the physical VR screen hosting it.
var resolution := Vector2i.ZERO
var crop_mode := -1

func validate() -> String:
	if id == &"":
		return "tab identity is empty"
	if kind not in KINDS:
		return "unknown content type"
	if resolution != Vector2i.ZERO and (resolution.x <= 0 or resolution.y <= 0 or resolution.x > 8192 or resolution.y > 8192):
		return "invalid tab resolution"
	if crop_mode < -1 or crop_mode > 6:
		return "invalid tab crop mode"
	match kind:
		STREAM:
			if str(locator.get("monitor_id", "")).is_empty():
				return "stream tab needs a monitor identity"
		BROWSER:
			var url := str(locator.get("url", ""))
			if url != "about:blank" and not url.begins_with("https://") and not url.begins_with("http://"):
				return "browser tab needs an HTTP(S) URL or about:blank"
		LOCAL_MEDIA:
			if StringName(locator.get("source", "")) not in MEDIA_SOURCES:
				return "unknown media source"
			if str(locator.get("item", "")).is_empty():
				return "media tab needs an item locator"
	return ""

func effective_resolution(default_size: Vector2i) -> Vector2i:
	return default_size if resolution == Vector2i.ZERO else resolution

func effective_crop(default_mode: int) -> int:
	return default_mode if crop_mode == -1 else crop_mode

static func _whole_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floorf(float(value))

static func for_monitor(monitor_id: StringName) -> ScreenContentTab:
	var tab := ScreenContentTab.new()
	tab.id = StringName("monitor:" + String(monitor_id))
	tab.title = String(monitor_id)
	tab.locator = {"monitor_id": String(monitor_id)}
	return tab

# Only approved locator fields enter workspace files. Never dump arbitrary
# provider dictionaries (which may contain authentication headers or tokens).
func to_dict() -> Dictionary:
	var saved_locator := {}
	var fields: Array = ["session_id", "monitor_id"] if kind == STREAM else (["url"] if kind == BROWSER else ["source", "server_id", "item"])
	for key in fields:
		if locator.has(key):
			saved_locator[key] = str(locator[key])
	return {"id": String(id), "kind": String(kind), "title": title,
		"locator": saved_locator, "keep_audio_playing": keep_audio_playing, "muted": muted,
		"resolution": [resolution.x, resolution.y], "crop_mode": crop_mode}

static func from_dict(data: Dictionary) -> ScreenContentTab:
	var tab := ScreenContentTab.new()
	tab.id = StringName(str(data.get("id", "")))
	tab.kind = StringName(str(data.get("kind", "")))
	tab.title = str(data.get("title", ""))
	var source = data.get("locator", {})
	if source is Dictionary:
		tab.locator = source.duplicate(true)
	tab.keep_audio_playing = bool(data.get("keep_audio_playing", false))
	tab.muted = bool(data.get("muted", false))
	var dimensions = data.get("resolution", [0, 0])
	if dimensions is Array and dimensions.size() == 2 and _whole_number(dimensions[0]) and _whole_number(dimensions[1]):
		tab.resolution = Vector2i(dimensions[0], dimensions[1])
	else:
		tab.resolution = Vector2i(-1, -1) # Transactional restore rejects malformed preferences.
	var crop = data.get("crop_mode", -1)
	tab.crop_mode = int(crop) if _whole_number(crop) else -2
	return tab
