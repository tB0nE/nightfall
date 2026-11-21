extends SceneTree

const Settings = preload("res://src/settings_controller.gd")

# Linux offers a depth model only when it can run: not Android-only, and its
# ncnn export is installed when it names one (EdgePad comes from Meteor).
func _init() -> void:
	var dir := OS.get_user_data_dir().path_join("linux-depth-models-test")
	DirAccess.make_dir_recursive_absolute(dir)
	for name in ["edgepad-256-vulkan.param", "edgepad-256-vulkan.bin", "edgepad-512x288-vulkan.param"]:
		FileAccess.open(dir.path_join(name), FileAccess.WRITE).store_string("x")
	assert(Settings.linux_model_available({"label": "ZipDepth-256-GPU"}, dir))
	assert(not Settings.linux_model_available({"label": "Fastest", "linux": false}, dir))
	assert(Settings.linux_model_available({"label": "EdgePad-256", "linux_file": "edgepad-256-vulkan"}, dir))
	assert(not Settings.linux_model_available({"label": "EdgePad-512", "linux_file": "edgepad-512x288-vulkan"}, dir), "the .bin is missing")
	assert(not Settings.linux_model_available({"label": "EdgePad-512", "linux_file": "edgepad-512x288-vulkan"}, dir.path_join("absent")))
	for name in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(name))
	DirAccess.remove_absolute(dir)
	print("All Linux depth model availability tests passed")
	quit()
