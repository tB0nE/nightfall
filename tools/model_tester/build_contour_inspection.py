#!/usr/bin/env python3
"""Make a pixel-zoom inspection page for the fixed 2560x1440 desktop example.

Only crops existing report images; it does not rerun or alter depth processing.
"""
import argparse
import base64
import io
import json
from pathlib import Path

import numpy as np
from PIL import Image

REGIONS = {
    "Back-left edge": {"crop": (1030,430,1160,620), "measure": (1060,450,1140,585)},
    "Middle-left edge": {"crop": (930,620,1060,760), "measure": (950,675,1030,725)},
    "Rounded front-left lip": {"crop": (490,840,680,1010), "measure": (510,900,600,955)},
}
VARIANTS = {"Linear":"0", "Bounded-2":"0-bounded-2", "Bounded-3":"0-bounded-3", "Bounded-4":"0-bounded-4"}


def contour_measure(image, box):
    x0,y0,x1,y1 = box
    row = np.asarray(image.convert("RGB"), dtype=float)[y0:y1,x0:x1]
    gradient = np.linalg.norm(np.diff(row,axis=1),axis=2)
    weights = gradient**4
    if np.any(weights.sum(axis=1) < 1e-12):
        raise ValueError("Measurement region must contain a detectable edge on each row")
    positions = (weights*np.arange(gradient.shape[1])[None,:]).sum(axis=1)/weights.sum(axis=1)+x0+.5
    y = np.arange(len(positions))
    residual = positions-np.polyval(np.polyfit(y,positions,2),y)
    return positions, {"mean_x":float(positions.mean()),"curve_residual_px":float(residual.std())}


def crop_uri(image, box):
    with io.BytesIO() as stream:
        image.crop(box).save(stream,format="PNG")
        return "data:image/png;base64,"+base64.b64encode(stream.getvalue()).decode("ascii")


def build(report):
    original = Image.open(report/"original.png").convert("RGB")
    if original.size != (2560,1440):
        raise ValueError("These fixed ROIs require the original 2560x1440 desktop example")
    metadata = json.loads((report/"report.json").read_text())
    if not metadata["models"] or "384" not in metadata["models"][0]["name"]:
        raise ValueError("First model must be EdgePad-384")
    tiles, metrics = {}, {}
    for name, region in REGIONS.items():
        tiles[name] = {"Original":{"original":crop_uri(original,region["crop"])}}
        reference, measured = contour_measure(original,region["measure"])
        metrics[name] = {"measurement_box":region["measure"],"Original":measured}
        for label, folder in VARIANTS.items():
            tiles[name][label] = {}
            for view in ("depth","overlay","left"):
                image = Image.open(report/folder/(view+".png"))
                tiles[name][label][view] = crop_uri(image,region["crop"])
                if view == "depth":
                    positions, measured = contour_measure(image,region["measure"])
                    measured["mean_absolute_colour_edge_gap_px"] = float(np.abs(positions-reference).mean())
                    metrics[name][label] = measured
    (report/"contour-metrics.json").write_text(json.dumps(metrics,indent=2)+"\n")
    template = """<!doctype html><html lang="en"><meta charset="utf-8"><title>EdgePad-384 contour close-ups</title>
<style>body{background:#15171b;color:#eee;font:16px system-ui;padding:24px}a{color:#83bfff}p{max-width:1100px;line-height:1.5}table{border-collapse:collapse}td,th{padding:12px;border:1px solid #444;vertical-align:top}img{display:block;image-rendering:pixelated}section{overflow:auto;margin:24px 0}select{font:inherit;padding:8px}small{display:block;max-width:240px;line-height:1.5;margin-top:8px}</style>
<h1>EdgePad-384 — pixel-level contour comparison</h1><a href="index.html">Full-frame report</a>
<p>These are identical-position crops of the existing full-resolution results, NOT new processing. Zoom uses nearest-neighbour display so tiny artifacts are not hidden by browser filtering. Original is unwarped; the colour-eye view is intentionally displaced for stereo.</p>
<label>View <select id="view"><option value="depth">Depth</option><option value="overlay">Cyan depth-edge overlay</option><option value="left">Warped left eye</option></select></label>
<label>Pixel zoom <select id="zoom"><option>1</option><option selected>2</option><option>4</option></select>×</label><main id="regions"></main>
<p>Contour measurements are diagnostic estimates: image gradients are not ground-truth depth boundaries. “Roughness” is residual after fitting a quadratic curve in the selected small measurement box, not a general image-quality score.</p>
<script>const tiles=__TILES__,metrics=__METRICS__;
function render(){const root=document.getElementById('regions');root.replaceChildren();const view=document.getElementById('view').value,zoom=Number(document.getElementById('zoom').value);
for(const [name,variants] of Object.entries(tiles)){const h=document.createElement('h2');h.textContent=name;root.append(h);const section=document.createElement('section'),table=document.createElement('table'),header=document.createElement('tr'),row=document.createElement('tr');
for(const [label,images] of Object.entries(variants)){const th=document.createElement('th');th.textContent=label;header.append(th);const td=document.createElement('td'),img=document.createElement('img');img.src=images[label==='Original'?'original':view];img.alt=name+' '+label;img.onload=()=>{img.style.width=img.naturalWidth*zoom+'px'};td.append(img);const m=metrics[name][label],caption=document.createElement('small');caption.textContent='Contour roughness: '+m.curve_residual_px.toFixed(3)+' px'+(label==='Original'?'':' · mean gap to colour edge: '+m.mean_absolute_colour_edge_gap_px.toFixed(2)+' px');td.append(caption);row.append(td)}
table.append(header,row);section.append(table);root.append(section)}}document.getElementById('view').onchange=document.getElementById('zoom').onchange=render;render();</script></html>"""
    html = template.replace("__TILES__",json.dumps(tiles).replace("<","\\u003c")).replace("__METRICS__",json.dumps(metrics))
    (report/"closeups.html").write_text(html)
    print(report/"closeups.html")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report",type=Path)
    build(parser.parse_args().report)
