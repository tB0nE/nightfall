//! CUDA refinement using NVDEC's existing, unnormalized planar RGB tensor.
//! Only the small 8-bit depth map crosses the CPU/GPU boundary.
use crate::nvdec::{Api, CuContext, CuDevicePtr, check, launch, load_functions, primary_context};
use std::ffi::c_void;
use std::ptr;
use std::sync::Mutex;

const PTX: &str = concat!(include_str!("../kernels/refinement.ptx"), "\0");
// load_functions retains its module for the process lifetime. Reuse these
// handles across model-size/stream changes instead of loading another module.
// Addresses are opaque CUDA handles; the primary context is process-global.
static KERNELS: Mutex<Option<[usize; 2]>> = Mutex::new(None);

pub struct GpuRefinement {
    api: &'static Api,
    ctx: CuContext,
    kernels: [*mut c_void; 2],
    pixels: usize,
    buffers: [CuDevicePtr; 3],
}

impl GpuRefinement {
    pub fn new(pixels: usize) -> Result<Self, String> {
        let (api, ctx) = primary_context()?;
        let kernels = {
            let mut cached = KERNELS
                .lock()
                .map_err(|_| "refinement kernel lock poisoned")?;
            if cached.is_none() {
                let loaded = load_functions(api, ctx, PTX, &[c"depth_align", c"depth_contour"])?;
                *cached = Some([loaded[0] as usize, loaded[1] as usize]);
            }
            cached.unwrap().map(|p| p as *mut c_void)
        };
        let mut result = Self {
            api,
            ctx,
            kernels,
            pixels,
            buffers: [0; 3],
        };
        // SAFETY: allocations owned by this instance, including partial failure.
        unsafe {
            check("cuCtxPushCurrent", (api.cu_ctx_push)(ctx))?;
            let allocated = result
                .buffers
                .iter_mut()
                .try_for_each(|p| check("cuMemAlloc", (api.cu_mem_alloc)(p, pixels)));
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
            allocated?;
        }
        Ok(result)
    }

