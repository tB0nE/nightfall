class_name AppInfo
extends RefCounted

## The app's name, version and source address, for Settings > About.

const NAME := "Nightfall"
const REPOSITORY := "https://github.com/tB0nE/nightfall"
const WEBSITE := "nightfallvr.com"

static var _version := ""
static var _version_read := false

## The installed version name: "0.9.1" for releases, "0.9.1-dev+abc123" for
## dev builds. Only Android builds know it (from the package); elsewhere "".
static func version() -> String:
	if not _version_read:
		_version_read = true
		if OS.get_name() == "Android" and Engine.has_singleton("JavaClassWrapper"):
			var app = Engine.get_singleton("JavaClassWrapper").wrap("com.godot.game.GodotApp")
			if app != null:
				_version = str(app.appVersion())
	return _version

## "Nightfall 0.9.1", or "Nightfall" when the version isn't known.
static func title() -> String:
	var v := version()
	return NAME if v.is_empty() else "%s %s" % [NAME, v]

## Where the source is: the repository, whose main branch holds every
## release (store builds can carry small changes after their tag).
static func source_url() -> String:
	return REPOSITORY
