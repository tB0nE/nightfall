//! Draws the tray icon so no image files ship: Nightfall's mark (an N whose
//! right stroke is a planet) as a white glyph on transparent, like other
//! monochrome tray icons. The planet is reduced to its lit edge, a crescent
//! beside the N's diagonal.

/// The sizes offered to the tray, which picks the closest.
pub const SIZES: [i32; 4] = [22, 32, 48, 64];

/// Samples per pixel along each axis, for anti-aliased edges.
const SUPERSAMPLE: i32 = 4;

/// ARGB32 pixels, as the StatusNotifierItem spec wants.
pub fn nightfall_alpha(size: i32) -> Vec<u8> {
    let outline = n_outline();
    let samples = size * SUPERSAMPLE;
    let mut alpha_data = Vec::with_capacity((size * size) as usize);
    for y in 0..size {
        for x in 0..size {
            let mut hits = 0;
            for sy in 0..SUPERSAMPLE {
                for sx in 0..SUPERSAMPLE {
                    let p = (
                        ((x * SUPERSAMPLE + sx) as f32 + 0.5) / samples as f32,
                        ((y * SUPERSAMPLE + sy) as f32 + 0.5) / samples as f32,
                    );
                    if inside(&outline, p) || in_crescent(p) {
                        hits += 1;
                    }
                }
            }
            let alpha = (hits * 255 / (SUPERSAMPLE * SUPERSAMPLE)) as u8;
            alpha_data.push(alpha);
        }
    }
    alpha_data
}

#[cfg(target_os = "linux")]
pub fn nightfall_icon(size: i32) -> ksni::Icon {
    let alpha = nightfall_alpha(size);
    let mut data = Vec::with_capacity(alpha.len() * 4);
    for a in alpha { data.extend_from_slice(&[a, 255, 255, 255]); }
    ksni::Icon { width: size, height: size, data }
}

/// The N in unit coordinates (y down): the stem, a rounded top, and the
/// diagonal sweeping down to the bottom right.
fn n_outline() -> Vec<(f32, f32)> {
    let mut points = vec![(0.16, 0.90)];
    points.extend(bezier((0.16, 0.20), (0.16, 0.10), (0.26, 0.11), 8));
    points.extend(bezier((0.26, 0.11), (0.40, 0.13), (0.80, 0.90), 24));
    points.extend([(0.65, 0.90), (0.28, 0.36), (0.28, 0.90)]);
    points
}

/// The planet's lit edge: inside the planet, outside a slightly offset copy
/// of it, and clear of the N's diagonal by a gap.
fn in_crescent(p: (f32, f32)) -> bool {
    let in_circle = |c: (f32, f32), r: f32| (p.0 - c.0).powi(2) + (p.1 - c.1).powi(2) < r * r;
    let (a, b) = ((0.40, 0.30), (0.80, 0.90));
    let side = ((b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0)) / (b.0 - a.0).hypot(b.1 - a.1);
    in_circle((0.50, 0.52), 0.37) && !in_circle((0.385, 0.50), 0.345) && side < -0.075
}

fn bezier(p0: (f32, f32), p1: (f32, f32), p2: (f32, f32), steps: usize) -> Vec<(f32, f32)> {
    (0..steps)
        .map(|i| {
            let t = i as f32 / (steps - 1) as f32;
            let u = 1.0 - t;
            (
                u * u * p0.0 + 2.0 * u * t * p1.0 + t * t * p2.0,
                u * u * p0.1 + 2.0 * u * t * p1.1 + t * t * p2.1,
            )
        })
        .collect()
}

/// Even-odd point-in-polygon test.
fn inside(polygon: &[(f32, f32)], p: (f32, f32)) -> bool {
    let mut result = false;
    for (i, &a) in polygon.iter().enumerate() {
        let b = polygon[(i + 1) % polygon.len()];
        if (a.1 > p.1) != (b.1 > p.1) && p.0 < (b.0 - a.0) * (p.1 - a.1) / (b.1 - a.1) + a.0 {
            result = !result;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn draws_a_white_glyph_on_transparent() {
        let icon = nightfall_alpha(32);
        assert_eq!(icon.len(), 32 * 32);
        let alpha = |x: usize, y: usize| icon[y * 32 + x];
        assert_eq!(alpha(7, 24), 255, "the stem");
        assert_eq!(alpha(1, 1), 0, "a corner");
        assert_eq!(alpha(26, 16), 255, "the crescent");
        assert_eq!(alpha(20, 16), 0, "between the diagonal and the crescent");
    }
}
