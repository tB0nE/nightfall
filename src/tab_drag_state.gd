class_name TabDragState
extends RefCounted

var source: VRScreen
var tab_id: StringName
var action: StringName
var origin := Vector3.ZERO
var pointer := ""
var dragging := false
var active := false
var threshold := 0.025

func begin(screen: VRScreen, id: StringName, command: StringName, point: Vector3, hand: String) -> void:
	source = screen
	tab_id = id
	action = command
	origin = point
	pointer = hand
	threshold = maxf(0.025, screen.mesh_size.x * 0.015)
	dragging = false
	active = true

func step(held: bool, point: Vector3, hand: String) -> StringName:
	if not active: return &""
	if not is_instance_valid(source) or hand != pointer or source.content_tabs.find_tab(tab_id) == null:
		cancel()
		return &"cancel"
	if point.distance_to(origin) > threshold: dragging = true
	if held: return &""
	active = false
	return &"drop" if dragging else &"click"

func cancel() -> void:
	active = false
	dragging = false
	source = null
	tab_id = &""
