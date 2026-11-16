#!/usr/bin/env python3
"""Compare full-frame VDA with a cached same-frame VDA centre-crop blend."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from blend_centre_depth import normalize, resize

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path,help='Output directory from blend_centre_depth.py')
    args=parser.parse_args();out=args.directory
    background=resize(normalize(np.load(out/'vda_full_raw.npy')),(1920,1080))
    centre=resize(normalize(np.load(out/'vda_centre_raw.npy')),(960,540))
    target=background[270:810,480:1440]
    y,x=np.indices(centre.shape)
    distance=np.minimum.reduce([x,y,959-x,539-y]).astype(np.float32)
    ring=(distance>=24)&(distance<=120)
    a=centre[ring].astype(float);b=target[ring].astype(float);keep=np.ones(a.shape,bool)
    for _ in range(5):
        scale,offset=np.linalg.lstsq(np.column_stack([a[keep],np.ones(keep.sum())]),b[keep],rcond=None)[0]
        error=np.abs(a*scale+offset-b);keep=error<=np.quantile(error,.85)
    if scale<=0:raise ValueError('Nonpositive depth alignment scale')
    aligned=centre*scale+offset
    t=np.clip(distance/96,0,1);weight=t*t*(3-2*t)
    blended=background.copy();blended[270:810,480:1440]=target*(1-weight)+aligned*weight
    np.save(out/'vda_vda_blend_float.npy',blended)
    Image.fromarray((np.clip(blended,0,1)*255).round().astype('uint8')).save(out/'vda_vda_blend_1080p.png')
    panels=[('Original frame','original.png'),('Full-frame VDA','vda_full_1080p.png'),('EdgePad-512 background + VDA centre','blend_1080p.png'),('VDA background + VDA centre (same 96px feather)','vda_vda_blend_1080p.png')]
    sheet=Image.new('RGB',(1920,1152),'#171b24');draw=ImageDraw.Draw(sheet)
    for i,(label,file) in enumerate(panels):
        px=i%2*960;py=i//2*576;draw.text((px+12,py+10),label,fill='white')
        sheet.paste(Image.open(out/file).convert('RGB').resize((960,540),Image.Resampling.LANCZOS),(px,py+36))
    sheet.save(out/'vda_vda_comparison.png')
    # Native-size crops make the increased sampling density easier to inspect.
    detail_box=(740,390,1220,750)
    details=Image.new('RGB',(1440,396),'#171b24');draw=ImageDraw.Draw(details)
    for i,(label,file) in enumerate([panels[1],panels[2],panels[3]]):
        draw.text((i*480+8,10),label,fill='white')
        details.paste(Image.open(out/file).convert('RGB').crop(detail_box),(i*480,36))
    details.save(out/'vda_vda_detail.png')
    report=dict(scope='Static cached inference; same VDA Small 518x294 cold-start model on full frame and 960x540 centre crop. No temporal history or performance measurement. Same normalization, robust affine ring fit and 96px feather as EdgePad/VDA comparison.',centre_box=[480,270,1440,810],scale=float(scale),offset=float(offset),ring_mae_before=float(np.mean(abs(a-b))),ring_mae_after=float(np.mean(abs(a*scale+offset-b))),clipped_fraction=float(np.mean((aligned<0)|(aligned>1))))
    (out/'vda_vda_report.json').write_text(json.dumps(report,indent=2))
    page=out/'index.html';s=page.read_text()
    button='<button onclick="view.src=\'vda_vda_blend_1080p.png\'">VDA + VDA centre</button>'
    if button not in s:s=s.replace('<button onclick="view.src=\'original.png\'">Original</button>',button+'<button onclick="view.src=\'original.png\'">Original</button>')
    s=s.replace('<h2>Overview</h2><img src="reverse_comparison.png">','<h2>VDA centre comparison</h2><img src="vda_vda_comparison.png"><h2>Native-size central details</h2><img src="vda_vda_detail.png"><h2>Previous arrangements</h2><img src="reverse_comparison.png">')
    page.write_text(s)
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
