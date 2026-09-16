class_name MenuSchema
extends RefCounted

const TARGET_UI := &"ui"
const TARGET_SETTINGS := &"settings"
const TARGET_SCREEN := &"screen"
const TARGET_CONTROLLER := &"controller"

static func get_tab_buttons() -> Array:
	return [
		_tab_button(&"_tab_btn_display", "Display", 0, "Configure the screen and its surrounding environment."),
		_tab_button(&"_tab_btn_stream", "Stream", 1, "Configure stream quality, frame rate, and encoding."),
		_tab_button(&"_tab_btn_control", "Control", 2, "Configure pointers, hand tracking, and controller mapping."),
		_tab_button(&"_tab_btn_ai3d", "AI 3D", 3, "Configure local AI stereoscopic depth conversion."),
		_tab_button(&"_tab_btn_picture", "Picture", 4, "Adjust the streamed image."),
		# Monitors remains visible as a disabled preview of the feature.
		_tab_button(&"_tab_btn_monitors", "Monitors", 5, "Configure physical and virtual monitor layouts. Coming soon.", true, true, 0.3),
		# Advanced is retained for future migrations but is not user-facing.
		_tab_button(&"_tab_btn_advanced", "Advanced", 6, "Configure connection and diagnostic options.", false, true),
	]

static func get_tabs() -> Array:
	return [
	{
		"id": &"display",
		"node_name": &"TabDisplay",
		"rows": [
			{
				"node_name": &"DispRow1",
				"options": [
					_option(&"_ui_pt_btn", "Passthrough", "On", "Show your physical surroundings behind the screen.", TARGET_SETTINGS, &"toggle_passthrough"),
					_option(&"_ui_sbs_btn", "SBS", "Off", "Display side-by-side 3D content using Stretch or Crop.", TARGET_UI, &"on_sbs_toggled"),
					_option(&"_ui_3d_speed_btn", "AI 3D", "Off", "Convert normal video into stereoscopic 3D using local depth inference.", TARGET_UI, &"on_ai_3d_speed_toggled"),
					_option(&"_ui_curve_btn", "Curve", "Flat", "Change the physical curvature of the virtual screen.", TARGET_SCREEN, &"cycle_curvature"),
				],
			},
			{
				"node_name": &"DispRow2",
				"options": [
					_option(&"_ui_bg_btn", "Background", "Black", "Choose the virtual background used when passthrough is off.", TARGET_SETTINGS, &"cycle_background"),
					_option(&"_ui_ambient_btn", "Ambient", "Off", "Add screen lighting using a fixed, slowly sampled, or live sampled colour.", TARGET_SETTINGS, &"cycle_ambient_mode"),
					_option(&"_ui_ambient_color_btn", "Colour", "White", "Choose the fixed ambient colour. Available in Static mode only.", TARGET_SETTINGS, &"cycle_ambient_color"),
					_option(&"_ui_bezel_btn", "Bezel", "On", "Show or hide the frame around the screen.", TARGET_SCREEN, &"toggle_bezel"),
				],
			},
		],
	},
	{
		"id": &"stream",
		"node_name": &"TabStream",
		"rows": [
			{
				"node_name": &"StreamRow1",
				"options": [
					_option(&"_ui_res_btn", "Resolution", "100%", "Choose the resolution requested from the host.", TARGET_SETTINGS, &"cycle_resolution"),
					_option(&"_ui_fps_btn", "FPS", "60", "Choose the stream frame rate and matching headset refresh rate.", TARGET_SETTINGS, &"cycle_fps"),
					_option(&"_ui_bitrate_btn", "Bitrate", "Auto", "Control stream bandwidth and image quality.", TARGET_SETTINGS, &"cycle_bitrate"),
					_option(&"_ui_host_cursor_btn", "Host Cursor", "Off", "Show or hide the host operating system cursor when supported.", TARGET_SETTINGS, &"toggle_host_cursor"),
				],
			},
			{
				"node_name": &"StreamRow2",
				"options": [
					_option(&"_ui_codec_btn", "Codec", "HEVC", "Choose the video codec used by the stream.", TARGET_SETTINGS, &"cycle_codec"),
					_option(&"_ui_quick_start_btn", "Quick Start", "Off", "Automatically reconnect to the most recently used host and application.", TARGET_SETTINGS, &"cycle_quick_start"),
				],
			},
		],
	},
	{
		"id": &"control",
		"node_name": &"TabControl",
		"rows": [
			{
				"node_name": &"ControlRow1",
				"options": [
					_option(&"_ui_cursor_btn", "Cursor Type", "Circle", "Choose the appearance of the VR pointer.", TARGET_SETTINGS, &"cycle_cursor_mode"),
					_option(&"_ui_steady_btn", "Cursor Steady", "Low", "Adjust pointer-motion smoothing.", TARGET_SETTINGS, &"cycle_steady"),
					_option(&"_ui_hand_tracking_btn", "Tracking", "Off", "Enable or disable hand tracking.", TARGET_SETTINGS, &"toggle_hand_tracking"),
					_option(&"_ui_double_click_btn", "Double Click", "Standard", "Choose how double-click input is triggered.", TARGET_SETTINGS, &"cycle_double_click_mode"),
				],
			},
			{
				"node_name": &"ControlRow2",
				"options": [
					_option(&"_ui_ctrl_mode_btn", "Mapping", "Off", "Enable controller or keyboard-and-mouse mapping.", TARGET_CONTROLLER, &"check_toggle_ui"),
					_option(&"_ui_ctrl_type_btn", "Device Mode", "PAD-HAND", "Choose the input layout sent to the host.", TARGET_CONTROLLER, &"cycle_type"),
					_option(&"_ui_btn_toggle_btn", "Alternate Mode", "Head", "Choose how the secondary button mapping is activated.", TARGET_CONTROLLER, &"cycle_btn_toggle"),
					_option(&"_ui_primary_btn", "Primary Hand", "Right", "Choose which hand provides primary pointer input.", TARGET_CONTROLLER, &"cycle_primary_hand"),
				],
			},
		],
	},
	{
		"id": &"picture",
		"node_name": &"TabPicture",
		"rows": [
			{
				"node_name": &"PictureRow1",
				"options": [
					_option(&"_ui_brightness_btn", "Brightness", "+0%", "Adjust the overall image brightness.", TARGET_SETTINGS, &"cycle_brightness"),
					_option(&"_ui_contrast_btn", "Contrast", "100%", "Adjust the difference between light and dark areas.", TARGET_SETTINGS, &"cycle_contrast"),
					_option(&"_ui_gamma_btn", "Gamma", "100%", "Adjust midtone brightness without equally changing highlights.", TARGET_SETTINGS, &"cycle_gamma"),
				],
			},
			{
				"node_name": &"PictureRow2",
				"options": [
					_option(&"_ui_sharpen_btn", "Sharpen", "Off", "Apply native runtime sharpening to the streamed image.", TARGET_SETTINGS, &"cycle_sharpen_mode"),
				],
			},
		],
	},
	{
		"id": &"advanced",
		"node_name": &"TabAdvanced",
		"rows": [
			{
				"node_name": &"AdvancedRow1",
				"options": [
					_option(&"_ui_reconnect_btn", "Auto-Reconnect", "On", "Automatically attempt to restore an interrupted stream.", TARGET_SETTINGS, &"cycle_auto_reconnect"),
					_option(&"_ui_idle_btn", "Idle Disconnect", "Off", "Disconnect after the selected period without input.", TARGET_SETTINGS, &"cycle_idle_timeout"),
				],
			},
			{
				"node_name": &"AdvancedRow2",
				# Android exposes this diagnostic directly on the AI 3D tab.
				# Retain the hidden Advanced copy on desktop for now so its
				# existing menu structure remains unchanged.
				"options": [] if OS.get_name() == "Android" else [
					_option(&"_ui_3d_debug_btn", "3D Debug", "Off", "Display intermediate AI depth data for troubleshooting.", TARGET_UI, &"on_ai_3d_debug_toggled", false, true),
				],
			},
		],
	},
]

