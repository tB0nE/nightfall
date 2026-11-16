//! CUDA fusion and resident VDA crop/normalization/overlap preparation.
use crate::depth_fusion::{Blend, Prepared};
use crate::nvdec::{Api, CuContext, CuDevicePtr, check, launch, load_functions, primary_context};
use std::{ffi::c_void, ptr, sync::Mutex};
const PTX: &str = concat!(include_str!("../kernels/fusion.ptx"), "\0");
static REFINEMENT_KERNELS: Mutex<Option<[usize; 2]>> = Mutex::new(None);
static RANGE_KERNELS: Mutex<Option<[usize; 3]>> = Mutex::new(None);
static KERNELS: Mutex<Option<[usize; 20]>> = Mutex::new(None);
pub struct GpuFusion {
    api: &'static Api,
    ctx: CuContext,
    kernels: [*mut c_void; 20],
    ranges: [*mut c_void; 3],
    buffers: [CuDevicePtr; 24],
    size: (usize, usize),
    filters: [(i32, f32); 4],
}
impl GpuFusion {
    pub fn new(size: (usize, usize)) -> Result<Self, String> {
        if size.0 == 0 || size.1 == 0 || size.0 > 1920 || size.1 > 1080 {
            return Err("Invalid GPU fusion size".into());
        }
        let (api, ctx) = primary_context()?;
        let kernels = {
            let mut cache = KERNELS.lock().map_err(|_| "Fusion kernel lock poisoned")?;
            if cache.is_none() {
                let k = load_functions(
                    api,
                    ctx,
                    PTX,
                    &[
                        c"fusion_blur",
                        c"fusion_product",
                        c"fusion_correct",
                        c"fusion_protect",
                        c"fusion_finish",
                        c"fusion_resample",
                        c"fusion_crop_planar",
                        c"fusion_fit",
                        c"fusion_prepare_delta",
                        c"fusion_quantize",
                        c"fusion_fit_samples",
                        c"fusion_fit_moments",
                        c"fusion_fit_solve",
                        c"fusion_fit_errors",
                        c"fusion_fit_radix_init",
                        c"fusion_fit_radix_hist",
                        c"fusion_fit_radix_select",
                        c"fusion_blur_cached",
                        c"fusion_quantize_checked",
                        c"fusion_copy_checked",
                    ],
                )?;
                *cache = Some(
                    k.into_iter()
                        .map(|p| p as usize)
                        .collect::<Vec<_>>()
                        .try_into()
                        .map_err(|_| "Fusion kernel count mismatch")?,
                );
            }
            cache.unwrap().map(|v| v as *mut c_void)
        };
        let sigmas: [f32; 4] = [2., 8., 24., 16. * size.0 as f32 / 960.];
        let coefficients: Vec<Vec<f32>> = sigmas
            .iter()
            .map(|sigma| {
                let r = (sigma * 3.).ceil() as i32;
                (-r..=r)
                    .map(|k| (-0.5 * (k as f32 / sigma).powi(2)).exp())
                    .collect()
            })
            .collect();
        let filters =
            std::array::from_fn(|i| ((sigmas[i] * 3.).ceil() as i32, coefficients[i].iter().sum()));
        let mut result = Self {
            api,
            ctx,
            kernels,
            ranges: {
                const RANGE_PTX: &str = concat!(include_str!("../kernels/postprocess.ptx"), "\0");
                let mut cache = RANGE_KERNELS
                    .lock()
                    .map_err(|_| "Fusion range kernel lock poisoned")?;
                if cache.is_none() {
                    let k = load_functions(
                        api,
                        ctx,
                        RANGE_PTX,
                        &[c"depth_minmax", c"depth_histogram", c"depth_range"],
                    )?;
                    *cache = Some([k[0] as usize, k[1] as usize, k[2] as usize]);
                }
                cache.unwrap().map(|p| p as *mut c_void)
            },
            buffers: [0; 24],
            size,
            filters,
        };
        // SAFETY: instance owns every allocation, including partial failures.
        unsafe {
            check("cuCtxPushCurrent", (api.cu_ctx_push)(ctx))?;
            let r = result
                .buffers
                .iter_mut()
                .enumerate()
                .try_for_each(|(i, p)| {
                    check(
                        "cuMemAlloc",
                        (api.cu_mem_alloc)(
                            p,
                            (size.0 * size.1).max(if i == 22 { 1920*1080 } else if i == 23 { 1024 } else { 512 })
                                * 4
                                * if i == 22 { 3 } else { 1 },
                        ),
                    )
                })
                .and_then(|()| {
                    for (i, weights) in coefficients.iter().enumerate() {
                        check(
                            "upload Gaussian coefficients",
                            (api.cu_memcpy_htod)(
                                result.buffers[23] + (i * 256 * 4) as u64,
                                weights.as_ptr().cast(),
                                weights.len() * 4,
                            ),
                        )?;
                    }
                    Ok(())
                });
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
            r?;
        }
        Ok(result)
    }
    unsafe fn blur(&self, src: CuDevicePtr, out: CuDevicePtr, sigma: f32) -> Result<(), String> {
        let index = if sigma == 2. {
            0
        } else if sigma == 8. {
            1
        } else if sigma == 24. {
            2
        } else {
            3
        };
        let (mut radius, mut norm) = self.filters[index];
        let mut weights = self.buffers[23] + (index * 256 * 4) as u64;
        let (mut w, mut h) = (self.size.0 as i32, self.size.1 as i32);
        let mut src = src;
        let mut out = out;
        let mut tmp = self.buffers[15];
        let mut axis = 0i32;
        macro_rules! args {($($v:expr),*)=>{[$((&mut $v as *mut _)as *mut c_void),*]};}
        let blocks = (w as u32 * h as u32).div_ceil(256);
        unsafe {
            launch(
                self.api,
                self.kernels[17],
                (blocks, 1),
                (256, 1),
                &mut args!(src, w, h, weights, radius, norm, axis, tmp),
            )?;
            axis = 1;
            launch(
                self.api,
                self.kernels[17],
                (blocks, 1),
                (256, 1),
                &mut args!(tmp, w, h, weights, radius, norm, axis, out),
            )
        }
    }
    /// Exact error-order statistic via parallel radix selection; no host fit.
    unsafe fn fit_parallel(&self) -> Result<(), String> {
        let (mut w, mut h) = (self.size.0 as i32, self.size.1 as i32);
        let mut n = (((w / 2 + 1) / 2) * ((h / 2 + 1) / 2)) as i32;
        let mut blocks = (n as u32).div_ceil(256) as i32;
        let (mut base, mut centre, mut fit) = (self.buffers[0], self.buffers[16], self.buffers[20]);
        // These scratch buffers are dead before blend_loaded reuses them.
        let (mut samples, mut errors, mut partial, mut histogram) = (
            self.buffers[3],
            self.buffers[4],
            self.buffers[5],
            self.buffers[6],
        );
        macro_rules! args {($($v:expr),*)=>{[$((&mut $v as *mut _)as *mut c_void),*]};}
        unsafe {
            launch(
                self.api,
                self.kernels[10],
                (blocks as u32, 1),
                (256, 1),
                &mut args!(base, centre, w, h, samples, fit),
            )?;
            for iteration in 0..5 {
                launch(
                    self.api,
                    self.kernels[11],
                    (blocks as u32, 1),
                    (256, 1),
                    &mut args!(samples, fit, n, partial),
                )?;
                launch(
                    self.api,
                    self.kernels[12],
                    (1, 1),
                    (1, 1),
                    &mut args!(partial, blocks, fit),
                )?;
                if iteration == 4 {
                    break;
                } // Last iteration needs no unused trim.
                launch(
                    self.api,
                    self.kernels[13],
                    (blocks as u32, 1),
                    (256, 1),
                    &mut args!(samples, fit, n, errors, partial),
                )?;
                launch(
                    self.api,
                    self.kernels[14],
                    (1, 1),
                    (1, 1),
                    &mut args!(partial, blocks, fit),
                )?;
                for _ in 0..8 {
                    launch(
                        self.api,
                        self.kernels[15],
                        (blocks as u32, 1),
                        (256, 1),
                        &mut args!(errors, fit, n, histogram),
                    )?;
                    launch(
                        self.api,
                        self.kernels[16],
                        (1, 1),
                        (256, 1),
                        &mut args!(histogram, blocks, fit),
                    )?;
                }
            }
            Ok(())
        }
    }
    unsafe fn blend_loaded(&self, mode: Blend) -> Result<CuDevicePtr, String> {
        let n = self.size.0 * self.size.1;
        let api = self.api;
        macro_rules! args {($($v:expr),*)=>{[$((&mut $v as *mut _)as *mut c_void),*]};}
        unsafe {
            let mut count = n as i32;
            let blocks = (n as u32).div_ceil(256);
            let mut base = self.buffers[0];
            let mut delta = self.buffers[1];
            let mut weight = self.buffers[2];
            if matches!(mode, Blend::LowFrequency | Blend::Protected) {
                let mut product = self.buffers[3];
                launch(
                    api,
                    self.kernels[1],
                    (blocks, 1),
                    (256, 1),
                    &mut args!(delta, weight, count, product),
                )?;
                let mut coarse = self.buffers[4];
                let mut weighted = self.buffers[5];
                let mut coverage = self.buffers[6];
                let sigma = 16. * self.size.0 as f32 / 960.;
                self.blur(delta, coarse, sigma)?;
                self.blur(product, weighted, sigma)?;
                self.blur(weight, coverage, sigma)?;
                let mut corrected = self.buffers[7];
                launch(
                    api,
                    self.kernels[2],
                    (blocks, 1),
                    (256, 1),
                    &mut args!(delta, coarse, weighted, coverage, count, corrected),
                )?;
                delta = corrected;
            }
            if mode == Blend::Protected {
                let (mut w, mut h) = (self.size.0 as i32, self.size.1 as i32);
                let mut protected = self.buffers[3];
                launch(
                    api,
                    self.kernels[3],
                    (blocks, 1),
                    (256, 1),
                    &mut args!(delta, weight, w, h, protected),
                )?;
                weight = protected;
            }
            let (mut d2, mut d8, mut d24, mut w2, mut w8, mut w24) = (
                self.buffers[8],
                self.buffers[9],
                self.buffers[10],
                self.buffers[11],
                self.buffers[12],
                self.buffers[13],
            );
            let mut multi = i32::from(matches!(mode, Blend::Multiscale | Blend::Protected));
            if multi != 0 {
                self.blur(delta, d2, 2.)?;
                self.blur(delta, d8, 8.)?;
                self.blur(delta, d24, 24.)?;
                self.blur(weight, w2, 2.)?;
                self.blur(weight, w8, 8.)?;
                self.blur(weight, w24, 24.)?;
            }
            let mut dest = self.buffers[14];
            launch(
                api,
                self.kernels[4],
                (blocks, 1),
                (256, 1),
                &mut args!(
                    base, delta, weight, d2, d8, d24, w2, w8, w24, count, multi, dest
                ),
            )?;
            Ok(dest)
        }
    }
    fn in_context<T>(&self, f: impl FnOnce() -> Result<T, String>) -> Result<T, String> {
        // SAFETY: push/pop our retained primary context, including errors.
        unsafe {
            check("cuCtxPushCurrent", (self.api.cu_ctx_push)(self.ctx))?;
            let result = f();
            let mut popped = ptr::null_mut();
            (self.api.cu_ctx_pop)(&mut popped);
            result
        }
    }
    /// The returned crop is owned by this instance, planar float RGB in 0..1.
    /// Models using it must finish before the next crop or this instance drops.
    pub fn crop_planar(
        &self,
        source: CuDevicePtr,
        size: (usize, usize),
    ) -> Result<(CuDevicePtr, (usize, usize)), String> {
        self.crop_box(source,size,(size.0/4,size.1/4,size.0/2,size.1/2))
    }
    pub fn crop_box(&self,source:CuDevicePtr,size:(usize,usize),rect:(usize,usize,usize,usize))->Result<(CuDevicePtr,(usize,usize)),String>{
        let (sw,sh)=size;let (x,y,cw,ch)=rect;let crop=(cw,ch);
        if cw==0||ch==0||x+cw>sw||y+ch>sh{return Err("Invalid crop rectangle".into());}
        if source == 0 || sw < 16 || sh < 16 || crop.0 * crop.1 > 1920*1080 {
            return Err("Invalid resident RGB crop".into());
        }
        self.in_context(|| {
            let mut src = source;
            let (mut sw, mut sh) = (sw as i32, sh as i32);
            let mut dest = self.buffers[22];
            let(mut x,mut y,mut cw,mut ch)=(x as i32,y as i32,cw as i32,ch as i32);
            macro_rules! args {($($v:expr),*)=>{[$((&mut $v as *mut _)as *mut c_void),*]};}
            // SAFETY: source is the live decoder tensor, destination holds 3 planes.
            unsafe {
                launch(
                    self.api,
                    self.kernels[6],
                    (((crop.0 * crop.1 * 3) as u32).div_ceil(256), 1),
                    (256, 1),
                    &mut args!(src, sw, sh, dest, x, y, cw, ch),
                )?;
            }
            Ok((dest, crop))
        })
    }
    unsafe fn normalize_device(
        &self,
        raw: CuDevicePtr,
        size: (usize, usize),
        target: (usize, usize),
        state: CuDevicePtr,
        dest: CuDevicePtr,
    ) -> Result<(), String> {
        let api = self.api;
        let mut raw = raw;
        let mut count = (size.0 * size.1) as i32;
        let mut range = self.buffers[17];
        let mut hist = self.buffers[18];
        let mut state = state;
        let mut lo = ((count as f32) * crate::postprocess::PERCENTILE_CLIP) as u32;
        let mut hi = ((count as f32) * (1. - crate::postprocess::PERCENTILE_CLIP)) as u32;
        let mut first = 1i32;
        let mut alpha = 1f32;
        macro_rules! args {($($v:expr),*)=>{[$((&mut $v as *mut _)as *mut c_void),*]};}
        unsafe {
            launch(
                api,
                self.ranges[0],
                (1, 1),
                (1024, 1),
                &mut args!(raw, count, range, hist),
            )?;
            launch(
                api,
                self.ranges[1],
                (((count as u32).div_ceil(256)).min(160), 1),
                (256, 1),
                &mut args!(raw, count, range, hist),
            )?;
            launch(
                api,
                self.ranges[2],
                (1, 1),
                (1, 1),
                &mut args!(range, hist, lo, hi, first, alpha, state),
            )?;
            let (mut sw, mut sh, mut w, mut h) = (
                size.0 as i32,
                size.1 as i32,
                target.0 as i32,
                target.1 as i32,
            );
            let mut dest = dest;
            launch(
                api,
                self.kernels[5],
                (((w * h) as u32).div_ceil(256), 1),
                (256, 1),
                &mut args!(raw, sw, sh, state, w, h, dest),
            )
        }
    }
    /// Resident preparation and blend. One terminal readback carries the final
    /// L8 map and a validity byte; no mid-pipeline CPU synchronization.
    pub fn process_device(
        &self,
        background: CuDevicePtr,
        bs: (usize, usize),
        detail: CuDevicePtr,
        ds: (usize, usize),
        mode: Blend,
    ) -> Result<Vec<u8>, String> {
        self.process_device_refined(background, bs, detail, ds, mode, None)
    }
    pub fn process_device_refined(
        &self,
        background: CuDevicePtr,
        bs: (usize, usize),
        detail: CuDevicePtr,
        ds: (usize, usize),
        mode: Blend,
        refinement: Option<(CuDevicePtr, (usize, usize), bool)>,
    ) -> Result<Vec<u8>, String> {
        if refinement.is_some_and(|(ptr, (w, h), _)| ptr == 0 || w == 0 || h == 0) {
            return Err("Invalid resident refinement guide".into());
        }
        if background == 0
            || detail == 0
            || bs.0 == 0
            || bs.1 == 0
            || ds.0 == 0
            || ds.1 == 0
            || bs.0 > 4096
            || bs.1 > 4096
            || ds.0 > 4096
            || ds.1 > 4096
        {
            return Err("Invalid resident depth dimensions".into());
        }
        self.in_context(|| {
            let api = self.api;
            let (w, h) = self.size;
            let mut width = w as i32;
            let mut height = h as i32;
            let mut base = self.buffers[0];
            let mut centre = self.buffers[16];
            let mut fit = self.buffers[20];
            let mut delta = self.buffers[1];
            let mut weight = self.buffers[2];
            macro_rules! args {($($v:expr),*)=>{[$((&mut $v as *mut _)as *mut c_void),*]};}
            // SAFETY: model output lifetimes are held by the caller; all fusion
            // buffers are allocated for n floats or larger, in the same context.
            unsafe {
                self.normalize_device(background, bs, (w, h), self.buffers[19], base)?;
                self.normalize_device(detail, ds, (w / 2, h / 2), self.buffers[19] + 8, centre)?;
                self.fit_parallel()?;
                launch(
                    api,
                    self.kernels[8],
                    (((w * h) as u32).div_ceil(256), 1),
                    (256, 1),
                    &mut args!(base, centre, fit, width, height, delta, weight),
                )?;
                let mut src = self.blend_loaded(mode)?;
                let mut count = (w * h) as i32;
                let mut dest = self.buffers[21];
                let blocks = (count as u32).div_ceil(256);
                if let Some((guide, guide_size, cleanup)) = refinement {
                    launch(
                        api,
                        self.kernels[9],
                        (blocks, 1),
                        (256, 1),
                        &mut args!(src, count, dest),
                    )?;
                    let kernels = {
                        let mut cache = REFINEMENT_KERNELS
                            .lock()
                            .map_err(|_| "Fusion refinement lock poisoned")?;
                        if cache.is_none() {
                            const PTX: &str =
                                concat!(include_str!("../kernels/refinement.ptx"), "\0");
                            let k = load_functions(
                                api,
                                self.ctx,
                                PTX,
                                &[c"depth_align", c"depth_contour"],
                            )?;
                            *cache = Some([k[0] as usize, k[1] as usize]);
                        }
                        cache.unwrap().map(|p| p as *mut c_void)
                    };
                    let mut guide = guide;
                    let (mut gw, mut gh) = (guide_size.0 as i32, guide_size.1 as i32);
                    let mut aligned = self.buffers[3];
                    let mut cleaned = self.buffers[4];
                    launch(
                        api,
                        kernels[0],
                        (blocks, 1),
                        (256, 1),
                        &mut args!(dest, guide, width, height, gw, gh, aligned),
                    )?;
                    if cleanup {
                        launch(
                            api,
                            kernels[1],
                            (blocks, 1),
                            (256, 1),
                            &mut args!(aligned, width, height, cleaned),
                        )?;
                    }
                    let mut ready = if cleanup { cleaned } else { aligned };
                    launch(
                        api,
                        self.kernels[19],
                        (blocks, 1),
                        (256, 1),
                        &mut args!(ready, fit, count, dest),
                    )?;
                } else {
                    launch(
                        api,
                        self.kernels[18],
                        (blocks, 1),
                        (256, 1),
                        &mut args!(src, fit, count, dest),
                    )?;
                }
                let mut out = vec![0u8; w * h + 1];
                check(
                    "cuMemcpyDtoH L8",
                    (api.cu_memcpy_dtoh)(out.as_mut_ptr().cast(), dest, out.len()),
                )?;
                if out.pop() != Some(1) {
                    return Err("Depth predictions disagree: invalid affine fit".into());
                }
                Ok(out)
            }
        })
    }
    pub fn process(&self, p: &Prepared, mode: Blend) -> Result<Vec<f32>, String> {
        let n = self.size.0 * self.size.1;
        if p.size != self.size || p.base.len() != n || p.delta.len() != n || p.weight.len() != n {
            return Err("Fusion input shape mismatch".into());
        }
        let api = self.api;
        let mut out = vec![0.; n];
        // SAFETY: kernels use bounded n-element buffers; synchronous readback
        // completes all default-stream work before this instance is reused.
        unsafe {
            check("cuCtxPushCurrent", (api.cu_ctx_push)(self.ctx))?;
            let result = (|| {
                for (idx, src) in [&p.base, &p.delta, &p.weight].into_iter().enumerate() {
                    check(
                        "cuMemcpyHtoD",
                        (api.cu_memcpy_htod)(self.buffers[idx], src.as_ptr().cast(), n * 4),
                    )?;
                }
                let dest = self.blend_loaded(mode)?;
                check(
                    "cuMemcpyDtoH",
                    (api.cu_memcpy_dtoh)(out.as_mut_ptr().cast(), dest, n * 4),
                )
            })();
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
            result?;
        }
        Ok(out)
    }
}
impl Drop for GpuFusion {
    fn drop(&mut self) {
        unsafe {
            if (self.api.cu_ctx_push)(self.ctx) != 0 {
                return;
            }
            for p in self.buffers {
                if p != 0 {
                    (self.api.cu_mem_free)(p);
                }
            }
            let mut popped = ptr::null_mut();
            (self.api.cu_ctx_pop)(&mut popped);
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cuda_matches_reference() {
        let gpu = match GpuFusion::new((64, 48)) {
            Ok(g) => g,
            Err(e) => {
                assert!(
                    std::env::var_os("METEOR_REQUIRE_FUSION_GPU").is_none(),
                    "CUDA required: {e}"
                );
                eprintln!("Skipping CUDA fusion: {e}");
                return;
            }
        };
        let p = Prepared {
            size: (64, 48),
            base: (0..64 * 48)
                .map(|i| 0.4 + (i / 64) as f32 * 0.002)
                .collect(),
            delta: (0..64 * 48)
                .map(|i| ((i % 64) as f32 * 0.3).sin() * 0.15)
                .collect(),
            weight: (0..64 * 48)
                .map(|i| if i % 64 > 12 && i % 64 < 52 { 1. } else { 0. })
                .collect(),
        };
        for mode in Blend::ALL {
            let expected = crate::depth_fusion::reference(&p, mode);
            let got = gpu.process(&p, mode).unwrap();
            let error = expected
                .iter()
                .zip(&got)
                .map(|(a, b)| (a - b).abs())
                .fold(0., f32::max);
            assert!(error < 2e-4, "{mode:?}: {error}");
        }
    }
    #[test]
    fn resident_preparation_matches_cpu() {
        let gpu = match GpuFusion::new((64, 48)) {
            Ok(g) => g,
            Err(e) => {
                assert!(
                    std::env::var_os("METEOR_REQUIRE_FUSION_GPU").is_none(),
                    "CUDA required: {e}"
                );
                eprintln!("Skipping resident fusion: {e}");
                return;
            }
        };
        let background: Vec<f32> = (0..64 * 48)
            .map(|i| 0.2 + (i % 64) as f32 * 0.01 + (i / 64) as f32 * 0.003)
            .collect();
        let detail: Vec<f32> = (0..32 * 24)
            .map(|i| {
                0.3 + (i % 32) as f32 * 0.02
                    + (i / 32) as f32 * 0.006
                    + ((i % 32) as f32 * 0.3).sin() * 0.01
            })
            .collect();
        let prepared =
            crate::depth_fusion::prepare(&background, (64, 48), &detail, (32, 24), (64, 48))
                .unwrap();
        let bp = gpu.buffers[22];
        let dp = bp + (background.len() * 4) as u64;
        gpu.in_context(|| unsafe {
            check(
                "upload test background",
                (gpu.api.cu_memcpy_htod)(bp, background.as_ptr().cast(), background.len() * 4),
            )?;
            check(
                "upload test detail",
                (gpu.api.cu_memcpy_htod)(dp, detail.as_ptr().cast(), detail.len() * 4),
            )
        })
        .unwrap();
        for mode in Blend::ALL {
            let expected = crate::depth_fusion::reference(&prepared, mode);
            let got = gpu
                .process_device(bp, (64, 48), dp, (32, 24), mode)
                .unwrap();
            let error = expected
                .iter()
                .zip(got)
                .map(|(a, b)| (a * 255. - b as f32).abs())
                .fold(0., f32::max);
            assert!(error <= 1.1, "{mode:?}: {error} levels");
        }
        // Resident final refinement must equal the previous CUDA refinement
        // path byte-for-byte, without the intermediate full-map CPU round trip.
        let rgb: Vec<f32> = (0..64 * 48 * 3)
            .map(|i| ((i * 13) % 251) as f32 / 250.)
            .collect();
        let mut guide = 0;
        gpu.in_context(|| unsafe {
            check(
                "allocate refinement guide",
                (gpu.api.cu_mem_alloc)(&mut guide, rgb.len() * 4),
            )?;
            check(
                "upload refinement guide",
                (gpu.api.cu_memcpy_htod)(guide, rgb.as_ptr().cast(), rgb.len() * 4),
            )
        })
        .unwrap();
        let plain = gpu
            .process_device(bp, (64, 48), dp, (32, 24), Blend::Protected)
            .unwrap();
        let refiner = crate::gpu_refinement::GpuRefinement::new(64 * 48).unwrap();
        for cleanup in [false, true] {
            let expected = refiner
                .process(&plain, (64, 48), guide, (64, 48), cleanup)
                .unwrap();
            let got = gpu
                .process_device_refined(
                    bp,
                    (64, 48),
                    dp,
                    (32, 24),
                    Blend::Protected,
                    Some((guide, (64, 48), cleanup)),
                )
                .unwrap();
            assert_eq!(
                got, expected,
                "Resident final refinement differs (cleanup={cleanup})"
            );
        }
        gpu.in_context(|| unsafe { check("free refinement guide", (gpu.api.cu_mem_free)(guide)) })
            .unwrap();
        // Verify crop origin/plane layout independently of the depth fit.
        let rgb: Vec<f32> = (0..16 * 16 * 3).map(|i| i as f32 / 768.).collect();
        let source = gpu.buffers[21];
        gpu.in_context(|| unsafe {
            check(
                "upload crop test",
                (gpu.api.cu_memcpy_htod)(source, rgb.as_ptr().cast(), rgb.len() * 4),
            )
        })
        .unwrap();
        let (crop, size) = gpu.crop_planar(source, (16, 16)).unwrap();
        assert_eq!(size, (8, 8));
        let mut got = vec![0f32; 8 * 8 * 3];
        gpu.in_context(|| unsafe {
            check(
                "read crop test",
                (gpu.api.cu_memcpy_dtoh)(got.as_mut_ptr().cast(), crop, got.len() * 4),
            )
        })
        .unwrap();
        for c in 0..3 {
            for y in 0..8 {
                for x in 0..8 {
                    assert_eq!(got[c * 64 + y * 8 + x], rgb[c * 256 + (y + 4) * 16 + x + 4]);
                }
            }
        }
    }
    #[test]
    fn square_crop_keeps_source_coordinates() {
        let gpu=match GpuFusion::new((32,24)){Ok(g)=>g,Err(e)=>{
            if std::env::var_os("METEOR_REQUIRE_FUSION_GPU").is_some(){panic!("{e}");}
            return;
        }};
        let rgb:Vec<f32>=(0..32*24*3).map(|i|i as f32).collect();
        let src=gpu.buffers[22];
        // Use separate guide storage: source and crop destination must not alias.
        let mut source=0;
        gpu.in_context(||unsafe{
            check("allocate crop source",(gpu.api.cu_mem_alloc)(&mut source,rgb.len()*4))?;
            check("upload crop source",(gpu.api.cu_memcpy_htod)(source,rgb.as_ptr().cast(),rgb.len()*4))
        }).unwrap();
        for x in [0,8]{
            let (dest,size)=gpu.crop_box(source,(32,24),(x,0,24,24)).unwrap();assert_eq!(size,(24,24));assert_eq!(dest,src);
            let mut got=vec![0f32;24*24*3];
            gpu.in_context(||unsafe{check("read square crop",(gpu.api.cu_memcpy_dtoh)(got.as_mut_ptr().cast(),dest,got.len()*4))}).unwrap();
            for c in 0..3{for y in 0..24{for xx in 0..24{assert_eq!(got[c*24*24+y*24+xx],rgb[c*32*24+y*32+x+xx]);}}}
        }
        assert!(gpu.crop_box(source,(32,24),(9,0,24,24)).is_err());
        gpu.in_context(||unsafe{check("free crop source",(gpu.api.cu_mem_free)(source))}).unwrap();
    }
    #[test]
    #[ignore = "explicit GPU profiling, run with --ignored --nocapture"]
    fn profile_parallel_fit() {
        let gpu = GpuFusion::new((960, 540)).expect("GPU profile requires CUDA");
        let (w, h) = gpu.size;
        let base: Vec<f32> = (0..w * h)
            .map(|i| {
                0.1 + (i % w) as f32 / w as f32 * 0.5
                    + (i / w) as f32 / h as f32 * 0.2
                    + ((i % w) as f32 * 0.037).sin() * 0.015
            })
            .collect();
        let centre: Vec<f32> = (0..w / 2 * h / 2)
            .map(|i| {
                base[(h / 4 + i / (w / 2)) * w + w / 4 + i % (w / 2)] * 1.3
                    + 0.03
                    + ((i % (w / 2)) as f32 * 0.27).sin() * 0.007
            })
            .collect();
        gpu.in_context(|| unsafe {
            check(
                "upload profile base",
                (gpu.api.cu_memcpy_htod)(gpu.buffers[0], base.as_ptr().cast(), base.len() * 4),
            )?;
            check(
                "upload profile centre",
                (gpu.api.cu_memcpy_htod)(gpu.buffers[16], centre.as_ptr().cast(), centre.len() * 4),
            )
        })
        .unwrap();
        let mut old_times = Vec::new();
        let mut new_times = Vec::new();
        for _ in 0..5 {
            gpu.in_context(|| unsafe {
                let (mut base, mut centre, mut fit) =
                    (gpu.buffers[0], gpu.buffers[16], gpu.buffers[20]);
                let (mut width, mut height) = (w as i32, h as i32);
                macro_rules! args {($($v:expr),*)=>{[$((&mut $v as *mut _)as *mut c_void),*]};}
                check("profile synchronize", (gpu.api.cu_ctx_synchronize)())?;
                let start = std::time::Instant::now();
                launch(
                    gpu.api,
                    gpu.kernels[7],
                    (1, 1),
                    (256, 1),
                    &mut args!(base, centre, width, height, fit),
                )?;
                let mut old = [0f32; 3];
                check(
                    "read old fit",
                    (gpu.api.cu_memcpy_dtoh)(old.as_mut_ptr().cast(), fit, 12),
                )?;
                old_times.push(start.elapsed().as_secs_f64() * 1000.);
                let start = std::time::Instant::now();
                gpu.fit_parallel()?;
                let mut new = [0f32; 3];
                check(
                    "read parallel fit",
                    (gpu.api.cu_memcpy_dtoh)(new.as_mut_ptr().cast(), fit, 12),
                )?;
                new_times.push(start.elapsed().as_secs_f64() * 1000.);
                assert_eq!(old[2], 1.);
                assert_eq!(new[2], 1.);
                assert!(
                    (old[0] - new[0]).abs() < 0.0001,
                    "scale: {old:?} vs {new:?}"
                );
                assert!(
                    (old[1] - new[1]).abs() < 0.0001,
                    "offset: {old:?} vs {new:?}"
                );
                Ok(())
            })
            .unwrap();
        }
        println!("Fit profile at 960x540: old_ms={old_times:?}, parallel_ms={new_times:?}");
    }
}
