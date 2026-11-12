#!/usr/bin/env python3
"""Bounded headless menu layout/scroll checks; no gamescope or GPU required."""
from pathlib import Path
import os,sys,socket,subprocess,tempfile,time,json
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'tools'));import nf
out=root/'build/verify/menu-pages';out.mkdir(parents=True,exist_ok=True)
with tempfile.TemporaryDirectory(prefix='nf-menu-pages-') as td:
 with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
 env=dict(os.environ,XDG_DATA_HOME=td+'/data',XDG_CONFIG_HOME=td+'/config')
 with (out/'godot.log').open('w') as log:
  proc=subprocess.Popen(['/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64','--headless','--xr-mode','off','--path',str(root),'--log-file',str(out/'session.log'),'--','--nf-no-xr','--nf-dev-bridge',f'--nf-dev-bridge-port={port}'],env=env,stdout=log,stderr=subprocess.STDOUT)
 def ev(expr):
  result=nf.request({'cmd':'eval','expr':expr},port,timeout=3)
  assert result.get('ok'),result
  return result.get('value')
 try:
  deadline=time.monotonic()+20
  while True:
   try:
    if nf.request({'cmd':'ping'},port,timeout=.5).get('ok'):break
   except (OSError,ValueError):pass
   if proc.poll() is not None or time.monotonic()>deadline:raise RuntimeError('No headless bridge')
   time.sleep(.2)
  reports=[]
  # Hold the offline UI fixture in place without simulating native streaming.
  ev('set_process(false)')
  for tab in [0,1,4,5,7]:
   ev(f'ui_controller.switch_tab({tab})');time.sleep(.1)
   ui=nf.request({'cmd':'ui','viewport':'ui'},port,timeout=3)
   (out/f'tab-{tab}.json').write_text(json.dumps(ui,indent=2))
   rect=ev('[ui_viewport.find_child("CompGrabBar",true,false).get_global_rect(), _ui_status_label.get_global_rect(), _ui_exit_btn.is_visible_in_tree(),ui_controller._settings_gear_btn.is_visible_in_tree()]')
   reports.append({'tab':tab,'rects_and_toolbar':rect})
  pcvr=ev('[ui_controller._pcvr_page.get_global_rect(),ui_controller._pcvr_status.get_global_rect(),ui_controller._pcvr_info.get_global_rect(),ui_controller._pcvr_resolution_btn.get_global_rect(),ui_controller._pcvr_tabs.get_global_rect()]')
  assert all(r['rects_and_toolbar'][:2] == reports[0]['rects_and_toolbar'][:2] for r in reports[:4]), reports
  assert all(r['rects_and_toolbar'][2:] == [True,True] for r in reports), reports
  assert ev('_ui_disconnect_btn.visible and _ui_disconnect_btn.disabled'), 'PCVR keeps a disabled Disconnect when no desktop stream exists'
  assert ev('ui_controller._browser_count_btn.disabled'), 'Browser count is read-only'
  assert ev('ui_controller._browser_count_btn.size == _ui_res_btn.size'), 'Screens uses standard option dimensions'
  ev('ui_controller.set("_vr_library_open", true)')
  ev('ui_controller.switch_tab(7)')
  cards=[{'key':f'steam:{i}','name':f'Test VR app {i}','source':'Steam','vr':True,'ready':True} for i in range(12)]
  ev('ui_controller._vr_library.set("_textures",'+json.dumps({c['key']:None for c in cards})+')')
  ev('ui_controller._vr_library._reply('+json.dumps({'action':'list','offset':0,'total':12,'apps':cards})+')')
  time.sleep(.2)
  assert ev('ui_controller._vr_library._scroll.get_v_scroll_bar().max_value > ui_controller._vr_library._scroll.get_v_scroll_bar().page'), 'Library must scroll past one row'
  ev('ui_controller._vr_library._scroll.set("scroll_vertical", 10000)');time.sleep(1.0)
  assert ev('ui_controller._vr_library._scroll.get_global_rect().intersects(ui_controller._vr_library._grid.get_child(11).get_global_rect())'), 'Final app reachable'
  gear=nf.request({'cmd':'press','target':'SettingsGear'},port,timeout=3)
  assert gear.get('ok') and gear.get('hit'), gear
  assert ev('ui_controller._current_tab == 6'), 'Gear remains clickable after scrolling the library'
  print('PASS: menu geometry, read-only browser count, 12 scrollable apps and toolbar hit testing')
  (out/'summary.json').write_text(json.dumps({'ok':True,'tabs':reports,'pcvr':pcvr,'library_scroll_and_gear':True},indent=2))
 finally:
  proc.terminate()
  try:proc.wait(timeout=5)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
