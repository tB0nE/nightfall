extends SceneTree

class Idle extends RefCounted:
 func is_exclusive(): return false
 func blocks_workspace(): return false
class Depth extends RefCounted:
 func set_enabled(_value): pass
class InputRecorder extends RefCounted:
 func cancel_transient_interactions(_reason): pass
class Presentation extends RefCounted:
 func deactivate_native(_value): pass
class Settings extends RefCounted:
 var restarts := 0
 func apply_stereo(): pass
 func _schedule_stream_restart(): restarts += 1
class Welcome extends RefCounted:
 var shown := 0
 func show_welcome_screen(_name): shown += 1
class Uploader extends RefCounted:
 var size := Vector2i(1920,1080)
 var allow_resize := true
 func resize_browser_prototype(width, height):
  if not allow_resize: return false
  size = Vector2i(width,height)
  return true
 func get_browser_surface_size(): return size
class Browser extends RefCounted:
 var browser_id := 1
 var pages: Array = [{"id":1,"title":"Retained"}]
 const RESOLUTIONS := [Vector2i(1920,1080),Vector2i(2560,1440)]
 var owner
 var active := false
 var suspended := false
 var closing := false
 var selected_page := 1
 var screen
 var actions: Array = []
 var uploader := Uploader.new()
 var render_size := Vector2i(1920,1080)
 var reported_render_size := Vector2i(1920,1080)
 var texture: Texture2D
 var _opening_at := 0
 func desired_render_size(): return owner.primary_screen.content_tabs.selected().effective_resolution(Vector2i(1920,1080))
 func _poll_pages(): reported_render_size = uploader.size
 func cancel_pointer(): pass
 func clear_gamepad(): pass
 func release_keys(): pass
 func _gamepad_bridge(): return null
 func start():
  active = true
  suspended = false
  owner.screen_sources.browser_opened(self)
  owner.screen_sources.sync_browser_pages([{"id":1,"title":"Retained"}],1,screen)
 func suspend_for_tab():
  active = false
  suspended = true
  return true
 func resume_from_tab():
  active = true
  suspended = false
  return true
 func tab_action(action, id): actions.append([action,id])
class Stream extends RefCounted:
 var owner
 var _current_host_id := 7
 var _current_app_id := 42
 var starts := 0
 func start_stream(host, app):
  assert(host == 7 and app == 42)
  starts += 1
  owner.is_streaming = true
  owner.session_lifecycle.begin_connect()
  owner.session_lifecycle.stream_started()
class Sources extends ScreenSources:
 var restored: Array = []
 func _restore_monitor_surface(screen): restored.append(screen)
 func _bind_monitor_geometry(screen): restored.append(screen)
 func make_primary(screen: VRScreen, _connecting: bool = false) -> bool:
  main.primary_screen = screen
  var provider = browser_for_screen(screen)
  if provider != null: main.browser_prototype = provider
  return true
class Owner extends Node3D:
 var resolutions := [Vector2i(1920,1080),Vector2i(2560,1440)]
 var primary_screen: VRScreen
 var screens: Array[VRScreen] = []
 var browser_prototype := Browser.new()
 var pcvr_test := Idle.new()
 var pcvr_handover := Idle.new()
 var depth_estimator := Depth.new()
 var xr_interaction := InputRecorder.new()
 var video_presentation := Presentation.new()
 var settings_controller := Settings.new()
 var welcome_screen := Welcome.new()
 var stream_manager := Stream.new()
 var session_lifecycle := SessionLifecycle.new()
 var screen_sources: Sources
 var is_streaming := true
 var disconnects := 0
 var preserve_seen := false
 var removed: Array = []
 func remove_screen(id):
  for screen in screens.duplicate():
   if screen.monitor_id == id:
    screens.erase(screen)
    removed.append(screen)
 func disconnect_stream():
  preserve_seen = screen_sources.preserves_browser_on_stream_close()
  disconnects += 1
  is_streaming = false
  session_lifecycle.request_disconnect()
  session_lifecycle.finish_cleanup()

