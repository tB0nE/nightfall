//! Opt-in same-frame depth fusion. CPU reference for the CUDA spike.
use serde::{Deserialize, Serialize};
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Blend {
    #[default]
    Feather,
    LowFrequency,
    Multiscale,
    Protected,
}
impl Blend {
    pub const ALL: [Self; 4] = [
        Self::Feather,
        Self::LowFrequency,
        Self::Multiscale,
        Self::Protected,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::Feather => "Affine + feather",
            Self::LowFrequency => "Low-frequency correction",
            Self::Multiscale => "Multiscale",
            Self::Protected => "Low-frequency + multiscale + disagreement protection",
        }
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub enabled: bool,
    pub square_tiles: bool,
    pub detail: Option<String>,
    pub blend: Blend,
}
pub const SIZE: (usize, usize) = (960, 540);
/// Pixel-centred bilinear RGB crop/resample. Coordinates refer to the decoded frame.
pub fn rgb_crop(
    src: &[u8],
    size: (usize, usize),
    crop: (usize, usize, usize, usize),
    output: (usize, usize),
) -> Vec<u8> {
    let (sw, sh) = size;
    let (x, y, w, h) = crop;
    let (dw, dh) = output;
    let mut out = vec![0; dw * dh * 3];
    for j in 0..dh {
        for i in 0..dw {
            let fx = (x as f32 + (i as f32 + 0.5) * w as f32 / dw as f32 - 0.5)
                .clamp(0., (sw - 1) as f32);
            let fy = (y as f32 + (j as f32 + 0.5) * h as f32 / dh as f32 - 0.5)
                .clamp(0., (sh - 1) as f32);
            let ix = fx as usize;
            let iy = fy as usize;
            let tx = fx - ix as f32;
            let ty = fy - iy as f32;
            for c in 0..3 {
                let at = |xx, yy| src[(yy * sw + xx) * 3 + c] as f32;
                let a = at(ix, iy) * (1. - tx) + at((ix + 1).min(sw - 1), iy) * tx;
                let b = at(ix, (iy + 1).min(sh - 1)) * (1. - tx)
                    + at((ix + 1).min(sw - 1), (iy + 1).min(sh - 1)) * tx;
                out[(j * dw + i) * 3 + c] = (a * (1. - ty) + b * ty).round() as u8;
            }
        }
    }
    out
}
pub fn resize(src: &[f32], size: (usize, usize), out: (usize, usize)) -> Vec<f32> {
    let (w, h) = size;
    let (ow, oh) = out;
    let mut result = vec![0.; ow * oh];
    for y in 0..oh {
        for x in 0..ow {
            let fx = ((x as f32 + 0.5) * w as f32 / ow as f32 - 0.5).clamp(0., (w - 1) as f32);
            let fy = ((y as f32 + 0.5) * h as f32 / oh as f32 - 0.5).clamp(0., (h - 1) as f32);
            let ix = fx as usize;
            let iy = fy as usize;
            let tx = fx - ix as f32;
            let ty = fy - iy as f32;
            let a = src[iy * w + ix] * (1. - tx) + src[iy * w + (ix + 1).min(w - 1)] * tx;
            let b = src[(iy + 1).min(h - 1) * w + ix] * (1. - tx)
                + src[(iy + 1).min(h - 1) * w + (ix + 1).min(w - 1)] * tx;
            result[y * ow + x] = a * (1. - ty) + b * ty;
        }
    }
    result
}
fn normalize(src: &[f32]) -> Vec<f32> {
    let (lo, hi) = crate::postprocess::robust_range(src, 0.02);
    src.iter()
        .map(|v| ((v - lo) / (hi - lo).max(1e-6)).clamp(0., 1.))
        .collect()
}
/// Input to the shared CPU/CUDA blend: normalized background, aligned delta, mask.
pub struct Prepared {
    pub base: Vec<f32>,
    pub delta: Vec<f32>,
    pub weight: Vec<f32>,
    pub size: (usize, usize),
}
pub fn prepare(
    background: &[f32],
    bs: (usize, usize),
    detail: &[f32],
    ds: (usize, usize),
    size: (usize, usize),
) -> Result<Prepared, String> {
    let (w, h) = size;
    if w < 16
        || h < 16
        || w > 1920
        || h > 1080
        || bs.0 == 0
        || bs.1 == 0
        || ds.0 == 0
        || ds.1 == 0
        || background.len() != bs.0 * bs.1
        || detail.len() != ds.0 * ds.1
        || background.iter().chain(detail).any(|v| !v.is_finite())
    {
        return Err("Invalid fusion dimensions/depth".into());
    }
    let base = resize(&normalize(background), bs, size);
    let (cw, ch) = (w / 2, h / 2);
    let (ox, oy) = (w / 4, h / 4);
    let centre = resize(&normalize(detail), ds, (cw, ch));
    let feather = w as f32 * 0.05;
    let mut samples = Vec::new();
    for y in (0..ch).step_by(2) {
        for x in (0..cw).step_by(2) {
            let d = x.min(y).min(cw - 1 - x).min(ch - 1 - y) as f32;
            if d >= feather * 0.25 && d <= feather * 1.25 {
                samples.push((
                    centre[y * cw + x] as f64,
                    base[(oy + y) * w + ox + x] as f64,
                ));
            }
        }
    }
    let mut keep = vec![true; samples.len()];
    let (mut scale, mut offset) = (1., 0.);
    for _ in 0..5 {
        let (mut n, mut sx, mut sy, mut xx, mut xy) = (0., 0., 0., 0., 0.);
        for (&(x, y), &k) in samples.iter().zip(&keep) {
            if k {
                n += 1.;
                sx += x;
                sy += y;
                xx += x * x;
                xy += x * y;
            }
        }
        if n < 8. {
            return Err("Insufficient fusion overlap".into());
        }
        let denom = xx - sx * sx / n;
        // Constant crop: preserve its mean without manufacturing a depth slope.
        scale = if denom > 1e-10 {
            (xy - sx * sy / n) / denom
        } else {
            1.
        };
        offset = (sy - scale * sx) / n;
        let mut errors: Vec<f64> = samples
            .iter()
            .map(|(x, y)| (x * scale + offset - y).abs())
            .collect();
        errors.sort_by(f64::total_cmp);
        let limit = errors[(errors.len() * 85 / 100).min(errors.len() - 1)];
        for (k, (x, y)) in keep.iter_mut().zip(&samples) {
            *k = (x * scale + offset - y).abs() <= limit;
        }
    }
    if !scale.is_finite() || !offset.is_finite() || scale <= 0. {
        return Err("Depth predictions disagree: invalid affine fit".into());
    }
    let mut delta = vec![0.; w * h];
    let mut weight = delta.clone();
    for y in 0..ch {
        for x in 0..cw {
            let idx = (oy + y) * w + ox + x;
            let d = x.min(y).min(cw - 1 - x).min(ch - 1 - y) as f32;
            let t = (d / feather).clamp(0., 1.);
            weight[idx] = t * t * (3. - 2. * t);
            delta[idx] = centre[y * cw + x] * scale as f32 + offset as f32 - base[idx];
        }
    }
    Ok(Prepared {
        base,
        delta,
        weight,
        size,
    })
}
/// Separable Gaussian, clamp-to-edge. Also used to verify GPU output numerically.
pub fn blur(src: &[f32], size: (usize, usize), sigma: f32) -> Vec<f32> {
    let (w, h) = size;
    let radius = (sigma * 3.).ceil() as isize;
    let weights: Vec<_> = (-radius..=radius)
        .map(|k| (-0.5 * (k as f32 / sigma).powi(2)).exp())
        .collect();
    let norm: f32 = weights.iter().sum();
    let mut tmp = vec![0.; src.len()];
    let mut out = tmp.clone();
    for y in 0..h {
        for x in 0..w {
            for (k, weight) in (-radius..=radius).zip(&weights) {
                tmp[y * w + x] +=
                    src[y * w + (x as isize + k).clamp(0, w as isize - 1) as usize] * weight / norm;
            }
        }
    }
    for y in 0..h {
        for x in 0..w {
            for (k, weight) in (-radius..=radius).zip(&weights) {
                out[y * w + x] +=
                    tmp[(y as isize + k).clamp(0, h as isize - 1) as usize * w + x] * weight / norm;
            }
        }
    }
    out
}
pub fn reference(p: &Prepared, mode: Blend) -> Vec<f32> {
    let n = p.base.len();
    let sigma = 16. * p.size.0 as f32 / 960.;
    let mut delta = p.delta.clone();
    let mut weight = p.weight.clone();
    if matches!(mode, Blend::LowFrequency | Blend::Protected) {
        let coarse = blur(&delta, p.size, sigma);
        let coverage = blur(&p.weight, p.size, sigma);
        let weighted: Vec<_> = p.delta.iter().zip(&p.weight).map(|(d, w)| d * w).collect();
        let weighted = blur(&weighted, p.size, sigma);
        for i in 0..n {
            delta[i] -= if coverage[i] > 0.01 {
                weighted[i] / coverage[i]
            } else {
                coarse[i]
            };
        }
    }
    if mode == Blend::Protected {
        let (w, h) = p.size;
        for y in 0..h {
            for x in 0..w {
                let i = y * w + x;
                let gx =
                    (delta[y * w + (x + 1).min(w - 1)] - delta[y * w + x.saturating_sub(1)]) * 0.5;
                let gy =
                    (delta[(y + 1).min(h - 1) * w + x] - delta[y.saturating_sub(1) * w + x]) * 0.5;
                weight[i] *= (-0.5 * (delta[i] / 0.10).powi(2)
                    - 0.5 * (gx * gx + gy * gy) / 0.025f32.powi(2))
                .exp();
            }
        }
    }
    if matches!(mode, Blend::Feather | Blend::LowFrequency) {
        return (0..n)
            .map(|i| (p.base[i] + delta[i] * weight[i]).clamp(0., 1.))
            .collect();
    }
    let d2 = blur(&delta, p.size, 2.);
    let d8 = blur(&delta, p.size, 8.);
    let d24 = blur(&delta, p.size, 24.);
    let w2 = blur(&weight, p.size, 2.);
    let w8 = blur(&weight, p.size, 8.);
    let w24 = blur(&weight, p.size, 24.);
    (0..n)
        .map(|i| {
            (p.base[i]
                + (delta[i] - d2[i]) * weight[i]
                + (d2[i] - d8[i]) * w2[i]
                + (d8[i] - d24[i]) * w8[i]
                + d24[i] * w24[i])
                .clamp(0., 1.)
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_is_off_and_roundtrips() {
        let s = Settings::default();
        assert!(!s.enabled);
        assert_eq!(
            toml::from_str::<Settings>(&toml::to_string(&s).unwrap()).unwrap(),
            s
        );
    }
    #[test]
    fn invalid_depth_is_rejected() {
        assert!(prepare(&[f32::NAN], (1, 1), &[1.], (1, 1), (32, 24)).is_err());
    }
    #[test]
    fn same_depth_is_identity_for_every_blend() {
        let data = vec![0.5; 32 * 24];
        let p = prepare(&data, (32, 24), &data, (32, 24), (32, 24)).unwrap();
        for b in Blend::ALL {
            assert!(reference(&p, b).iter().all(|x| x.abs() < 1e-5));
        }
    }
    #[test]
    fn feather_preserves_outside() {
        let p = Prepared {
            base: vec![0.4; 32 * 24],
            delta: vec![0.2; 32 * 24],
            weight: vec![0.; 32 * 24],
            size: (32, 24),
        };
        assert!(
            reference(&p, Blend::Feather)
                .iter()
                .all(|v| (*v - 0.4).abs() < 1e-6)
        );
    }
    #[test]
    fn rgb_crop_preserves_asymmetric_location() {
        let src: Vec<u8> = (0..8 * 4)
            .flat_map(|i| [(i % 8) as u8, (i / 8) as u8, 0])
            .collect();
        assert_eq!(rgb_crop(&src, (8, 4), (2, 1, 4, 2), (4, 2))[..3], [2, 1, 0]);
    }
}

/// Two square predictions covering the left/right edges of the same source.
/// Fit only their common image coordinates, then feather across that overlap.
pub const TILE_DISAGREEMENT: &str = "Square tile depths disagree: invalid positive affine fit";
pub fn stitch_square(left:&[f32],right:&[f32],source:(usize,usize),output:(usize,usize))->Result<Vec<u8>,String>{
    let (sw,sh)=source;let (w,h)=output;
    if left.len()!=392*392 || right.len()!=392*392 || left.iter().chain(right).any(|v|!v.is_finite()) || sh==0 || sw<sh || sw>=2*sh || w<16 || h<16 {
        return Err("Invalid square tile shapes/source/depth".into());
    }
    let cw=(sh*w+sw/2)/sw;
    let ox=w-cw;let overlap=cw-ox;
    if overlap<8{return Err("Insufficient square tile overlap".into());}
    let a=resize(&normalize(left),(392,392),(cw,h));
    let b=resize(&normalize(right),(392,392),(cw,h));
    let mut samples=Vec::new();
    for y in (0..h).step_by(2){for x in (0..overlap).step_by(2){samples.push((b[y*cw+x]as f64,a[y*cw+ox+x]as f64));}}
    let mut keep=vec![true;samples.len()];let(mut scale,mut offset)=(1.,0.);
    for _ in 0..5{
        let(mut n,mut sx,mut sy,mut xx,mut xy)=(0.,0.,0.,0.,0.);
        for (&(x,y),&k)in samples.iter().zip(&keep){if k{n+=1.;sx+=x;sy+=y;xx+=x*x;xy+=x*y;}}
        if n<8.{return Err("Insufficient tile fit samples".into());}
        let denom=xx-sx*sx/n;
        scale=if denom>1e-10{(xy-sx*sy/n)/denom}else{1.};offset=(sy-scale*sx)/n;
        let mut errors:Vec<f64>=samples.iter().map(|(x,y)|(x*scale+offset-y).abs()).collect();
        let rank=errors.len()*85/100;let threshold=*errors.select_nth_unstable_by(rank,f64::total_cmp).1;
        for(k,(x,y))in keep.iter_mut().zip(&samples){*k=(x*scale+offset-y).abs()<=threshold;}
    }
    if !scale.is_finite()||!offset.is_finite()||scale<=0.{return Err(TILE_DISAGREEMENT.into());}
    let mut result=vec![0.;w*h];
    for y in 0..h{for x in 0..w{
        result[y*w+x]=if x<ox{a[y*cw+x]}else if x>=cw{b[y*cw+x-ox]*scale as f32+offset as f32}else{
            let t=(x-ox)as f32/(overlap-1)as f32;let t=t*t*(3.-2.*t);
            a[y*cw+x]*(1.-t)+(b[y*cw+x-ox]*scale as f32+offset as f32)*t
        };
    }}
    Ok(normalize(&result).iter().map(|v|(v*255.).round()as u8).collect())
}

#[cfg(test)]
mod square_tests{
    use super::*;
    #[test]
    fn overlapping_global_ramp_stays_monotonic(){
        let map=|start:f32| (0..392*392).map(|i|start+(i%392)as f32/391.*1080.).collect::<Vec<_>>();
        let out=stitch_square(&map(0.),&map(840.),(1920,1080),(960,540)).unwrap();
        assert_eq!(out.len(),960*540);
        for row in out.chunks_exact(960){assert!(row.windows(2).all(|v|v[1]>=v[0]));assert!(row[900]>row[60]+150);}
    }
    #[test]
    fn rejects_invalid_tiles(){
        assert!(stitch_square(&[],&[],(1920,1080),(960,540)).is_err());
        let a=vec![0.;392*392];let mut b=a.clone();b[5]=f32::NAN;
        assert!(stitch_square(&a,&b,(1920,1080),(960,540)).is_err());
        assert!(stitch_square(&a,&a,(2160,1080),(960,540)).is_err());
        assert_eq!(stitch_square(&a,&a,(1920,1080),(960,540)).unwrap().len(),960*540);
    }
}
