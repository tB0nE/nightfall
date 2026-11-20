class_name SettingsOptionPopup
extends Control

## In-viewport modal: no native window or additional XR composition layer.
var _cancel := Callable()
var _slider: HSlider
var _committing := false
var _choice_scroll: ScrollContainer
var _choice_drag_start := 0.0
var _choice_drag_last := 0.0
var _choice_dragged := false

func _init() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 100
	hide()
	gui_input.connect(func(event):
		if event is InputEventMouseButton:
			accept_event()
			if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
				close())
	visibility_changed.connect(func():
		if not is_visible_in_tree() and not _committing and _cancel.is_valid():
			var callback := _cancel
			_cancel = Callable()
			callback.call())

func close() -> void:
	if _cancel.is_valid():
		var callback := _cancel
		_cancel = Callable()
		callback.call()
	hide()

func _finish(callback: Callable) -> void:
	_cancel = Callable()
	_committing = true
	if callback.is_valid(): callback.call()
	hide()
	_committing = false

func open_slider(title: String, value: float, minimum: float, maximum: float,
	step: float, suffix: String, preview: Callable, commit: Callable,
	cancel: Callable, reset_label: String, reset: Callable, positive_sign: bool = false) -> void:
	close()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_cancel = cancel
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(720, 320)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.12, 0.98)
	style.set_corner_radius_all(12)
	style.content_margin_left = 28
	style.content_margin_right = 28
	style.content_margin_top = 20
	style.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 18)
	panel.add_child(box)
	var heading := Label.new()
	heading.text = tr(title)
	heading.add_theme_font_size_override("font_size", 28)
	box.add_child(heading)
	var readout := Label.new()
	readout.add_theme_font_size_override("font_size", 26)
	box.add_child(readout)
	_slider = HSlider.new()
	_slider.name = "ValueSlider"
	_slider.custom_minimum_size = Vector2(0, 80)
	_slider.min_value = minimum
	_slider.max_value = maximum
	_slider.step = step
	_slider.value = value
	_slider.focus_mode = Control.FOCUS_NONE
	readout.text = ("%+d%s" if positive_sign else "%d%s") % [roundi(_slider.value), suffix]
	_slider.value_changed.connect(func(selected):
		readout.text = ("%+d%s" if positive_sign else "%d%s") % [roundi(selected), suffix]
		if preview.is_valid(): preview.call(selected))
	box.add_child(_slider)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 20)
	box.add_child(actions)
	if not reset_label.is_empty() and reset.is_valid():
		_add_action(actions, reset_label, func(): _finish(reset))
	# A slider that previews applies as it moves: its button only closes it.
	_add_action(actions, "Done" if preview.is_valid() else "Apply", func(): _finish(func(): commit.call(_slider.value)))
	show()
	move_to_front()
	_place_panel.call_deferred(panel)

func _add_action(parent: Control, label: String, callback: Callable) -> void:
	var button := Button.new()
	button.text = tr(label)
	button.custom_minimum_size = Vector2(230, 64)
	button.add_theme_font_size_override("font_size", 24)
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)

