#!/usr/bin/python3
"""Bounded temporary-profile Chrome rendering and video comparison, with automatic device cleanup.
Requires the rebuilt companion installed and the NDK-built static probe binary.
"""
import argparse
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import time
from test_guard import HeadsetTestGuard

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--x11", action="store_true", help="Test isolated Xvfb display rather than headless")
    parser.add_argument("--software", action="store_true", help="Measure the existing software Chrome baseline")
    parser.add_argument("--video", action="store_true", help="Also play the local generated 720p60 clip")
    parser.add_argument("--va", action="store_true", help="Try guest VA-API bridged to Android MediaCodec")
    parser.add_argument("--pps-driver",action="store_true",help="Use the experimental corrected VA reconstruction driver")
    parser.add_argument("--dri3-server",action="store_true",help="Use the isolated patched DRI3 Xvfb server")
    parser.add_argument("--native-egl-only",action="store_true",help="Test native window swaps without launching Chrome or media")
    parser.add_argument("--readback-ms",type=int,choices=(0,16,33),default=16,help="Diagnostic Xvfb CPU readback interval; zero disables capture")
    parser.add_argument("--async-readback",action="store_true",help="Diagnostic fence/PBO framebuffer capture")
    parser.add_argument("--foreground",action="store_true",help="Show the lab Activity before spawning Linux to measure foreground CPU scheduling")
    parser.add_argument("--server-sysmem",action="store_true",help="Diagnostic Freedreno untiled server rendering")
    parser.add_argument("--coherent-readback",action="store_true",help="Diagnostic coherent KGSL staging allocations")
    parser.add_argument("--gpu-capture",action="store_true",help="Generated XComposite/DRI3 GPU capture to Android AHB")
    parser.add_argument("--surface-capture",action="store_true",help="Use native EGL window output with a generated ImageReader sink")
    parser.add_argument("--surface-stop-early",action="store_true",help="Interrupt the generated Surface test to check shutdown and resource cleanup")
    args = parser.parse_args()
    if args.surface_stop_early:args.surface_capture=True
    if args.surface_capture:args.gpu_capture=True
    if args.gpu_capture:
        args.x11=args.video=args.va=args.pps_driver=args.dri3_server=True
        args.readback_ms=0
    if args.native_egl_only:args.x11=args.va=args.pps_driver=args.dri3_server=True
    if args.dri3_server and not (args.x11 and args.pps_driver):parser.error("--dri3-server requires --x11 --pps-driver")
    if args.pps_driver and not args.va:parser.error("--pps-driver requires --va")
    if args.va and (args.software or not (args.video or args.native_egl_only)): parser.error("--va requires --video and GPU mode")
    binary = ROOT / '.build-cache/browser-quest-linux/kgsl-probe/libnightfall-kgsl-compat.so'
    if not binary.is_file(): raise RuntimeError('Compile kgsl-compat.c with NDK r29 first')
    result = {'limits': 'Temporary-profile Chrome; generated page/optional generated clip only; no accounts.'}
    output = ROOT / '.build-cache/browser-quest-linux' / ('chrome-gpu-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '.json')
    with HeadsetTestGuard(35) as guard:
        # Generated local video is optional; no worn/awake override is needed.
        guard.shell('am force-stop app.nightfall.browserlab')
        for source, name in ((binary, 'libnightfall-kgsl-compat.so'),
                             (ROOT / 'tools/experiments/browser-quest-linux/probe-chrome-gpu.py', 'probe-chrome-gpu.py'),
                             (ROOT / 'tools/experiments/browser-quest-linux/browser-diagnostics.py', 'browser-diagnostics.py'),
                             (ROOT / 'tools/experiments/browser-quest-linux/probe-dri3-buffer.py', 'probe-dri3-buffer.py'),
                             (ROOT / 'tools/experiments/browser-quest-linux/paint-generated-dmabuf.py', 'paint-generated-dmabuf.py'),
                             (ROOT / 'tools/experiments/browser-quest-linux/probe-native-egl-window.py', 'probe-native-egl-window.py'),
                             (ROOT / 'tools/experiments/browser-quest-linux/gpu-x11-capture.py', 'gpu-x11-capture.py')):
            target = 'files/linux/rootfs/tmp/' + name
            guard.shell('run-as app.nightfall.browserlab sh -c ' + shlex.quote('cat > ' + target), input=source.read_bytes())
            guard.shell('run-as app.nightfall.browserlab chmod 700 ' + target)
        guard.shell('run-as app.nightfall.browserlab sh -c "cat > files/linux/rootfs/tmp/nf-xvfb-readback-ms"',input=(str(args.readback_ms)+','+str(int(args.async_readback))+','+str(int(args.server_sysmem))+','+str(int(args.coherent_readback))).encode())
        if args.gpu_capture:
            guard.shell('run-as app.nightfall.browserlab sh -c "cat > files/linux/gpu-buffer-probe"',input=(ROOT/'.build-cache/browser-quest-linux/kgsl-probe/gpu-buffer-probe').read_bytes())
            guard.shell('run-as app.nightfall.browserlab chmod 700 files/linux/gpu-buffer-probe')
        if args.video:
            clip = ROOT / '.build-cache/browser-quest-linux/generated-720p60.mp4'
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/rootfs/tmp/nf-generated-video.mp4'), input=clip.read_bytes())
        if args.va:
            daemon=ROOT/'.build-cache/browser-quest-linux/termux-va-source/build/termux-va'
            guard.shell('run-as app.nightfall.browserlab sh -c '+shlex.quote('cat > files/linux/termux-va'),input=daemon.read_bytes())
            guard.shell('run-as app.nightfall.browserlab chmod 700 files/linux/termux-va')
        guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-allocation-status.json files/linux/gpu-allocation-chrome.json')
        if args.surface_capture:
            guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-surface-status.json files/linux/gpu-surface-probe.json')
        if args.foreground:
            guard.shell('am start -W -n app.nightfall.browserlab/.BrowserLabActivity')
            time.sleep(1)
        guard.shell('run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.GpuAllocationService --ez chrome_probe true' + (' --ez chrome_x11 true' if args.x11 else '') + (' --ez chrome_software true' if args.software else '') + (' --ez chrome_video true' if args.video else '') + (' --ez chrome_va true' if args.va else '') + (' --ez pps_driver true' if args.pps_driver else '') + (' --ez dri3_server true' if args.dri3_server else '') + (' --ez native_egl_only true' if args.native_egl_only else '')+(' --ez chrome_gpu_capture true' if args.gpu_capture else '')+(' --ez chrome_surface_capture true' if args.surface_capture else '')+(' --ez chrome_surface_stop true' if args.surface_stop_early else ''))
        deadline = time.monotonic() + 24
        while time.monotonic() < deadline:
            try:
                status = json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-status.json').stdout)
                if status.get('complete'):
                    result['status'] = status
                    break
            except (ValueError, subprocess.SubprocessError): pass
            time.sleep(.2)
        else: raise TimeoutError('Allocation service did not finish before bounded deadline')
        for mode in ('chrome',):
            raw = guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-' + mode + '.json').stdout.decode()
            reports = []
            for line in raw.splitlines():
                try:
                    value = json.loads(line)
                    if isinstance(value, dict): reports.append(value)
                except ValueError: pass
            result[mode] = reports[-1] if reports else {'passed': False}
            result[mode]['diagnostics'] = raw[-5000:]
            result[mode]['device_lost'] = 'DEVICE LOST' in raw.upper()
            result[mode]['submission_error'] = 'submit failed' in raw.lower()
            result[mode]['reliable_candidate'] = bool(result[mode].get('passed')
                    and not result[mode].get('software_renderer', True)
                    and not result[mode]['device_lost']
                    and not result[mode]['submission_error']
                    and result['status'].get(mode + '_exit') == 0
                    and (not args.video or result[mode].get('video_benchmark',{}).get('smooth_playback_candidate',False)))
        if args.surface_capture:
            result['gpu_surface_status']=json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-surface-status.json').stdout)
            result['gpu_surface_probe']=result['status'].get('surface_probe',{})
            if args.surface_stop_early:
                sink=result['gpu_surface_probe']
                result['expected_stop_test']={'passed':bool(0<=sink.get('early_stop_ms',-1)<2500 and not sink.get('worker_alive_after_early_stop',True) and result['gpu_surface_status'].get('state')=='stopped' and sink.get('received_frames',0)>0 and result['status'].get('chrome_exit')==0),'early_stop_ms':sink.get('early_stop_ms'),'limits':'Intentional interruption; complete video/quadrant validation is not expected.'}
            gpu_status=result['gpu_surface_status']
            expected_frames=result['chrome'].get('gpu_capture',{}).get('frames',0)
            result['surface_fences_balanced']=bool(expected_frames>0 and all(gpu_status.get(key)==expected_frames for key in ('posted_frames','imported_fences','exported_fences')) and result['chrome'].get('gpu_capture',{}).get('release_fences')==expected_frames)
            if not (result['gpu_surface_probe'].get('passed') and gpu_status.get('state')=='stopped' and result['surface_fences_balanced']):
                result['chrome']['passed']=False;result['chrome']['reliable_candidate']=False
        elif args.gpu_capture:
            raw_native=guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-capture-native.json').stdout.decode(errors='replace')
            result['gpu_capture_diagnostics']=raw_native[-6000:]
            for line in raw_native.splitlines():
                try:result['gpu_capture_native']=json.loads(line)
                except ValueError:pass
            if not (result.get('gpu_capture_native',{}).get('shared',{}).get('passed') and result['status'].get('buffer_export_exit')==0):
                result['chrome']['passed']=False;result['chrome']['reliable_candidate']=False
        if args.va and not args.native_egl_only:
            result['codec_daemon']=guard.shell('run-as app.nightfall.browserlab cat files/linux/media-probe-daemon.log').stdout.decode(errors='replace')[-8000:]
            frames=[int(n) for n in re.findall(r'(\d+) frames out',result['codec_daemon'])]
            result['bridge_decode_confirmed']=bool(frames and max(frames)>0)
            if not result['bridge_decode_confirmed']:
                result['chrome']['passed']=False
                result['chrome']['reliable_candidate']=False
        output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'output': str(output), **result}, indent=2))


if __name__ == '__main__': main()
