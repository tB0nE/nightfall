//! Depth post-processing on the GPU (`kernels/postprocess.cu`), for model
//! output that is already in GPU memory. Same result as
//! `postprocess::PostProcessor`, byte for byte, in a fraction of the time
//! (the CPU version took about 0.9 ms per 384x384 map on a Ryzen host).
//! Only the finished 8-bit map is copied back.

use std::ffi::{c_int, c_uint, c_void};
use std::ptr;
use std::time::Instant;

use crate::nvdec::{Api, CuContext, CuDevicePtr, check, launch, load_functions, primary_context};
use crate::postprocess::{DEPTH_TAU_SECONDS, PERCENTILE_CLIP, RANGE_TAU_SECONDS};

const PTX: &str = concat!(include_str!("../kernels/postprocess.ptx"), "\0");
const BINS: usize = 512;
const MINMAX_THREADS: c_uint = 1024;
const THREADS: c_uint = 256;
/// Enough blocks to fill the GPU for the histogram; each loops over pixels.
const HISTOGRAM_BLOCKS: c_uint = 160;

pub struct GpuPost {
    api: &'static Api,
    ctx: CuContext,
    pixels: usize,
    kernels: [*mut c_void; 4], // minmax, histogram, range, normalize
    range: CuDevicePtr,        // 2 floats: raw min, max
    hist: CuDevicePtr,         // BINS u32
    state: CuDevicePtr,        // 2 floats: smoothed range
    smoothed: CuDevicePtr,     // pixels floats
    out: CuDevicePtr,          // pixels bytes
    host: Vec<u8>,
    first: bool,
    last: Option<Instant>,
    /// The per-pixel smoothing's time constant; 0 turns it off.
    pub depth_tau: f32,
}

impl GpuPost {
    pub fn new(pixels: usize) -> Result<GpuPost, String> {
        let (api, ctx) = primary_context()?;
        let names = [c"depth_minmax", c"depth_histogram", c"depth_range", c"depth_normalize"];
        let kernels: [*mut c_void; 4] = load_functions(api, ctx, PTX, &names)?
            .try_into()
            .map_err(|_| "kernel lookup failed".to_string())?;
        let mut post = GpuPost {
            api,
            ctx,
            pixels,
            kernels,
            range: 0,
            hist: 0,
            state: 0,
            smoothed: 0,
            out: 0,
            host: vec![0; pixels],
            first: true,
            last: None,
            depth_tau: DEPTH_TAU_SECONDS,
        };
        // SAFETY: allocations in the pushed primary context; freed in Drop
        // (which also handles a partial failure here).
        unsafe {
            (api.cu_ctx_push)(ctx);
            let allocated = [
                (&mut post.range, 8),
                (&mut post.hist, BINS * 4),
                (&mut post.state, 8),
                (&mut post.smoothed, pixels * 4),
                (&mut post.out, pixels),
            ]
            .into_iter()
            .try_for_each(|(ptr, bytes)| check("cuMemAlloc", (api.cu_mem_alloc)(ptr, bytes)));
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
            allocated?;
        }
        Ok(post)
    }

    pub fn pixels(&self) -> usize {
        self.pixels
    }

    /// Forget the previous frames (new stream or new model).
    pub fn reset(&mut self) {
        self.first = true;
        self.last = None;
    }

