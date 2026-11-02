#!/usr/bin/python3
"""Bounded clear-only Mesa comparison with and without Nightfall XR active."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
from gpu_hang_monitor import GpuHangMonitor
from android_activity_state import activity_snapshot
from test_guard import HeadsetTestGuard
ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('nf',ROOT/'tools/nf.py');nf=importlib.util.module_from_spec(spec);spec.loader.exec_module(nf)
def evaluate(expression):
    reply=nf.request({'cmd':'eval','expr':expression},timeout=3)
    if not reply.get('ok'):raise RuntimeError(reply.get('error','Bridge evaluation failed'))
    return reply.get('value')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--already-open',action='store_true',help='Test XR only in manually foregrounded Nightfall; skip completed standalone baseline')
    parser.add_argument('--share',action='store_true',help='Replace private clear with three generated RGB writes to an Android-owned 128x128 buffer')
    parser.add_argument('--hd',action='store_true',help='Use 1280x720 instead of 128x128 for shared-buffer test')
    parser.add_argument('--fences',action='store_true',help='120 generated frames with bidirectional native fences; implies --hd')
    parser.add_argument('--draw',action='store_true',help='Add a minimal GLES3 triangle to the private clear probe')
    parser.add_argument('--standalone-only',action='store_true',help='Do not launch or test Nightfall XR')
    parser.add_argument('--diagnostics',action='store_true',help='Compile/dump the generated shaders in one standalone frame')
    parser.add_argument('--no-early-preamble',action='store_true',help='Disable the compiler early-preamble feature only in the private probe')
    parser.add_argument('--no-preamble',action='store_true',help='Disable preamble optimizations in the private shader probe')
    parser.add_argument('--arithmetic-vertex',action='store_true',help='Generate vertex positions arithmetically rather than loading a constant table')
    args=parser.parse_args()
    if args.diagnostics:
        if not args.standalone_only:parser.error('--diagnostics requires --standalone-only')
        args.draw=True
    if args.standalone_only and args.already_open:parser.error('--standalone-only cannot use --already-open')
    if args.fences:args.hd=True
    if args.hd:args.share=True
    directory=ROOT/'.build-cache/browser-quest-linux';stamp=time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())
    output=directory/('minimal-gpu-xr-'+stamp+'.json');result={'passed':False,'limits':'32x32 private GLES3 clear/readback, 120 paced frames; no browser/video/imports; not a performance benchmark.'}
    result['test_kind']='android-buffer-sharing' if args.share else 'private-clear'
    if args.share:result['limits']='Three generated RGB writes to '+('1280x720' if args.hd else '128x128')+' Android-owned AHB with synchronous glFinish/ack; no Xvfb, Chrome, video or XR output Surface. Not a sustained fence test.'
    if args.fences:
        result['test_kind']='continuous-fence-sharing'
        result['limits']='120 paced generated frames at 1280x720 with bidirectional native fences and Android pixel checks; no X11/Chrome/video or XR output Surface.'
    if args.draw:
        if args.share:parser.error('--draw is a private-buffer test; cannot combine with sharing')
        result['test_kind']='private-triangle'
    if args.diagnostics:result['limits']='One standalone generated triangle frame with shader compiler diagnostics; no XR session.'
    result['early_preamble_disabled']=args.no_early_preamble or args.no_preamble
    result['preamble_optimization_disabled']=args.no_preamble
    result['vertex_mode']='arithmetic' if args.arithmetic_vertex else 'array'
    monitor=None
    with HeadsetTestGuard(70) as guard:
        try:
            if not args.already_open:guard.shell('am force-stop app.nightfall.quest')
            guard.shell('am force-stop app.nightfall.browserlab')
            source=ROOT/'tools/experiments/browser-quest-linux/probe-minimal-gpu-clear.py'
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/rootfs/tmp/probe-minimal-gpu-clear.py'),input=source.read_bytes())
            if args.share:
                for name in ('probe-gpu-buffer-share.py','paint-generated-dmabuf.py','probe-gpu-fence-loop.py','gpu-x11-capture.py'):
                    guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/rootfs/tmp/'+name),input=(ROOT/'tools/experiments/browser-quest-linux'/name).read_bytes())
                guard.shell('run-as app.nightfall.browserlab sh -c "cat > files/linux/gpu-buffer-probe"',input=(directory/'kgsl-probe/gpu-buffer-probe').read_bytes())
                guard.shell('run-as app.nightfall.browserlab chmod 700 files/linux/gpu-buffer-probe')
            since=guard.shell("date '+%m-%d %H:%M:%S.000'").stdout.decode().strip()
            kernel=directory/('minimal-gpu-xr-'+stamp+'-kernel.txt')
            monitor=GpuHangMonitor(guard,since,kernel).start();result['kernel_log']=str(kernel)
            def run_clear():
                guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-allocation-status.json files/linux/gpu-allocation-kgsl.json')
                guard.shell('run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.GpuAllocationService '+(('--ez gpu_shared_probe true'+(' --ez gpu_hd true' if args.hd else '')+(' --ez gpu_fence_loop true' if args.fences else '')) if args.share else ('--ez egl_probe true --ez minimal_clear true'+(' --ez minimal_draw true' if args.draw else '')+(' --ez minimal_diagnostics true' if args.diagnostics else '')+(' --ez minimal_no_early_preamble true' if args.no_early_preamble else '')+(' --ez minimal_no_preamble true' if args.no_preamble else '')+(' --ez minimal_arithmetic_vertex true' if args.arithmetic_vertex else ''))))
                deadline=time.monotonic()+8
                while time.monotonic()<deadline:
                    monitor.check()
                    try:
                        state=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-status.json').stdout)
                        if state.get('complete'):break
                    except (ValueError,subprocess.SubprocessError):pass
                    time.sleep(.1)
                else:raise TimeoutError('Minimal clear service deadline')
                raw=guard.shell('run-as app.nightfall.browserlab cat files/linux/'+('gpu-sharing-native.json' if args.share else 'gpu-allocation-kgsl.json')).stdout.decode(errors='replace')
                if args.diagnostics:
                    shader_log=directory/('minimal-gpu-'+stamp+'-generated-shaders.txt')
                    shader_log.write_text(raw);result['generated_shader_log']=str(shader_log)
                reports=[]
                for line in raw.splitlines():
                    try:
                        value=json.loads(line)
                        if isinstance(value,dict):reports.append(value)
                    except ValueError:pass
                report=reports[-1] if reports else {'passed':False,'error':'No completed probe report'}
                if args.fences:
                    counters={key:report.get(key) for key in ('capture_frames','imported_fences','exported_fences')}
                    result['last_native_counters']=counters
                    if any(value!=120 for value in counters.values()):state['invalid_fence_counts']=True
                if args.share:report=report.get('shared',{'passed':False,'error':'No shared-buffer result'})
                return {'service':state,'probe':report,'diagnostics':raw[-2500:]}
            def passed(data):
                exits=('guest_exit','native_exit') if args.share else ('kgsl_exit',)
                return bool(data['probe'].get('passed') and not data['service'].get('invalid_fence_counts') and all(data['service'].get(key)==0 for key in exits))
            if not args.already_open:
                result['stage']='baseline'
                result['baseline']=run_clear();monitor.check()
                if not passed(result['baseline']):raise RuntimeError('Baseline clear failed; skipping XR')
                guard.shell('am force-stop app.nightfall.browserlab')
            else:
                result['baseline_skipped']='XR-only retry; consult the separate standalone baseline report'
            if args.standalone_only:
                result['passed']=passed(result['baseline'])
                result['stage']='standalone_complete'
            else:
                result['stage']='xr_launch'
                env=dict(os.environ,ADB=guard.adb,ANDROID_SERIAL=guard.serial)
                for command in (('awake',) if args.already_open else ('awake','launch')):
                    subprocess.run(['/usr/bin/python3',str(ROOT/'tools/quest.py'),'--serial',guard.serial,command],env=env,check=True,capture_output=True,timeout=12)
                subprocess.run([guard.adb,'-s',guard.serial,'forward','tcp:47950','tcp:47950'],check=True,capture_output=True,timeout=5)
                deadline=time.monotonic()+15
                while time.monotonic()<deadline:
                    monitor.check()
                    try:
                        if evaluate('_startup_ready'):break
                    except (OSError,ValueError):pass
                    time.sleep(.2)
                else:raise TimeoutError('Nightfall not foreground/startup ready')
                result['xr_preconditions']=evaluate('[get_viewport().use_xr,browser_prototype.active,is_streaming]')
                if result['xr_preconditions']!=[True,False,False]:raise RuntimeError('Expected XR welcome screen with no browser or stream')
                result['stage']='xr_clear';result['xr']=run_clear();monitor.check()
                result['passed']=passed(result['xr'])
        except Exception as error:
            result['error']=type(error).__name__+': '+str(error)
            try:result['activity_state']=activity_snapshot(guard.shell('dumpsys activity activities').stdout.decode(errors='replace'))
            except Exception as snapshot_error:result['activity_snapshot_error']=type(snapshot_error).__name__
        finally:
            if monitor is not None:
                monitor.stop()
                if monitor.hang.is_set():result.update(passed=False,gpu_hang_detected=True)
                if monitor.error:result['monitor_error']=monitor.error
            guard.shell('am force-stop app.nightfall.browserlab');guard.shell('am force-stop app.nightfall.quest')
            output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'output':str(output),**result},indent=2));return 0 if result.get('passed') else 1
if __name__=='__main__':raise SystemExit(main())
