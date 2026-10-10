extends SceneTree

# Every component under Settings > About > Licences must have its text.
func _init():
	var names := Licences.names()
	assert(names.size() == Licences.ENTRIES.size())
	for i in names.size():
		var lines := Licences.lines(i)
		var text := "\n".join(lines)
		assert(lines.size() > 2, "%s has no text" % names[i])
		assert(not text.contains("is missing from this build"), "%s: licence file missing" % names[i])
	var godot := "\n".join(Licences.lines(names.find("Godot components")))
	assert(godot.contains("FreeType") and godot.contains("---- FTL ----"), "Godot components need FreeType's notice and licence")
	assert("\n".join(Licences.lines(names.find("ZipDepth"))).contains("Copyright (c) 2026 Fabio Tosi"))
	print("All licences tests passed")
	quit()
