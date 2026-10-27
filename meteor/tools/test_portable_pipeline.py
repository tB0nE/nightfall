#!/usr/bin/env python3
"""Replay a local fixture through Meteor using isolated settings, never user state.

Build first with cargo build --release --no-default-features.
Use --forbid-cuda on Linux to verify the complete EdgePad path loads no CUDA.
"""
import argparse,json,os,re,socket,subprocess,tempfile,time
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('video',type=Path)
    parser.add_argument('--binary',type=Path,default=ROOT/'meteor/target/release/nightfall-meteor')
    parser.add_argument('--models',type=Path,required=True)
    parser.add_argument('--ncnn',type=Path,required=True)
    parser.add_argument('--model',default='zipdepth_wide_512x288.ncnn.param')
    parser.add_argument('--backend',choices=['auto','nvdec','vaapi','software'],default='auto')
    parser.add_argument('--gpu');parser.add_argument('--device');parser.add_argument('--icd')
    parser.add_argument('--forbid-cuda',action='store_true')
    parser.add_argument('--cpu-processing',action='store_true')
    parser.add_argument('--cpu-inference',action='store_true')
    parser.add_argument('--cpu-post',action='store_true')
    parser.add_argument('--cpu-frames',action='store_true')
    parser.add_argument('--rate',type=int,default=20)
    parser.add_argument('--tensorrt-dir',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args();args.output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='meteor-pipeline-') as temporary:
        work=Path(temporary);config=work/'config/nightfall-meteor';config.mkdir(parents=True)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1',0));depth_port=probe.getsockname()[1]
        configuration='discovery_port = '+str(depth_port-1)+'\nmodels_dir = '+json.dumps(str(args.models.resolve()))+'\nncnn_lib = '+json.dumps(str(args.ncnn.resolve()))+'\ntensorrt = '+str(args.tensorrt_dir is not None).lower()+'\n'
        if args.tensorrt_dir:configuration+='tensorrt_dir = '+json.dumps(str(args.tensorrt_dir.resolve()))+'\n'
        (config/'meteor.toml').write_text(configuration)
        state='enabled = true\nmodel = '+json.dumps(args.model)+'\nrate = '+str(args.rate)+'\ncpu_inference = '+str(args.cpu_inference).lower()+'\nedge_alignment = true\ncontour_cleanup = true\n'
        if args.gpu:state+='edgepad_gpu = '+json.dumps(args.gpu)+'\n'
        state+='[decode]\nbackend = '+json.dumps(args.backend)+'\ncpu_processing = '+str(args.cpu_processing).lower()+'\n'
        if args.device:state+='vaapi_device = '+json.dumps(args.device)+'\n'
        (config/'state.toml').write_text(state)
        env=dict(os.environ,XDG_CONFIG_HOME=str(work/'config'),XDG_DATA_HOME=str(work/'data'),XDG_STATE_HOME=str(work/'state'),RUST_LOG='nightfall_meteor=info')
        if args.icd:env.update(VK_DRIVER_FILES=args.icd,VK_ICD_FILENAMES=args.icd)
        with args.output.open('w') as log:
            command=[str(args.binary.resolve()),'--replay',str(args.video.resolve()),'--fps','60','--no-mic']
            if args.cpu_post:command.append('--cpu-post')
            if args.cpu_frames:command.append('--cpu-frames')
            process=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT)
            cuda=False;deadline=time.monotonic()+120
            try:
                while process.poll() is None:
                    try:cuda=cuda or '/libcuda.so' in Path(f'/proc/{process.pid}/maps').read_text()
                    except FileNotFoundError:pass
                    if time.monotonic()>deadline:raise TimeoutError('Replay exceeded 120 seconds')
                    time.sleep(.1)
            finally:
                if process.poll() is None:process.kill()
                process.wait()
        text=args.output.read_text()
        for line in text.splitlines():
            if any(s in line for s in ['Replay using','Host depth decoding','Replay done','Stage medians']):print(line)
        print('CUDA loaded:',cuda,'Log:',args.output)
        if process.returncode!=0:raise RuntimeError(f'Replay failed: see {args.output}')
        if args.forbid_cuda and cuda:raise RuntimeError('Compatibility pipeline loaded CUDA')
        match=re.search(r'Replay done: \d+ frames in, (\d+) maps out',text)
        if not match or int(match[1])<6:raise RuntimeError('Insufficient depth output')

if __name__=='__main__':main()
