#!/usr/bin/env python3
"""Replay Nightfall's temporal depth pipeline against a local video clip.

This is intentionally a depth-motion tester, not a stereo renderer.  It
decodes the source at its native frame rate, runs ZipDepth at a configurable
inference cadence, applies the same robust-range and EMA state used by
DepthEstimator.java, converts the result to Nightfall's 480x270 working map,
and holds each result until the next inference completes.

Two videos are written:

* ``depth.mp4``: the actual held 480x270 depth-map sequence.
* ``dmap-warp.mp4``: the final occlusion-offset field shown by DMap-Warp.
* ``review.mp4``: source, depth, and DMap-Warp together for diagnosis.

The default model/tau/upsample values mirror Android's production EdgePad-384 path.
No left/right eye images or stereo warp are generated because neither is
needed to evaluate depth-map consistency over time.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import subprocess
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import run_models


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_VIDEO = Path(
    "/var/srv/media/Video/Youtube/"
    "JJ's Friend Attacked by Evil Golem ？! (Maizen) [Y7fEldmgkJY].webm"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("video", nargs="?", type=Path, default=DEFAULT_VIDEO)
    parser.add_argument("--start", type=float, default=410.0,
                        help="Clip start in seconds (default: 410)")
    parser.add_argument("--duration", type=float, default=12.0,
                        help="Clip duration in seconds (default: 12)")
    parser.add_argument("--model", default="zipdepth_384_standard_edgepad",
                        help="Model key from settings.json")
    parser.add_argument("--inference-fps", type=float, default=20.0,
                        help="Maximum depth update rate (default: 20)")
    parser.add_argument("--depth-tau", type=float, default=0.055,
                        help="Per-pixel depth EMA time constant in seconds")
    parser.add_argument("--range-tau", type=float, default=0.308,
                        help="Normalization-range EMA time constant in seconds")
    parser.add_argument("--upsample", choices=("guided-linear", "guided", "linear"),
                        default="linear",
                        help="Final 480x270 conversion (default: linear)")
    parser.add_argument("--separation", type=float, default=0.006,
                        help="Native renderer parallax at 100%% (default: 0.006)")
    parser.add_argument("--convergence", type=float, default=0.5,
                        help="Depth convergence point (default: 0.5)")
    parser.add_argument("--output-dir", type=Path,
                        default=SCRIPT_DIR / "output" / "temporal-depth")
    parser.add_argument("--output-width", type=int, default=480)
    parser.add_argument("--output-height", type=int, default=270)
    return parser.parse_args()


def probe_video(path: Path) -> dict:
    command = [
        "ffprobe", "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,avg_frame_rate",
        "-of", "json", str(path),
    ]
    data = json.loads(subprocess.check_output(command, text=True))
    stream = data["streams"][0]
    numerator, denominator = stream["avg_frame_rate"].split("/")
    return {
        "width": int(stream["width"]),
        "height": int(stream["height"]),
        "fps": float(numerator) / float(denominator),
    }


def open_decoder(path: Path, start: float, duration: float,
                 width: int, height: int) -> subprocess.Popen:
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-ss", str(start), "-i", str(path), "-t", str(duration),
        "-map", "0:v:0", "-an", "-sn", "-dn",
        "-pix_fmt", "rgb24", "-f", "rawvideo", "pipe:1",
    ]
    return subprocess.Popen(command, stdout=subprocess.PIPE, bufsize=width * height * 3 * 4)


def open_encoder(path: Path, width: int, height: int, fps: float) -> subprocess.Popen:
    path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{width}x{height}", "-r", f"{fps:.8f}", "-i", "pipe:0",
        "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "15",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path),
    ]
    return subprocess.Popen(command, stdin=subprocess.PIPE)


def read_exact(stream, byte_count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < byte_count:
        chunk = stream.read(byte_count - len(chunks))
        if not chunk:
            break
        chunks.extend(chunk)
    return bytes(chunks)


class TemporalPostProcessor:
    """Stateful equivalent of DepthEstimator.java postProcess()."""

    def __init__(self, percentile_clip: float, hist_bins: int,
                 depth_tau: float, range_tau: float):
        self.percentile_clip = percentile_clip
        self.hist_bins = hist_bins
        self.depth_tau = depth_tau
        self.range_tau = range_tau
        self.smooth_lo: float | None = None
        self.smooth_hi: float | None = None
        self.smoothed_depth: np.ndarray | None = None

    def process(self, raw: np.ndarray, dt: float) -> tuple[np.ndarray, dict]:
        lo, hi = run_models.robust_range(
            raw, self.percentile_clip, self.hist_bins
        )
        if self.smooth_lo is None:
            self.smooth_lo, self.smooth_hi = lo, hi
            range_alpha = 1.0
        else:
            range_alpha = 1.0 - math.exp(-dt / self.range_tau)
            self.smooth_lo += range_alpha * (lo - self.smooth_lo)
            self.smooth_hi += range_alpha * (hi - self.smooth_hi)

        scale = 1.0 / max(self.smooth_hi - self.smooth_lo, 1e-6)
        normalized = np.clip((raw - self.smooth_lo) * scale, 0.0, 1.0)
        if self.smoothed_depth is None:
            smoothed = normalized
            depth_alpha = 1.0
        else:
            depth_alpha = 1.0 - math.exp(-dt / self.depth_tau)
            smoothed = self.smoothed_depth + depth_alpha * (
                normalized - self.smoothed_depth
            )
        self.smoothed_depth = smoothed
        return smoothed, {
            "raw_lo": lo,
            "raw_hi": hi,
            "smooth_lo": self.smooth_lo,
            "smooth_hi": self.smooth_hi,
            "range_alpha": range_alpha,
            "depth_alpha": depth_alpha,
        }


def make_offset_view(depth: np.ndarray, separation: float,
                     convergence: float) -> np.ndarray:
    """CPU replica of OFFSET_FRAGMENT_SRC plus DMap-Warp visualization.

    Only the left-eye channel is returned.  Nightfall deliberately flips the
    right-eye debug polarity, so both eyes show the same diagnostic image.
    """
    height, width = depth.shape
    disparity = separation * width
    reach = int(math.ceil(abs(disparity) * max(convergence, 1.0 - convergence))) + 2
    x = np.arange(width, dtype=np.int32)[None, :]
    here = depth
    best_depth = np.full((height, width), -1.0, dtype=np.float32)
    best_offset = -disparity * (here - convergence)

    previous_depth = depth[:, np.clip(x - reach, 0, width - 1)[0]]
    previous_error = -float(reach) + disparity * (previous_depth - convergence)
    for tap in range(-reach + 1, reach + 1):
        current_depth = depth[:, np.clip(x + tap, 0, width - 1)[0]]
        current_error = float(tap) + disparity * (current_depth - convergence)
        span = current_error - previous_error
        crossing = (previous_error * current_error <= 0.0) & (np.abs(span) > 1e-6)
        fraction = np.clip(
            -previous_error / np.where(np.abs(span) > 1e-6, span, 1.0),
            0.0, 1.0,
        )
        crossing_depth = previous_depth + fraction * (current_depth - previous_depth)
        replace = crossing & (crossing_depth > best_depth)
        best_depth = np.where(replace, crossing_depth, best_depth)
        best_offset = np.where(replace, float(tap - 1) + fraction, best_offset)
        previous_depth = current_depth
        previous_error = current_error

    encoded = np.clip(best_offset / (2.0 * reach) + 0.5, 0.0, 1.0)
    # offset_texture is GL_RGBA8, so preserve the quantization that the debug
    # shader sees rather than visualizing the higher-precision CPU value.
    encoded = np.round(encoded * 255.0) / 255.0
    visible = np.clip(0.5 + (encoded - 0.5) * 4.0, 0.0, 1.0)
    return np.floor(visible * 255.0).astype(np.uint8)


def make_labelled_review(source: np.ndarray, depth_gray: np.ndarray,
                         warp_gray: np.ndarray,
                         width: int, height: int, update_index: int,
                         frame_index: int, fps: float,
                         inference_fps: float) -> np.ndarray:
    source_small = cv2.resize(source, (width, height), interpolation=cv2.INTER_AREA)
    depth_rgb = np.repeat(depth_gray[:, :, None], 3, axis=2)
    warp_rgb = np.repeat(warp_gray[:, :, None], 3, axis=2)
    review = np.concatenate((source_small, depth_rgb, warp_rgb), axis=1)
    cv2.rectangle(review, (0, 0), (review.shape[1], 29), (18, 20, 24), -1)
    cv2.putText(review, "SOURCE", (10, 21), cv2.FONT_HERSHEY_SIMPLEX,
                0.55, (238, 238, 238), 1, cv2.LINE_AA)
    cv2.putText(review, f"NIGHTFALL DEPTH (held at {inference_fps:g} Hz)",
                (width + 10, 21), cv2.FONT_HERSHEY_SIMPLEX,
                0.55, (238, 238, 238), 1, cv2.LINE_AA)
    cv2.putText(review, "DMAP-WARP OFFSET FIELD",
                (width * 2 + 10, 21), cv2.FONT_HERSHEY_SIMPLEX,
                0.55, (238, 238, 238), 1, cv2.LINE_AA)
    timestamp = frame_index / fps
    cv2.putText(review, f"t={timestamp:5.2f}s  depth #{update_index}",
                (review.shape[1] - 208, height - 10),
                cv2.FONT_HERSHEY_SIMPLEX, 0.42, (238, 238, 238), 1,
                cv2.LINE_AA)
    return review


def main() -> int:
    args = parse_args()
    if not args.video.is_file():
        print(f"Video not found: {args.video}", file=sys.stderr)
        return 2
    if args.duration <= 0 or args.inference_fps <= 0:
        print("duration and inference-fps must be positive", file=sys.stderr)
        return 2

    settings = run_models.load_settings()
    if args.model not in settings["models"]:
        print(f"Unknown model key: {args.model}", file=sys.stderr)
        return 2
    model_cfg = settings["models"][args.model]
    model_path = (SCRIPT_DIR / model_cfg["path"]).resolve()

    probe = probe_video(args.video)
    source_width = probe["width"]
    source_height = probe["height"]
    source_fps = probe["fps"]
    expected_frames = int(round(args.duration * source_fps))
    frame_bytes = source_width * source_height * 3

    print(f"Loading {args.model}: {model_path}")
    interpreter = run_models.make_interpreter(model_path)
    input_shape = interpreter.get_input_details()[0]["shape"]
    model_height, model_width = int(input_shape[1]), int(input_shape[2])
    processor = TemporalPostProcessor(
        settings["percentile_clip"]["zipdepth"], settings["hist_bins"],
        args.depth_tau, args.range_tau,
    )

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    depth_path = output_dir / "depth.mp4"
    warp_path = output_dir / "dmap-warp.mp4"
    review_path = output_dir / "review.mp4"
    metrics_path = output_dir / "metrics.csv"
    metadata_path = output_dir / "metadata.json"

    decoder = open_decoder(args.video, args.start, args.duration,
                           source_width, source_height)
    depth_encoder = open_encoder(
        depth_path, args.output_width, args.output_height, source_fps
    )
    warp_encoder = open_encoder(
        warp_path, args.output_width, args.output_height, source_fps
    )
    review_encoder = open_encoder(
        review_path, args.output_width * 3, args.output_height, source_fps
    )

    next_inference_time = 0.0
    last_inference_time: float | None = None
    held_depth: np.ndarray | None = None
    held_warp: np.ndarray | None = None
    previous_depth: np.ndarray | None = None
    previous_warp: np.ndarray | None = None
    frame_index = 0
    update_index = 0
    inference_times: list[float] = []
    metric_rows: list[dict] = []
    started = time.perf_counter()

    try:
        while frame_index < expected_frames:
            frame_data = read_exact(decoder.stdout, frame_bytes)
            if len(frame_data) != frame_bytes:
                break
            source = np.frombuffer(frame_data, dtype=np.uint8).reshape(
                source_height, source_width, 3
            )
            timestamp = frame_index / source_fps

            if held_depth is None or timestamp + 1e-9 >= next_inference_time:
                # INTER_AREA is the closest practical CPU equivalent of the
                # headset's 4x4 footprint box downscale.
                model_rgb_u8 = cv2.resize(
                    source, (model_width, model_height), interpolation=cv2.INTER_AREA
                )
                model_rgb = model_rgb_u8.astype(np.float32) / 255.0
                infer_started = time.perf_counter()
                raw = run_models.infer_zipdepth(
                    interpreter, model_rgb, model_width, model_height
                )
                inference_ms = (time.perf_counter() - infer_started) * 1000.0
                inference_times.append(inference_ms)

                dt = (args.depth_tau if last_inference_time is None
                      else max(1.0 / 60.0,
                               min(timestamp - last_inference_time, 1.0)))
                normalized, range_stats = processor.process(raw, dt)
                # Android uploads normalized depth as an 8-bit texture before
                # the native renderer performs production hardware-linear
                # conversion to the quarter-resolution 480x270 working map.
                depth_u8 = np.floor(
                    np.clip(normalized, 0.0, 1.0) * 255.0
                ).astype(np.uint8)
                if args.upsample == "guided-linear":
                    guided = run_models.guided_linear_resample(
                        depth_u8.astype(np.float32) / 255.0,
                        model_rgb,
                        target_width=args.output_width,
                        target_height=args.output_height,
                    )
                    held_depth = np.floor(
                        np.clip(guided, 0.0, 1.0) * 255.0
                    ).astype(np.uint8)
                elif args.upsample == "guided":
                    guided = run_models.native_guided_resample(
                        depth_u8.astype(np.float32) / 255.0,
                        model_rgb,
                        target_width=args.output_width,
                        target_height=args.output_height,
                    )
                    held_depth = np.floor(
                        np.clip(guided, 0.0, 1.0) * 255.0
                    ).astype(np.uint8)
                else:
                    held_depth = cv2.resize(
                        depth_u8, (args.output_width, args.output_height),
                        interpolation=cv2.INTER_LINEAR,
                    )
                held_depth_float = held_depth.astype(np.float32) / 255.0
                held_warp = make_offset_view(
                    held_depth_float, args.separation, args.convergence
                )
                temporal_delta = (0.0 if previous_depth is None else
                                  float(np.mean(np.abs(
                                      held_depth.astype(np.float32)
                                      - previous_depth.astype(np.float32)
                                  ))) / 255.0)
                warp_delta = (0.0 if previous_warp is None else
                              float(np.mean(np.abs(
                                  held_warp.astype(np.float32)
                                  - previous_warp.astype(np.float32)
                              ))) / 255.0)
                previous_depth = held_depth.copy()
                previous_warp = held_warp.copy()
                last_inference_time = timestamp
                update_index += 1
                next_inference_time = update_index / args.inference_fps
                metric_rows.append({
                    "update": update_index,
                    "source_frame": frame_index,
                    "timestamp_s": f"{timestamp:.6f}",
                    "dt_s": f"{dt:.6f}",
                    "inference_ms_desktop_cpu": f"{inference_ms:.3f}",
                    "mean_abs_depth_change": f"{temporal_delta:.8f}",
                    "mean_abs_warp_change": f"{warp_delta:.8f}",
                    **{key: f"{value:.8f}" for key, value in range_stats.items()},
                })

            depth_rgb = np.repeat(held_depth[:, :, None], 3, axis=2)
            warp_rgb = np.repeat(held_warp[:, :, None], 3, axis=2)
            review = make_labelled_review(
                source, held_depth, held_warp,
                args.output_width, args.output_height,
                update_index, frame_index, source_fps, args.inference_fps,
            )
            depth_encoder.stdin.write(depth_rgb.tobytes())
            warp_encoder.stdin.write(warp_rgb.tobytes())
            review_encoder.stdin.write(review.tobytes())
            frame_index += 1
            if frame_index % max(1, int(source_fps * 2)) == 0:
                print(f"Processed {frame_index}/{expected_frames} video frames, "
                      f"{update_index} depth updates")
    finally:
        if decoder.stdout:
            decoder.stdout.close()
        decoder.wait()
        for encoder in (depth_encoder, warp_encoder, review_encoder):
            if encoder.stdin:
                encoder.stdin.close()
            encoder.wait()

    with metrics_path.open("w", newline="") as metrics_file:
        if metric_rows:
            writer = csv.DictWriter(metrics_file, fieldnames=metric_rows[0].keys())
            writer.writeheader()
            writer.writerows(metric_rows)

    elapsed = time.perf_counter() - started
    metadata = {
        "source": str(args.video.resolve()),
        "start_s": args.start,
        "requested_duration_s": args.duration,
        "processed_frames": frame_index,
        "source_fps": source_fps,
        "source_size": [source_width, source_height],
        "model": args.model,
        "model_path": str(model_path),
        "model_input_size": [model_width, model_height],
        "inference_fps": args.inference_fps,
        "depth_tau_s": args.depth_tau,
        "range_tau_s": args.range_tau,
        "upsample": args.upsample,
        "separation": args.separation,
        "convergence": args.convergence,
        "output_size": [args.output_width, args.output_height],
        "depth_updates": update_index,
        "desktop_cpu_inference_ms_mean": (
            float(np.mean(inference_times)) if inference_times else None
        ),
        "desktop_cpu_inference_ms_p95": (
            float(np.percentile(inference_times, 95)) if inference_times else None
        ),
        "wall_time_s": elapsed,
        "outputs": {
            "depth": str(depth_path),
            "dmap_warp": str(warp_path),
            "review": str(review_path),
            "metrics": str(metrics_path),
        },
        "faithfulness_notes": [
            "Source downscale uses OpenCV INTER_AREA as a CPU approximation of the headset 4x4 box shader.",
            "Inference runs synchronously at ideal 20 Hz source timestamps; variable on-device completion latency is not yet simulated.",
            "Robust range, range EMA, depth EMA, uint8 upload, selected 480x270 conversion, and held maps match the production design.",
            "Desktop CPU timing is not representative of Quest GPU timing.",
        ],
    }
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n")

    print(f"Done in {elapsed:.1f}s")
    print(f"Depth:  {depth_path}")
    print(f"Warp:   {warp_path}")
    print(f"Review: {review_path}")
    print(f"Metrics: {metrics_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
