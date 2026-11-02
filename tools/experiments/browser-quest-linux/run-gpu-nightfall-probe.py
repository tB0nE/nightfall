#!/usr/bin/python3
"""Bounded generated-only cold attach through real Nightfall Binder Surface."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
from test_guard import HeadsetTestGuard
from gpu_hang_monitor import GpuHangMonitor
from android_activity_state import activity_snapshot
ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('nf',ROOT/'tools/nf.py');nf=importlib.util.module_from_spec(spec);spec.loader.exec_module(nf)
def evaluate(expression):
    reply=nf.request({'cmd':'eval','expr':expression},timeout=8)
    if not reply.get('ok'):raise RuntimeError(reply.get('error','Bridge expression failed'))
    return reply.get('result',reply.get('value'))
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--interactive',action='store_true',help='Generated scrolling/layout fixture, no video')
    parser.add_argument('--disable-ai3d',action='store_true',help='Disable AI 3D in memory for this run only; no saved settings changes')
    parser.add_argument('--already-open',action='store_true',help='Use manually opened Nightfall instead of relaunching behind Horizon taskbar')
    parser.add_argument('--capture-mode',choices=('composite','solid'),default='composite',help='Solid generates colours instead of reading/blitting the X11 source')
    parser.add_argument('--driver-policy',choices=('default','sysmem','linear'),default='default',help='Apply untiled Mesa rendering to Xvfb, Chrome and capture together')
    parser.add_argument('--surface-only',action='store_true',help='120 generated frames to real Surface, no Xvfb/Chrome/runtime startup')
    parser.add_argument('--surface-x11',choices=('off','startup','idle','capture','idle-gles','capture-gles'),default='off',help='Add Xvfb drawing alongside generated Surface, optionally capture its image; implies --surface-only')
    parser.add_argument('--software-baseline',action='store_true',help='Known software Chrome/Xvfb route with Android hardware Canvas; no Linux Mesa GPU')
    args=parser.parse_args()
    if args.software_baseline and (args.surface_only or args.surface_x11!='off'):parser.error('Software baseline cannot use GPU Surface diagnostics')
    if args.surface_x11!='off':args.surface_only=True
    cache=ROOT/'.build-cache/browser-quest-linux';result={}
    stamp=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
    log_path=cache/('gpu-nightfall-'+stamp+'-logcat.txt')
    monitor=None
    with HeadsetTestGuard(80) as guard:
        if not args.already_open:guard.shell('am force-stop app.nightfall.quest')
        guard.shell('am force-stop app.nightfall.browserlab')
        config='files/linux/direct-frame-config.json'
        previous=guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('if [ -f '+config+' ]; then cat '+config+'; else printf null; fi')).stdout
        mode_file='files/linux/rootfs/tmp/nf-gpu-capture-mode'
        previous_mode=guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('if [ -f '+mode_file+' ]; then cat '+mode_file+'; else printf absent; fi')).stdout
        policy_file='files/linux/rootfs/tmp/nf-gpu-driver-policy'
        previous_policy=guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('if [ -f '+policy_file+' ]; then cat '+policy_file+'; else printf absent; fi')).stdout
        renderer_file='files/linux/rootfs/tmp/nightfall-chrome-renderer'
        previous_renderer=guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('if [ -f '+renderer_file+' ]; then cat '+renderer_file+'; else printf absent; fi')).stdout
        try:
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+mode_file),input=args.capture_mode.encode())
            if args.software_baseline:guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+renderer_file),input=b'software\n')
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+policy_file),input=args.driver_policy.encode())
            result['driver_policy']=args.driver_policy
            result['software_baseline']=args.software_baseline
            result['surface_x11_mode']=args.surface_x11
            result['capture_mode']='generated' if args.surface_only else args.capture_mode
            log_since=guard.shell("date '+%m-%d %H:%M:%S.000'").stdout.decode().strip()
            monitor=GpuHangMonitor(guard,log_since,log_path).start()
            result['kernel_log']=str(log_path)
            value={} if previous.strip()==b'null' else json.loads(previous)
            value.update(gpu_renderer=not args.software_baseline,generated_gpu_test=True,generated_minimal_gpu_test=args.surface_only,generated_surface_x11_mode=args.surface_x11)
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+config),input=json.dumps(value).encode())
            for name in ('gpu-process-groups.sh','start-desktop.sh','gpu-x11-capture.py','gpu-browser-capture.py','gpu-runtime-test.html','probe-gpu-surface-generated.py'):
                guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/rootfs/tmp/'+name),input=(ROOT/'tools/experiments/browser-quest-linux'/('gpu-runtime-interactive.html' if args.interactive and name=='gpu-runtime-test.html' else name)).read_bytes())
            guard.shell('run-as app.nightfall.browserlab rm -f files/linux/direct-frame-status.json files/linux/gpu-surface-status.json files/linux/rootfs/tmp/gpu-live-status.json files/linux/rootfs/tmp/gpu-generated-surface-status.json')
            env=dict(os.environ,ADB=guard.adb,ANDROID_SERIAL=guard.serial)
            result['stage']='launch'
            for command in (('awake',) if args.already_open else ('awake','launch')):
                subprocess.run(['/usr/bin/python3',str(ROOT/'tools/quest.py'),'--serial',guard.serial,command],env=env,check=True,capture_output=True,timeout=12)
            subprocess.run([guard.adb,'-s',guard.serial,'forward','tcp:47950','tcp:47950'],check=True,capture_output=True,timeout=5)
            result['stage']='bridge'
            deadline=time.monotonic()+12
            while time.monotonic()<deadline:
                try:
                    if nf.request({'cmd':'ping'},timeout=1).get('ok'):break
                except (OSError,ValueError):pass
                time.sleep(.2)
            else:raise TimeoutError('Nightfall dev bridge unavailable')
            result['stage']='startup_ready'
            deadline=time.monotonic()+12
            while time.monotonic()<deadline:
                if evaluate('_startup_ready'):break
                time.sleep(.2)
            else:raise TimeoutError('Nightfall startup did not complete')
            result['initial_ai3d_speed']=evaluate('settings.host.ai_3d_speed')
            if args.disable_ai3d:
                evaluate('settings.host.set("ai_3d_speed", 0)')
                evaluate('settings_controller.apply_stereo()')
            result['test_ai3d_speed']=evaluate('settings.host.ai_3d_speed')
            result['stage']='open_browser'
            evaluate('browser_prototype.start()')
            deadline=time.monotonic()+10
            while time.monotonic()<deadline:
                if evaluate('browser_prototype.uploader.poll_browser_prototype() == 2'):break
                time.sleep(.25)
            else:raise TimeoutError('WebView did not become ready')
            result['stage']='browser_state'
            result['available']=evaluate('browser_prototype.navigation.get("compatibility_available", false)')
            result['stage']='enter_compatibility'
            evaluate('browser_prototype.navigation_action("compatibility")')
            result['stage']='generated_interaction' if args.interactive else 'generated_video'
            deadline=time.monotonic()+(6 if args.surface_only else 27 if args.interactive else 12)
            while time.monotonic()<deadline:
                monitor.check()
                if args.disable_ai3d:
                    speed=evaluate('settings.host.ai_3d_speed')
                    result['last_test_ai3d_speed']=speed
                    if speed!=0:raise RuntimeError('AI3D test precondition changed during capture')
                time.sleep(1)
            result['stage']='active_state'
            result['active']=evaluate('browser_prototype.active')
            result['direct_active']=evaluate('browser_prototype._linux_direct_seen')
            result['stage']='close_compatibility'
            evaluate('browser_prototype.navigation_action("compatibility")')
            time.sleep(2)
            if args.software_baseline:
                result['native']=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/direct-frame-status.json').stdout)
                result['passed']=bool(result['active'] and result['direct_active'] and result['native'].get('posted_frames',0)>100 and result['native'].get('state')=='stopped' and result['native'].get('changed_samples',0)>0 and result['native'].get('drawing')=='hardware_canvas')
            else:
                result['native']=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-surface-status.json').stdout)
                result['producer']=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/rootfs/tmp/'+('gpu-generated-surface-status.json' if args.surface_only else 'gpu-live-status.json')).stdout)
                result['passed']=bool(result['active'] and result['direct_active'] and result['native'].get('posted_frames',0)>100 and result['native'].get('state')=='stopped' and (result['producer'].get('passed') if args.surface_only else result['producer'].get('state')=='stopped'))
        except Exception as error:
            # Error snapshots can also follow the hang monitor stopping apps.
            # Android has resumed activities on several displays: the last one
            # is often TaskBar even while Nightfall itself is resumed.
            try:
                result['activity_state']=activity_snapshot(guard.shell('dumpsys activity activities').stdout.decode(errors='replace'))
                result['focus']=result['activity_state']['preferred_activity']
                result['activity_snapshot_after_error']=True
            except Exception as snapshot_error:result['activity_snapshot_error']=type(snapshot_error).__name__
            result.update(passed=False,error=type(error).__name__+': '+str(error))
            for key,name in [('native_failure_state','direct-frame-status.json' if args.software_baseline else 'gpu-surface-status.json'),('producer_failure_state','rootfs/tmp/gpu-generated-surface-status.json' if args.surface_only else 'rootfs/tmp/gpu-live-status.json')]:
                try:result[key]=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/'+name).stdout)
                except (ValueError,subprocess.SubprocessError):pass
        finally:
            if monitor is not None:
                monitor.stop()
                if monitor.hang.is_set():result.update(passed=False,gpu_hang_detected=True)
                if monitor.error:result['monitor_error']=monitor.error
            guard.shell('am force-stop app.nightfall.quest');guard.shell('am force-stop app.nightfall.browserlab')
            if previous_renderer==b'absent':guard.shell('run-as app.nightfall.browserlab rm -f '+renderer_file)
            else:guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+renderer_file),input=previous_renderer)
            if previous_policy==b'absent':guard.shell('run-as app.nightfall.browserlab rm -f '+policy_file)
            else:guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+policy_file),input=previous_policy)
            if previous_mode==b'absent':guard.shell('run-as app.nightfall.browserlab rm -f '+mode_file)
            else:guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+mode_file),input=previous_mode)
            if previous.strip()==b'null':guard.shell('run-as app.nightfall.browserlab rm -f '+config)
            else:guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+config),input=previous)
        result['fixture']='software-browser-generated' if args.software_baseline else 'generated-surface-no-x11' if args.surface_only else 'generated-scroll-layout' if args.interactive else 'generated-video'
        output=cache/('gpu-nightfall-'+stamp+'.json');output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'output':str(output),**result},indent=2));return 0 if result.get('passed') else 1
if __name__=='__main__':raise SystemExit(main())