func _init(): _run.call_deferred()
func _run():
 await _test_close_last_stream()
 await _test_close_last_stream_without_browser()
 await _test_close_last_stream_with_other_browser()
 var owner := Owner.new()
 root.add_child(owner)
 var screen := VRScreen.new()
 owner.primary_screen = screen
 owner.screens.append(screen)
 owner.browser_prototype.owner = owner
 owner.browser_prototype.screen = screen
 owner.stream_manager.owner = owner
 owner.screen_sources = Sources.new(owner,"Android")
 screen.content_tabs.add(ScreenContentTab.for_monitor(&"m0"))
 screen.content_tabs.add(ScreenContentTab.for_monitor(&"v1"),false)
 owner.session_lifecycle.begin_connect()
 owner.session_lifecycle.stream_started()
 assert(owner.screen_sources.set_monitor_tab_resolution(screen,Vector2i(2560,1440)))
 assert(owner.settings_controller.restarts == 1)
 assert(not owner.screen_sources.set_monitor_tab_resolution(screen,Vector2i(-1,720)))
 assert(owner.screen_sources.set_monitor_tab_resolution(screen,Vector2i.ZERO))
 assert(await owner.screen_sources.select_browser_tab(screen))
 assert(owner.is_streaming and owner.disconnects == 0, "Browser tabs must retain the host session")
 assert(screen.content_tabs.find_tab(&"monitor:m0") != null and screen.content_tabs.find_tab(&"monitor:v1") != null)
 assert(owner.browser_prototype.active)
 var page := screen.content_tabs.find_tab(&"browser:page:1")
 page.crop_mode = 2
 assert(await owner.screen_sources.select_monitor_tab(screen))
 assert(owner.is_streaming and owner.stream_manager.starts == 0, "Returning to a monitor must not reconnect")
 assert(screen.content_tabs.find_tab(&"monitor:v1") != null and owner.screens.size() == 1)
 assert(owner.browser_prototype.suspended and not owner.browser_prototype.active)
 assert(screen.content_tabs.selected().kind == ScreenContentTab.STREAM)
 assert(await owner.screen_sources.select_browser_tab(screen,1))
 assert(owner.disconnects == 0 and owner.is_streaming)
 assert(screen.content_tabs.selected() == page and page.crop_mode == 2)
 assert(not owner.screen_sources.switching_tab)
 assert(await owner.screen_sources.set_browser_tab_resolution(screen,Vector2i(2560,1440)))
 assert(page.resolution == Vector2i(2560,1440) and owner.browser_prototype.render_size == Vector2i(2560,1440))
 assert(await owner.screen_sources.set_browser_tab_resolution(screen,Vector2i.ZERO))
 assert(page.resolution == Vector2i.ZERO and owner.browser_prototype.render_size == Vector2i(1920,1080))
 assert(not await owner.screen_sources.set_browser_tab_resolution(screen,Vector2i(8192,8192)))
 owner.browser_prototype.uploader.allow_resize = false
 assert(not await owner.screen_sources.set_browser_tab_resolution(screen,Vector2i(2560,1440)))
 assert(not owner.screen_sources.switching_tab and page.resolution == Vector2i(1920,1080))
 var second := VRScreen.new()
 second.content_tabs.add(ScreenContentTab.for_monitor(&"m1"))
 owner.screens.append(second)
 assert(owner.screen_sources.can_switch_content_tab(screen), "Other monitors must not disable the primary toolbar")
 owner.is_streaming = true
 owner.session_lifecycle.begin_connect()
 owner.session_lifecycle.stream_started()
 var provider := Browser.new()
 provider.owner = owner
 provider.screen = second
 var strip := ScreenTabStrip.new(owner, second, provider)
 owner.screen_sources._menus[second.get_instance_id()] = strip
 assert(await owner.screen_sources.select_browser_tab(second))
 assert(owner.is_streaming and provider.active, "A secondary tab must not disconnect the shared desktop session")
 owner.screen_sources.register_browser(second,provider)
 assert(await owner.screen_sources.select_monitor_tab(second))
 assert(provider.suspended and not provider.active and owner.is_streaming)
 assert(second.content_tabs.selected().kind == ScreenContentTab.STREAM)
 assert(owner.screen_sources.restored.has(second))
 owner.browser_prototype.active = false
 owner.browser_prototype.suspended = false
 owner.screen_sources._tab_stream_session = {"host":7,"app":42}
 owner.is_streaming = false
 owner.session_lifecycle.request_disconnect()
 owner.session_lifecycle.finish_cleanup()
 owner.screen_sources.browser_closed()
 var starts_before := owner.stream_manager.starts
 assert(await owner.screen_sources.restore_stream_after_browser_close(screen))
 assert(owner.is_streaming and owner.stream_manager.starts == starts_before + 1)
 assert(owner.screen_sources._tab_stream_session.is_empty(), "A restored connection must consume its parked session")
 assert(screen.content_tabs.selected().kind == ScreenContentTab.STREAM)
 owner.is_streaming = false
 owner.session_lifecycle.request_disconnect()
 owner.session_lifecycle.finish_cleanup()
 assert(not await owner.screen_sources.restore_stream_after_browser_close(screen), "A welcome-only browser must not reconnect a previously consumed session")
 owner.screen_sources._tab_stream_session = {"host":7,"app":42}
 owner.session_lifecycle.begin_connect()
 assert(not await owner.screen_sources.restore_stream_after_browser_close(screen), "A new connection must win over an old browser-close callback")
 assert(owner.stream_manager.starts == starts_before + 1)
 second.free()
 screen.free()
 owner.free()
 print("All unified screen tab switching tests passed")
 quit()

