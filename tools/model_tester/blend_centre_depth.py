#!/usr/bin/env python3
"""Offline 1080p EdgePad background / cropped VDA centre feasibility experiment."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from pipeline_report import infer
from run_models import robust_range

ROOT = Path(__file__).resolve().parents[2]

def resize(a, size):
    return np.asarray(Image.fromarray(a.astype(np.float32)).resize(size, Image.Resampling.BILINEAR))

def normalize(a):
    lo, hi = robust_range(a, .02, 512)
    return np.clip((a-lo)/max(hi-lo, 1e-6), 0, 1)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, default=ROOT/'tools/model_tester/eg_input_1.png')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vda', type=Path, default=Path.home()/'.local/share/nightfall-meteor/models/vda_s_518x294_cold.onnx')
    args = parser.parse_args()
    out = args.output; out.mkdir(parents=True, exist_ok=True)
    image = Image.open(args.image).convert('RGB').resize((1920,1080),Image.Resampling.LANCZOS)
    image.save(out/'original.png')
    edge_spec = dict(path=str(ROOT/'models/zipdepth-wide-512x288-edgepad-gpu.tflite'), input_layout='nhwc', output_layout='packed2x2')
    vda_spec = dict(path=str(args.vda.resolve()), input_layout='ntchw', output_layout='nchw', output_name='depth', preprocessing='imagenet')
    edge, edge_info = infer(edge_spec,np.asarray(image.resize((512,288),Image.Resampling.BILINEAR)),ROOT)
    # A central quarter of image area; VDA sees only this crop, not the full frame.
    box=(480,270,1440,810); crop=image.crop(box)
    vda, vda_info = infer(vda_spec,np.asarray(crop.resize((518,294),Image.Resampling.BILINEAR)),ROOT)
    full_vda, full_vda_info = infer(vda_spec,np.asarray(image.resize((518,294),Image.Resampling.BILINEAR)),ROOT)
    np.save(out/'vda_full_raw.npy', full_vda)
    full_depth = resize(normalize(full_vda), (1920,1080))
    np.save(out/'edgepad_raw.npy',edge); np.save(out/'vda_centre_raw.npy',vda)
    background=resize(normalize(edge),(1920,1080))
    centre=resize(normalize(vda),crop.size)
    target=background[270:810,480:1440]
    y,x=np.indices(centre.shape)
    distance=np.minimum.reduce([x,y,centre.shape[1]-1-x,centre.shape[0]-1-y]).astype(np.float32)
    # Fit in a ring surrounding the strongest VDA region. Robust trimming avoids
    # allowing a handful of disagreeing edges to dominate the affine depth match.
    ring=(distance>=24)&(distance<=120)
    a=centre[ring].astype(np.float64); b=target[ring].astype(np.float64)
    keep=np.ones(a.shape,dtype=bool)
    for _ in range(5):
        scale,offset=np.linalg.lstsq(np.column_stack([a[keep],np.ones(keep.sum())]),b[keep],rcond=None)[0]
        error=np.abs(a*scale+offset-b)
        keep=error<=np.quantile(error,.85)
    if scale<=0:
        raise ValueError('Non-positive fitted scale: depth conventions or scene predictions do not agree')
    aligned=centre*scale+offset
    t=np.clip(distance/96.,0,1); weight=t*t*(3-2*t)
    blended=background.copy(); blended[270:810,480:1440]=target*(1-weight)+aligned*weight
    vda_only=background.copy();vda_only[270:810,480:1440]=aligned
    mask=np.zeros_like(background);mask[270:810,480:1440]=weight
    def save_depth(name,array):
        Image.fromarray((np.clip(array,0,1)*255).round().astype(np.uint8)).save(out/name)
    for name,array in [('vda_full_1080p.png',full_depth),('edgepad_1080p.png',background),('vda_centre_matched.png',vda_only),('blend_1080p.png',blended),('blend_mask.png',mask)]:save_depth(name,array)
    np.save(out/'blend_float.npy',blended)
    crop.save(out/'vda_source_crop.png')
    panels=[('Original 1080p frame',image),('EdgePad-512 / full frame',Image.open(out/'edgepad_1080p.png')),('VDA / full frame (independent normalization)',Image.open(out/'vda_full_1080p.png')),('VDA centre / feathered blend',Image.open(out/'blend_1080p.png'))]
    sheet=Image.new('RGB',(1920,1152),'#171b24');draw=ImageDraw.Draw(sheet)
    for i,(label,panel) in enumerate(panels):
        px=(i%2)*960;py=(i//2)*576
        draw.text((px+12,py+10),label,fill='white')
        sheet.paste(panel.convert('RGB').resize((960,540),Image.Resampling.LANCZOS),(px,py+36))
    sheet.save(out/'comparison.png')
    report=dict(scope='Still image feasibility, CPU inference; not production pipeline parity, temporal VDA or headset performance. Bilinear input resize and depth upscale; no edge alignment, contour cleanup or stereo warp.',source=str(args.image.resolve()),size=[1920,1080],centre_box=list(box),feather_px=96,vda='518x294 cold-start on centre crop; slight input aspect rounding follows model shape',edgepad=edge_info,vda_inference=vda_info,vda_full_inference=full_vda_info,alignment=dict(scale=float(scale),offset=float(offset),ring_mae_before=float(np.mean(np.abs(a-b))),ring_mae_after=float(np.mean(np.abs(a*scale+offset-b))),clipped_centre_fraction=float(np.mean((aligned<0)|(aligned>1)))))
    (out/'report.json').write_text(json.dumps(report,indent=2))
    (out/'index.html').write_text('''<!doctype html><meta charset="utf-8"><title>EdgePad + VDA centre experiment</title><style>body{background:#171b24;color:#eee;font:16px system-ui;margin:24px}img{max-width:100%}button{padding:12px;margin:8px}p{max-width:1000px}</style><h1>1080p EdgePad background + VDA centre</h1><p>VDA processes a 960×540 centre crop. Relative depth is fitted to EdgePad in an overlap ring and blended across 96 pixels. Full-frame VDA uses the same 518×294 cold-start model on the entire image; its depth is normalized independently. Brightness is relative, not a shared metric distance. Static feasibility only: no motion, timing, production refinements or stereo warp. Each standalone depth image is genuinely 1920×1080.</p><button onclick="view.src='edgepad_1080p.png'">EdgePad</button><button onclick="view.src='vda_full_1080p.png'">Full-frame VDA</button><button onclick="view.src='blend_1080p.png'">Blended</button><button onclick="view.src='vda_centre_matched.png'">Hard boundary</button><button onclick="view.src='original.png'">Original</button><button onclick="view.requestFullscreen()">Fullscreen</button><br><img id="view" src="blend_1080p.png"><h2>Overview</h2><img src="comparison.png">''')
    print(json.dumps(report,indent=2),flush=True)

if __name__=='__main__':main()
