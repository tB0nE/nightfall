//! Draws the tray icon (a meteor with its tail) so no image files ship.

/// ARGB32 pixels, as the StatusNotifierItem spec wants.
pub fn meteor_icon(size: i32) -> ksni::Icon {
    let n = size as f32;
    let head = (0.36, 0.64);
    let tail_end = (0.92, 0.08);
    let head_radius = 0.2;
    let mut data = Vec::with_capacity((size * size * 4) as usize);
    for y in 0..size {
        for x in 0..size {
            let p = ((x as f32 + 0.5) / n, (y as f32 + 0.5) / n);
            // Tail: a streak that narrows and fades towards its far end.
            let (t, dist) = segment_distance(p, head, tail_end);
            let tail_width = head_radius * (1.0 - t) * 0.9;
            let tail_alpha = coverage(tail_width - dist, n) * (1.0 - t).powf(1.4);
            // Head: a hot core fading out to orange.
            let head_dist = ((p.0 - head.0).powi(2) + (p.1 - head.1).powi(2)).sqrt();
            let head_alpha = coverage(head_radius - head_dist, n);
            let heat = (1.0 - head_dist / head_radius).clamp(0.0, 1.0);

            let head_rgb = mix((255.0, 140.0, 40.0), (255.0, 250.0, 225.0), heat.powf(0.7));
            let tail_rgb = mix((255.0, 170.0, 60.0), (150.0, 90.0, 255.0), t);
            let a = head_alpha + tail_alpha * (1.0 - head_alpha);
            let rgb = if a > 0.0 {
                mix(tail_rgb, head_rgb, head_alpha / a)
            } else {
                (0.0, 0.0, 0.0)
            };
            data.extend_from_slice(&[
                (a * 255.0) as u8,
                rgb.0 as u8,
                rgb.1 as u8,
                rgb.2 as u8,
            ]);
        }
    }
    ksni::Icon { width: size, height: size, data }
}

/// How far along a->b the closest point to p is (0..1), and the distance to it.
fn segment_distance(p: (f32, f32), a: (f32, f32), b: (f32, f32)) -> (f32, f32) {
    let ab = (b.0 - a.0, b.1 - a.1);
    let ap = (p.0 - a.0, p.1 - a.1);
    let t = ((ap.0 * ab.0 + ap.1 * ab.1) / (ab.0 * ab.0 + ab.1 * ab.1)).clamp(0.0, 1.0);
    let closest = (a.0 + ab.0 * t, a.1 + ab.1 * t);
    (t, ((p.0 - closest.0).powi(2) + (p.1 - closest.1).powi(2)).sqrt())
}

/// Anti-aliased edge: 1 inside, 0 outside, a one-pixel ramp between.
fn coverage(signed_distance: f32, size: f32) -> f32 {
    (signed_distance * size + 0.5).clamp(0.0, 1.0)
}

fn mix(a: (f32, f32, f32), b: (f32, f32, f32), t: f32) -> (f32, f32, f32) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}
