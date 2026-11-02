#!/usr/bin/python3
"""Bounded app-domain test of upstream Termux:VA's tiny built-in AVC sample.
No accounts, protected media, display or main Nightfall APK involved.
Build the pinned upstream dependency in the ignored cache first (see plan).
"""
import argparse
import json
from pathlib import Path
import shlex
import time
import subprocess
from test_guard import HeadsetTestGuard

ROOT=Path(__file__).resolve().parents[3]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--va',action='store_true',help='Enumerate the guest VA driver with the daemon active')
    parser.add_argument("--ffmpeg",action="store_true",help="Decode 60 generated frames through guest FFmpeg VA-API")
    parser.add_argument("--low-delay",action="store_true",help="Use a separate generated H.264 clip without B-frame reordering")
    parser.add_argument("--display-order",action="store_true",help="Test daemon without the Qualcomm picture-order override")
    parser.add_argument("--elementary",action="store_true",help="Feed the original Annex B stream directly to the daemon")
    parser.add_argument("--pps-driver",action="store_true",help="Select the isolated experimental PPS reconstruction build")
    args=parser.parse_args()
    if args.elementary and (args.ffmpeg or args.va or args.low_delay):parser.error("--elementary is a separate test mode")
    if args.low_delay and not args.ffmpeg: parser.error("--low-delay requires --ffmpeg")
    source=ROOT/'.build-cache/browser-quest-linux/termux-va-source'
    revision=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    result={'pps_driver':args.pps_driver,'display_order_test':args.display_order,'low_delay_clip':args.low_delay,'upstream':'https://github.com/lfdevs/termux-va','revision':revision}
    output=ROOT/'.build-cache/browser-quest-linux'/('mediacodec-'+time.strftime('%Y%m%dT%H%M%SZ',time.gmtime())+'.json')
    with HeadsetTestGuard(20) as guard:
        guard.shell('am force-stop app.nightfall.browserlab')
        for name in ('termux-va','tva-probe'):
            path='files/linux/'+name
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > '+path),input=(source/'build'/name).read_bytes())
            guard.shell('run-as app.nightfall.browserlab chmod 700 '+path)
        if args.elementary:
            for source,target in [(source/'tools/test_decode.py','tva-test-decode.py'),(ROOT/'.build-cache/browser-quest-linux/generated-original-60.h264','nf-generated-video.h264')]:
                guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/rootfs/tmp/'+target),input=source.read_bytes())
        if args.ffmpeg:
            for source,target in [(ROOT/"tools/experiments/browser-quest-linux/probe-ffmpeg-va.py","probe-ffmpeg-va.py"),(ROOT/(".build-cache/browser-quest-linux/generated-720p60-low-delay.mp4" if args.low_delay else ".build-cache/browser-quest-linux/generated-720p60.mp4"),"nf-generated-video.mp4")]:
                guard.shell("run-as app.nightfall.browserlab sh -c "+shlex.quote("cat > files/linux/rootfs/tmp/"+target),input=source.read_bytes())
        if args.va:
            script=ROOT/'tools/experiments/browser-quest-linux/probe-linux-va.py'
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/rootfs/tmp/probe-linux-va.py'),input=script.read_bytes())
        guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-allocation-status.json')
        guard.shell('run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.GpuAllocationService ' + ('--ez elementary_probe true' if args.elementary else '--ez ffmpeg_probe true' if args.ffmpeg else '--ez va_probe true' if args.va else '--ez media_probe true') + (' --ez codec_display_order true' if args.display_order else '') + (' --ez pps_driver true' if args.pps_driver else ''))
        deadline=time.monotonic()+12
        while time.monotonic()<deadline:
            try:
                status=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-status.json').stdout)
                if status.get('complete'): result['status']=status;break
            except (ValueError,subprocess.SubprocessError):pass
            time.sleep(.2)
        else:raise TimeoutError('Media probe deadline')
        for name in ('daemon','client'):
            try:result[name]=guard.shell('run-as app.nightfall.browserlab cat files/linux/media-probe-'+name+'.log').stdout.decode(errors='replace')[-32768:]
            except subprocess.SubprocessError:result[name]='No diagnostic output'
        for line in result.get('client','').splitlines():
            try:
                value=json.loads(line)
                if isinstance(value,dict):result['client_report']=value
            except ValueError:pass
        output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'output':str(output),**result},indent=2))

if __name__=='__main__':main()
