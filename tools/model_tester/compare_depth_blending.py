#!/usr/bin/env python3
"""Cached still-image comparison of centre-depth fusion methods; no app changes."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import gaussian_filter
from blend_centre_depth import normalize, resize


def pyramid_blend(base, overlay, weight, levels=6):
    """Gaussian mask pyramid / Laplacian depth pyramids, reconstructed at 1080p."""
    bases=[base];overlays=[overlay];weights=[weight]
    for _ in range(levels-1):
        bases.append(gaussian_filter(bases[-1],1)[::2,::2])
        overlays.append(gaussian_filter(overlays[-1],1)[::2,::2])
        weights.append(gaussian_filter(weights[-1],1.5)[::2,::2])
    result=bases[-1]*(1-weights[-1])+overlays[-1]*weights[-1]
    for i in range(levels-2,-1,-1):
        size=(bases[i].shape[1],bases[i].shape[0])
        lb=bases[i]-resize(bases[i+1],size)
        lo=overlays[i]-resize(overlays[i+1],size)
        result=resize(result,size)+lb*(1-weights[i])+lo*weights[i]
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path,help='Output of blend_centre_depth.py')
    args=parser.parse_args();src=args.directory;out=src/'blending-methods';out.mkdir(exist_ok=True)
    base=resize(normalize(np.load(src/'edgepad_raw.npy')),(1920,1080))
    centre=resize(normalize(np.load(src/'vda_centre_raw.npy')),(960,540))
    params=json.loads((src/'report.json').read_text())
    aligned=centre*params['alignment']['scale']+params['alignment']['offset']
    target=base[270:810,480:1440]
    y,x=np.indices(centre.shape);distance=np.minimum.reduce([x,y,959-x,539-y]).astype(np.float32)
    t=np.clip(distance/96,0,1);alpha=t*t*(3-2*t)
    weight=np.zeros_like(base);weight[270:810,480:1440]=alpha
    overlay=base.copy();overlay[270:810,480:1440]=aligned
    simple=base*(1-weight)+overlay*weight
    # Remove only the broad disagreement field. Smaller-scale VDA structure
    # remains, but this deliberately sacrifices some of VDA's broad geometry.
    correction=gaussian_filter(aligned-target,32,mode='reflect')
    corrected=aligned-correction
    corrected_overlay=base.copy();corrected_overlay[270:810,480:1440]=corrected
    low=base*(1-weight)+corrected_overlay*weight
    multi=pyramid_blend(base,overlay,weight)
    # Reject mutually inconsistent fine structure after broad shape correction.
    # Both gradients and residual disagreement are measured in normalized depth.
    delta=gaussian_filter(np.abs(corrected-target),3)
    gy,gx=np.gradient(gaussian_filter(target,1.5));vy,vx=np.gradient(gaussian_filter(corrected,1.5))
    gradient_delta=gaussian_filter(np.hypot(vx-gx,vy-gy),2)
    confidence=np.exp(-.5*(delta/.10)**2-.5*(gradient_delta/.025)**2)
    confidence=gaussian_filter(confidence,4)
    protected_weight=weight.copy();protected_weight[270:810,480:1440]*=confidence
    combined=pyramid_blend(base,corrected_overlay,protected_weight)
    arrays={'edgepad':base,'original-blend':simple,'low-frequency':low,'multiscale':multi,'combined-protected':combined,
            'full-vda':resize(normalize(np.load(src/'vda_full_raw.npy')),(1920,1080))}
    labels={'edgepad':'EdgePad-512 baseline','original-blend':'Original affine + feather','low-frequency':'Low-frequency correction','multiscale':'Multiscale blend','combined-protected':'Low-frequency + multiscale + protection','full-vda':'Full-frame VDA reference'}
    for name,array in arrays.items():
        np.save(out/(name+'.npy'),array)
        Image.fromarray((np.clip(array,0,1)*255).round().astype('uint8')).save(out/(name+'.png'))
    Image.fromarray((confidence*255).round().astype('uint8')).save(out/'confidence.png')
    try: font=ImageFont.truetype('/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf',18)
    except OSError:font=ImageFont.load_default()
    order=list(arrays)
    sheet=Image.new('RGB',(1920,1728),'#171b24');draw=ImageDraw.Draw(sheet)
    for i,name in enumerate(order):
        px=i%2*960;py=i//2*576
        draw.text((px+12,py+9),labels[name],fill='white',font=font)
        sheet.paste(Image.open(out/(name+'.png')).convert('RGB').resize((960,540),Image.Resampling.LANCZOS),(px,py+36))
    sheet.save(out/'comparison.png')
    # Same crop at native pixel resolution, including top and left join plus
    # central object detail. No enlarged/smoothed thumbnails in this sheet.
    cropbox=(440,230,1280,830)
    details=Image.new('RGB',(1680,1908),'#171b24');draw=ImageDraw.Draw(details)
    for i,name in enumerate(order):
        px=i%2*840;py=i//2*636;draw.text((px+10,py+9),labels[name],fill='white',font=font)
        details.paste(Image.open(out/(name+'.png')).convert('RGB').crop(cropbox),(px,py+36))
    details.save(out/'details.png')
    buttons=''.join(f'<button onclick="view.src=\'{name}.png\'">{labels[name]}</button>' for name in order)
    html='''<!doctype html><meta charset="utf-8"><title>Depth blending methods</title><style>body{background:#171b24;color:#eee;font:16px system-ui;margin:24px}img{max-width:100%}button{padding:10px;margin:5px}p{max-width:1100px}</style><h1>VDA centre over EdgePad-512</h1><p>Same cached inference for every variant. VDA sees a 960×540 centre crop; EdgePad sees the full frame. Full-size outputs: 1920×1080. White is nearer. Relative-depth visual experiment only: no temporal history, stereo warp, production-pipeline parity, ground-truth accuracy or Quest timing measurements.</p><p>Low-frequency correction removes broad disagreement at sigma 32 px. Multiscale uses six Gaussian/Laplacian pyramid levels. Combined adds both and suppresses VDA where corrected depths or gradients disagree; this can also suppress useful VDA detail.</p>'''+buttons+'''<button onclick="view.requestFullscreen()">Fullscreen</button><img id="view" src="combined-protected.png"><h2>Overview</h2><img src="comparison.png"><h2>Native-pixel details, same region</h2><img src="details.png">'''
    (out/'index.html').write_text(html)
    report={'scope':'Cached still-image fusion feasibility only; not measured on Quest; no ground truth or temporal tests','source_report':str((src/'report.json').resolve()),'size':[1920,1080],'centre_box':[480,270,1440,810],'feather_px':96,'low_frequency_sigma_px':32,'pyramid_levels':6,'confidence_depth_sigma':.10,'confidence_gradient_sigma':.025,'mean_confidence_in_full_weight_region':float(confidence[alpha>.999].mean()),'variants':{}}
    for name,array in arrays.items():
        report['variants'][name]={'finite':bool(np.isfinite(array).all()),'clipped_fraction':float(np.mean((array<0)|(array>1))),'range':[float(array.min()),float(array.max())]}
        assert np.isfinite(array).all() and array.shape==(1080,1920)
    (out/'report.json').write_text(json.dumps(report,indent=2))
    parent=src/'index.html';s=parent.read_text();link='<p><a href="blending-methods/index.html">Compare low-frequency, multiscale and protected blending</a></p>'
    if link not in s:parent.write_text(s+link)
    print(out/'index.html')

if __name__=='__main__':main()
