class_name SphereLayers
extends RefCounted

## Screens on the sphere grid are drawn as latitude/longitude bands of one
## sphere (OpenXR equirect2 layers), so they warp with it and tile edge to edge.
## A band layer is a child of the cylinder layer it replaces: it shares that
## layer's visibility, and is freed with it. A SubViewport can feed only one
## composition layer, so the viewport moves to whichever of the two is in use.
## Bands off the equator need the godot-4.7-equirect-bands engine patch.

const NODE_NAME := "SphereBand"

static func band_of(cylinder: Node) -> OpenXRCompositionLayerEquirect:
	if cylinder == null: return null
	return cylinder.get_node_or_null(NODE_NAME) as OpenXRCompositionLayerEquirect

## The viewport this cylinder's picture comes from, whichever layer holds it.
static func viewport_of(cylinder: OpenXRCompositionLayer) -> SubViewport:
	if cylinder == null: return null
	var band := band_of(cylinder)
	if band != null and band.get_layer_viewport() != null: return band.get_layer_viewport()
	return cylinder.get_layer_viewport()

## Use in place of cylinder.set_layer_viewport(): leaves a band that already
## shows the viewport alone instead of failing to share it.
static func bind(cylinder: OpenXRCompositionLayer, viewport: SubViewport) -> void:
	if cylinder == null: return
	var band := band_of(cylinder)
	if band != null and viewport != null and band.get_layer_viewport() == viewport: return
	cylinder.set_layer_viewport(viewport)

static func supported() -> bool:
	return ClassDB.class_exists("OpenXRCompositionLayerEquirect")

## Show the cylinder's picture as a sphere band (on) or on the cylinder again (off).
## frame: the sphere's centre and orientation, -Z through the band's centre
## longitude. Angles in radians; upper/lower are latitudes (lower < upper).
static func sync(cylinder: OpenXRCompositionLayer, on: bool, frame: Transform3D, radius: float,
		horizontal: float, upper: float, lower: float, sort_order: int) -> bool:
	if cylinder == null: return false
	var band := band_of(cylinder)
	if not on or not supported():
		if band != null and band.get_layer_viewport() != null:
			var viewport := band.get_layer_viewport()
			band.set_layer_viewport(null)
			cylinder.set_layer_viewport(viewport)
		if band != null: band.visible = false
		return false
	if band == null:
		band = OpenXRCompositionLayerEquirect.new()
		band.name = NODE_NAME
		band.set_enable_hole_punch(false)
		band.set_alpha_blend(cylinder.get_alpha_blend())
		band.set_eye_visibility(cylinder.get_eye_visibility())
		cylinder.add_child(band)
	band.visible = true
	var viewport := cylinder.get_layer_viewport()
	if viewport != null:
		cylinder.set_layer_viewport(null)
		band.set_layer_viewport(viewport)
	band.set_sort_order(sort_order)
	band.set_radius(maxf(radius, 0.05))
	band.set_central_horizontal_angle(clampf(horizontal, 0.001, TAU))
	upper = clampf(upper, -PI * 0.5 + 0.001, PI * 0.5)
	lower = clampf(lower, -PI * 0.5, upper - 0.001)
	band.set_upper_vertical_angle(upper)
	# Godot's lower angle counts downwards from the equator.
	band.set_lower_vertical_angle(-lower)
	band.global_transform = frame
	return true

## Before freeing a cylinder layer: detach its band's viewport like its own.
static func release(cylinder: OpenXRCompositionLayer) -> void:
	var band := band_of(cylinder)
	if band != null:
		band.visible = false
		band.set_layer_viewport(null)
