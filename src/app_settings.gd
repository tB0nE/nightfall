class_name AppSettings
extends RefCounted

## Typed, side-effect-free application settings.
##
## Runtime controllers may react to these values, but this object deliberately
## owns no UI nodes, renderer objects, persistence paths, or platform checks.
## Settings are moving here one group at a time so existing behavior can remain
## stable while main.gd compatibility properties are retired gradually.

const APP_STATE_VERSION := 1

const DEFAULT_BEZEL_ENABLED := true
const DEFAULT_PASSTHROUGH_ENABLED := false
const DEFAULT_BACKGROUND_MODE := 0
const DEFAULT_SHARPEN_MODE := 0
const DEFAULT_BRIGHTNESS_PCT := 0
const DEFAULT_CONTRAST_PCT := 100
const DEFAULT_GAMMA_PCT := 100
const DEFAULT_AMBIENT_MODE := 0
const DEFAULT_AMBIENT_COLOR := 0

var bezel_enabled: bool = DEFAULT_BEZEL_ENABLED
var passthrough_enabled: bool = DEFAULT_PASSTHROUGH_ENABLED
var background_mode: int = DEFAULT_BACKGROUND_MODE
var sharpen_mode: int = DEFAULT_SHARPEN_MODE
var brightness_pct: int = DEFAULT_BRIGHTNESS_PCT
var contrast_pct: int = DEFAULT_CONTRAST_PCT
var gamma_pct: int = DEFAULT_GAMMA_PCT
var ambient_mode: int = DEFAULT_AMBIENT_MODE
var ambient_color: int = DEFAULT_AMBIENT_COLOR

func reset_display() -> void:
	bezel_enabled = DEFAULT_BEZEL_ENABLED
	passthrough_enabled = DEFAULT_PASSTHROUGH_ENABLED
	background_mode = DEFAULT_BACKGROUND_MODE
	sharpen_mode = DEFAULT_SHARPEN_MODE
	brightness_pct = DEFAULT_BRIGHTNESS_PCT
	contrast_pct = DEFAULT_CONTRAST_PCT
	gamma_pct = DEFAULT_GAMMA_PCT
	ambient_mode = DEFAULT_AMBIENT_MODE
	ambient_color = DEFAULT_AMBIENT_COLOR
