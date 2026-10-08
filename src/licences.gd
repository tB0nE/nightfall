class_name Licences
extends RefCounted

## The components behind Settings > About > Licences, and their texts. The
## texts live in licences/ (see its README.md) and stay in English, with
## their original line breaks.

const DIR := "res://licences/"
## Text from the engine rather than a file.
const GODOT := "<godot>"
const GODOT_COMPONENTS := "<godot-components>"

## name, a note shown above the text, and the text's file.
const ENTRIES := [
	["Nightfall", "Nightfall is free software under the GNU General Public License, version 3. Source code: https://github.com/tB0nE/nightfall", "GPL-3.0.txt"],
	["ZipDepth", "The EdgePad depth models are Nightfall's fine-tune of ZipDepth (https://github.com/fabiotosi92/ZipDepth).", "zipdepth.txt"],
	["Godot Engine", "", GODOT],
	["Godot components", "Third-party components built into the Godot Engine.", GODOT_COMPONENTS],
	["godot-cpp", "godot-cpp 4.4.", "godot-cpp.txt"],
	["OpenXR Vendors", "Godot OpenXR Vendors plugin 5.0.0.", "godot-openxr-vendors.txt"],
	["OpenXR loader", "The Khronos OpenXR loader. Copyright (c) 2017-2025 The Khronos Group Inc. Apache License 2.0.", "Apache-2.0.txt"],
	["Meta OpenXR SDK", "Meta's OpenXR extension headers, used to build the OpenXR Vendors plugin.", "meta-openxr-sdk.txt"],
	["moonlight-common-c", "Moonlight's streaming protocol library, with Nightfall's changes (PyroWave). GNU General Public License, version 3. Source code: https://github.com/moonlight-stream/moonlight-common-c", "GPL-3.0.txt"],
	["ENet", "Bundled with moonlight-common-c.", "enet.txt"],
	["nanors", "Bundled with moonlight-common-c.", "nanors.txt"],
	["FFmpeg", "FFmpeg 7.1.2, built with its GPL components, so under the GNU General Public License, version 2 or later. Source code: https://ffmpeg.org", "GPL-2.0.txt"],
	["OpenSSL", "OpenSSL 3.6.0. Copyright (c) 1998-2025 The OpenSSL Project Authors. Apache License 2.0.", "Apache-2.0.txt"],
	["curl", "curl 8.17.0.", "curl.txt"],
	["Opus", "Opus 1.5.2.", "opus.txt"],
	["zlib", "zlib 1.3.1.", "zlib.txt"],
	["SIMDe", "SIMDe 0.8.2.", "simde.txt"],
	["PyroWave", "The PyroWave video codec.", "pyrowave.txt"],
	["Granite", "Bundled with PyroWave.", "granite.txt"],
	["volk", "Bundled with PyroWave.", "volk.txt"],
	["LiteRT", "LiteRT (TensorFlow Lite) runs the on-device depth models. Copyright The TensorFlow Authors. Apache License 2.0.", "tensorflow.txt"],
	["XNNPACK", "Bundled with LiteRT.", "xnnpack.txt"],
	["pthreadpool", "Bundled with LiteRT.", "pthreadpool.txt"],
	["cpuinfo", "Bundled with LiteRT.", "cpuinfo.txt"],
	["FP16", "Bundled with LiteRT.", "fp16.txt"],
	["FXdiv", "Bundled with LiteRT.", "fxdiv.txt"],
	["ruy", "Bundled with LiteRT. Copyright 2019 Google LLC. Apache License 2.0.", "Apache-2.0.txt"],
	["gemmlowp", "Bundled with LiteRT. Copyright 2015 The Gemmlowp Authors. Apache License 2.0.", "Apache-2.0.txt"],
	["FlatBuffers", "Bundled with LiteRT. Copyright 2014 Google Inc. Apache License 2.0.", "Apache-2.0.txt"],
	["Abseil", "Bundled with LiteRT. Copyright 2017 The Abseil Authors. Apache License 2.0.", "Apache-2.0.txt"],
	["Eigen", "Bundled with LiteRT. Mozilla Public License 2.0. Source code: https://gitlab.com/libeigen/eigen", "MPL-2.0.txt"],
	["farmhash", "Bundled with LiteRT.", "farmhash.txt"],
	["fft2d", "Bundled with LiteRT.", "fft2d.txt"],
	["ncnn", "Runs depth models on Vulkan in the Linux build.", "ncnn.txt"],
	["Noto Sans CJK", "The Chinese, Japanese and Korean menu fonts (subsets).", "noto-cjk.txt"],
]

static func names() -> PackedStringArray:
	var result := PackedStringArray()
	for entry in ENTRIES:
		result.append(entry[0])
	return result

## The entry's text, line by line: its note, a blank line, then the licence.
static func lines(index: int) -> PackedStringArray:
	var entry: Array = ENTRIES[index]
	var result := PackedStringArray()
	if not String(entry[1]).is_empty():
		result.append(entry[1])
		result.append("")
	var source: String = entry[2]
	var text: String
	if source == GODOT:
		text = Engine.get_license_text()
	elif source == GODOT_COMPONENTS:
		text = _godot_components()
	else:
		text = FileAccess.get_file_as_string(DIR + source)
		if text.is_empty():
			text = "The licence text (%s) is missing from this build." % source
	result.append_array(text.strip_edges(false, true).replace("\r\n", "\n").split("\n"))
	return result

## Each component's copyright and licence, then each licence's text once.
static func _godot_components() -> String:
	var out := PackedStringArray()
	var used := {}
	for component in Engine.get_copyright_info():
		if component["name"] == "Godot Engine":
			continue
		out.append(component["name"])
		for part in component["parts"]:
			for holder in part["copyright"]:
				out.append("    Copyright (c) " + holder)
			out.append("    License: " + part["license"])
			for name in String(part["license"]).replace(" or ", " and ").split(" and "):
				used[name.strip_edges()] = true
		out.append("")
	var texts := Engine.get_license_info()
	var licence_names := used.keys()
	licence_names.sort()
	for name in licence_names:
		if texts.has(name):
			out.append("---- " + name + " ----")
			out.append("")
			out.append(String(texts[name]).strip_edges())
			out.append("")
	return "\n".join(out)