static func _option(
	field: StringName,
	label: String,
	value: String,
	tooltip: String,
	target: StringName,
	action: StringName,
	visible: bool = true,
	disabled: bool = false
) -> Dictionary:
	return {
		"field": field,
		"label": label,
		"value": value,
		"tooltip": tooltip,
		"target": target,
		"action": action,
		"visible": visible,
		"disabled": disabled,
	}

static func _tab_button(
	field: StringName,
	label: String,
	index: int,
	tooltip: String,
	visible: bool = true,
	disabled: bool = false,
	alpha: float = 1.0
) -> Dictionary:
	return {
		"field": field,
		"label": label,
		"index": index,
		"tooltip": tooltip,
		"visible": visible,
		"disabled": disabled,
		"alpha": alpha,
	}

static func get_tab(id: StringName) -> Dictionary:
	for tab in get_tabs():
		if tab["id"] == id:
			return tab
	return {}

static func validate() -> PackedStringArray:
	var errors := PackedStringArray()
	var tab_ids := {}
	var fields := {}
	var valid_targets := {
		TARGET_UI: true,
		TARGET_SETTINGS: true,
		TARGET_SCREEN: true,
		TARGET_CONTROLLER: true,
	}
	var tab_indexes := {}
	for button in get_tab_buttons():
		var tab_index: int = button.get("index", -1)
		if tab_index < 0 or tab_indexes.has(tab_index):
			errors.append("Menu tab indexes must be non-negative and unique: %d" % tab_index)
		tab_indexes[tab_index] = true
		if button.get("field", &"") == &"" or button.get("label", "") == "" or button.get("tooltip", "") == "":
			errors.append("Menu tab buttons require a field, label, and tooltip")
	for tab in get_tabs():
		var tab_id: StringName = tab.get("id", &"")
		if tab_id == &"" or tab_ids.has(tab_id):
			errors.append("Menu tab IDs must be non-empty and unique: %s" % tab_id)
		tab_ids[tab_id] = true
		for row in tab.get("rows", []):
			var options: Array = row.get("options", [])
			if options.is_empty() or options.size() > 4:
				errors.append("Menu row %s must contain one to four options" % row.get("node_name", &""))
			for option in options:
				var field: StringName = option.get("field", &"")
				if field == &"" or fields.has(field):
					errors.append("Menu option fields must be non-empty and unique: %s" % field)
				fields[field] = true
				if not valid_targets.has(option.get("target", &"")):
					errors.append("Menu option %s has an unknown command target" % field)
				if option.get("action", &"") == &"":
					errors.append("Menu option %s has no command" % field)
				if option.get("tooltip", "") == "":
					errors.append("Menu option %s has no tooltip" % field)
	return errors
