"""Guarded standalone AMD interop test. Does not start or modify Meteor."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'.build-cache/meteor-xr/amd-vaapi'


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


def require_healthy_boot(marker):
    if marker.exists() and json.loads(marker.read_text()).get('boot_id')==boot_id():
        raise RuntimeError('AMD recovery failed earlier in this boot. Reboot before running another GPU probe.')


def amd_device(root=Path('/sys/class/drm')):
    candidates=[]
    for path in root.glob('renderD*'):
        try:
            if (path/'device/vendor').read_text().strip()=='0x1002':
                candidates.append('/dev/dri/'+path.name)
        except OSError: pass
    if len(candidates)!=1:
        raise RuntimeError('Specify --device: expected exactly one AMD render device, found '+str(candidates))
    return candidates[0]


def require_current_build():
    try:
        stamp=json.loads((OUTPUT/'validated-sources.json').read_text())
        for name,expected in stamp['sources'].items():
            if hashlib.sha256((ROOT/name).read_bytes()).hexdigest()!=expected:
                raise ValueError('Source changed: '+name)
        for name,key in [('meteor-vulkan-vaapi-probe','binary_sha256'),('pattern.spv','shader_sha256'),('libmeteor-vaapi-probe.so','bridge_sha256')]:
            if hashlib.sha256((OUTPUT/name).read_bytes()).hexdigest()!=stamp[key]:
                raise ValueError('Artifact changed: '+name)
    except (OSError,ValueError,KeyError) as error:
        raise RuntimeError('Rebuild with tools/build_support/build_meteor_vaapi_probe.sh before testing') from error


def recovery_check(output):
    result=subprocess.run(['journalctl','-k','--since','2 minutes ago','--no-pager'],capture_output=True,text=True,timeout=5)
    (output/'kernel.log').write_text(result.stdout+result.stderr)
    if 'GPU Recovery Failed' in result.stdout:
        (OUTPUT/'failed-boot.json').write_text(json.dumps({'boot_id':boot_id(),'reason':'kernel AMD recovery failure'})+'\n')
        raise RuntimeError('AMD driver recovery failed; further probes are blocked until reboot')


def run(args):
    require_healthy_boot(OUTPUT/'failed-boot.json')
    require_current_build()
    output=OUTPUT/('run-'+str(time.time_ns()))
    output.mkdir(parents=True)
    clip=output/('stereo.'+args.codec)
    report=output/'timing.json'
    env=dict(os.environ,METEOR_VAAPI_PROBE_PACE_HZ=str(args.hz),METEOR_VAAPI_PROBE_RC_MODE=args.rc_mode,METEOR_VAAPI_PROBE_PROFILE=args.profile)
    command=[str(OUTPUT/'meteor-vulkan-vaapi-probe'),args.device or amd_device(),args.codec,str(args.width),str(args.height),
             str(args.frames),str(OUTPUT/'pattern.spv'),str(clip),str(report)]
    with (output/'encoder.log').open('w') as log:
        process=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
        deadline=time.monotonic()+30
        try:
            while process.poll() is None and time.monotonic()<deadline:
                time.sleep(.1)
            if process.poll() is None:
                process.kill()
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired: pass  # A wedged driver must not trap the runner in wait().
                recovery_check(output)
                raise RuntimeError(f'GPU probe timed out; do not repeat before reviewing {output}')
            recovery_check(output)
            if process.returncode:
                raise RuntimeError(f'Encoder failed; see {output}/encoder.log')
        finally:
            if process.poll() is None: process.kill()
    info=json.loads(subprocess.check_output(['/usr/bin/ffprobe','-v','error','-count_frames',
        '-show_entries','stream=codec_name,width,height,nb_read_frames','-of','json',str(clip)],text=True))
    stream=info['streams'][0]
    assert (stream['width'],stream['height'],int(stream['nb_read_frames']))==(args.width,args.height,args.frames)
    strict=subprocess.run(['/usr/bin/ffmpeg','-v','error','-xerror','-err_detect','explode',
        '-hwaccel','none','-i',str(clip),'-f','null','-'],capture_output=True,text=True,timeout=30)
    (output/'strict-decode.log').write_text(strict.stderr)
    if strict.returncode:
        raise RuntimeError(f'Corrupt encoded frames; see {output}/strict-decode.log')
    pixels=subprocess.check_output(['/usr/bin/ffmpeg','-v','error','-hwaccel','none','-i',str(clip),
        '-frames:v','1','-f','rawvideo','-pix_fmt','rgb24','-'],timeout=30)
    def sample(x,y):
        offset=(y*args.width+x)*3
        return list(pixels[offset:offset+3])
    left=sample(args.width//4,args.height//2)
    right=sample(args.width*3//4,args.height//2)
    top=sample(args.width//4,args.height//4)
    bottom=sample(args.width//4,args.height*3//4)
    assert left[0]>left[2]+100 and right[2]>right[0]+100, (left,right)
    assert bottom[1]>top[1]+20, (top,bottom)
    info.update({'left_sample':left,'right_sample':right,'top_sample':top,'bottom_sample':bottom,
                 'pixel_path':'Vulkan -> shared DMA-BUF -> VA VPP -> NV12 -> VA encoder'})
    (output/'validation.json').write_text(json.dumps(info,indent=2)+'\n')
    print(report.read_text())
    print('PASS decoded frame count, left/right colors and vertical orientation:',output)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device',help='Explicit DRM render node; otherwise select the sole AMD device')
    parser.add_argument('--codec',choices=['hevc','h264'],default='hevc')
    parser.add_argument('--rc-mode',choices=['CBR','CQP','VBR'],default='CBR')
    parser.add_argument('--profile',choices=['baseline','main','high'],default='main')
    parser.add_argument('--width',type=int,default=1024)
    parser.add_argument('--height',type=int,default=512)
    parser.add_argument('--frames',type=int,default=48)
    parser.add_argument('--hz',type=int,default=72)
    run(parser.parse_args())
