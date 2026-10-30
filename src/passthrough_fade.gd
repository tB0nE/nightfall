class_name PassthroughFade
extends RefCounted

# Darkens passthrough so the screen and menus stand out against a bright room
# (Rush_iam: white wall). Godot's passthrough has no opacity control, so a
# compositor sphere of translucent black sits between the room and every
# other layer. Composition layers reach the compositor whether or not Godot
# submits its projection layer, so this works in projectionless mode too.

const FADE_VALUES: Array = [0, 25, 50, 75, 90]
# The Meta vendors plugin submits passthrough itself as a layer at -100, so
# the fade must sit above it, yet below the projection and ambient layers (0).
const SORT_ORDER := -50
# The C++ setter stores a float but checks against double PI/2. Exactly
# 90 degrees rounds above that bound and can leave the default 45-degree cap.
const VERTICAL_HALF_ANGLE := PI * 0.5 - 0.000001

var layer: Node3D = null
var _viewport: SubViewport = null
var _fill: ColorRect = null

static func next_fade(current: int) -> int:
	var idx := FADE_VALUES.find(current)
	return FADE_VALUES[(idx + 1) % FADE_VALUES.size()]

static func label(fade_pct: int) -> String:
	return "Off" if fade_pct <= 0 else "%d%%" % fade_pct

## Creates the layer; false when the runtime lacks equirect layers.
func setup(scene_root: Node, xr_origin: Node3D) -> bool:
	if layer:
		return true
	layer = OpenXRCompositionLayerEquirect.new()
	layer.name = "PassthroughFadeLayer"
	layer.set_sort_order(SORT_ORDER)
	layer.set_radius(40.0)
	layer.set_central_horizontal_angle(TAU)
	layer.set_upper_vertical_angle(VERTICAL_HALF_ANGLE)
	layer.set_lower_vertical_angle(VERTICAL_HALF_ANGLE)
	layer.set_enable_hole_punch(false)
	layer.set_alpha_blend(true)
	layer.visible = false
	xr_origin.add_child(layer)
	if not layer.is_natively_supported():
		layer.queue_free()
		layer = null
		return false
	_viewport = SubViewport.new()
	_viewport.name = "PassthroughFadeViewport"
	_viewport.disable_3d = true
	_viewport.transparent_bg = true
	_viewport.size = Vector2i(16, 16)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	scene_root.add_child(_viewport)
	_fill = ColorRect.new()
	_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fill.color = Color(0, 0, 0, 0)
	_viewport.add_child(_fill)
	layer.set_layer_viewport(_viewport)
	return true

## Shows the fade at `fade_pct` percent while passthrough is on.
func apply(passthrough_on: bool, fade_pct: int) -> void:
	if not layer:
		return
	var show := passthrough_on and fade_pct > 0
	if show:
		_fill.color = Color(0, 0, 0, fade_pct / 100.0)
	# A uniform 16x16 texture: rendering it continuously costs nothing, and
	# UPDATE_ONCE churns the GLES render target on Quest.
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if show else SubViewport.UPDATE_DISABLED
	layer.visible = show
