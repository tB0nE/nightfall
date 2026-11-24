class_name StoreBuild
extends Node

## Meta Horizon Store builds only (`build.sh --release --store`, export feature
## `nightfall_store`): checks that the signed-in account owns the app, as the
## store requires (VRC security; docs/plans/active/meta-horizon-store.md).
## Sideloaded builds from GitHub don't have the feature, carry no Platform SDK
## and never run this.
##
## The check runs beside start-up rather than in front of it: discovery and the
## menus come up as normal. When the account isn't entitled, the app says so on
## the main screen and quits.

## The app's ID in the Meta developer dashboard. It's public: it appears in the
## store's own URLs.
const META_APP_ID := "1499244296598470"
const FEATURE := "nightfall_store"
const SDK_SINGLETON := "MetaPlatformSDK"
const NOT_ENTITLED_TEXT := "This copy of Nightfall isn't licensed for this Meta account. Install it from the Meta Horizon Store."
const QUIT_AFTER_SECONDS := 10.0

signal checked(entitled: bool)

var main
var result := ""

static func is_store() -> bool:
	return OS.has_feature(FEATURE)

## Store builds on the headset; the Platform SDK only exists on Android.
static func wanted() -> bool:
	return is_store() and OS.get_name() == "Android"

func _init(owner) -> void:
	main = owner
	name = "StoreBuild"
	process_mode = Node.PROCESS_MODE_ALWAYS

func _ready() -> void:
	_check()

func _check() -> void:
	# Looked up by name so this script parses in builds without the toolkit.
	if not Engine.has_singleton(SDK_SINGLETON):
		_fail("Platform SDK missing")
		return
	var sdk = Engine.get_singleton(SDK_SINGLETON)
	var init_result = await sdk.initialize_platform_async(META_APP_ID).completed
	if init_result.is_error():
		_fail("initialise: %s" % _error_text(init_result))
		return
	var entitlement = await sdk.entitlement_get_is_viewer_entitled_async().completed
	if entitlement.is_error():
		_fail("entitlement: %s" % _error_text(entitlement))
		return
	result = "entitled"
	_log("[STORE] Entitlement check passed")
	checked.emit(true)

static func _error_text(message) -> String:
	var error = message.get("error")
	return "unknown error" if error == null else str(error)

func _fail(reason: String) -> void:
	result = "not entitled (%s)" % reason
	_log("[STORE] Entitlement check failed: %s" % reason)
	checked.emit(false)
	var text := Localization.t(NOT_ENTITLED_TEXT)
	# The menu's status line for the home screen; the toast for the stream
	# screen, where the overlay is visible.
	if main and main.get("ui_controller"):
		main.ui_controller.show_temporary_status(text, QUIT_AFTER_SECONDS + 1.0)
	if main and main.get("composition_toast"):
		main.composition_toast.show(text, main.get("xr_camera"), -1.0)
	await get_tree().create_timer(QUIT_AFTER_SECONDS).timeout
	get_tree().quit(1)

func _log(text: String) -> void:
	if main and main.has_method("_log"):
		main._log(text)
	else:
		print(text)
