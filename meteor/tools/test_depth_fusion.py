#!/usr/bin/python3
"""Bounded real-model fusion replay. Isolated settings; does not restart Meteor."""
import argparse,json,os,re,socket,struct,subprocess,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--background',default='zipdepth_wide_512x288.ncnn.param')
    p.add_argument('--detail',default='vda_s_518x294')
    p.add_argument('--modes',nargs='+',default=['Feather','LowFrequency','Multiscale','Protected'])
    p.add_argument('--seconds',type=int,default=8)
    p.add_argument('--square-tiles',action='store_true')
    p.add_argument('--static-reference',action='store_true')
    args=p.parse_args()
    if not 4<=args.seconds<=30:p.error('seconds must be 4..30')
    if any(m not in ['Feather','LowFrequency','Multiscale','Protected']for m in args.modes):p.error('unknown blend')
    out=ROOT/'build/verify'/time.strftime('depth-fusion-%Y%m%d-%H%M%S');out.mkdir(parents=True)
    video=out/'generated.h264'
    subprocess.run(['/usr/bin/ffmpeg','-v','error','-y',*(['-loop','1','-framerate','12','-i',str(ROOT/'tools/model_tester/eg_input_1.png'),'-vf','scale=1920:1080'] if args.static_reference else ['-f','lavfi','-i','testsrc2=size=1920x1080:rate=12']),'-t',str(args.seconds),'-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-x264-params','keyint=12:bframes=0','-pix_fmt','yuv420p',str(video)],check=True,timeout=45)
    summary={'scope':'Generated 1080p real-model replay; not headset quality or max throughput','runs':[]}
    for mode in args.modes:
        work=out/mode;config=work/'config/nightfall-meteor';config.mkdir(parents=True)
        with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
        (config/'meteor.toml').write_text(f'discovery_port={port}\nmodels_dir={json.dumps(str(Path.home()/".local/share/nightfall-meteor/models"))}\nncnn_lib={json.dumps(str(ROOT/"meteor/target/appimage/work/stage/libncnn.so.1"))}\ntensorrt=true\n')
        (config/'state.toml').write_text(f'enabled=true\ncpu_inference=false\nmodel={json.dumps(args.background)}\nrate=12\nedge_alignment=false\ncontour_cleanup=false\n[fusion]\nenabled=true\nsquare_tiles={str(args.square_tiles).lower()}\ndetail={json.dumps(args.detail)}\nblend={json.dumps(mode)}\n')
        env=dict(os.environ,XDG_CONFIG_HOME=str(work/'config'),XDG_DATA_HOME=str(work/'data'),XDG_STATE_HOME=str(work/'state'),RUST_LOG='nightfall_meteor=info')
        command=[str(ROOT/'meteor/target/release/nightfall-meteor'),'--replay',str(video),'--fps','12','--no-mic','--no-tray','--save-depth',str(work/'frames'),'--save-every','6']
        with (work/'replay.log').open('w')as log:
            result=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600 if args.square_tiles else 150)
        text=(work/'replay.log').read_text();snapshots=list((work/'frames').glob('*-depth.png'))
        sizes=[struct.unpack('>II',f.read_bytes()[16:24])for f in snapshots]
        cost=[float(v)for v in re.findall(r'blend/prep ([\d.]+) ms',text)]
        run={'mode':mode,'background':args.background,'detail':args.detail,'exit_code':result.returncode,'snapshots':len(sizes),'sizes':sorted(set(sizes)),'cuda_reported':('TensorRT; two 392x392 tiles'in text)if args.square_tiles else ('Depth fusion: CUDA;'in text),'square_tiles':args.square_tiles,'reported_blend_prep_ms':cost,'errors':re.findall(r'Depth inference failed: (.*)',text),'replay_summary':re.findall(r'Replay done: .*',text)}
        run['ok']=result.returncode==0 and bool(sizes)and all(s==(960,540)for s in sizes)and run['cuda_reported']and not run['errors']and bool(run['replay_summary'])
        summary['runs'].append(run);print(json.dumps(run),flush=True)
        (out/'summary.json').write_text(json.dumps(summary,indent=2))
    summary['ok']=all(r['ok']for r in summary['runs']);(out/'summary.json').write_text(json.dumps(summary,indent=2));print(out/'summary.json');raise SystemExit(0 if summary['ok']else 1)
if __name__=='__main__':main()
