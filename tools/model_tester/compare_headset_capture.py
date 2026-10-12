#!/usr/bin/env python3
"""Replay captured headset input without resizing; isolate GPU/orientation differences."""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from ai_edge_litert.interpreter import Interpreter
from run_models import infer_zipdepth, robust_range


def normalized(raw):
    lo, hi = robust_range(raw, .02, 512)
    return np.clip((raw-lo)/max(hi-lo,1e-6),0,1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture_dir",type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    report = {}
    for metadata in args.capture_dir.glob("*.json"):
        if metadata.name == "replay-report.json":
            continue
        m = json.loads(metadata.read_text())
        stem = metadata.stem
        image = Image.open(args.capture_dir / (stem+"-input.png")).convert("RGB")
        rgb = np.asarray(image,dtype=np.float32)/255
        if m["pad_rows"]:
            rgb = np.pad(rgb,((m["pad_rows"],m["pad_rows"]),(0,0),(0,0)),mode="edge")
        interp = Interpreter(model_path=str(root/"models"/m["asset"]),num_threads=4)
        interp.allocate_tensors()
        cpu = infer_zipdepth(interp,rgb,m["input_width"],m["input_height"])
        upright = infer_zipdepth(interp,rgb[::-1].copy(),m["input_width"],m["input_height"])
        pad = m["pad_rows"]
        if pad:
            cpu,upright = cpu[pad:-pad],upright[pad:-pad]
        gpu = np.fromfile(args.capture_dir/(stem+"-raw.f32"),dtype="<f4").reshape(m["map_height"],m["map_width"])
        processed = np.fromfile(args.capture_dir/(stem+"-processed.u8"),dtype=np.uint8).reshape(gpu.shape)
        report[stem] = {"gpu_cpu_raw_mae":float(np.abs(gpu-cpu).mean()),"gpu_cpu_normalized_mae":float(np.abs(normalized(gpu)-normalized(cpu)).mean()),"gpu_cpu_raw_range_fraction_mae":float(np.abs(gpu-cpu).mean()/max(float(np.ptp(cpu)),1e-6)),"orientation_normalized_mae":float(np.abs(normalized(cpu)[::-1]-normalized(upright)).mean())}
        sheet = Image.new("RGB",(480*4,300),"#15171b")
        draw = ImageDraw.Draw(sheet)
        tiles = [("Actual input (flipped upright for viewing)",image.transpose(Image.Transpose.FLIP_TOP_BOTTOM)),("GPU processed (flipped for viewing)",processed[::-1]/255),("CPU exact input (flipped for viewing)",normalized(cpu)[::-1]),("CPU upright input",normalized(upright))]
        for i,(label,tile) in enumerate(tiles):
            if isinstance(tile,np.ndarray):
                tile = Image.fromarray((tile*255).astype(np.uint8)).convert("RGB")
            sheet.paste(tile.resize((480,270),Image.Resampling.BILINEAR),(i*480,30))
            draw.text((i*480+5,8),label,fill="white")
        sheet.save(args.capture_dir/(stem+"-replay.png"))
    (args.capture_dir/"replay-report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2))


if __name__ == "__main__":
    main()