func _test_close_last_stream():
 var owner := Owner.new()
 root.add_child(owner)
 var screen := VRScreen.new()
 owner.primary_screen = screen
 owner.screens.append(screen)
 owner.browser_prototype.owner = owner
 owner.browser_prototype.screen = screen
 owner.browser_prototype.suspended = true
 owner.stream_manager.owner = owner
 owner.screen_sources = Sources.new(owner,"Android")
 screen.content_tabs.add(ScreenContentTab.for_monitor(&"m0"))
 screen.content_tabs.sync_browser_pages(owner.browser_prototype.pages,1)
 screen.content_tabs.select(&"monitor:m0")
 var retained := screen.content_tabs.find_tab(&"browser:page:1")
 owner.screen_sources._tab_stream_session = {"host":7,"app":42}
 owner.session_lifecycle.begin_connect()
 owner.session_lifecycle.stream_started()
 await owner.screen_sources._close_last_monitor_keep_browser(screen,owner.browser_prototype)
 assert(owner.preserve_seen, "Disconnect cleanup must preserve the browser screen")
 assert(owner.disconnects == 1 and not owner.is_streaming)
 assert(owner.browser_prototype.active and owner.browser_prototype.pages.size() == 1)
 assert(screen.content_tabs.selected() == retained and owner.screen_sources.monitor_tab(screen) == null)
 assert(owner.screen_sources._tab_stream_session.is_empty(), "Closing Desktop must not park an automatic reconnect")
 assert(not owner.screen_sources.switching_tab and not owner.screen_sources.preserves_browser_on_stream_close())
 assert(not await owner.screen_sources.restore_stream_after_browser_close(screen))
 assert(owner.stream_manager.starts == 0)
 screen.free()
 owner.free()

func _test_close_last_stream_without_browser():
 var owner := Owner.new()
 root.add_child(owner)
 owner.screen_sources = Sources.new(owner,"Android")
 owner.session_lifecycle.begin_connect()
 owner.session_lifecycle.stream_started()
 assert(owner.screen_sources._remaining_browser() == null)
 await owner.screen_sources._close_last_monitor_to_welcome()
 assert(owner.disconnects == 1 and not owner.is_streaming)
 assert(owner.session_lifecycle.phase == SessionLifecycle.Phase.SERVER_SELECTION)
 assert(not owner.preserve_seen and not owner.screen_sources.switching_tab)
 assert(owner.stream_manager.starts == 0, "Closing the final source must not reopen the physical stream")
 owner.free()

func _test_close_last_stream_with_other_browser():
 var owner := Owner.new()
 root.add_child(owner)
 var desktop := VRScreen.new()
 desktop.monitor_id = &"m0"
 var browser_screen := VRScreen.new()
 browser_screen.monitor_id = &"browser-screen:1"
 owner.primary_screen = desktop
 owner.screens.assign([desktop,browser_screen])
 owner.screen_sources = Sources.new(owner,"Android")
 var provider := Browser.new()
 provider.owner = owner
 provider.screen = browser_screen
 provider.active = true
 browser_screen.content_tabs.sync_browser_pages(provider.pages,1)
 owner.screen_sources.register_browser(browser_screen,provider)
 owner.session_lifecycle.begin_connect()
 owner.session_lifecycle.stream_started()
 assert(owner.screen_sources._remaining_browser() == provider)
 await owner.screen_sources._close_last_monitor_keep_browser(desktop,provider)
 assert(owner.primary_screen == browser_screen and provider.active)
 assert(owner.removed == [desktop] and owner.screens == [browser_screen])
 assert(owner.preserve_seen and not owner.is_streaming and owner.stream_manager.starts == 0)
 desktop.free()
 browser_screen.free()
 owner.free()
