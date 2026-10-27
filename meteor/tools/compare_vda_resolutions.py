#!/usr/bin/env python3
"""Compare actual self-fed GPU depth across two input resolutions.

This compares raw depth before Nightfall refinement/warping, not stereo output
or ground-truth accuracy. Both runs must represent the same video/timestamps.
"""
import argparse
import csv
import json
from pathlib import Path
import subprocess
import cv2
import numpy as np


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for key in ['baseline-sequence','baseline-run','candidate-sequence','candidate-run','output']:
        parser.add_argument('--'+key,type=Path,required=True)
    args=parser.parse_args()
    high=json.loads((args.baseline_sequence/'sequence.json').read_text())
    low=json.loads((args.candidate_sequence/'sequence.json').read_text())
    for key in ['source','start_seconds','fps']:
        if high[key]!=low[key]:raise ValueError('Different source or sampling')
    expected=[(f['index'],f['timestamp'],f['reset']) for f in high['frames']]
    if expected!=[(f['index'],f['timestamp'],f['reset']) for f in low['frames']]:
        raise ValueError('Frames, timestamps or resets differ')
    if (args.baseline_run/'history.tsv').read_bytes()!=(args.candidate_run/'history.tsv').read_bytes():
        raise ValueError('Different history selection')
    def read(directory,metadata):
        w,h=metadata['size'];maps=[]
        for frame in metadata['frames']:
            value=np.fromfile(directory/f"frame_{frame['index']:04d}.depth.f32",'<f4').reshape(h,w)
            if not np.isfinite(value).all():raise ValueError('Nonfinite depth')
            maps.append(value)
        return maps
    before=read(args.baseline_run,high);after=read(args.candidate_run,low)
    minimum,maximum=np.quantile(np.stack(before)[:,::4,::4],[.02,.98])
    width,height=high['size'];args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'frames').mkdir(exist_ok=True)
    def color(value):
        # Same raw-depth range for both models and every frame; no hidden fitting.
        value=cv2.resize(value,(width,height),interpolation=cv2.INTER_LINEAR)
        value=np.clip((value-minimum)/max(maximum-minimum,1e-6)*255,0,255).astype(np.uint8)
        return cv2.applyColorMap(value,cv2.COLORMAP_TURBO)
    labels=['Model input',f"VDA {high['size'][0]}x{high['size'][1]}",f"VDA {low['size'][0]}x{low['size'][1]}"]
    encoder=subprocess.Popen(['ffmpeg','-v','error','-y','-f','rawvideo','-pix_fmt','bgr24',
        '-s',f'{width*3}x{height+32}','-r',str(high['fps']),'-i','pipe:0','-an',
        '-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p',str(args.output/'comparison.mp4')],stdin=subprocess.PIPE)
    try:
        for i,(index,_,_) in enumerate(expected):
            rgb=cv2.imread(str(args.baseline_sequence/f'frame_{index:04d}.jpg'))
            if rgb is None:raise ValueError('Missing input preview')
            canvas=np.zeros((height+32,width*3,3),np.uint8)
            for col,image in enumerate([rgb,color(before[i]),color(after[i])]):
                canvas[32:,col*width:(col+1)*width]=image
                cv2.putText(canvas,labels[col],(col*width+8,23),cv2.FONT_HERSHEY_SIMPLEX,.6,(230,230,230),1,cv2.LINE_AA)
            cv2.imwrite(str(args.output/'frames'/f'frame_{i:04d}.jpg'),canvas)
            encoder.stdin.write(canvas.tobytes())
        encoder.stdin.close()
        if encoder.wait():raise RuntimeError('Video encoding failed')
    finally:
        if encoder.poll() is None:encoder.terminate();encoder.wait()
    metadata={'baseline_size':high['size'],'candidate_size':low['size'],'frames':len(expected),
        'shared_raw_depth_range':[float(minimum),float(maximum)],'resampling':'linear for display only',
        'scope':'raw self-fed GPU depth; no final refinement/warping',
        'baseline_run':str(args.baseline_run),'candidate_run':str(args.candidate_run)}
    def timing(directory,sequence):
        rows=list(csv.DictReader((directory/'timings.csv').open()));selected=[];age=0
        for frame in sequence['frames']:
            age=0 if frame['reset']!='none' else age+1
            if age>5:selected.append(rows[frame['index']])
        if not selected:raise ValueError('No warmed recurrent timing samples')
        graph=[float(row['graph_ms']) for row in selected]
        core=[sum(float(row[key]) for key in ['prepare_ms','graph_ms','store_ms']) for row in selected]
        return {'graph_median_ms':float(np.median(graph)),'graph_p95_ms':float(np.percentile(graph,95)),
            'core_median_ms':float(np.median(core)),'samples':len(graph)}
    metadata['baseline_timing']=timing(args.baseline_run,high)
    metadata['candidate_timing']=timing(args.candidate_run,low)
    (args.output/'comparison.json').write_text(json.dumps(metadata,indent=2)+'\n')
    document='''<!doctype html><meta charset="utf-8"><title>RX480 VDA resolution comparison</title>
<style>body{background:#16191d;color:#ddd;font:16px system-ui;margin:24px}img,video{max-width:100%}button,input{margin:8px}#viewer:fullscreen{display:grid;align-content:center;background:#111}a{color:#8bf}</style>
<h1>VDA: full resolution versus RX480 performance candidate</h1>
<table><tr><th>Input size</th><th>Model median</th><th>Model p95</th><th>Core median</th></tr>TIMINGS</table>
<p>Core includes input/history preparation and storage. These are standalone inference timings, not live stream latency.</p>
<p>Raw self-fed GPU depth, before Nightfall refinement or warping. Both maps use one fixed colour scale. The smaller map is resized linearly for display; no scale/offset fitting is applied.</p>
<p><a href="validation/index.html">Low-resolution GPU vs CPU validation and timings</a> · <a href="comparison.json">Comparison metadata</a></p>
<div id="viewer"><img id="frame" src="frames/frame_0000.jpg"></div>
<button id="play">Play/pause</button><button id="full">Fullscreen</button><input id="seek" type="range" min="0" max="COUNT" value="0"><span id="number">0</span>
<p><a href="comparison.mp4">Comparison video</a></p><video controls src="comparison.mp4"></video>
<script>const seek=document.querySelector('#seek'),img=document.querySelector('#frame');function show(){img.src='frames/frame_'+String(seek.value).padStart(4,'0')+'.jpg';document.querySelector('#number').textContent=seek.value}seek.oninput=show;let timer;document.querySelector('#play').onclick=()=>{if(timer){clearInterval(timer);timer=null}else timer=setInterval(()=>{seek.value=(Number(seek.value)+1)%(Number(seek.max)+1);show()},INTERVAL)};document.querySelector('#full').onclick=()=>document.querySelector('#viewer').requestFullscreen();</script>'''
    table=''.join(f"<tr><td>{size[0]}×{size[1]}</td><td>{values['graph_median_ms']:.2f} ms</td><td>{values['graph_p95_ms']:.2f} ms</td><td>{values['core_median_ms']:.2f} ms</td></tr>"
        for size,values in [(high['size'],metadata['baseline_timing']),(low['size'],metadata['candidate_timing'])])
    (args.output/'index.html').write_text(document.replace('TIMINGS',table).replace('COUNT',str(len(expected)-1)).replace('INTERVAL',str(round(1000/high['fps']))))
    print(json.dumps(metadata),flush=True)


if __name__=='__main__':main()
