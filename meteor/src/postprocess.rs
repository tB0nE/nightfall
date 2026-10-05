//! Turns a raw model output into an 8-bit depth map, the same way the Quest
//! does for ZipDepth, so a host map looks like a local one.
//!
//! Port of `DepthEstimator.postProcess()` (android/.../DepthEstimator.java)
//! as used by the ZipDepth GPU variants: 2nd-98th percentile range from a
//! 512-bin histogram, the range and the per-pixel values smoothed with time
//! constants (alpha = 1 - exp(-dt / tau)), no dilate/blur. Keep the two in
//! step when either changes.

use std::time::Instant;

const HIST_BINS: usize = 512;
pub const PERCENTILE_CLIP: f32 = 0.02;
/// ZipDepth's tau pair: `ZIPDEPTH_DEPTH_TAU_SECONDS` and
/// `ZIPDEPTH_RANGE_TAU_SECONDS` in DepthEstimator.java, used by the EdgePad
/// models the Quest runs.
pub const DEPTH_TAU_SECONDS: f32 = 0.055;
pub const RANGE_TAU_SECONDS: f32 = 0.308;

pub struct PostProcessor {
    smooth_lo: f32,
    smooth_hi: f32,
    smoothed: Vec<f32>,
    last: Option<Instant>,
    pub depth_tau: f32,
    pub range_tau: f32,
}

impl Default for PostProcessor {
    fn default() -> Self {
        PostProcessor {
            smooth_lo: 0.0,
            smooth_hi: 1.0,
            smoothed: Vec::new(),
            last: None,
            depth_tau: DEPTH_TAU_SECONDS,
            range_tau: RANGE_TAU_SECONDS,
        }
    }
}

impl PostProcessor {
    /// Forget the previous frames (new stream or new model).
    pub fn reset(&mut self) {
        self.smoothed.clear();
        self.last = None;
    }

    pub fn process(&mut self, raw: &[f32], now: Instant) -> Vec<u8> {
        // dt clamped to [1/60, 1] s, as on the Quest.
        let dt = match self.last {
            None => self.depth_tau,
            Some(last) => now.duration_since(last).as_secs_f32().clamp(1.0 / 60.0, 1.0),
        };
        let first = self.last.is_none() || self.smoothed.len() != raw.len();
        self.last = Some(now);

        let (lo, hi) = robust_range(raw, PERCENTILE_CLIP);
        if first {
            self.smooth_lo = lo;
            self.smooth_hi = hi;
        } else {
            let alpha = 1.0 - (-dt / self.range_tau).exp();
            self.smooth_lo += alpha * (lo - self.smooth_lo);
            self.smooth_hi += alpha * (hi - self.smooth_hi);
        }
        let scale = 1.0 / (self.smooth_hi - self.smooth_lo).max(1e-6);
        let lo = self.smooth_lo;

        if first {
            self.smoothed = raw.iter().map(|v| ((v - lo) * scale).clamp(0.0, 1.0)).collect();
        } else {
            let alpha = 1.0 - (-dt / self.depth_tau).exp();
            for (prev, v) in self.smoothed.iter_mut().zip(raw) {
                let normalized = ((v - lo) * scale).clamp(0.0, 1.0);
                *prev += alpha * (normalized - *prev);
            }
        }
        // Java casts with (byte)(v * 255f), which truncates.
        self.smoothed.iter().map(|v| (v.clamp(0.0, 1.0) * 255.0) as u8).collect()
    }
}

/// The `clip` and `1 - clip` percentiles of `v`, via a histogram.
pub fn robust_range(v: &[f32], clip: f32) -> (f32, f32) {
    let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
    for &x in v {
        lo = lo.min(x);
        hi = hi.max(x);
    }
    if v.is_empty() || hi <= lo {
        let lo = if lo.is_finite() { lo } else { 0.0 };
        return (lo, lo + 1.0);
    }
    let mut hist = [0u32; HIST_BINS];
    let bin_scale = HIST_BINS as f32 / (hi - lo);
    for &x in v {
        let b = (((x - lo) * bin_scale) as usize).min(HIST_BINS - 1);
        hist[b] += 1;
    }
    let count = v.len() as f32;
    let percentile_bin = |target: u32| {
        let mut acc = 0;
        hist.iter()
            .position(|&n| {
                acc += n;
                acc >= target
            })
            .unwrap_or(HIST_BINS - 1)
    };
    let lo_bin = percentile_bin((count * clip) as u32);
    let hi_bin = percentile_bin((count * (1.0 - clip)) as u32);
    let bin_width = (hi - lo) / HIST_BINS as f32;
    let robust_lo = lo + lo_bin as f32 * bin_width;
    let mut robust_hi = lo + (hi_bin + 1) as f32 * bin_width;
    if robust_hi <= robust_lo {
        robust_hi = robust_lo + 1e-3;
    }
    (robust_lo, robust_hi)
}

/// Halves an 8-bit map in each direction (2x2 average); odd edges are dropped.
#[allow(dead_code)] // the depth side channel (Phase 2) sends half-size maps
pub fn half_size(map: &[u8], width: usize, height: usize) -> (Vec<u8>, usize, usize) {
    let (w, h) = (width / 2, height / 2);
    let mut out = Vec::with_capacity(w * h);
    for y in 0..h {
        let top = &map[2 * y * width..];
        let bottom = &map[(2 * y + 1) * width..];
        for x in 0..w {
            let sum = u16::from(top[2 * x]) + u16::from(top[2 * x + 1]) + u16::from(bottom[2 * x]) + u16::from(bottom[2 * x + 1]);
            out.push(((sum + 2) / 4) as u8);
        }
    }
    (out, w, h)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn robust_range_ignores_outliers() {
        // 1000 values 0..1 plus two far outliers.
        let mut v: Vec<f32> = (0..1000).map(|i| i as f32 / 1000.0).collect();
        v.push(-50.0);
        v.push(80.0);
        let (lo, hi) = robust_range(&v, PERCENTILE_CLIP);
        // Bins are 130/512 wide here, so the result is coarse but must not
        // reach the outliers.
        assert!(lo > -1.0 && lo <= 0.02, "lo {lo}");
        assert!((0.98..1.5).contains(&hi), "hi {hi}");
        assert_eq!(robust_range(&[3.0, 3.0], 0.02), (3.0, 4.0));
    }

    #[test]
    fn first_frame_is_a_plain_stretch_then_smooths() {
        let mut p = PostProcessor::default();
        let t0 = Instant::now();
        let ramp: Vec<f32> = (0..=255).map(|i| i as f32).collect();
        let first = p.process(&ramp, t0);
        assert!(first[0] == 0 && first[255] == 255);
        assert!(first[128].abs_diff(128) <= 6);

        // A sudden jump only moves part of the way after one 60 Hz frame...
        let inverted: Vec<f32> = ramp.iter().rev().copied().collect();
        let second = p.process(&inverted, t0 + Duration::from_millis(16));
        assert!(second[0] > 30 && second[0] < 225, "{}", second[0]);
        // ...and converges after a few tau.
        let later = p.process(&inverted, t0 + Duration::from_millis(500));
        assert!(later[0] >= 250);
    }

    #[test]
    fn halves_maps() {
        let map = [0u8, 10, 20, 30, 100, 110, 120, 130];
        let (out, w, h) = half_size(&map, 4, 2);
        assert_eq!((w, h), (2, 1));
        assert_eq!(out, vec![55, 75]);
    }
}
