extends SceneTree
class Browser extends RefCounted:
 var active := false
 var suspended := false
 var pages: Array = []
 var selected_page := 1
 var closing := false
 var browser_id := 0
 func resume_from_tab():
  active = true
  suspended = false
  return true
class Controller extends RefCounted:
 var owner
 var _restart_pending := false
 var _virtual_apply_active := false
 var requests: Array = []
 var _monitor_selection_override: Variant = null
 func _real_monitor_count():
  var count := 0
  for monitor in owner.layout.monitors:
   if monitor.capturable and not monitor.hint.get("virtual",false): count += 1
  return count
 func sync_staged_from_current_layout():
  owner._staged_physical_count = 0
  owner._staged_virtual_count = 0
  for monitor in owner.layout.enabled_monitors():
   if monitor.hint.get("virtual",false): owner._staged_virtual_count += 1
   else: owner._staged_physical_count += 1
 func stage_monitor_count(count): owner._staged_physical_count = count
 func stage_virtual_count(count): owner._staged_virtual_count = count
 func apply_staged_monitor_config(preserve_current := false):
  requests.append([owner._staged_physical_count,owner._staged_virtual_count,preserve_current])
  _restart_pending = true
class Owner extends Node3D:
 var settings := AppSettings.new()
 var layout := ScreenLayout.new()
 var browser_prototype := Browser.new()
 var session_lifecycle := SessionLifecycle.new()
 var settings_controller := Controller.new()
 var is_streaming := true
 var screens: Array[VRScreen] = []
 var primary_screen: VRScreen
 var _staged_physical_count := 1
 var _staged_virtual_count := 0
func _init():
 _test_close_dispatch()
 _test_close_dispatch(true)
 var owner := Owner.new()
 owner.settings_controller.owner = owner
 owner.settings.host.is_polaris_host = true
 owner.settings.host.virtual_display_installed = true
 owner.settings.host.virtual_display_max_count = 1
 owner.session_lifecycle.begin_connect()
 owner.session_lifecycle.stream_started()
 for i in 3:
  var monitor := ScreenLayout.MonitorSpec.new()
  monitor.id = StringName("m%d" % i)
  monitor.enabled = i == 0
  monitor.capturable = i != 2
  owner.layout.monitors.append(monitor)
 var screen := VRScreen.new()
 owner.primary_screen = screen
 owner.screens.append(screen)
 var sources := ScreenSources.new(owner,"Android")
 var close_plan := ScreenSources.monitor_removal_plan(owner.layout, &"m0")
 assert(close_plan.physical.is_empty() and close_plan.virtual == 0, "Closing the last physical source must leave zero captured monitors")
 owner.layout.monitors[1].enabled = true
 close_plan = ScreenSources.monitor_removal_plan(owner.layout, &"m0")
 assert(close_plan.physical == [&"m1"] and close_plan.virtual == 0, "Closing a physical monitor must retain the other exact output")
 owner.layout.monitors[1].enabled = false
 assert(ScreenSources.valid_virtual_size(Vector2i(2560,1440)))
 assert(not ScreenSources.valid_virtual_size(Vector2i(2561,1440)))
 assert(not ScreenSources.valid_virtual_size(Vector2i(8192,8192)))
 assert(not await sources.add_monitor_screen(true,Vector2i(2560,1440)), "Old hosts must not silently ignore custom sizes")
 owner.layout.virtual_modes_supported = true
 var secondary := VRScreen.new()
 var secondary_menu := sources.menu_for_screen(secondary)
 assert(secondary_menu != null, "Captured secondary monitors need a toolbar too")
 assert(secondary_menu.browser.screen == secondary and not secondary_menu.browser.active)
 assert(sources.browser_for_screen(secondary) == null, "A monitor toolbar must not allocate/register a browser")
 assert(sources.menu_for_screen(secondary) == secondary_menu, "Reuse the monitor toolbar")
 secondary.free()
 assert(sources.can_add_monitor_screen(false) and sources.can_add_monitor_screen(true))
 assert(await sources.add_monitor_screen(false))
 assert(owner.settings_controller.requests[-1] == [2,0,true])
 assert(not sources.can_add_monitor_screen(false) and not sources.can_add_browser_screen(), "A pending host change reserves the screen budget")
 owner.settings_controller._restart_pending = false
 assert(await sources.add_monitor_screen(true,Vector2i(2560,1440)))
 assert(sources.virtual_modes_query(1) == "2560x1440")
 assert(owner.settings_controller.requests[-1] == [1,1,true])
 owner.settings_controller._restart_pending = false
 owner.settings.host.virtual_display_installed = false
 assert(not sources.can_add_monitor_screen(true))
 owner.settings.host.virtual_display_installed = true
 var virtual_monitor := ScreenLayout.MonitorSpec.new()
 virtual_monitor.id = &"virtual0"
 virtual_monitor.hint = {"virtual":true}
 owner.layout.monitors.append(virtual_monitor)
 close_plan = ScreenSources.monitor_removal_plan(owner.layout, &"virtual0")
 assert(close_plan.physical == [&"m0"] and close_plan.virtual == 0)
 owner.layout.monitors[0].enabled = false
 close_plan = ScreenSources.monitor_removal_plan(owner.layout, &"virtual0")
 assert(close_plan.physical.is_empty() and close_plan.virtual == 0, "Closing the last virtual must not reopen a physical output")
 owner.layout.monitors[0].enabled = true
 assert(not sources.can_add_monitor_screen(true), "Respect the host virtual-display count limit")
 owner.layout.monitors[1].capturable = false
 assert(not sources.can_add_monitor_screen(false), "Do not offer an uncapturable physical output")
 owner.layout.monitors[1].capturable = true
 for i in 3: owner.screens.append(VRScreen.new())
 assert(not sources.can_add_monitor_screen(false) and not sources.can_add_browser_screen(), "Browsers and monitors share four visible surfaces")
 for s in owner.screens: s.free()
 owner.screens.clear()
 owner.settings.host.is_polaris_host = false
 assert(not sources.can_add_monitor_screen(false))
 owner.free()
 print("All screen creation tests passed")
 quit()

