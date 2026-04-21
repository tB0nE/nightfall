extends SceneTree

func _init():
	var classes = [MoonlightStreamCore.new(), MoonlightComputerManager.new(), MoonlightConfigManager.new()]
	for obj in classes:
		print("--- " + obj.get_class() + " SIGNALS ---")
		for s in obj.get_signal_list():
			var args_str = ""
			for arg in s.args:
				args_str += arg.name + ": " + str(arg.type) + ", "
			print("signal " + s.name + "(" + args_str + ")")
	quit()
