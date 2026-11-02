#!/usr/bin/python3
"""Short generated-only native Android GPU-buffer capability/correctness probe."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from test_guard import HeadsetTestGuard
ROOT=Path(__file__).resolve().parents[3]
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--share',action='store_true');parser.add_argument('--hd',action='store_true');args=parser.parse_args()
    if args.hd:args.share=True
    cache=ROOT/'.build-cache/browser-quest-linux'
    binary=cache/'kgsl-probe/gpu-buffer-probe'
    result={'limits':('Generated '+('1280x720' if args.hd else '128x128')+' shared RGB only' if args.share else 'Generated 64x64 RGB only')+'; no Chrome, accounts, media or awake override.'}
    with HeadsetTestGuard(20) as guard:
        guard.shell('am force-stop app.nightfall.browserlab')
        guard.shell('run-as app.nightfall.browserlab sh -c "cat > files/linux/gpu-buffer-probe"',input=binary.read_bytes())
        guard.shell('run-as app.nightfall.browserlab chmod 700 files/linux/gpu-buffer-probe')
        guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-allocation-status.json files/linux/gpu-allocation-buffer.json')
        if args.share:
            for name in ('probe-gpu-buffer-share.py','paint-generated-dmabuf.py'):
                guard.shell('run-as app.nightfall.browserlab sh -c "cat > files/linux/rootfs/tmp/'+name+'"',input=(ROOT/'tools/experiments/browser-quest-linux'/name).read_bytes())
        guard.shell('run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.GpuAllocationService --ez '+('gpu_shared_probe' if args.share else 'gpu_buffer_probe')+' true'+(' --ez gpu_hd true' if args.hd else ''))
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            try:
                status=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-status.json').stdout)
                if status.get('complete'):result['status']=status;break
            except (ValueError,subprocess.SubprocessError):pass
            time.sleep(.15)
        else:raise TimeoutError('Native GPU buffer test deadline')
        raw=guard.shell('run-as app.nightfall.browserlab cat files/linux/'+('gpu-sharing-native.json' if args.share else 'gpu-allocation-buffer.json')).stdout.decode(errors='replace')
        if args.share:
            result['linux_diagnostics']=guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-sharing-linux.json').stdout.decode(errors='replace')[-6000:]
        result['diagnostics']=raw[-6000:]
        for line in raw.splitlines():
            try:result['native']=json.loads(line)
            except ValueError:pass
        result['passed']=bool(result.get('native',{}).get('shared',{}).get('passed') and result['status'].get('guest_exit')==0 and result['status'].get('native_exit')==0) if args.share else bool(result.get('native',{}).get('generated_rgb_passed') and result['status'].get('buffer_exit')==0)
        output=cache/('gpu-buffer-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'.json')
        output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'output':str(output),**result},indent=2))
    return 0 if result['passed'] else 1
if __name__=='__main__':raise SystemExit(main())