## Choices carry stable IDs, display labels and optional enabled state.
func open_choices(title: String, choices: Array, current: Variant, commit: Callable, note: String = "") -> void:
	close()
	for child in get_children():
		remove_child(child)
		child.queue_free()
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.08, 0.12, 0.98)
	style.set_corner_radius_all(12)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 16
	style.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	var heading := Label.new()
	heading.text = tr(title)
	heading.add_theme_font_size_override("font_size", 28)
	box.add_child(heading)
	var scroll := ScrollContainer.new()
	_choice_scroll = scroll
	scroll.scroll_deadzone = 1000000
	# GLES flips this clip rectangle in the menu SubViewport. Match the
	# Advanced page workaround and cull rows explicitly instead.
	scroll.clip_contents = false
	scroll.get_v_scroll_bar().value_changed.connect(func(_value): _cull_choices.call_deferred())
	scroll.gui_input.connect(_choice_drag_input)
	scroll.custom_minimum_size = Vector2.ZERO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	var grid := GridContainer.new()
	var long_labels := false
	for choice in choices:
		if tr(String(choice.label)).length() > 19: long_labels = true
	grid.columns = mini(choices.size(), 2 if long_labels else 3)
	grid.columns = maxi(grid.columns, 1)
	var button_width := 375 if long_labels else 245
	var rows := ceili(float(choices.size()) / grid.columns)
	panel.custom_minimum_size.x = grid.columns * button_width + (grid.columns - 1) * 12 + 48
	scroll.custom_minimum_size.y = mini(rows * 96 + maxi(rows - 1, 0) * 12, 420)
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 12)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)
	for choice in choices:
		var button := Button.new()
		button.text = tr(String(choice.label))
		button.custom_minimum_size = Vector2(375 if long_labels else 245, 96)
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		button.add_theme_font_size_override("font_size", 25)
		button.focus_mode = Control.FOCUS_NONE
		button.toggle_mode = true
		button.button_pressed = choice.id == current
		button.disabled = not choice.get("enabled", true)
		var id: Variant = choice.id
		button.set_meta(&"nightfall_clip", scroll)
		button.gui_input.connect(_choice_drag_input)
		button.pressed.connect(func():
			if not _choice_dragged: _finish(func(): commit.call(id)))
		grid.add_child(button)
	if not note.is_empty():
		var explanation := Label.new()
		explanation.name = "ChoiceNote"
		explanation.text = tr(note)
		explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		explanation.custom_minimum_size.x = panel.custom_minimum_size.x - 48
		explanation.add_theme_font_size_override("font_size", 20)
		explanation.modulate = Color(0.8, 0.8, 0.85)
		explanation.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(explanation)
	show()
	move_to_front()
	_place_panel.call_deferred(panel)

func _place_panel(panel: PanelContainer) -> void:
	if not is_instance_valid(panel) or panel.get_parent() != self: return
	var bounds := size if size.x > 0 and size.y > 0 else Vector2(1200, 580)
	# Measure the actual themed grid, rather than squeezing it into a fixed
	# short viewport. Long lists still scroll and stay inside the menu bounds.
	if is_instance_valid(_choice_scroll) and panel.is_ancestor_of(_choice_scroll):
		var grid := _choice_scroll.get_child(0) as GridContainer
		var content_height := grid.get_combined_minimum_size().y
		var chrome := panel.get_combined_minimum_size().y - _choice_scroll.custom_minimum_size.y
		_choice_scroll.custom_minimum_size.y = minf(content_height, maxf(96, bounds.y - chrome - 32))
	panel.reset_size()
	panel.position = ((bounds - panel.size) * 0.5).max(Vector2(16, 16))
	_cull_choices.call_deferred()

func _process(_delta: float) -> void:
	if visible: _cull_choices()

func _cull_choices() -> void:
	if not is_instance_valid(_choice_scroll) or not _choice_scroll.is_visible_in_tree(): return
	var grid := _choice_scroll.get_child(0) as GridContainer
	var bounds := _choice_scroll.get_global_rect()
	for button in grid.get_children():
		var rect: Rect2 = button.get_global_rect()
		var inside := rect.position.y >= bounds.position.y - 1.0 and rect.end.y <= bounds.end.y + 1.0
		button.modulate.a = 1.0 if inside else 0.0
		button.mouse_filter = Control.MOUSE_FILTER_STOP if inside else Control.MOUSE_FILTER_IGNORE

## XR pointers synthesize mouse events, so ScrollContainer's touch-only drag
## cannot handle these. Capture travel on press; a swipe must never select.
func _choice_drag_input(event: InputEvent) -> void:
	if not is_instance_valid(_choice_scroll): return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_choice_drag_start = event.global_position.y
		_choice_drag_last = _choice_drag_start
		_choice_dragged = false
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var travel: float = event.global_position.y - _choice_drag_start
		if not _choice_dragged and absf(travel) < 12.0: return
		var movement: float = event.global_position.y - _choice_drag_last if _choice_dragged else travel
		_choice_dragged = true
		_choice_drag_last = event.global_position.y
		var bar := _choice_scroll.get_v_scroll_bar()
		_choice_scroll.scroll_vertical = clampi(_choice_scroll.scroll_vertical - roundi(movement), 0, maxi(0, ceili(bar.max_value - bar.page)))
		_choice_scroll.accept_event()