func _test_close_dispatch(keep_browser := false):
 var owner := Owner.new()
 owner.settings_controller.owner = owner
 owner.settings.host.is_polaris_host = true
 owner.settings.host.virtual_display_installed = true
 owner.session_lifecycle.begin_connect()
 owner.session_lifecycle.stream_started()
 for id in [&"m0", &"v1", &"v2"]:
  var monitor := ScreenLayout.MonitorSpec.new()
  monitor.id = id
  monitor.hint = {"virtual": id != &"m0"}
  monitor.is_primary = id == &"m0"
  owner.layout.monitors.append(monitor)
  var view := VRScreen.new()
  view.monitor_id = id
  view.content_tabs.add(ScreenContentTab.for_monitor(id))
  owner.screens.append(view)
 owner.primary_screen = owner.screens[0]
 var sources := ScreenSources.new(owner,"Android")
 var provider := Browser.new()
 var browser_tab := ScreenContentTab.new()
 if keep_browser:
  provider.suspended = true
  provider.pages = [{"id":1,"title":"Retained browser"}]
  provider.browser_id = 1
  sources._browsers[owner.screens[1].get_instance_id()] = provider
  browser_tab.id = &"browser:page:1"
  browser_tab.kind = ScreenContentTab.BROWSER
  browser_tab.locator = {"url":"about:blank"}
  assert(owner.screens[1].content_tabs.add(browser_tab))
  owner.screens[1].content_tabs.select(&"monitor:v1")
 sources.virtual_sizes = [Vector2i(1280,720),Vector2i(2560,1440)]
 var retained_tab := owner.screens[2].content_tabs.selected()
 retained_tab.crop_mode = 2
 assert(sources.close_monitor_screen(owner.screens[1]))
 assert(owner.settings_controller.requests[-1] == [1,1,true])
 assert(owner.settings_controller._monitor_selection_override == [&"m0"])
 assert(sources.virtual_sizes == [Vector2i(2560,1440)])
 assert(owner.screens[2].monitor_id == &"v1")
 assert(owner.screens[2].content_tabs.selected() == retained_tab and retained_tab.crop_mode == 2)
 assert(retained_tab.locator.monitor_id == "v1")
 if keep_browser:
  assert(provider.active and provider.pages.size() == 1, "Closing the monitor tab must retain other browser tabs")
  assert(owner.screens[1].content_tabs.selected() == browser_tab)
  assert(String(owner.screens[1].monitor_id).begins_with("browser-screen:"))
 assert(not sources.close_monitor_screen(owner.screens[2]), "Do not race a pending monitor change")
 for screen in owner.screens: screen.free()
 owner.free()
