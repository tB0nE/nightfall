class_name WebApps
extends RefCounted

# Web Apps: shortcuts on the welcome screen that open a service's own website
# in Nightfall's browser, optionally with a user agent the site has a better
# mode for (YouTube's TV interface is built for a gamepad and a big screen).
# The list is data, in web_apps.json: adding an app isn't a code change.
# Everything here works without DRM, so AI 3D can see the picture.

const PATH := "res://src/web_apps.json"

## The valid entries of the list at `path`: each has an id, a name and an
## https address, and may have a user_agent. Anything else is skipped.
static func load_apps(path: String = PATH) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	return parse(file.get_as_text())

static func parse(text: String) -> Array:
	var data = JSON.parse_string(text)
	var apps: Array = []
	if not data is Array:
		return apps
	for entry in data:
		if not entry is Dictionary:
			continue
		var id := str(entry.get("id", ""))
		var name := str(entry.get("name", ""))
		var url := str(entry.get("url", ""))
		if id.is_empty() or name.is_empty() or not url.begins_with("https://"):
			continue
		apps.append({"id": id, "name": name, "url": url, "user_agent": str(entry.get("user_agent", ""))})
	return apps
