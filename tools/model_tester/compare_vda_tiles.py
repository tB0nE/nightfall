#!/usr/bin/env python3
"""Two overlapping VDA tiles versus full-frame and full+centre VDA, still only."""
import argparse,json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from blend_centre_depth import infer,normalize,resize


def fit(a,b):
    a=np.asarray(a,dtype=np.float64).ravel();b=np.asarray(b,dtype=np.float64).ravel()
    keep=np.ones(a.shape,bool)
    for _ in range(5):
        scale,offset=np.linalg.lstsq(np.column_stack([a[keep],np.ones(keep.sum())]),b[keep],rcond=None)[0]
        error=np.abs(a*scale+offset-b);keep=error<=np.quantile(error,.85)
    if scale<=0 or not np.isfinite([scale,offset]).all():raise ValueError('Invalid overlap depth fit')
    return float(scale),float(offset),float(np.mean(np.abs(a*scale+offset-b)))


def tile_input(crop,padded):
    if not padded:return crop.resize((518,294),Image.Resampling.BILINEAR),(0,0,518,294)
    # 1080x1080 square content becomes 294x294, with edge-replicated padding.
    active=crop.resize((294,294),Image.Resampling.BILINEAR)
    pixels=np.pad(np.asarray(active),((0,0),(112,112),(0,0)),mode='edge')
    return Image.fromarray(pixels),(112,0,406,294)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source',type=Path,help='Existing centre experiment output directory')
    p.add_argument('--square-vda',type=Path,help='392x392 cold ONNX export for square-crop comparison')
    p.add_argument('--vda',type=Path,default=Path.home()/'.local/share/nightfall-meteor/models/vda_s_518x294_cold.onnx')
    args=p.parse_args();src=args.source;out=src/'side-by-side';out.mkdir(exist_ok=True)
    original=Image.open(src/'original.png').convert('RGB');assert original.size==(1920,1080)
    spec=dict(path=str(args.vda.resolve()),input_layout='ntchw',output_layout='nchw',output_name='depth',preprocessing='imagenet')
    metadata={'scope':'Static cold-start VDA on CPU. No temporal history, runtime timing, colour guidance, edge refinement or stereo warping. Common affine + feather blending for centre and tile comparison. Full output depth PNGs are 1920x1080.','model_input':[518,294],'source':[1920,1080],'tile_boxes':[[0,0,1080,1080],[840,0,1920,1080]],'overlap_px':240,'blend':'Positive affine fit in overlap (five 85% trimmed iterations), horizontal smoothstep feather. Independent per-tile percentile normalization; final stitched map normalized for display. No third full-frame inference used to anchor tiles.','variants':{}}
    results={'full-vda':np.asarray(Image.open(src/'vda_full_1080p.png')).astype(np.float32)/255,
             'centre-vda':np.load(src/'vda_vda_blend_float.npy')}
    variants=[(False,'tiles-stretched'),(True,'tiles-padded')]
    if args.square_vda:variants.append((False,'tiles-square-392'))
    for padded,name in variants:
        depths=[];infos=[]
        for index,box in enumerate(metadata['tile_boxes']):
            model_image,active=tile_input(original.crop(box),padded)
            current_spec=spec
            if name=='tiles-square-392':
                model_image=original.crop(box).resize((392,392),Image.Resampling.BILINEAR)
                current_spec=dict(spec,path=str(args.square_vda.resolve()))
            model_image.save(out/f'{name}-{index}-input.png')
            raw,info=infer(current_spec,np.asarray(model_image),out)
            np.save(out/f'{name}-{index}-raw.npy',raw)
            if padded:raw=raw[active[1]:active[3],active[0]:active[2]]
            depths.append(resize(normalize(raw),(1080,1080)));infos.append(info)
        left,right=depths
        # Match the right prediction to the left over a common, same-coordinate
        # overlap. Subsample uniformly for fit only, not for output resolution.
        scale,offset,error=fit(right[:,:240][::2,::2],left[:,840:1080][::2,::2])
        aligned=right*scale+offset
        t=np.linspace(0,1,240,dtype=np.float32);weight=(t*t*(3-2*t))[None,:]
        stitched=np.empty((1080,1920),np.float32)
        stitched[:,:840]=left[:,:840]
        stitched[:,840:1080]=left[:,840:]*(1-weight)+aligned[:,:240]*weight
        stitched[:,1080:]=aligned[:,240:]
        np.save(out/f'{name}-float.npy',stitched)
        results[name]=normalize(stitched)
        metadata['variants'][name]={'scale':scale,'offset':offset,'overlap_mae_after_fit':error,'inference':infos,'input_content':('392x392 square input, aspect preserved'if name=='tiles-square-392'else'294x294 with edge padding; aspect preserved'if padded else'518x294 stretched from square crop; aspect distorted'),'horizontal_samples_across_full_frame_approx':(392 if name=='tiles-square-392'else 294 if padded else 518)*1920/1080,'vertical_samples':392 if name=='tiles-square-392'else 294}
    if args.square_vda:
        contract=args.square_vda.parent/'contract.json'
        if contract.exists():metadata['square_export_contract']=json.loads(contract.read_text())
        metadata['square_pair_input_pixels']=2*392*392
        metadata['widescreen_pair_input_pixels']=2*518*294
    for name,array in results.items():
        assert array.shape==(1080,1920)and np.isfinite(array).all()
        Image.fromarray((np.clip(array,0,1)*255).round().astype('uint8')).save(out/f'{name}.png')
    original.save(out/'original.png')
    labels={'full-vda':'Full-frame VDA / one inference','centre-vda':'Full-frame + centre VDA / two inferences','tiles-stretched':'Two VDA tiles / stretched input','tiles-padded':'Two VDA tiles / aspect-preserving padding'}
    if args.square_vda:
        labels['tiles-square-392']='Two VDA tiles / 392x392 square input'
    main_labels={k:v for k,v in labels.items()if not(args.square_vda and k=='tiles-padded')}
    try:font=ImageFont.truetype('/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf',18)
    except OSError:font=ImageFont.load_default()
    sheet=Image.new('RGB',(1920,1152),'#171b24');draw=ImageDraw.Draw(sheet)
    for i,(name,label)in enumerate(main_labels.items()):
        x=i%2*960;y=i//2*576;draw.text((x+12,y+9),label,fill='white',font=font)
        sheet.paste(Image.open(out/f'{name}.png').convert('RGB').resize((960,540),Image.Resampling.LANCZOS),(x,y+36))
    comparison=out/'comparison.png'
    if args.square_vda and comparison.exists()and not(out/'comparison-518-only.png').exists():
        (out/'comparison-518-only.png').write_bytes(comparison.read_bytes())
    sheet.save(comparison)
    crop=(600,180,1320,900)
    details=Image.new('RGB',(1440,1512),'#171b24');draw=ImageDraw.Draw(details)
    for i,(name,label)in enumerate(main_labels.items()):
        x=i%2*720;y=i//2*756;draw.text((x+10,y+9),label,fill='white',font=font);details.paste(Image.open(out/f'{name}.png').convert('RGB').crop(crop),(x,y+36))
    details.save(out/'details.png')
    buttons=''.join(f'<button onclick="view.src=\'{name}.png\'">{label}</button>'for name,label in labels.items())
    (out/'index.html').write_text('''<!doctype html><meta charset="utf-8"><title>VDA two-tile comparison</title><style>body{background:#171b24;color:#eee;font:16px system-ui;margin:24px}img{max-width:100%}button{padding:10px;margin:5px}p{max-width:1100px}</style><h1>VDA: two side-by-side tiles versus detailed centre</h1><p>The deployed model input is 518×294. Left/right source crops are each 1080×1080, overlapping by 240 pixels. Stretched input allocates all model pixels to each crop but changes object proportions. Padded input preserves proportions but only 294×294 model pixels contain the crop. Both use two inferences, as does full-frame + centre VDA. The optional 392×392 export uses unchanged checkpoint weights and naturally square inputs: 307,328 pixels per pair versus 304,584 for the widescreen pair. Similar pixel count is not a measured runtime guarantee.</p><p>Same simple affine + feather blend as the original centre example; this is not the optimized runtime protected pipeline. Relative brightness is independently normalized for display. Static cold-start results only: no timing or temporal conclusions.</p>'''+buttons+'''<button onclick="view.src='original.png'">Original</button><button onclick="view.requestFullscreen()">Fullscreen</button><img id="view" src="tiles-stretched.png"><h2>Overview</h2><img src="comparison.png"><h2>Native-size central details</h2><img src="details.png">''')
    (out/'report.json').write_text(json.dumps(metadata,indent=2))
    parent=src/'index.html';s=parent.read_text();link='<p><a href="side-by-side/index.html">Two side-by-side VDA tiles versus detailed centre</a></p>'
    if link not in s:parent.write_text(s+link)
    print(out/'index.html',flush=True)

if __name__=='__main__':main()