    /// `raw` is the model's output in GPU memory (`pixels` floats). Returns
    /// the 8-bit depth map.
    pub fn process(&mut self, raw: CuDevicePtr, now: Instant) -> Result<Vec<u8>, String> {
        // The same timing and blend factors as PostProcessor::process.
        let dt = match self.last {
            None => DEPTH_TAU_SECONDS,
            Some(last) => now.duration_since(last).as_secs_f32().clamp(1.0 / 60.0, 1.0),
        };
        self.last = Some(now);
        let mut range_alpha = 1.0 - (-dt / RANGE_TAU_SECONDS).exp();
        let mut depth_alpha = if self.depth_tau > 0.0 { 1.0 - (-dt / self.depth_tau).exp() } else { 1.0 };
        let count = self.pixels as f32;
        let mut lo_target = (count * PERCENTILE_CLIP) as u32;
        let mut hi_target = (count * (1.0 - PERCENTILE_CLIP)) as u32;
        let mut first = c_int::from(self.first);
        self.first = false;

        let mut raw = raw;
        let mut n = self.pixels as c_int;
        let (mut range, mut hist, mut state) = (self.range, self.hist, self.state);
        let (mut smoothed, mut out) = (self.smoothed, self.out);
        macro_rules! args {
            ($($v:expr),*) => { [$((&mut $v as *mut _) as *mut c_void),*] };
        }
        let api = self.api;
        let [minmax, histogram, range_k, normalize] = self.kernels;
        let blocks = (self.pixels as c_uint).div_ceil(THREADS);
        // SAFETY: each argument list matches its kernel's signature; the
        // buffers are sized for `pixels`; the context is pushed around the
        // launches and the (synchronous) copy back.
        unsafe {
            (api.cu_ctx_push)(self.ctx);
            let result = launch(api, minmax, (1, 1), (MINMAX_THREADS, 1), &mut args!(raw, n, range, hist))
                .and_then(|()| {
                    launch(api, histogram, (HISTOGRAM_BLOCKS.min(blocks), 1), (THREADS, 1), &mut args!(raw, n, range, hist))
                })
                .and_then(|()| {
                    launch(
                        api,
                        range_k,
                        (1, 1),
                        (1, 1),
                        &mut args!(range, hist, lo_target, hi_target, first, range_alpha, state),
                    )
                })
                .and_then(|()| {
                    launch(
                        api,
                        normalize,
                        (blocks, 1),
                        (THREADS, 1),
                        &mut args!(raw, n, state, first, depth_alpha, smoothed, out),
                    )
                })
                .and_then(|()| {
                    check(
                        "cuMemcpyDtoH",
                        (api.cu_memcpy_dtoh)(self.host.as_mut_ptr().cast(), self.out, self.pixels),
                    )
                });
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
            result?;
        }
        Ok(self.host.clone())
    }
}

impl Drop for GpuPost {
    fn drop(&mut self) {
        // SAFETY: freeing our own allocations in the pushed context.
        unsafe {
            (self.api.cu_ctx_push)(self.ctx);
            for ptr in [self.range, self.hist, self.state, self.smoothed, self.out] {
                if ptr != 0 {
                    (self.api.cu_mem_free)(ptr);
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
    use crate::postprocess::PostProcessor;
    use std::time::Duration;

    /// Same raw frames, same timestamps: the GPU and CPU must agree byte for
    /// byte, including the smoothing across frames. Skipped without an
    /// NVIDIA GPU.
    #[test]
    fn matches_the_cpu_post_processing() {
        let pixels = 384 * 384;
        let mut gpu = match GpuPost::new(pixels) {
            Ok(gpu) => gpu,
            Err(err) => {
                eprintln!("skipping: no CUDA ({err})");
                return;
            }
        };
        let mut cpu = PostProcessor::default();
        let api = gpu.api;
        let mut raw_dev: CuDevicePtr = 0;
        unsafe {
            (api.cu_ctx_push)(gpu.ctx);
            check("cuMemAlloc", (api.cu_mem_alloc)(&mut raw_dev, pixels * 4)).unwrap();
        }
        let t0 = Instant::now();
        let mut seed = 12345u32;
        let mut rand = move || {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            seed as f32 / u32::MAX as f32
        };
        for frame in 0..8 {
            // A smooth "scene" with noise, shifting each frame, plus outliers.
            let raw: Vec<f32> = (0..pixels)
                .map(|i| {
                    let (x, y) = ((i % 384) as f32, (i / 384) as f32);
                    let mut v = 0.5 + 0.4 * ((x + frame as f32 * 7.0) / 60.0).sin() * (y / 90.0).cos() + 0.05 * rand();
                    if i % 9973 == 0 {
                        v += 40.0 * (rand() - 0.5);
                    }
                    v * 3.7
                })
                .collect();
            unsafe {
                check("cuMemcpyHtoD", (api.cu_memcpy_htod)(raw_dev, raw.as_ptr().cast(), pixels * 4)).unwrap();
            }
            // Irregular frame spacing exercises the time-based blend.
            let now = t0 + Duration::from_millis([0, 14, 28, 35, 49, 80, 94, 300][frame]);
            let expected = cpu.process(&raw, now);
            let got = gpu.process(raw_dev, now).unwrap();
            let diff = expected.iter().zip(&got).filter(|(a, b)| a != b).count();
            assert_eq!(diff, 0, "frame {frame}: {diff} of {pixels} bytes differ");
        }
        unsafe {
            (api.cu_mem_free)(raw_dev);
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
        }
    }
}
