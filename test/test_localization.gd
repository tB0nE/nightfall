extends SceneTree

# Problems are collected rather than asserted one at a time, so a single run
# lists every missing string, glyph, or over-long tooltip (and a failure exits
# instead of stopping in the debugger).
var _failures := PackedStringArray()

func _fail(message: String) -> void:
	_failures.append(message)

func _init():
	assert(Localization.LANGUAGES[0]["code"] == Localization.DEFAULT_LANGUAGE)
	assert(Localization.resolve_language("it") == "it")
	assert(Localization.is_supported(Localization.resolve_language("")))
	assert(Localization.resolve_language("xx") != "xx")
	assert(Localization.match_os_locale("de_AT") == "de")
	assert(Localization.match_os_locale("pt_PT") == "pt_BR")
	assert(Localization.match_os_locale("zh_Hant_HK") == "zh_TW")
	assert(Localization.match_os_locale("zh_TW") == "zh_TW")
	assert(Localization.match_os_locale("zh_CN") == "zh_CN")
	assert(Localization.match_os_locale("no_NO") == "nb")
	assert(Localization.match_os_locale("xx_YY") == Localization.DEFAULT_LANGUAGE)
	assert(Localization.language_name("it") == "Italiano")

	# Non-CJK languages rely on Godot's default font alone.
	var base_font := ThemeDB.fallback_font
	for language in Localization.LANGUAGES:
		if Localization.CJK_FONTS.has(language["code"]):
			continue
		var name_missing := _missing_chars(base_font, [language["name"]])
		if not name_missing.is_empty():
			_fail("Default font lacks %s in %s" % [name_missing, language["name"]])
		if language["code"] != Localization.DEFAULT_LANGUAGE:
			var missing := _missing_chars(base_font, Localization.load_dictionary(language["code"]).values())
			if not missing.is_empty():
				_fail("Default font lacks %s used by %s.json" % [missing, language["code"]])

	for language in Localization.LANGUAGES:
		var code: String = language["code"]
		if code == Localization.DEFAULT_LANGUAGE:
			continue
		var messages := Localization.load_dictionary(code)
		if messages.is_empty():
			_fail("%s.json must load" % code)
		var missing := PackedStringArray()
		for text in _menu_strings():
			if not messages.has(text):
				missing.append(text)
		if not missing.is_empty():
			_fail("%s.json is missing menu strings: %s" % [code, ", ".join(missing)])
		for key in messages:
			# Format strings must keep their placeholders.
			if String(key).count("%s") != String(messages[key]).count("%s"):
				_fail("%s placeholder mismatch: %s" % [code, key])
		if Localization.CJK_FONTS.has(code):
			_assert_font_covers(code, messages)

	# Tooltips share a single 1000px bar (24px text, 24px margins) and are
	# trimmed with an ellipsis beyond it.
	for language in Localization.LANGUAGES:
		Localization.apply(language["code"])
		for text in _menu_tooltips():
			var width := ThemeDB.fallback_font.get_string_size(Localization.t(text), HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
			if width > 952:
				_fail("%s tooltip too long (%dpx): %s" % [language["code"], width, Localization.t(text)])

	if not _failures.is_empty():
		for failure in _failures:
			printerr("Assertion failed: " + failure)
		quit(1)
		return

	Localization.apply("it")
	assert(Localization.current() == "it")
	assert(Localization.t("Settings") == "Impostazioni")
	assert(Localization.t("Not in any dictionary") == "Not in any dictionary")
	assert(Localization.t("App: %s") % "Desktop" == "App: Desktop")
	Localization.apply("en")
	assert(Localization.t("Settings") == "Settings")
	print("All localization tests passed")
	quit()

# The bundled subset must contain every character the dictionary uses; rerun
# tools/i18n/build_cjk_fonts.py after editing a CJK dictionary.
func _assert_font_covers(code: String, messages: Dictionary) -> void:
	var font: Font = load(Localization.CJK_FONTS[code])
	assert(font != null, "Missing font for %s" % code)
	var missing := _missing_chars(font, messages.values())
	if not missing.is_empty():
		_fail("%s font subset lacks: %s (run tools/i18n/build_cjk_fonts.py)" % [code, missing])

func _missing_chars(font: Font, texts: Array) -> String:
	var missing := {}
	for text in texts:
		for i in String(text).length():
			var c := String(text).unicode_at(i)
			if c > 0x7F and not font.has_char(c):
				missing[String.chr(c)] = true
	return "".join(missing.keys())

func _menu_tooltips() -> PackedStringArray:
	var tooltips := PackedStringArray()
	for button in MenuSchema.get_tab_buttons():
		tooltips.append(button["tooltip"])
	for tab in MenuSchema.get_tabs():
		for row in tab["rows"]:
			for option in row["options"]:
				tooltips.append(option["tooltip"])
	return tooltips

# Every label, tooltip, and section title in the declarative menu.
func _menu_strings() -> PackedStringArray:
	var strings := PackedStringArray()
	for button in MenuSchema.get_tab_buttons():
		strings.append(button["label"])
		strings.append(button["tooltip"])
	for tab in MenuSchema.get_tabs():
		for row in tab["rows"]:
			if row.has("title"):
				strings.append(row["title"])
			for option in row["options"]:
				strings.append(option["label"])
				strings.append(option["tooltip"])
	return strings
