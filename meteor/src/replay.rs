//! `--replay <file>`: runs a recorded elementary stream (for example one
//! written by `--dump-video`) through the host depth pipeline at its frame
//! rate, without a client. Used to test decoding, inference and timing.

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use crate::depth::{Depth, DepthFeed};
use crate::stream_info::Codec;
use crate::video_tap::Frame;

pub fn run(path: &Path, fps: u32, depth: Arc<Depth>) -> Result<(), String> {
    let codec = match path.extension().and_then(|e| e.to_str()) {
        Some("h264" | "264") => Codec::H264,
        Some("hevc" | "h265" | "265") => Codec::Hevc,
        other => return Err(format!("replay supports .h264 and .hevc files, not {other:?}")),
    };
    let data = std::fs::read(path).map_err(|err| format!("{}: {err}", path.display()))?;
    let units = split_access_units(codec, &data);
    log::info!("Replaying {} frames of {codec:?} at {fps} fps", units.len());

    // Wait for the model.
    // Without CUDA, the first model is the TensorRT engine, so the wait
    // counts from the end of the build.
    let mut started = Instant::now();
    while depth.active_model().is_none() {
        if depth.tensorrt_pending.load(Ordering::Relaxed) {
            started = Instant::now();
        }
        if !depth.available() || started.elapsed() > Duration::from_secs(60) {
            return Err(format!("host depth isn't available: {}", depth.status()));
        }
        std::thread::sleep(Duration::from_millis(50));
    }

    // Measure the backend Meteor will settle on, not CUDA during the build.
    std::thread::sleep(Duration::from_millis(200)); // the TensorRT load starts right after CUDA
    let waited = Instant::now();
    while depth.tensorrt_pending.load(Ordering::Relaxed) && waited.elapsed() < Duration::from_secs(300) {
        if waited.elapsed().as_secs().is_multiple_of(15) {
            log::info!("Waiting for the TensorRT engine build ({} s so far)", waited.elapsed().as_secs());
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    std::thread::sleep(Duration::from_millis(300)); // let the engine pick it up
    log::info!("Replay using {}", depth.status());

    // The model only runs for a depth client; stand in for one.
    depth.subscribers.fetch_add(1, Ordering::Relaxed);
    let mut feed = DepthFeed::new(depth.clone(), None);
    let interval = Duration::from_secs_f64(1.0 / f64::from(fps.max(1)));
    let start = Instant::now();
    let mut totals = Vec::new();
    // decode, handoff to the engine, model (incl. output copy), post-processing
    let mut stages: [Vec<u32>; 4] = Default::default();
    let mut last_map = 0;
    for (i, unit) in units.iter().enumerate() {
        let frame = Frame {
            epoch: 0,
            index: i as u32 + 1,
            rtp_timestamp: 0,
            idr: is_keyframe(codec, unit),
            after_loss: false,
            data: unit.to_vec(),
        };
        feed.push(&frame, Some(codec));
        if let Some(sleep) = (start + interval * (i as u32 + 1)).checked_duration_since(Instant::now()) {
            std::thread::sleep(sleep);
        }
        let maps = depth.stats.maps.load(Ordering::Relaxed);
        // The first second includes one-off CUDA and model warm-up.
        if maps != last_map
            && start.elapsed() > Duration::from_secs(1)
            && let Some(map) = depth.latest.lock().ok().and_then(|m| m.clone())
        {
            totals.push(depth.stats.total_us.load(Ordering::Relaxed));
            let us = |a: Instant, b: Instant| b.saturating_duration_since(a).as_micros() as u32;
            stages[0].push(us(map.frame_queued, map.decoded));
            stages[1].push(us(map.decoded, map.infer_start));
            stages[2].push(us(map.infer_start, map.infer_end));
            stages[3].push(us(map.infer_end, map.done));
        }
        last_map = maps;
    }
    std::thread::sleep(Duration::from_millis(300));
    let s = &depth.stats;
    totals.sort_unstable();
    let pct = |p: usize| totals.get(totals.len().saturating_sub(1) * p / 100).copied().unwrap_or(0) as f64 / 1000.0;
    log::info!(
        "Replay done: {} frames in, {} maps out, {} skipped; frame-to-map latency after warm-up: median {:.1} ms, p95 {:.1} ms, max {:.1} ms; last decode {:.1} ms, inference {:.1} ms",
        units.len(),
        s.maps.load(Ordering::Relaxed),
        s.skipped.load(Ordering::Relaxed),
        pct(50),
        pct(95),
        pct(100),
        f64::from(s.decode_us.load(Ordering::Relaxed)) / 1000.0,
        f64::from(s.infer_us.load(Ordering::Relaxed)) / 1000.0,
    );
    let median = |v: &mut Vec<u32>| {
        v.sort_unstable();
        v.get(v.len() / 2).copied().unwrap_or(0) as f64 / 1000.0
    };
    let [d, h, m, p] = &mut stages;
    log::info!(
        "Stage medians: decode {:.2} ms, handoff {:.2} ms, model {:.2} ms, post-processing {:.2} ms",
        median(d),
        median(h),
        median(m),
        median(p)
    );
    Ok(())
}

/// Splits an Annex B stream into access units: a new one starts at a
/// parameter set, delimiter or SEI that follows picture data, or at a slice
/// that is the first in its picture.
pub fn split_access_units(codec: Codec, data: &[u8]) -> Vec<&[u8]> {
    let starts = nal_starts(data);
    let mut units = Vec::new();
    let mut unit_start = None;
    let mut seen_picture = false;
    for (i, &(start, header)) in starts.iter().enumerate() {
        let Some(&nal) = data.get(header) else { break };
        let next = data.get(header + if codec == Codec::Hevc { 2 } else { 1 }).copied().unwrap_or(0);
        let (is_slice, first_slice, is_prefix) = match codec {
            Codec::Hevc => {
                let t = (nal >> 1) & 0x3F;
                (t < 32, t < 32 && next & 0x80 != 0, matches!(t, 32..=35 | 39))
            }
            _ => {
                let t = nal & 0x1F;
                (matches!(t, 1 | 5), matches!(t, 1 | 5) && next & 0x80 != 0, matches!(t, 6..=9))
            }
        };
        if seen_picture && (is_prefix || first_slice) {
            if let Some(s) = unit_start {
                units.push(&data[s..start]);
            }
            unit_start = None;
            seen_picture = false;
        }
        if unit_start.is_none() {
            unit_start = Some(start);
        }
        seen_picture |= is_slice;
        if i + 1 == starts.len()
            && let Some(s) = unit_start
        {
            units.push(&data[s..]);
        }
    }
    units
}

/// (start code offset, NAL header offset) for each NAL unit.
fn nal_starts(data: &[u8]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i + 3 <= data.len() {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            let start = if i > 0 && data[i - 1] == 0 { i - 1 } else { i };
            out.push((start, i + 3));
            i += 3;
        } else {
            i += 1;
        }
    }
    out
}

fn is_keyframe(codec: Codec, unit: &[u8]) -> bool {
    nal_starts(unit).iter().any(|&(_, h)| match (codec, unit.get(h)) {
        (Codec::Hevc, Some(n)) => matches!((n >> 1) & 0x3F, 16..=21),
        (_, Some(n)) => n & 0x1F == 5,
        _ => false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_hevc_access_units() {
        // VPS SPS PPS IDR(first) | TRAIL(first) TRAIL(not first) | AUD TRAIL(first)
        let stream: Vec<u8> = [
            &[0, 0, 0, 1, 0x40, 0x01][..],
            &[0, 0, 0, 1, 0x42, 0x01],
            &[0, 0, 0, 1, 0x44, 0x01],
            &[0, 0, 0, 1, 0x26, 0x01, 0x80],
            &[0, 0, 0, 1, 0x02, 0x01, 0x80],
            &[0, 0, 0, 1, 0x02, 0x01, 0x00],
            &[0, 0, 0, 1, 0x46, 0x01, 0x50],
            &[0, 0, 0, 1, 0x02, 0x01, 0x80],
        ]
        .concat();
        let units = split_access_units(Codec::Hevc, &stream);
        assert_eq!(units.len(), 3);
        assert_eq!(units[0].len(), 6 + 6 + 6 + 7);
        assert!(is_keyframe(Codec::Hevc, units[0]));
        assert!(!is_keyframe(Codec::Hevc, units[1]));
        assert_eq!(units[1].len(), 14);
        assert_eq!(units[2].len(), 14);
    }
}
