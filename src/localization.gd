class_name Localization
extends RefCounted

## UI translations, in the style of web2py: the English text is the key, and
## each locale/<code>.json maps it to the translated text. Strings missing from
## a dictionary fall back to English, so a partial translation is safe.
##
## Translations are registered with Godot's TranslationServer, so plain Labels
## and Buttons translate themselves (their `text` stays the English key). Text
## composed at runtime goes through tr()/Localization.t() instead.

const LOCALE_DIR := "res://locale"
const DEFAULT_LANGUAGE := "en"
# English is the source language and has no dictionary file. Names are shown
# in their own language so a user can always find theirs.
const LANGUAGES: Array = [
	{"code": "en", "name": "English"},
	{"code": "fr", "name": "Français"},
	{"code": "de", "name": "Deutsch"},
	{"code": "es", "name": "Español"},
	{"code": "pt_BR", "name": "Português (BR)"},
	{"code": "it", "name": "Italiano"},
	{"code": "nl", "name": "Nederlands"},
	{"code": "af", "name": "Afrikaans"},
	{"code": "pl", "name": "Polski"},
	{"code": "sv", "name": "Svenska"},
	{"code": "da", "name": "Dansk"},
	{"code": "nb", "name": "Norsk bokmål"},
	{"code": "fi", "name": "Suomi"},
	{"code": "cs", "name": "Čeština"},
	{"code": "tr", "name": "Türkçe"},
	{"code": "ru", "name": "Русский"},
	{"code": "uk", "name": "Українська"},
	{"code": "ja", "name": "日本語"},
	{"code": "ko", "name": "한국어"},
	{"code": "zh_CN", "name": "简体中文"},
	{"code": "zh_TW", "name": "繁體中文"},
]
# Godot's default font has no CJK characters. These Noto Sans CJK subsets
# (rebuilt by tools/i18n/build_cjk_fonts.py) hold just the characters each
# dictionary uses, and are added as fallbacks to the default font.
const CJK_FONTS := {
	"ja": "res://src/assets/fonts/noto-sans-cjk-ja-subset.otf",
	"ko": "res://src/assets/fonts/noto-sans-cjk-ko-subset.otf",
	"zh_CN": "res://src/assets/fonts/noto-sans-cjk-zh_CN-subset.otf",
	"zh_TW": "res://src/assets/fonts/noto-sans-cjk-zh_TW-subset.otf",
}

static var _loaded := false
static var _base_fallbacks: Array = []
static var _cjk_fonts := {}
static var _current := DEFAULT_LANGUAGE

static func load_translations() -> void:
	if _loaded:
		return
	_loaded = true
	for language in LANGUAGES:
		var code: String = language["code"]
		if code == DEFAULT_LANGUAGE:
			continue
		var messages := load_dictionary(code)
		if messages.is_empty():
			continue
		var translation := Translation.new()
		translation.locale = code
		for key in messages:
			translation.add_message(key, messages[key])
		TranslationServer.add_translation(translation)

static func load_dictionary(code: String) -> Dictionary:
	var path := "%s/%s.json" % [LOCALE_DIR, code]
	if not FileAccess.file_exists(path):
		push_warning("Missing translation dictionary: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_warning("Invalid translation dictionary: %s" % path)
		return {}
	var messages := {}
	for key in parsed:
		# Keys starting with "_" are notes for translators, not UI strings.
		if String(key).begins_with("_") or String(parsed[key]).is_empty():
			continue
		messages[String(key)] = String(parsed[key])
	return messages

## Resolves a saved language code, or the OS language when nothing was saved.
static func resolve_language(saved: String) -> String:
	if is_supported(saved):
		return saved
	return match_os_locale(OS.get_locale())

## Maps an OS locale such as "de_AT", "pt_PT", or "zh_Hant_HK" to the closest
## supported language.
static func match_os_locale(locale: String) -> String:
	var parts := locale.replace("-", "_").split("_")
	var language := parts[0].to_lower()
	match language:
		"zh":
			# Traditional script for Taiwan, Hong Kong, Macau, or an explicit Hant tag.
			for part in parts.slice(1):
				if part in ["TW", "HK", "MO", "Hant", "#Hant"]:
					return "zh_TW"
			return "zh_CN"
		"pt":
			return "pt_BR"
		"no", "nn":
			return "nb"
	return language if is_supported(language) else DEFAULT_LANGUAGE

static func is_supported(code: String) -> bool:
	return language_index(code) >= 0

static func language_index(code: String) -> int:
	for i in LANGUAGES.size():
		if LANGUAGES[i]["code"] == code:
			return i
	return -1

static func language_name(code: String) -> String:
	var index := language_index(code)
	return LANGUAGES[index]["name"] if index >= 0 else code

static func current() -> String:
	return _current

static func apply(code: String) -> void:
	load_translations()
	_current = code if is_supported(code) else DEFAULT_LANGUAGE
	_apply_fonts(_current)
	TranslationServer.set_locale(_current)

# Every CJK subset stays loaded so the language picker can always draw each
# language's name. The current language's font goes first, because Chinese,
# Japanese, and Korean draw some shared characters differently.
static func _apply_fonts(code: String) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	if _cjk_fonts.is_empty():
		_base_fallbacks = font.fallbacks.duplicate()
		for language in CJK_FONTS:
			var cjk = load(CJK_FONTS[language])
			if cjk is Font:
				_cjk_fonts[language] = cjk
	var ordered: Array[Font] = []
	ordered.assign(_base_fallbacks)
	if _cjk_fonts.has(code):
		ordered.append(_cjk_fonts[code])
	for language in _cjk_fonts:
		if language != code:
			ordered.append(_cjk_fonts[language])
	font.fallbacks = ordered

static func t(text: String) -> String:
	return String(TranslationServer.translate(text)) if not text.is_empty() else text
