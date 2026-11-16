#!/usr/bin/python3
"""Compare existing single-model pipelines with host VDA/VDA fusion, isolated."""
import argparse,json,os,re,socket,statistics,subprocess,time,threading,csv
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
NUMBER=r'([\d.]+)'

def gpu_sample():
    result=subprocess.run(['nvidia-smi','--id=0','--query-gpu=name,utilization.gpu,memory.used,power.draw','--format=csv,noheader,nounits'],capture_output=True,text=True,check=True,timeout=5)
    name,busy,memory,power=next(csv.reader(result.stdout.splitlines()))
    return {'gpu':name.strip(),'busy_pct':float(busy),'memory_mib':float(memory),'power_w':float(power)}

class GpuMonitor:
    def __init__(self):self.stop=threading.Event();self.samples=[];self.errors=[];self.started=time.monotonic();self.thread=threading.Thread(target=self.run,daemon=True)
    def run(self):
        while not self.stop.is_set():
            try:self.samples.append(dict(elapsed_s=time.monotonic()-self.started,**gpu_sample()))
            except Exception as e:self.errors.append(str(e))
            self.stop.wait(.5)
    def start(self):self.thread.start()
    def finish(self):self.stop.set();self.thread.join(timeout=7)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--only',nargs='+',choices=['edgepad','vda','fusion','mixed'],help='Restrict benchmarks to selected pipelines')
    p.add_argument('--include-mixed',action='store_true',help='Also measure the existing nonresident EdgePad + VDA path')
    p.add_argument('--gpu-metrics',action='store_true',help='Sample GPU 0 board-wide busy time, memory and power; excludes initial 3 seconds')
    p.add_argument('--static-reference',action='store_true',help='Use the desktop comparison image as a constant video input')
    p.add_argument('--fps',type=int,default=72)
    p.add_argument('--seconds',type=int,default=12)
    p.add_argument('--repeats',type=int,default=2)
    args=p.parse_args()
    if not 1<=args.fps<=120 or not 4<=args.seconds<=30 or not 1<=args.repeats<=4:p.error('bounded limits: fps 1..120, seconds 4..30, repeats 1..4')
    out=ROOT/'build/verify'/time.strftime('depth-fusion-latency-%Y%m%d-%H%M%S');out.mkdir(parents=True)
    video=out/'generated.h264'
    source=['-loop','1','-framerate',str(args.fps),'-i',str(ROOT/'tools/model_tester/eg_input_1.png'),'-vf','scale=1920:1080'] if args.static_reference else ['-f','lavfi','-i',f'testsrc2=size=1920x1080:rate={args.fps}']
    subprocess.run(['/usr/bin/ffmpeg','-v','error','-y',*source,'-t',str(args.seconds),'-c:v','libx264','-preset','ultrafast','-tune','zerolatency','-x264-params',f'keyint={args.fps}:bframes=0','-pix_fmt','yuv420p',str(video)],check=True,timeout=90)
    configurations=[('EdgePad-512','zipdepth_wide_512x288.ncnn.param',False),('VDA','vda_s_518x294',False),('VDA over VDA','vda_s_518x294',True)]
    if args.include_mixed or (args.only and 'mixed'in args.only):configurations.append(('VDA over EdgePad-512','zipdepth_wide_512x288.ncnn.param',True))
    if args.only:
        selected={'edgepad':'EdgePad-512','vda':'VDA','fusion':'VDA over VDA','mixed':'VDA over EdgePad-512'}
        configurations=[c for c in configurations if c[0]in {selected[k]for k in args.only}]
    idle=[gpu_sample()for _ in range(3)] if args.gpu_metrics else []
    report={'idle_gpu_samples':idle,'gpu_metric_scope':'Board-wide counters, not FLOPs or application-exclusive utilization. Extra VRAM is relative to pre-test board memory; other processes can affect readings.','input':'static desktop reference' if args.static_reference else 'moving generated testsrc2','scope':'Host compressed-frame submission to final depth map; excludes capture/encoding before Meteor, network, Quest and display latency. Real-model generated replay, normal single-model decode targets; fusion requests 1080p. Refinement/contour enabled for all. No snapshot PNG writes during timing. First second excluded by existing replay instrumentation; cached model loading excluded from steady-state table. Not direct kernel timing.','fps':args.fps,'seconds':args.seconds,'repeats':args.repeats,'runs':[]}
    for repeat in range(args.repeats):
        for label,model,fusion in configurations[repeat:]+configurations[:repeat]:
            work=out/f'{repeat}-{label.replace(" ","-")}';config=work/'config/nightfall-meteor';config.mkdir(parents=True)
            with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
            (config/'meteor.toml').write_text(f'discovery_port={port}\nmodels_dir={json.dumps(str(Path.home()/".local/share/nightfall-meteor/models"))}\nncnn_lib={json.dumps(str(ROOT/"meteor/target/appimage/work/stage/libncnn.so.1"))}\ntensorrt=true\n')
            (config/'state.toml').write_text(f'enabled=true\ncpu_inference=false\nmodel={json.dumps(model)}\nrate={args.fps}\nedge_alignment=true\ncontour_cleanup=true\n[fusion]\nenabled={str(fusion).lower()}\ndetail="vda_s_518x294"\nblend="Protected"\n')
            env=dict(os.environ,XDG_CONFIG_HOME=str(work/'config'),XDG_DATA_HOME=str(work/'data'),XDG_STATE_HOME=str(work/'state'),RUST_LOG='nightfall_meteor=info')
            with (work/'replay.log').open('w')as log:
                monitor=GpuMonitor() if args.gpu_metrics else None
                if monitor:monitor.start()
                try:result=subprocess.run([str(ROOT/'meteor/target/release/nightfall-meteor'),'--replay',str(video),'--fps',str(args.fps),'--no-mic','--no-tray'],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=150)
                finally:
                    if monitor:monitor.finish()
            text=(work/'replay.log').read_text()
            done=re.search(r'Replay done: (\d+) frames in, (\d+) maps out, (\d+) skipped;.*?median '+NUMBER+r' ms, p95 '+NUMBER+r' ms, max '+NUMBER+r' ms',text)
            stages=re.search(r'Stage medians: decode '+NUMBER+r' ms, handoff '+NUMBER+r' ms, model '+NUMBER+r' ms, post-processing '+NUMBER+r' ms',text)
            steady=re.search(r'Replay steady-state: (\d+) maps over ([\d.]+) s = ([\d.]+) maps/s',text)
            errors=re.findall(r'Depth inference failed: (.*)',text)
            run={'label':label,'repeat':repeat+1,'model':model,'fusion':fusion,'exit_code':result.returncode,'errors':errors,'cuda_fusion':bool(re.search(r'Depth fusion: CUDA;',text)),'resident_fusion':'resident VDA + VDA'in text,'decoder':re.findall(r'Host depth decoding .*',text),'actual_model':re.findall(r'Replay using .*',text)}
            run['ok']=result.returncode==0 and bool(done)and bool(stages)and not errors and (not fusion or (run['cuda_fusion']and (model!='vda_s_518x294' or run['resident_fusion'])))
            if done:
                run.update(zip(['frames','maps','skipped'],map(int,done.groups()[:3])))
                run.update(zip(['median_ms','p95_ms','max_ms'],map(float,done.groups()[3:])))
                run['delivered_maps_per_s']=run['maps']/args.seconds
            if steady:run['steady_maps_per_s']=float(steady[3])
            if stages:run['stages_ms']=dict(zip(['decode','handoff','model_including_fusion','post'],map(float,stages.groups())))
            run['fusion_blend_prep_ms']=[float(v)for v in re.findall(r'blend/prep ([\d.]+) ms',text)]
            if monitor:
                samples=[x for x in monitor.samples if x['elapsed_s']>=3]
                run['gpu_samples']=monitor.samples;run['gpu_sample_errors']=monitor.errors
                if samples:
                    run['gpu_metrics']={key:statistics.mean(x[key]for x in samples)for key in ['busy_pct','memory_mib','power_w']}
                    run['gpu_metrics']['extra_memory_mib']=run['gpu_metrics']['memory_mib']-statistics.median(x['memory_mib']for x in idle)
                    run['gpu_metrics']['peak_extra_memory_mib']=max(x['memory_mib']for x in samples)-statistics.median(x['memory_mib']for x in idle)
            report['runs'].append(run);(out/'summary.json').write_text(json.dumps(report,indent=2));print(json.dumps(run),flush=True)
    report['ok']=all(r['ok']for r in report['runs'])
    report['aggregate']={}
    for label,_,_ in configurations:
        runs=[r for r in report['runs']if r['label']==label and r['ok']]
        if runs:
            report['aggregate'][label]={key:statistics.median(r[key]for r in runs)for key in ['median_ms','p95_ms','delivered_maps_per_s']}
            if all('steady_maps_per_s'in r for r in runs):report['aggregate'][label]['steady_maps_per_s']=statistics.median(r['steady_maps_per_s']for r in runs)
    for label,_,_ in configurations:
        runs=[r for r in report['runs']if r['label']==label and r['ok']and r.get('gpu_metrics')]
        if runs:
            report['aggregate'][label]['gpu_metrics']={key:statistics.mean(r['gpu_metrics'][key]for r in runs)for key in ['busy_pct','extra_memory_mib','peak_extra_memory_mib','power_w']}
    (out/'summary.json').write_text(json.dumps(report,indent=2));print(out/'summary.json');raise SystemExit(0 if report['ok']else 1)
if __name__=='__main__':main()
