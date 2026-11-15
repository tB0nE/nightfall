extends SceneTree

func _init():
	var h264 := StreamPackingBudget.options(0, false, Vector2i(2560,1440))
	assert(h264 == StreamPackingBudget.options(5,false,Vector2i(2560,1440)), "H.264+ must not change the spatial budget")
	var hevc := StreamPackingBudget.options(1,false)
	assert(h264.nf_max_axis == 4032 and hevc.nf_max_axis == 8192)
	assert(StreamPackingBudget.options(1,true).nf_max_pixels == 1920*1080, "Preserve the existing Quest 2 policy")
	var plan := {"packing_budget_version":1,"packing_fits":true,"frame_size":[2560,2880]}
	assert(StreamPackingBudget.full_size_fits(plan,h264))
	plan.frame_size = [5120,1440]
	assert(not StreamPackingBudget.full_size_fits(plan,h264))
	assert(StreamPackingBudget.full_size_fits(plan,hevc))
	plan.packing_fits = false
	assert(not StreamPackingBudget.full_size_fits(plan,hevc), "Scaled previews must not count as full resolution")
	assert(not StreamPackingBudget.full_size_fits({},hevc))
	h264.capture_outputs = "DP-1,HDMI-A-1"
	h264.nf_physical_modes = "m0:1920x1080"
	var query := StreamPackingBudget.query(h264)
	assert(query.contains("outputs=DP-1%2CHDMI-A-1") and query.contains("nf_max_axis=4032"))
	assert(query.contains("nf_physical_modes=m0%3A1920x1080"))
	h264.nf_require_fit = 1
	assert(StreamPackingBudget.query(h264) == query, "Strictness is for launch, not preview")
	var layout := ScreenLayout.single(Vector2i(2560,2880))
	layout.packing_budget_version = 1
	layout.packing_profiled = true
	assert(ScreenLayout.from_dict(layout.to_dict()).packing_profiled)
	assert(layout.rescale_to(Vector2i(1280,1440)).packing_budget_version == 1)
	var menu := ScreenTabStrip.new(Node3D.new(), null, RefCounted.new())
	var result := {"cancelled":false}
	menu.confirm_hevc(func(value): result.cancelled = not value)
	assert(menu.popup == "packing_confirmation")
	menu.dismiss_packing_confirmation()
	assert(result.cancelled and menu.popup.is_empty())
	menu.main.free()
	print("All codec packing budget and confirmation tests passed")
	quit()
