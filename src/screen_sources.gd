class_name ScreenSources
extends RefCounted

# First source-picker slice: one physical screen, existing PC/welcome content
# or the proven GPU browser. Do not expose extra screens/concurrent providers
# until input, hidden-tab audio and presentation ownership support them.
signal changed

const PRIMARY_BROWSER: StringName = &"browser:primary"
var main: Node3D
var browser_supported: bool

func _init(owner: Node3D, platform: String = "") -> void:
	main = owner
	browser_supported = (OS.get_name() if platform.is_empty() else platform) == "Android"

func can_open_browser() -> bool:
	return browser_supported and not main.browser_prototype.closing and not main.is_streaming and main.screens.size() == 1 \
		and main.session_lifecycle.phase in [SessionLifecycle.Phase.BOOT,
			SessionLifecycle.Phase.SERVER_SELECTION, SessionLifecycle.Phase.FAILED]

func choose_source(kind: StringName) -> bool:
	if kind == ScreenContentTab.BROWSER:
		if not can_open_browser():
			return false
		main.browser_prototype.start()
		return main.browser_prototype.active
	if kind == ScreenContentTab.STREAM:
		# Returning to the PC/welcome source closes the browser tab. This is
		# explicitly not hidden-tab suspension or a PC reconnect operation.
		main.browser_prototype.stop()
		return true
	return false

func browser_opened() -> void:
	var screen: VRScreen = main.primary_screen
	if screen == null:
		return
	var tabs := screen.content_tabs
	if tabs.tabs.is_empty():
		tabs.add(ScreenContentTab.for_monitor(screen.monitor_id))
	if tabs.find_tab(PRIMARY_BROWSER) == null:
		var tab := ScreenContentTab.new()
		tab.id = PRIMARY_BROWSER
		tab.kind = ScreenContentTab.BROWSER
		tab.title = "Browser"
		# Session-only identity. Do not copy navigation URLs or credentials
		# into diagnostics/workspace persistence as part of this milestone.
		tab.locator = {"url": "about:blank"}
		tabs.add(tab)
	else:
		tabs.select(PRIMARY_BROWSER)
	changed.emit()

func browser_closed() -> void:
	if main.primary_screen:
		main.primary_screen.content_tabs.remove(PRIMARY_BROWSER)
	changed.emit()
