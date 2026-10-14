//! Optional spatial depth refinement, after temporal smoothing (never fed
//! back into its history). CPU reference for the Bounded-2 / Bounded-4 trials.
//! Pixel-centred, clamp-to-edge bilinear sampling matches the local shaders.

fn smooth(lo: f32, hi: f32, x: f32) -> f32 {
    let t = ((x - lo) / (hi - lo)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn sample<const C: usize>(data: &[f32], w: usize, h: usize, x: f32, y: f32) -> [f32; C] {
    let x = x.clamp(0.0, (w - 1) as f32);
    let y = y.clamp(0.0, (h - 1) as f32);
    let (ix, iy) = (x as usize, y as usize);
    let (jx, jy) = ((ix + 1).min(w - 1), (iy + 1).min(h - 1));
    let (fx, fy) = (x - ix as f32, y - iy as f32);
    std::array::from_fn(|c| {
        let a = data[(iy * w + ix) * C + c];
        let b = data[(iy * w + jx) * C + c];
        let d = data[(jy * w + ix) * C + c];
        let e = data[(jy * w + jx) * C + c];
        (a + (b - a) * fx) * (1.0 - fy) + (d + (e - d) * fx) * fy
    })
}

/// Keeps the wire map at the model's native output resolution. Unlike the
/// offline trial, the guide is model-input RGB, not full-resolution video.
pub fn process(
    data: &[u8],
    size: (usize, usize),
    rgb: &[u8],
    guide_size: (usize, usize),
    cleanup: bool,
) -> Vec<u8> {
    let (w, h) = size;
    let (gw, gh) = guide_size;
    if w == 0 || h == 0 || gw == 0 || gh == 0 || data.len() != w * h || rgb.len() != gw * gh * 3 {
        return data.to_vec();
    }
    let depth: Vec<f32> = data.iter().map(|&v| v as f32 / 255.0).collect();
    let guide: Vec<f32> = rgb.iter().map(|&v| v as f32 / 255.0).collect();
    let d = |x, y| sample::<1>(&depth, w, h, x, y)[0];
    let colour = |x: f32, y: f32| {
        sample::<3>(
            &guide,
            gw,
            gh,
            (x + 0.5) * gw as f32 / w as f32 - 0.5,
            (y + 0.5) * gh as f32 / h as f32 - 0.5,
        )
    };
    let mut aligned = Vec::with_capacity(data.len());
    for y in 0..h {
        for x in 0..w {
            let (x, y) = (x as f32, y as f32);
            let base = d(x, y);
            let (gx, gy) = (d(x + 1.0, y) - d(x - 1.0, y), d(x, y + 1.0) - d(x, y - 1.0));
            let mag = gx.hypot(gy);
            if mag < 0.015 {
                aligned.push(base);
                continue;
            }
            let (nx, ny) = (gx / mag, gy / mag);
            let (mut sum, mut weight) = (0.0, 0.0);
            for i in -4..=4 {
                let s = i as f32 * 0.5;
                let (qx, qy) = (x + nx * s, y + ny * s);
                let score =
                    (d(qx + nx * 0.5, qy + ny * 0.5) - d(qx - nx * 0.5, qy - ny * 0.5)).abs();
                let v = score.powi(4);
                sum += s * v;
                weight += v;
            }
            let position = sum / weight.max(1e-12);
            let (mut sum, mut weight, mut peak) = (0.0, 0.0, 0.0f32);
            for i in -4..=4 {
                let s = i as f32 * 0.5;
                let (qx, qy) = (x + nx * s, y + ny * s);
                let (xp, xm) = (colour(qx + 0.5, qy), colour(qx - 0.5, qy));
                let (yp, ym) = (colour(qx, qy + 0.5), colour(qx, qy - 0.5));
                let (mut energy, mut along) = (0.0, 0.0);
                for c in 0..3 {
                    let (cx, cy) = (xp[c] - xm[c], yp[c] - ym[c]);
                    energy += cx * cx + cy * cy;
                    along += (cx * nx + cy * ny).powi(2);
                }
                let orientation = smooth(0.65, 0.9, along / energy.max(1e-8));
                let contrast = along.sqrt();
                let v = along * along * orientation * (-((s - position) / 2.0).powi(2) * 2.0).exp();
                sum += s * v;
                weight += v;
                peak = peak.max(contrast * orientation);
            }
            let value = if weight < 1e-10 {
                base
            } else {
                let confidence = smooth(0.015, 0.06, mag) * smooth(0.06, 0.2, peak);
                let shift = (position - sum / weight).clamp(-2.0, 2.0) * confidence * 0.75;
                d(x + nx * shift, y + ny * shift)
            };
            // Bounded-2's intermediate in the offline trial is RGBA8.
            aligned.push((value * 255.0).round() / 255.0);
        }
    }
    if cleanup {
        contour(&aligned, w, h)
    } else {
        aligned.iter().map(|v| (v * 255.0).round() as u8).collect()
    }
}

fn contour(depth: &[f32], w: usize, h: usize) -> Vec<u8> {
    let d = |x, y| sample::<1>(depth, w, h, x, y)[0];
    let mut out = Vec::with_capacity(depth.len());
    for y in 0..h {
        for x in 0..w {
            let (x, y) = (x as f32, y as f32);
            let centre = d(x, y);
            let [tl, tc, tr, ml, mr, bl, bc, br] = [
                (-1., -1.),
                (0., -1.),
                (1., -1.),
                (-1., 0.),
                (1., 0.),
                (-1., 1.),
                (0., 1.),
                (1., 1.),
            ]
            .map(|(dx, dy)| d(x + dx, y + dy));
            let gx = (tr + 2.0 * mr + br - tl - 2.0 * ml - bl) * 0.25;
            let gy = (bl + 2.0 * bc + br - tl - 2.0 * tc - tr) * 0.25;
            let mag = gx.hypot(gy);
            let mut value = centre;
            if mag >= 0.015 {
                let (nx, ny) = (gx / mag, gy / mag);
                let neighbours = [tl, tc, tr, ml, mr, bl, bc, br];
                let lo = neighbours.into_iter().fold(f32::INFINITY, f32::min);
                let hi = neighbours.into_iter().fold(f32::NEG_INFINITY, f32::max);
                let guard = smooth(
                    0.4,
                    0.85,
                    (d(x + nx * 2.0, y + ny * 2.0) - d(x - nx * 2.0, y - ny * 2.0)).abs()
                        / (hi - lo).max(1e-5),
                );
                let mut sum = centre * 6.0;
                for i in [-2i32, -1, 1, 2] {
                    sum += d(x - ny * i as f32, y + nx * i as f32)
                        * if i.abs() == 1 { 4.0 } else { 1.0 };
                }
                let limit = 0.08f32.min(mag * 0.4);
                value = (centre
                    + smooth(0.015, 0.06, mag)
                        * guard
                        * 0.85
                        * (sum / 16.0 - centre).clamp(-limit, limit))
                .clamp(lo, hi);
            }
            out.push((value.clamp(0.0, 1.0) * 255.0).round() as u8);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flat_depth_and_missing_colour_do_not_create_edges() {
        for cleanup in [false, true] {
            let rgb = vec![128; 16 * 12 * 3];
            assert_eq!(
                process(&vec![123; 16 * 12], (16, 12), &rgb, (16, 12), cleanup),
                vec![123; 16 * 12]
            );
            let depth: Vec<u8> = (0..192)
                .map(|i| if i % 16 < 8 { 30 } else { 220 })
                .collect();
            assert_eq!(process(&depth, (16, 12), &rgb, (16, 12), cleanup), depth);
        }
    }

    #[test]
    fn bounded_alignment_moves_misaligned_edge_toward_colour() {
        let (w, h) = (32, 16);
        let depth: Vec<u8> = (0..w * h)
            .map(|i| if i % w < 17 { 30 } else { 220 })
            .collect();
        let rgb: Vec<u8> = (0..w * h * 3)
            .map(|i| if i / 3 % w < 16 { 0 } else { 255 })
            .collect();
        for cleanup in [false, true] {
            let out = process(&depth, (w, h), &rgb, (w, h), cleanup);
            assert!(out[8 * w + 16] > depth[8 * w + 16]);
            assert_eq!(out[8 * w + 8], 30);
            assert_eq!(out[8 * w + 24], 220);
        }
    }

    #[test]
    fn cleanup_reduces_wobble_without_erasing_thin_lines() {
        let (w, h) = (40, 32);
        let depth: Vec<f32> = (0..w * h)
            .map(|i| if i % w >= 20 + (i / w % 2) { 0.9 } else { 0.1 })
            .collect();
        let out = contour(&depth, w, h);
        let roughness = |values: &[f32]| -> f32 {
            (2..h - 2)
                .map(|y| (values[y * w + 20] - values[(y - 1) * w + 20]).abs())
                .sum()
        };
        let result: Vec<f32> = out.iter().map(|&v| v as f32 / 255.0).collect();
        assert!(roughness(&result) < roughness(&depth));
        let thin: Vec<f32> = (0..w * h)
            .map(|i| if i % w == 20 { 1.0 } else { 0.0 })
            .collect();
        assert_eq!(
            contour(&thin, w, h),
            thin.iter().map(|v| (v * 255.0) as u8).collect::<Vec<_>>()
        );
    }

    #[test]
    fn guide_resize_and_invalid_inputs_are_safe() {
        assert_eq!(process(&[], (0, 0), &[], (0, 0), true), Vec::<u8>::new());
        assert_eq!(process(&[12], (1, 1), &[], (0, 0), true), [12]);
        assert_eq!(process(&[12], (1, 1), &[100; 12], (2, 2), true), [12]);
    }

    #[test]
    #[ignore = "manual release-mode timing, not a hardware-independent assertion"]
    fn benchmark_refinement() {
        for (w, h) in [(384, 384), (512, 288), (518, 294)] {
            let depth: Vec<u8> = (0..w * h)
                .map(|i| (((i % w) as f32 * 0.11).sin() * 90.0 + 127.0) as u8)
                .collect();
            let rgb: Vec<u8> = depth.iter().flat_map(|&v| [v, v, v]).collect();
            for cleanup in [false, true] {
                let start = std::time::Instant::now();
                for _ in 0..5 {
                    std::hint::black_box(process(&depth, (w, h), &rgb, (w, h), cleanup));
                }
                eprintln!(
                    "{w}x{h} cleanup={cleanup}: {:.2} ms/frame (CPU synthetic, excludes guide download)",
                    start.elapsed().as_secs_f64() * 200.0
                );
            }
        }
    }
}
