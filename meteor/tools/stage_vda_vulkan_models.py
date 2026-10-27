#!/usr/bin/env python3
"""Stage validated ncnn VDA exports, with explicit dimensions and SHA-256 manifest.
No model retraining or graph rewriting; the input must be repaired probe exports.
"""
import argparse,hashlib,json,shutil
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',type=Path,required=True)
p.add_argument('--destination',type=Path,required=True)
a=p.parse_args()
for width,height,folder,step,cold in [(518,294,a.source,'step-amd-scalar-spatial','cold-repaired'),(392,224,a.source/'res392x224','step-repaired','cold-repaired')]:
 target=a.destination/f'vda_vulkan_{width}x{height}';target.mkdir(parents=True,exist_ok=True)
 shutil.copyfile(Path(__file__).resolve().parents[1]/'third_party/video-depth-anything/LICENSE',target/'LICENSE')
 files={}
 for base,prefix in [('step',step),('cold',cold)]:
  for ext in ['param','bin']:
   src=folder/f'{prefix}.ncnn.{ext}';dst=target/f'{base}.ncnn.{ext}'
   if dst.exists():
    if hashlib.sha256(dst.read_bytes()).digest()!=hashlib.sha256(src.read_bytes()).digest(): raise SystemExit(f'Refusing to overwrite different model: {dst}')
   else: shutil.copyfile(src,dst)
   files[dst.name]=hashlib.sha256(dst.read_bytes()).hexdigest()
 (target/'manifest.json').write_text(json.dumps(dict(schema=1,width=width,height=height,checkpoint_sha256='13379300b739e659f076a59d52e9801bd8d38c541a7e71f73bbca4dcfb013609',files=files),indent=2)+'\n')
 print(target)
