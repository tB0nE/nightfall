extends SceneTree
func _init():
 var app = load("res://main.gd").new()
 var screen := VRScreen.new()
 app.screen_registry.initialize(screen)
 var monitor := ScreenContentTab.for_monitor(&"m0")
 screen.content_tabs.add(monitor)
 app.settings.codec_preference = 0
 app.settings.host.is_polaris_host = false
 app.settings.host.resolution_idx = 1
 var baseline: Vector2i = app.compute_requested_resolution(false)
 monitor.resolution = Vector2i(2560,1440)
 assert(app.compute_requested_resolution(false) == Vector2i(2560,1440))
 assert(app.settings.host.resolution_idx == 1, "A tab override must not change Default Res")
 monitor.resolution = Vector2i(7680,4320)
 var bounded: Vector2i = app.compute_requested_resolution(false)
 assert(bounded.x <= app.H264_MAX_DIMENSION and bounded.y <= app.H264_MAX_DIMENSION)
 monitor.resolution = Vector2i.ZERO
 assert(app.compute_requested_resolution(false) == baseline)
 var browser := ScreenContentTab.new()
 browser.id = &"browser:page:1"
 browser.kind = ScreenContentTab.BROWSER
 browser.locator = {"url":"about:blank"}
 browser.resolution = Vector2i(1280,720)
 screen.content_tabs.add(browser)
 assert(app.compute_requested_resolution(false) == baseline, "Browser preferences must not leak into desktop negotiation")
 screen.free()
 app.free()
 print("All per-tab stream resolution tests passed")
 quit()