    pub fn process(
        &self,
        data: &[u8],
        size: (usize, usize),
        guide: CuDevicePtr,
        guide_size: (usize, usize),
        cleanup: bool,
    ) -> Result<Vec<u8>, String> {
        if size.0 * size.1 != self.pixels
            || data.len() != self.pixels
            || size.0 == 0
            || size.1 == 0
            || guide_size.0 == 0
            || guide_size.1 == 0
        {
            return Err("invalid refinement dimensions".into());
        }
        let (mut w, mut h) = (size.0 as i32, size.1 as i32);
        let (mut gw, mut gh) = (guide_size.0 as i32, guide_size.1 as i32);
        let [mut input, mut aligned, mut cleaned] = self.buffers;
        let mut guide = guide;
        let blocks = (self.pixels as u32).div_ceil(256);
        let mut out = vec![0; self.pixels];
        macro_rules! args { ($($v:expr),*) => { [$((&mut $v as *mut _) as *mut c_void),*] }; }
        let api = self.api;
        // SAFETY: buffers hold pixels bytes, guide is the live frame's RGB
        // tensor in the same primary context; synchronous copy completes work.
        unsafe {
            check("cuCtxPushCurrent", (api.cu_ctx_push)(self.ctx))?;
            let result = check(
                "cuMemcpyHtoD",
                (api.cu_memcpy_htod)(input, data.as_ptr().cast(), self.pixels),
            )
            .and_then(|()| {
                launch(
                    api,
                    self.kernels[0],
                    (blocks, 1),
                    (256, 1),
                    &mut args!(input, guide, w, h, gw, gh, aligned),
                )
            })
            .and_then(|()| {
                if cleanup {
                    launch(
                        api,
                        self.kernels[1],
                        (blocks, 1),
                        (256, 1),
                        &mut args!(aligned, w, h, cleaned),
                    )
                } else {
                    Ok(())
                }
            })
            .and_then(|()| {
                check(
                    "cuMemcpyDtoH",
                    (api.cu_memcpy_dtoh)(
                        out.as_mut_ptr().cast(),
                        if cleanup { cleaned } else { aligned },
                        self.pixels,
                    ),
                )
            });
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
            result?;
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cuda_matches_cpu_reference() {
        let gpu = match GpuRefinement::new(64 * 48) {
            Ok(gpu) => gpu,
            Err(err) => {
                eprintln!("skipping CUDA refinement: {err}");
                return;
            }
        };
        // Deliberately non-square, differently sized guide, diagonal + wavy
        // edges, and an asymmetric vertical colour gradient catch flipped Y.
        let (w, h, gw, gh) = (64, 48, 96, 72);
        let depth: Vec<u8> = (0..w * h)
            .map(|i| {
                let (x, y) = ((i % w) as f32, (i / w) as f32);
                if x > 25.0 + y * 0.3 + (y * 0.9).sin() {
                    220
                } else {
                    30
                }
            })
            .collect();
        let rgb: Vec<u8> = (0..gw * gh)
            .flat_map(|i| {
                let (x, y) = ((i % gw) as f32, (i / gw) as f32);
                let v = if x / 1.5 > 24.0 + y / 1.5 * 0.3 {
                    240
                } else {
                    10
                };
                [v, (y * 3.0) as u8, v]
            })
            .collect();
        let planar: Vec<f32> = (0..3)
            .flat_map(|c| rgb.chunks_exact(3).map(move |p| p[c] as f32 / 255.0))
            .collect();
        let api = gpu.api;
        let mut guide = 0;
        // SAFETY: test-owned planar float buffer and primary context.
        unsafe {
            check("cuCtxPushCurrent", (api.cu_ctx_push)(gpu.ctx)).unwrap();
            check(
                "cuMemAlloc",
                (api.cu_mem_alloc)(&mut guide, planar.len() * 4),
            )
            .unwrap();
            check(
                "cuMemcpyHtoD",
                (api.cu_memcpy_htod)(guide, planar.as_ptr().cast(), planar.len() * 4),
            )
            .unwrap();
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
        }
        let results: Vec<_> = [false, true]
            .into_iter()
            .map(|cleanup| {
                let cpu = crate::refinement::process(&depth, (w, h), &rgb, (gw, gh), cleanup);
                let got = gpu
                    .process(&depth, (w, h), guide, (gw, gh), cleanup)
                    .unwrap();
                cpu.iter()
                    .zip(&got)
                    .map(|(a, b)| a.abs_diff(*b))
                    .max()
                    .unwrap()
            })
            .collect();
        unsafe {
            (api.cu_ctx_push)(gpu.ctx);
            (api.cu_mem_free)(guide);
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
        }
        // Floating-point sqrt/hypot and exp may straddle one byte's rounding.
        for max_diff in results {
            assert!(max_diff <= 1, "max byte difference {max_diff}");
        }
    }

    #[test]
    #[ignore = "manual CUDA release-mode timing"]
    fn benchmark_cuda_refinement() {
        for (w, h) in [(384, 384), (512, 288), (518, 294)] {
            let gpu = GpuRefinement::new(w * h).expect("CUDA required for benchmark");
            let depth: Vec<u8> = (0..w * h)
                .map(|i| (((i % w) as f32 * 0.11).sin() * 90.0 + 127.0) as u8)
                .collect();
            let rgb: Vec<f32> = (0..3)
                .flat_map(|_| depth.iter().map(|&v| v as f32 / 255.0))
                .collect();
            let mut guide = 0;
            unsafe {
                (gpu.api.cu_ctx_push)(gpu.ctx);
                check(
                    "cuMemAlloc",
                    (gpu.api.cu_mem_alloc)(&mut guide, rgb.len() * 4),
                )
                .unwrap();
                check(
                    "cuMemcpyHtoD",
                    (gpu.api.cu_memcpy_htod)(guide, rgb.as_ptr().cast(), rgb.len() * 4),
                )
                .unwrap();
                let mut popped = ptr::null_mut();
                (gpu.api.cu_ctx_pop)(&mut popped);
            }
            for cleanup in [false, true] {
                for _ in 0..3 {
                    gpu.process(&depth, (w, h), guide, (w, h), cleanup).unwrap();
                }
                let start = std::time::Instant::now();
                for _ in 0..30 {
                    std::hint::black_box(
                        gpu.process(&depth, (w, h), guide, (w, h), cleanup).unwrap(),
                    );
                }
                eprintln!(
                    "CUDA {w}x{h} cleanup={cleanup}: {:.3}ms/frame (including map transfers)",
                    start.elapsed().as_secs_f64() * 1000.0 / 30.0
                );
            }
            unsafe {
                (gpu.api.cu_ctx_push)(gpu.ctx);
                (gpu.api.cu_mem_free)(guide);
                let mut popped = ptr::null_mut();
                (gpu.api.cu_ctx_pop)(&mut popped);
            }
        }
    }
}

impl Drop for GpuRefinement {
    fn drop(&mut self) {
        // SAFETY: frees only our buffers in their owning context.
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
