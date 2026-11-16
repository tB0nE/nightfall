#!/usr/bin/env python3
"""Still comparison: four overlapping widescreen VDA crops, without a base pass."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from blend_centre_depth import infer, normalize, resize
from compare_vda_tiles import fit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--vda', type=Path, default=Path.home()/'.local/share/nightfall-meteor/models/vda_s_518x294_cold.onnx')
    args = parser.parse_args()
    out = args.source/'four-tiles'
    out.mkdir(exist_ok=True)
    original = Image.open(args.source/'original.png').convert('RGB')
    assert original.size == (1920, 1080)
    boxes = [(0,0,1152,648), (768,0,1920,648), (0,432,1152,1080), (768,432,1920,1080)]
    spec = dict(path=str(args.vda.resolve()), input_layout='ntchw', output_layout='nchw', output_name='depth', preprocessing='imagenet')
    total = np.zeros((1080,1920), np.float32)
    weights = np.zeros_like(total)
    records = []
    for i, (x0,y0,x1,y1) in enumerate(boxes):
        inp = original.crop(boxes[i]).resize((518,294), Image.Resampling.BILINEAR)
        inp.save(out/f'tile-{i}-input.png')
        raw_path = out/f'tile-{i}-raw.npy'
        if raw_path.exists():
            raw = np.load(raw_path)
            info = {'cached': True}
        else:
            raw, info = infer(spec, np.asarray(inp), out)
            np.save(raw_path, raw)
        depth = resize(normalize(raw), (1152,648))
        old = weights[y0:y1,x0:x1]
        overlap = old > .05
        scale, offset, error = 1., 0., 0.
        if i:
            target = total[y0:y1,x0:x1]/np.maximum(old,1e-8)
            sample = overlap.copy()
            sample[1::2,:] = False
            sample[:,1::2] = False
            scale, offset, error = fit(depth[sample], target[sample])
        depth = depth*scale+offset
        # Complementary smoothstep ramps; outer frame boundaries retain weight 1.
        wx = np.ones(1152, np.float32)
        wy = np.ones(648, np.float32)
        for w,n,pos in [(wx,384,x0),(wy,216,y0)]:
            t = np.linspace(0,1,n,dtype=np.float32)
            ramp = t*t*(3-2*t)
            if pos == 0: w[-n:] = 1-ramp
            else: w[:n] = ramp
        weight = wy[:,None]*wx[None,:]
        total[y0:y1,x0:x1] += depth*weight
        old += weight
        records.append(dict(box=list(boxes[i]),scale=scale,offset=offset,overlap_mae=error,inference=info))
        print(f'Tile {i+1}/4 complete',flush=True)
    assert np.all(weights > 0)
    stitched = total/weights
    assert np.isfinite(stitched).all()
    np.save(out/'four-tiles-float.npy', stitched)
    Image.fromarray((normalize(stitched)*255).round().astype('uint8')).save(out/'four-tiles.png')
    panels = [('Full-frame VDA / one pass',args.source/'side-by-side/full-vda.png'),
              ('Two square 392x392 tiles / two passes',args.source/'side-by-side/tiles-square-392.png'),
              ('Two stretched 518x294 tiles / two passes',args.source/'side-by-side/tiles-stretched.png'),
              ('Four 518x294 tiles / four passes',out/'four-tiles.png')]
    try:
        font = ImageFont.truetype('/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf',18)
    except OSError:
        font = ImageFont.load_default(size=18)
    sheet = Image.new('RGB',(1920,1152),'#171b24')
    details = Image.new('RGB',(1440,1512),'#171b24')
    buttons = ''
    for i,(label,path) in enumerate(panels):
        name = f'view-{i}.png'
        image = Image.open(path).convert('RGB')
        image.save(out/name)
        x,y = i%2*960,i//2*576
        ImageDraw.Draw(sheet).text((x+12,y+9),label,font=font,fill='white')
        sheet.paste(image.resize((960,540),Image.Resampling.LANCZOS),(x,y+36))
        x,y = i%2*720,i//2*756
        ImageDraw.Draw(details).text((x+10,y+9),label,font=font,fill='white')
        details.paste(image.crop((600,180,1320,900)),(x,y+36))
        buttons += f'<button onclick="view.src=\'{name}\'">{label}</button>'
    sheet.save(out/'comparison.png')
    details.save(out/'details.png')
    original.save(out/'original.png')
    scope = 'Static cold-start CPU inference; no temporal history, timing, production refinement or stereo warp. Four 1152x648 crops overlap by 384 horizontally and 216 vertically. Each runs at 518x294 (minor aspect rounding). Sequential robust positive affine alignment to accumulated overlap, separable smoothstep feather. No extra global model pass. Independent display normalization; brightness is not metric distance. Sequential alignment may accumulate drift and is not temporally validated.'
    (out/'report.json').write_text(json.dumps(dict(scope=scope,tiles=records,input_pixels=4*518*294,output=[1920,1080]),indent=2))
    (out/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Four VDA tiles</title><style>body{background:#171b24;color:#eee;font:16px system-ui;margin:24px}img{max-width:100%}button{padding:10px;margin:5px}</style><h1>Four overlapping VDA tiles</h1><p>'+scope+'</p>'+buttons+'<button onclick="view.src=\'original.png\'">Original</button><button onclick="view.requestFullscreen()">Fullscreen</button><br><img id="view" src="four-tiles.png"><h2>Overview</h2><img src="comparison.png"><h2>Native-pixel details</h2><img src="details.png">')
    print(out/'index.html',flush=True)


if __name__ == '__main__':
    main()
