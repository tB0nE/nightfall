#!/usr/bin/python3
"""Generated normal-runtime start/Surface detach/reattach probe; restores config."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import time
from test_guard import HeadsetTestGuard
ROOT=Path(__file__).resolve().parents[3]
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--animation-only',action='store_true',help='Generated CSS animation; no video decode')
    args=parser.parse_args()
    cache=ROOT/'.build-cache/browser-quest-linux';sources=ROOT/'tools/experiments/browser-quest-linux'
    result={}
    fixture=(sources/('gpu-runtime-animation.html' if args.animation_only else 'gpu-runtime-test.html')).read_bytes()
    with HeadsetTestGuard(70) as guard:
        guard.shell('am force-stop app.nightfall.browserlab')
        config='files/linux/direct-frame-config.json'
        previous=guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('if [ -f '+config+' ]; then cat '+config+'; else printf null; fi')).stdout
        try:
            value={} if previous.strip()==b'null' else json.loads(previous)
            value.update(gpu_renderer=True,target_hz=60)
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+config),input=json.dumps(value).encode())
            for name in ('gpu-process-groups.sh','start-desktop.sh','gpu-x11-capture.py','gpu-browser-capture.py','gpu-runtime-test.html'):
                guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/rootfs/tmp/'+name),input=fixture if name=='gpu-runtime-test.html' else (sources/name).read_bytes())
            if not args.animation_only:
                guard.shell('run-as app.nightfall.browserlab sh -c "cat > files/linux/rootfs/tmp/nf-generated-video.mp4"',input=(cache/'generated-720p60.mp4').read_bytes())
            guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-runtime-probe.json files/linux/rootfs/tmp/nightfall-chrome.pid files/linux/rootfs/tmp/nightfall-framebuffer/Xvfb_screen0')
            guard.shell('run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.GpuRuntimeProbeService')
            deadline=time.monotonic()+50
            while time.monotonic()<deadline:
                try:
                    result=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-runtime-probe.json').stdout)
                    if result.get('complete'):break
                except (ValueError,subprocess.SubprocessError):pass
                time.sleep(.25)
            else:raise TimeoutError('GPU runtime test deadline')
            if not result.get('passed'):
                # Generated test only: no ordinary desktop/profile logs are collected.
                result['generated_runtime_diagnostics']=guard.shell('run-as app.nightfall.browserlab tail -c 5000 files/linux/desktop.log').stdout.decode(errors='replace')
                result['capture_diagnostics']=guard.shell('run-as app.nightfall.browserlab sh -c "test ! -f files/linux/gpu-live.log || tail -c 2000 files/linux/gpu-live.log"').stdout.decode(errors='replace')
        finally:
            guard.shell('am force-stop app.nightfall.browserlab')
            if previous.strip()==b'null':guard.shell('run-as app.nightfall.browserlab rm -f '+config)
            else:guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+config),input=previous)
        result['fixture']='css-animation-no-video' if args.animation_only else 'generated-video'
        output=cache/('gpu-runtime-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'.json')
        output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'output':str(output),**result},indent=2))
    return 0 if result.get('passed') else 1
if __name__=='__main__':raise SystemExit(main())
