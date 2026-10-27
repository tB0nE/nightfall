#!/usr/bin/env python3
"""Prepare real VDA frames, run an independent CPU ONNX rollout, and compare GPU rollouts.

GPU model runs use vda_ncnn_probe with VDA_PROBE_SEQUENCE=1. All paths are local;
this tool does not modify Meteor settings, models or services.
"""
import argparse
import csv
import hashlib
import html
import json
from pathlib import Path
import subprocess
import time

import cv2
import numpy as np

WIDTH, HEIGHT = 518, 294
SHAPES = [(777, 192)]*2 + [(209, 384)]*2 + [(777, 64)]*2 + [(3108, 64)]*2


def state_shapes(width, height):
    if min(width, height)<14 or width%14 or height%14:
        raise ValueError('VDA dimensions must be multiples of 14')
    x, y = width//14, height//14
    return [(x*y,192)]*2 + [(((x+1)//2)*((y+1)//2),384)]*2 + [(x*y,64)]*2 + [(x*y*4,64)]*2


def name(index):
    return f"frame_{index:04d}"


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024*1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class History:
    """Independent implementation of Meteor's 44-slot reference history policy."""
    def __init__(self):
        self.list = [0]*32
        self.steps = 0

    def selection(self):
        return self.list[:2] + self.list[-29:]

    def free_slot(self):
        return next(i for i in range(44) if i not in self.list)

    def push(self, slot):
        self.steps += 1
        self.list.append(slot)
        if self.steps+32 > 42:
            del self.list[1]
        assert len(self.list) <= 42


def thumbnail(image):
    result = np.empty((3, 9, 16), np.float32)
    for y in range(9):
        for x in range(16):
            result[:, y, x] = image[:, y*HEIGHT//9:(y+1)*HEIGHT//9,
                                    x*WIDTH//16:(x+1)*WIDTH//16].mean(axis=(1, 2))
    return result


def prepare(args):
    args.output.mkdir(parents=True, exist_ok=True)
    if (args.output/"sequence.json").exists():
        raise FileExistsError("Choose a fresh sequence output directory")
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height", "-of", "json", str(args.video)]))
    stream = probe["streams"][0]
    width, height = stream["width"], stream["height"]
    frames, previous = [], None
    mean = np.array([0.485, 0.456, 0.406], np.float32)
    std = np.array([0.229, 0.224, 0.225], np.float32)
    command = ["ffmpeg", "-v", "error", "-ss", str(args.start), "-i", str(args.video),
               "-an", "-vf", f"fps={args.fps}", "-frames:v", str(args.frames),
               "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1"]
    with (args.output/"decode.log").open("w") as error:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=error)
        try:
            for index in range(args.frames):
                raw = process.stdout.read(width*height*3)
                if len(raw) != width*height*3:
                    raise RuntimeError(f"Video ended at frame {index}; see decode.log")
                rgb = np.frombuffer(raw, np.uint8).reshape(height, width, 3)
                resized = cv2.resize(rgb.astype(np.float32)/255, (WIDTH, HEIGHT),
                                     interpolation=cv2.INTER_CUBIC)
                image = ((resized-mean)/std).transpose(2, 0, 1).copy()
                thumb = thumbnail(image)
                change = 0.0 if previous is None else float(np.abs(thumb-previous).mean())
                timestamp = index/args.fps + (0.75 if args.gap_at >= 0 and index >= args.gap_at else 0)
                reset = "start" if index == 0 else "gap" if index == args.gap_at else "cut" if change > 1.0 else "none"
                image.astype("<f4").tofile(args.output/(name(index)+".f32"))
                cv2.imwrite(str(args.output/(name(index)+".jpg")),
                            cv2.cvtColor(np.clip(resized*255, 0, 255).astype(np.uint8), cv2.COLOR_RGB2BGR))
                frames.append({"index": index, "timestamp": timestamp, "reset": reset,
                               "thumbnail_change": change,
                               "input_sha256": hashlib.sha256(image.tobytes()).hexdigest()})
                previous = thumb
                if index % 16 == 0:
                    print(f"Prepared frame {index}", flush=True)
            if process.wait():
                raise RuntimeError("FFmpeg failed; see decode.log")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()
    metadata = {"source": str(args.video), "start_seconds": args.start, "fps": args.fps,
                "size": [WIDTH, HEIGHT], "synthetic_gap_at": args.gap_at,
                "preprocess": "FFmpeg RGB decode; float OpenCV INTER_CUBIC; DINO mean/std",
                "frames": frames}
    (args.output/"sequence.json").write_text(json.dumps(metadata, indent=2)+"\n")
    (args.output/"frames.tsv").write_text("".join(
        f"{f['index']}\t{f['timestamp']:.9f}\t{f['reset']}\n" for f in frames))
    print(json.dumps({"prepared": len(frames), "resets": [(f["index"], f["reset"])
                                                         for f in frames if f["reset"] != "none"]}))


def reference(args):
    import onnxruntime as ort
    metadata = json.loads((args.sequence/"sequence.json").read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    options.inter_op_num_threads = 1
    cold = ort.InferenceSession(str(args.cold), options, providers=["CPUExecutionProvider"])
    step = ort.InferenceSession(str(args.step), options, providers=["CPUExecutionProvider"])
    pool, history = {}, History()
    with (args.output/"timings.csv").open("w") as timing, (args.output/"history.tsv").open("w") as trace:
        writer = csv.writer(timing)
        writer.writerow(["frame", "timestamp", "reset", "prepare_ms", "graph_ms", "store_ms", "validation_download_ms"])
        for frame in metadata["frames"]:
            index = frame["index"]
            started = time.perf_counter()
            image = np.fromfile(args.sequence/(name(index)+".f32"), "<f4").reshape(1, 1, 3, HEIGHT, WIDTH)
            if hashlib.sha256(image.tobytes()).hexdigest() != frame["input_sha256"]:
                raise ValueError("Input fixture changed")
            first = frame["reset"] != "none"
            if first:
                history, pool = History(), {}
                slot, selected = 0, []
                session, feed = cold, {"image": image}
            else:
                slot, selected = history.free_slot(), history.selection()
                session, feed = step, {"image": image}
                for i in range(8):
                    feed[f"cache_{i}"] = np.concatenate([pool[s][i] for s in selected], axis=1).astype(np.float32)
            prepare_ms = (time.perf_counter()-started)*1000
            started = time.perf_counter()
            result = session.run(None, feed)
            graph_ms = (time.perf_counter()-started)*1000
            if len(result) != 9 or not all(np.isfinite(x).all() for x in result):
                raise ValueError(f"Invalid reference outputs at frame {index}")
            result[0].astype("<f4").tofile(args.output/(name(index)+".depth.f32"))
            states = tuple(x.astype(np.float16) for x in result[1:])
            if not all(np.isfinite(x).all() for x in states):
                raise ValueError("History overflow")
            pool[slot] = states
            if not first:
                history.push(slot)
            for i, (state, shape) in enumerate(zip(states, SHAPES)):
                if state.shape != (shape[0], 1, shape[1]):
                    raise ValueError("State shape changed")
                state.astype("<f2").tofile(args.output/(name(index)+f".state{i}.f16"))
            writer.writerow([index, frame["timestamp"], frame["reset"], prepare_ms, graph_ms, 0, 0])
            trace.write("\t".join(map(str, [index, frame["reset"], slot, *selected]))+"\n")
            timing.flush()
            if index % 8 == 0 or first:
                print(f"Reference frame {index}: {frame['reset']}, {graph_ms:.2f} ms", flush=True)
    (args.output/"complete.json").write_text(json.dumps({"frames": len(metadata["frames"]),
        "provider": "CPUExecutionProvider", "history_storage": "float16", "self_fed": True,
        "cold_model_sha256": file_hash(args.cold), "step_model_sha256": file_hash(args.step)}, indent=2)+"\n")


def report(args):
    metadata = json.loads((args.sequence/"sequence.json").read_text())
    frames = metadata["frames"]
    count = len(frames)
    runs = [entry.split("=", 1) for entry in args.run]
    if any(len(entry) != 2 for entry in runs):
        raise ValueError("Run format is label=directory")
    if len({label for label, _ in runs}) != len(runs):
        raise ValueError("Run labels must be unique")
    for frame in frames:
        if file_hash(args.sequence/(name(frame["index"])+".f32")) != frame["input_sha256"]:
            raise ValueError("Input fixture changed after reference generation")
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output/"frames").mkdir(exist_ok=True)
    reference_depth = np.stack([np.fromfile(args.reference/(name(i)+".depth.f32"), "<f4").reshape(HEIGHT, WIDTH)
                                for i in range(count)])
    if not np.isfinite(reference_depth).all():
        raise ValueError("Nonfinite reference")
    summary = {"source": metadata, "scope": "raw VDA output before depth normalization/refinement/warping",
               "runs": {}}
    depth_runs = []
    for label, directory in runs:
        directory = Path(directory)
        if (directory/"history.tsv").read_text() != (args.reference/"history.tsv").read_text():
            raise ValueError(f"History selection differs: {label}")
        depths = np.stack([np.fromfile(directory/(name(i)+".depth.f32"), "<f4").reshape(HEIGHT, WIDTH)
                           for i in range(count)])
        if not np.isfinite(depths).all():
            raise ValueError(f"Nonfinite depth: {label}")
        depth_runs.append(depths)
        timing = list(csv.DictReader((directory/"timings.csv").open()))
        if len(timing) != count:
            raise ValueError("Incomplete timing data")
        results, steady, steady_indices, segment = [], [], [], 0
        for i, frame in enumerate(frames):
            spread = max(float(np.quantile(reference_depth[i], .98)-np.quantile(reference_depth[i], .02)), 1e-6)
            difference = np.abs(depths[i]-reference_depth[i])
            state_errors = []
            for state in range(8):
                expected = np.fromfile(args.reference/(name(i)+f".state{state}.f16"), "<f2").astype(np.float32)
                actual = np.fromfile(directory/(name(i)+f".state{state}.f16"), "<f2").astype(np.float32)
                if expected.size != SHAPES[state][0]*SHAPES[state][1] or actual.size != expected.size or not np.isfinite(actual).all():
                    raise ValueError(f"Invalid state {state}, frame {i}, run {label}")
                state_errors.append(float(np.abs(expected-actual).mean()))
            item = {"frame": i, "reset": frame["reset"], "depth_mae": float(difference.mean()),
                    "normalized_mae": float(difference.mean())/spread, "state_mae": state_errors}
            if i and frame["reset"] == "none":
                residual = (depths[i]-depths[i-1])-(reference_depth[i]-reference_depth[i-1])
                item["temporal_delta_error"] = float(np.abs(residual).mean())/spread
            segment = 0 if frame["reset"] != "none" else segment+1
            if segment > 5:
                steady.append(float(timing[i]["graph_ms"]))
                steady_indices.append(i)
            results.append(item)
        if not steady_indices:
            steady_indices = [i for i, frame in enumerate(frames) if frame["reset"] == "none"]
            steady = [float(timing[i]["graph_ms"]) for i in steady_indices]
        if not steady:
            raise ValueError("No recurrent frames available for timing")
        summary["runs"][label] = {"frames": results, "history_trace_matches": True,
            "mean_normalized_mae": float(np.mean([r["normalized_mae"] for r in results])),
            "max_normalized_mae": float(max(r["normalized_mae"] for r in results)),
            "mean_temporal_delta_error": float(np.mean([r["temporal_delta_error"] for r in results if "temporal_delta_error" in r])),
            "steady_model_median_ms": float(np.median(steady)), "steady_model_p95_ms": float(np.percentile(steady, 95)),
            "steady_samples": len(steady), "all_finite": True,
            "steady_phase_medians_ms": {phase: float(np.median([float(timing[i][phase]) for i in steady_indices]))
                for phase in ("prepare_ms", "graph_ms", "store_ms", "validation_download_ms")},
            "steady_core_median_ms": float(np.median([sum(float(timing[i][p]) for p in ("prepare_ms", "graph_ms", "store_ms")) for i in steady_indices]))}
    low, high = np.quantile(reference_depth[:, ::4, ::4], [.02, .98])
    def color(depth):
        value = np.clip((depth-low)/max(high-low, 1e-6)*255, 0, 255).astype(np.uint8)
        return cv2.applyColorMap(value, cv2.COLORMAP_TURBO)
    video_width = WIDTH*(2+len(runs))
    encoder = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24",
        "-s", f"{video_width}x{HEIGHT+32}", "-r", str(metadata["fps"]), "-i", "pipe:0", "-an",
        "-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p", str(args.output/"comparison.mp4")], stdin=subprocess.PIPE)
    try:
        for i in range(count):
            images = [cv2.imread(str(args.sequence/(name(i)+".jpg"))), color(reference_depth[i])]
            images += [color(depth[i]) for depth in depth_runs]
            canvas = np.zeros((HEIGHT+32, video_width, 3), np.uint8)
            labels = ["Model input", "ONNX CPU reference"]+[label for label, _ in runs]
            for column, (image, label) in enumerate(zip(images, labels)):
                canvas[32:, column*WIDTH:(column+1)*WIDTH] = image
                cv2.putText(canvas, label, (column*WIDTH+10, 23), cv2.FONT_HERSHEY_SIMPLEX, .6, (230, 230, 230), 1, cv2.LINE_AA)
            cv2.imwrite(str(args.output/"frames"/(name(i)+".jpg")), canvas)
            encoder.stdin.write(canvas.tobytes())
        encoder.stdin.close()
        if encoder.wait():
            raise RuntimeError("Comparison video encoding failed")
    finally:
        if encoder.poll() is None:
            encoder.terminate()
            encoder.wait()
    if args.max_normalized_error is not None:
        for label, result in summary["runs"].items():
            if result["max_normalized_mae"] > args.max_normalized_error:
                raise ValueError(f"Accuracy gate failed for {label}: worst-frame normalized MAE "
                                 f"{result['max_normalized_mae']:.6f} > {args.max_normalized_error:.6f}")
    (args.output/"summary.json").write_text(json.dumps(summary, indent=2)+"\n")
    rows = "".join(f"<tr><td>{html.escape(label)}</td><td>{r['steady_model_median_ms']:.2f} ms</td>"
                   f"<td>{r['steady_model_p95_ms']:.2f} ms</td><td>{r['mean_normalized_mae']:.4%}</td>"
                   f"<td>{r['mean_temporal_delta_error']:.4%}</td></tr>" for label, r in summary["runs"].items())
    document = """<!doctype html><meta charset=utf-8><title>VDA video sequence validation</title>
<style>body{background:#15171b;color:#ddd;font:16px system-ui;margin:24px}img{width:100%;display:block}table{border-collapse:collapse}td,th{padding:10px;text-align:left;border-bottom:1px solid #444}button,input{margin:12px}input{width:65%}a{color:#8bf}</style>
<h1>VDA recurrent video validation</h1><p>Each model feeds its own states into later frames. Shared color scale is fixed over the full sequence.</p>
<p>Raw model depth before softening, refinement and stereo warping. Model timings exclude preparation, history stores and validation readback. A synthetic gap tests reset behavior.</p>
<table><tr><th>Path</th><th>Model median</th><th>p95</th><th>Normalized error</th><th>Temporal delta error</th></tr>__ROWS__</table>
<button id=play>Play</button><input id=slider type=range min=0 max=__MAX__ value=0><span id=label></span><button onclick="document.querySelector('img').requestFullscreen()">Fullscreen</button>
<img id=frame src=frames/frame_0000.jpg><p><a href=comparison.mp4>Comparison video</a> · <a href=summary.json>Full metrics</a></p>
<script>const frames=__FRAMES__, slider=document.querySelector('#slider'), image=document.querySelector('#frame'), label=document.querySelector('#label');
function show(){let i=Number(slider.value);image.src='frames/frame_'+String(i).padStart(4,'0')+'.jpg';label.textContent='Frame '+i+' · '+frames[i].reset;}
slider.oninput=show;let timer=null;document.querySelector('#play').onclick=()=>{if(timer){clearInterval(timer);timer=null;}else{timer=setInterval(()=>{slider.value=(Number(slider.value)+1)%frames.length;show();},__INTERVAL__);}};show();</script>"""
    document = document.replace("__ROWS__", rows).replace("__MAX__", str(count-1)).replace("__FRAMES__", json.dumps(frames)).replace("__INTERVAL__", str(1000/metadata["fps"]))
    (args.output/"index.html").write_text(document)
    print(json.dumps({label: {k: v for k, v in r.items() if k != "frames"}
                      for label, r in summary["runs"].items()}, indent=2))


def main():
    global WIDTH, HEIGHT, SHAPES
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--video", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p.add_argument("--frames", type=int, default=80); p.add_argument("--fps", type=float, default=20)
    p.add_argument("--start", type=float, default=30); p.add_argument("--gap-at", type=int, default=64)
    p.add_argument("--width", type=int, default=518);p.add_argument("--height", type=int, default=294)
    p = sub.add_parser("reference")
    p.add_argument("--sequence", type=Path, required=True); p.add_argument("--output", type=Path, required=True)
    p.add_argument("--cold", type=Path, required=True); p.add_argument("--step", type=Path, required=True)
    p = sub.add_parser("report")
    p.add_argument("--sequence", type=Path, required=True); p.add_argument("--reference", type=Path, required=True)
    p.add_argument("--run", action="append", required=True); p.add_argument("--output", type=Path, required=True)
    p.add_argument("--max-normalized-error", type=float,
                   help="Reject reports exceeding this worst-frame MAE / reference p98-p2 range")
    args = parser.parse_args()
    if args.command == 'prepare':
        WIDTH, HEIGHT = args.width, args.height
    else:
        WIDTH, HEIGHT = json.loads((args.sequence/'sequence.json').read_text())['size']
    SHAPES = state_shapes(WIDTH, HEIGHT)
    if args.command == "prepare" and (args.frames<2 or args.fps<=0 or args.start<0 or args.gap_at>=args.frames):
        parser.error("Invalid frame count, FPS, start or gap index")
    {"prepare": prepare, "reference": reference, "report": report}[args.command](args)


if __name__ == "__main__":
    main()
