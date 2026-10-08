class_name Licences
extends RefCounted

## The text behind Settings > About > Licences. Licence texts stay in English
## and keep their original line breaks.

const NIGHTFALL := "Nightfall is free software under the GNU General Public License, version 3. Source code: https://github.com/tB0nE/nightfall"

# The Quest's EdgePad depth models are fine-tuned from ZipDepth's released
# weights (tools/ZipDepth). MIT asks for this notice in every copy.
const ZIPDEPTH_CREDIT := "The EdgePad depth models are Nightfall's fine-tune of ZipDepth (https://github.com/fabiotosi92/ZipDepth)."
const ZIPDEPTH_LICENSE := """MIT License

Copyright (c) 2026 Fabio Tosi

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE."""

## The page as [kind, text] pairs: kind is &"heading" or &"line".
static func entries() -> Array:
	var result := [[&"line", NIGHTFALL], [&"heading", "ZipDepth"], [&"line", ZIPDEPTH_CREDIT]]
	for line in ZIPDEPTH_LICENSE.split("\n"):
		result.append([&"line", line])
	result.append([&"heading", "Godot Engine"])
	for line in Engine.get_license_text().strip_edges().split("\n"):
		result.append([&"line", line])
	return result
