//! Optional FP32 Vulkan image processing; never silently initializes CUDA.
use std::{
    ffi::{CStr, c_char, c_int, c_void},
    path::PathBuf,
    sync::{Arc, OnceLock},
    time::Instant,
};
type Create = unsafe extern "C" fn(c_int, c_int, c_int, *mut c_char, usize) -> *mut c_void;
type Post = unsafe extern "C" fn(
    *mut c_void,
    *const f32,
    *const u8,
    c_int,
    c_int,
    c_int,
    f32,
    f32,
    c_int,
    c_int,
    *mut u8,
    *mut c_char,
    usize,
) -> c_int;
pub(crate) type ResidentDestroy = unsafe extern "C" fn(*mut c_void);
pub(crate) type ResidentDownload =
    unsafe extern "C" fn(*mut c_void, *mut f32, *mut c_char, usize) -> c_int;
type ResidentPost = unsafe extern "C" fn(
    *mut c_void,
    *mut c_void,
    *const u8,
    c_int,
    c_int,
    c_int,
    f32,
    f32,
    c_int,
    c_int,
    *mut u8,
    *mut c_char,
    usize,
) -> c_int;
struct Api {
    _library: libloading::Library,
    create: Create,
    post: Post,
    resident_post: ResidentPost,
    resident_edge: unsafe extern "C" fn(
        *mut c_void,
        *mut c_void,
        *const u8,
        *mut *mut c_void,
        *mut c_char,
        usize,
    ) -> c_int,
    depth_destroy: ResidentDestroy,
    depth_download: ResidentDownload,
    nv12: unsafe extern "C" fn(
        *mut c_void,
        *const u8,
        c_int,
        c_int,
        c_int,
        c_int,
        *mut u8,
        *mut c_char,
        usize,
    ) -> c_int,
    destroy: unsafe extern "C" fn(*mut c_void),
}
fn api() -> Result<Arc<Api>, String> {
    static API: OnceLock<Result<Arc<Api>, String>> = OnceLock::new();
    API.get_or_init(|| {
        let name = if cfg!(windows) {
            "meteor_vda_vulkan.dll"
        } else {
            "libmeteor_vda_vulkan.so"
        };
        let mut paths = Vec::new();
        if let Some(exe) = std::env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|p| p.to_owned()))
        {
            paths.extend([exe.join(name), exe.join("../lib").join(name)]);
        }
        if let Some(path) = option_env!("METEOR_VDA_VULKAN_LIBRARY") {
            paths.push(PathBuf::from(path));
        }
        paths.push(name.into());
        let mut errors = Vec::new();
        for path in paths {
            // SAFETY: versioned C ABI provided by our optional processing runtime.
            let loaded: Result<Api, String> = unsafe {
                (|| {
                    let library = libloading::Library::new(&path).map_err(|e| e.to_string())?;
                    let abi = library
                        .get::<unsafe extern "C" fn() -> u32>(b"meteor_processing_abi\0")
                        .map_err(|e| e.to_string())?;
                    if abi() != 2 {
                        return Err("Incompatible Vulkan processing ABI".into());
                    }
                    let create = *library
                        .get(b"meteor_processing_create\0")
                        .map_err(|e| e.to_string())?;
                    let post = *library
                        .get(b"meteor_processing_post\0")
                        .map_err(|e| e.to_string())?;
                    let resident_post = *library
                        .get(b"meteor_processing_post_resident\0")
                        .map_err(|e| e.to_string())?;
                    let resident_edge = *library
                        .get(b"meteor_processing_edge\0")
                        .map_err(|e| e.to_string())?;
                    let depth_destroy = *library
                        .get(b"meteor_processing_depth_destroy\0")
                        .map_err(|e| e.to_string())?;
                    let depth_download = *library
                        .get(b"meteor_processing_depth_download\0")
                        .map_err(|e| e.to_string())?;
                    let nv12 = *library
                        .get(b"meteor_processing_nv12\0")
                        .map_err(|e| e.to_string())?;
                    let destroy = *library
                        .get(b"meteor_processing_destroy\0")
                        .map_err(|e| e.to_string())?;
                    Ok(Api {
                        _library: library,
                        create,
                        post,
                        resident_post,
                        resident_edge,
                        depth_destroy,
                        depth_download,
                        nv12,
                        destroy,
                    })
                })()
            };
            match loaded {
                Ok(api) => return Ok(Arc::new(api)),
                Err(e) => errors.push(format!("{}: {e}", path.display())),
            }
        }
        Err(format!(
            "Vulkan processing unavailable: {}",
            errors.join("; ")
        ))
    })
    .clone()
}
pub struct Processor {
    api: Arc<Api>,
    handle: *mut c_void,
    pub gpu: String,
    pub size: (usize, usize),
    last: Option<Instant>,
}
/// Immutable Vulkan output. Its native allocator and library outlive the model
/// and processor, so retaining/dropping it across a model switch is safe.
pub(crate) struct ResidentDepth {
    handle: *mut c_void,
    _owner: Arc<dyn Send + Sync>,
    destroy: ResidentDestroy,
    download: ResidentDownload,
    size: (usize, usize),
    gpu: String,
}
unsafe impl Send for ResidentDepth {}
impl Drop for ResidentDepth {
    fn drop(&mut self) {
        unsafe { (self.destroy)(self.handle) }
    }
}
impl ResidentDepth {
    /// SAFETY: handle is an owned native MeteorResidentDepth with these ABI functions.
    pub(crate) unsafe fn from_native(
        handle: *mut c_void,
        owner: Arc<dyn Send + Sync>,
        destroy: ResidentDestroy,
        download: ResidentDownload,
        size: (usize, usize),
        gpu: String,
    ) -> Self {
        Self {
            handle,
            _owner: owner,
            destroy,
            download,
            size,
            gpu,
        }
    }
    /// Explicit fallback/reference only; production success downloads packed bytes.
    pub(crate) fn download(&self) -> Result<Vec<f32>, String> {
        let mut raw = vec![0.; self.size.0 * self.size.1];
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.download)(
                self.handle,
                raw.as_mut_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 {
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        if raw.iter().any(|v| !v.is_finite()) {
            return Err("Nonfinite resident depth readback".into());
        }
        Ok(raw)
    }
}
// SAFETY: exclusive ownership; calls require &mut self and synchronize Vulkan.
unsafe impl Send for Processor {}
impl Drop for Processor {
    fn drop(&mut self) {
        unsafe { (self.api.destroy)(self.handle) }
    }
}
impl Processor {
    pub fn new(gpu: Option<&str>, size: (usize, usize)) -> Result<Self, String> {
        if size.0 == 0 || size.1 == 0 || size.0 > 8192 || size.1 > 8192 {
            return Err("Invalid Vulkan processing dimensions".into());
        }
        let api = api()?;
        let name = crate::ncnn::resolved_gpu_name(gpu)?;
        let index = crate::ncnn::gpu_index(Some(&name))?;
        let mut error = [0 as c_char; 1024];
        let handle = unsafe {
            (api.create)(
                index,
                size.0 as c_int,
                size.1 as c_int,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if handle.is_null() {
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        Ok(Self {
            api,
            handle,
            gpu: name,
            size,
            last: None,
        })
    }
    pub fn reset(&mut self) {
        self.last = None;
    }
    /// SAFETY: net belongs to the same ncnn runtime, remains live, and is used exclusively.
    pub(crate) unsafe fn infer_edge(
        &mut self,
        net: *mut c_void,
        rgb: &[u8],
    ) -> Result<ResidentDepth, String> {
        if rgb.len() != self.size.0 * self.size.1 * 3 {
            return Err("Invalid resident EdgePad RGB".into());
        }
        let mut handle = std::ptr::null_mut();
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.api.resident_edge)(
                self.handle,
                net,
                rgb.as_ptr(),
                &mut handle,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 || handle.is_null() {
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        Ok(unsafe {
            ResidentDepth::from_native(
                handle,
                self.api.clone(),
                self.api.depth_destroy,
                self.api.depth_download,
                self.size,
                self.gpu.clone(),
            )
        })
    }
    pub(crate) fn process_resident(
        &mut self,
        raw: &ResidentDepth,
        rgb: &[u8],
        guide: (usize, usize),
        now: Instant,
        depth_tau: f32,
        alignment: bool,
        cleanup: bool,
    ) -> Result<Vec<u8>, String> {
        if raw.size != self.size
            || raw.gpu != self.gpu
            || alignment
                && (guide.0 == 0
                    || guide.1 == 0
                    || guide.0 > 8192
                    || guide.1 > 8192
                    || rgb.len() != guide.0 * guide.1 * 3)
        {
            return Err("Resident depth processor/guide mismatch".into());
        }
        let first = self.last.is_none();
        let dt = self
            .last
            .and_then(|last| now.checked_duration_since(last))
            .map(|d| d.as_secs_f32().clamp(1. / 60., 1.))
            .unwrap_or(depth_tau);
        let da = if depth_tau > 0. {
            1. - (-dt / depth_tau).exp()
        } else {
            1.
        };
        let ra = 1. - (-dt / crate::postprocess::RANGE_TAU_SECONDS).exp();
        let mut output = vec![0; self.size.0 * self.size.1];
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.api.resident_post)(
                self.handle,
                raw.handle,
                rgb.as_ptr(),
                guide.0 as c_int,
                guide.1 as c_int,
                first as c_int,
                da,
                ra,
                alignment as c_int,
                cleanup as c_int,
                output.as_mut_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 {
            self.reset();
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        self.last = Some(now);
        Ok(output)
    }
    pub fn nv12(
        &mut self,
        source: &[u8],
        size: (usize, usize),
        matrix: u8,
        full: bool,
    ) -> Result<Vec<u8>, String> {
        if size.0 < 2
            || size.1 < 2
            || size.0 > 8192
            || size.1 > 8192
            || size.0 % 2 != 0
            || size.1 % 2 != 0
            || source.len() != size.0 * size.1 * 3 / 2
        {
            return Err("Invalid Vulkan NV12 input".into());
        }
        let mut output = vec![0; self.size.0 * self.size.1 * 3];
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.api.nv12)(
                self.handle,
                source.as_ptr(),
                size.0 as c_int,
                size.1 as c_int,
                matrix as c_int,
                full as c_int,
                output.as_mut_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 {
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        Ok(output)
    }
    pub fn process(
        &mut self,
        raw: &[f32],
        rgb: &[u8],
        guide: (usize, usize),
        now: Instant,
        depth_tau: f32,
        alignment: bool,
        cleanup: bool,
    ) -> Result<Vec<u8>, String> {
        if raw.len() != self.size.0 * self.size.1
            || raw.iter().any(|v| !v.is_finite())
            || alignment
                && (guide.0 == 0
                    || guide.1 == 0
                    || guide.0 > 8192
                    || guide.1 > 8192
                    || rgb.len() != guide.0 * guide.1 * 3)
        {
            return Err("Invalid Vulkan postprocessing input".into());
        }
        let first = self.last.is_none();
        let dt = self
            .last
            .and_then(|last| now.checked_duration_since(last))
            .map(|d| d.as_secs_f32().clamp(1. / 60., 1.))
            .unwrap_or(depth_tau);
        let da = if depth_tau > 0. {
            1. - (-dt / depth_tau).exp()
        } else {
            1.
        };
        let ra = 1. - (-dt / crate::postprocess::RANGE_TAU_SECONDS).exp();
        let mut output = vec![0; raw.len()];
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.api.post)(
                self.handle,
                raw.as_ptr(),
                rgb.as_ptr(),
                guide.0 as c_int,
                guide.1 as c_int,
                first as c_int,
                da,
                ra,
                alignment as c_int,
                cleanup as c_int,
                output.as_mut_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 {
            self.reset();
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        self.last = Some(now);
        Ok(output)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires Vulkan GPU and native runtime"]
    fn resident_nonfinite_recovery_and_device_guard() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        crate::ncnn::init(Some(&root.join("target/ncnn/lib/libncnn.so.1"))).unwrap();
        let gpus = crate::ncnn::gpu_names();
        assert!(!gpus.is_empty());
        for gpu in &gpus {
            let mut p = Processor::new(Some(gpu), (17, 13)).unwrap();
            type Upload = unsafe extern "C" fn(
                *mut c_void,
                *const f32,
                *mut *mut c_void,
                *mut c_char,
                usize,
            ) -> c_int;
            let upload = unsafe {
                *p.api
                    ._library
                    .get::<Upload>(b"meteor_processing_depth_upload\0")
                    .unwrap()
            };
            for invalid in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
                let mut values = vec![2.; 17 * 13];
                values[27] = invalid;
                let mut handle = std::ptr::null_mut();
                let mut error = [0 as c_char; 1024];
                assert_eq!(
                    unsafe {
                        upload(
                            p.handle,
                            values.as_ptr(),
                            &mut handle,
                            error.as_mut_ptr(),
                            error.len(),
                        )
                    },
                    0
                );
                let depth = unsafe {
                    ResidentDepth::from_native(
                        handle,
                        p.api.clone(),
                        p.api.depth_destroy,
                        p.api.depth_download,
                        p.size,
                        p.gpu.clone(),
                    )
                };
                assert!(
                    p.process_resident(&depth, &[], (0, 0), Instant::now(), 0., false, false)
                        .unwrap_err()
                        .contains("Nonfinite")
                );
                assert!(depth.download().is_err());
                assert_eq!(
                    p.process(
                        &vec![2.; 17 * 13],
                        &[],
                        (0, 0),
                        Instant::now(),
                        0.,
                        false,
                        false
                    )
                    .unwrap(),
                    vec![0; 17 * 13]
                );
                if let Some(other) = gpus.iter().find(|name| *name != gpu) {
                    let mut other = Processor::new(Some(other), p.size).unwrap();
                    assert!(
                        other
                            .process_resident(&depth, &[], (0, 0), Instant::now(), 0., false, false)
                            .unwrap_err()
                            .contains("mismatch")
                    );
                }
            }
        }
    }
    #[test]
    #[ignore = "requires Vulkan GPUs and installed EdgePad models"]
    fn resident_edge_matches_host_and_owns_lifetime() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        crate::ncnn::init(Some(&root.join("target/ncnn/lib/libncnn.so.1"))).unwrap();
        let gpus = crate::ncnn::gpu_names();
        assert!(!gpus.is_empty());
        for gpu in gpus {
            for name in [
                "zipdepth_edgepad_256",
                "zipdepth_edgepad_384",
                "zipdepth_wide_512x288",
                "zipdepth_wide_672x384",
            ] {
                let mut model = crate::ncnn::NcnnModel::load_on_gpu(
                    &crate::config::default_models_dir().join(format!("{name}.ncnn.param")),
                    false,
                    Some(&gpu),
                )
                .unwrap();
                let size = (model.width, model.height);
                let mut processor = Processor::new(Some(&gpu), size).unwrap();
                let mut last = None;
                let mut last_raw = Vec::new();
                let start = Instant::now();
                let mut worst = 0;
                let mut total = 0u64;
                let mut count = 0;
                for (alignment, cleanup, tau) in [
                    (false, false, 0.),
                    (true, false, 0.055),
                    (true, true, 0.055),
                ] {
                    processor.reset();
                    let mut cpu = crate::postprocess::PostProcessor::default();
                    cpu.depth_tau = tau;
                    for i in 0..8 {
                        let rgb: Vec<u8> = (0..size.0 * size.1 * 3)
                            .map(|j| ((j * 7 + j / (size.0 * 3) * 13 + i * 19) % 256) as u8)
                            .collect();
                        let reference = model.infer(&rgb).unwrap();
                        let depth = model.infer_resident(&rgb, &mut processor).unwrap();
                        let raw = depth.download().unwrap();
                        let range = (reference.iter().copied().fold(f32::NEG_INFINITY, f32::max)
                            - reference.iter().copied().fold(f32::INFINITY, f32::min))
                        .max(1e-6);
                        let mae = raw
                            .iter()
                            .zip(&reference)
                            .map(|(a, b)| (a - b).abs() / range)
                            .sum::<f32>()
                            / raw.len() as f32;
                        assert!(mae < 0.0001, "{gpu} {name} resident inference MAE {mae}");
                        let now = start + std::time::Duration::from_millis(i as u64 * 50);
                        let mut expected = cpu.process(&reference, now);
                        if alignment {
                            expected =
                                crate::refinement::process(&expected, size, &rgb, size, cleanup);
                        }
                        let actual = processor
                            .process_resident(&depth, &rgb, size, now, tau, alignment, cleanup)
                            .unwrap();
                        for (a, b) in actual.iter().zip(&expected) {
                            let d = a.abs_diff(*b);
                            worst = worst.max(d);
                            total += u64::from(d);
                            count += 1;
                        }
                        last = Some(depth);
                        last_raw = raw;
                    }
                }
                let mean = total as f64 / count as f64;
                eprintln!("Resident {gpu} {name}: max byte delta {worst}, mean {mean:.6}");
                assert!(worst <= 3 && mean < 0.03);
                let retained = last.unwrap();
                drop(model);
                drop(processor);
                assert_eq!(retained.download().unwrap(), last_raw);
                // A different processor can consume the retained tensor after both
                // producing objects are gone, on the same device and at the same size.
                let mut processor = Processor::new(Some(&gpu), size).unwrap();
                let rgb = vec![128; size.0 * size.1 * 3];
                assert!(
                    processor
                        .process_resident(&retained, &rgb, (1, 1), start, 0., true, true)
                        .is_err()
                );
                let expected =
                    crate::postprocess::PostProcessor::default().process(&last_raw, start);
                assert_eq!(
                    processor
                        .process_resident(&retained, &[], (0, 0), start, 0., false, false)
                        .unwrap(),
                    expected
                );
            }
        }
    }
    #[test]
    #[ignore = "requires Vulkan GPU and processing runtime"]
    fn vulkan_preparation_matches_cpu() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        crate::ncnn::init(Some(&root.join("target/ncnn/lib/libncnn.so.1"))).unwrap();
        let gpus = crate::ncnn::gpu_names();
        assert!(!gpus.is_empty());
        for gpu in gpus {
            for (sw, sh, w, h) in [
                (32, 18, 19, 11),
                (128, 72, 64, 36),
                (1280, 720, 518, 294),
                (1280, 720, 1280, 720),
            ] {
                let mut p = Processor::new(Some(&gpu), (w, h)).unwrap();
                let nv12: Vec<u8> = (0..sw * sh * 3 / 2)
                    .map(|i| ((i * 17 + i / sw * 3) % 256) as u8)
                    .collect();
                let reference = crate::nvdec::Nv12Footprint::new((sw, sh), (w, h));
                for matrix in [1, 5, 9] {
                    for full in [false, true] {
                        let expected = reference.convert(&nv12, matrix, full);
                        let got = p.nv12(&nv12, (sw, sh), matrix, full).unwrap();
                        let errors: Vec<_> = got
                            .iter()
                            .zip(&expected)
                            .map(|(a, b)| a.abs_diff(*b))
                            .collect();
                        let worst = *errors.iter().max().unwrap();
                        let mean =
                            errors.iter().map(|v| *v as f64).sum::<f64>() / errors.len() as f64;
                        eprintln!(
                            "{gpu} NV12 {sw}x{sh}->{w}x{h} matrix={matrix} full={full}: max={worst} mean={mean:.6}"
                        );
                        assert!(worst <= 1 && mean < 0.02);
                    }
                }
            }
            for (w, h) in [(392, 224), (518, 294)] {
                let p = Processor::new(Some(&gpu), (w, h)).unwrap();
                let (sw, sh) = (1280, 720);
                let rgb: Vec<u8> = (0..sw * sh * 3)
                    .map(|i| ((i * 7 + i / sw * 13) % 256) as u8)
                    .collect();
                let mut planar = vec![0.; sw * sh * 3];
                for (i, pixel) in rgb.chunks_exact(3).enumerate() {
                    for c in 0..3 {
                        planar[c * sw * sh + i] = pixel[c] as f32 / 255.;
                    }
                }
                let expected = crate::vda::resize_normalize_size(&planar, sw, sh, w, h);
                type Prepare = unsafe extern "C" fn(
                    *mut c_void,
                    *const c_void,
                    c_int,
                    c_int,
                    c_int,
                    *mut f32,
                    *mut c_char,
                    usize,
                ) -> c_int;
                let prepare = unsafe {
                    *p.api
                        ._library
                        .get::<Prepare>(b"meteor_processing_prepare\0")
                        .unwrap()
                };
                for format in [0, 1] {
                    let mut output = vec![0.; w * h * 3];
                    let mut error = [0 as c_char; 1024];
                    let source = if format == 0 {
                        rgb.as_ptr().cast()
                    } else {
                        planar.as_ptr().cast()
                    };
                    assert_eq!(
                        unsafe {
                            prepare(
                                p.handle,
                                source,
                                sw as c_int,
                                sh as c_int,
                                format,
                                output.as_mut_ptr(),
                                error.as_mut_ptr(),
                                error.len(),
                            )
                        },
                        0,
                        "{}",
                        unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy()
                    );
                    let worst = output
                        .iter()
                        .zip(&expected)
                        .map(|(a, b)| (a - b).abs())
                        .fold(0., f32::max);
                    eprintln!("{gpu} resize {sw}x{sh}->{w}x{h} format={format}: max={worst}");
                    assert!(worst < 1e-4);
                }
                type Blur = unsafe extern "C" fn(
                    *mut c_void,
                    *const f32,
                    f32,
                    *mut f32,
                    *mut c_char,
                    usize,
                ) -> c_int;
                let blur = unsafe {
                    *p.api
                        ._library
                        .get::<Blur>(b"meteor_processing_blur\0")
                        .unwrap()
                };
                let raw: Vec<f32> = (0..w * h)
                    .map(|i| ((i % w) as f32 * 0.07).sin() * 3. + (i / w) as f32 * 0.01)
                    .collect();
                for sigma in [0., 0.75, 0.85, 1.] {
                    let expected = crate::vda::blur_size(&raw, sigma, w, h);
                    let mut output = vec![0.; w * h];
                    let mut error = [0 as c_char; 1024];
                    assert_eq!(
                        unsafe {
                            blur(
                                p.handle,
                                raw.as_ptr(),
                                sigma,
                                output.as_mut_ptr(),
                                error.as_mut_ptr(),
                                error.len(),
                            )
                        },
                        0,
                        "{}",
                        unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy()
                    );
                    let worst = output
                        .iter()
                        .zip(&expected)
                        .map(|(a, b)| (a - b).abs())
                        .fold(0., f32::max);
                    eprintln!("{gpu} blur {w}x{h} sigma={sigma}: max={worst}");
                    assert!(worst < 1e-4);
                }
            }
        }
    }
    #[test]
    #[ignore = "requires hardware Vulkan and optional native runtime"]
    fn vulkan_post_matches_cpu() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        crate::ncnn::init(Some(&root.join("target/ncnn/lib/libncnn.so.1"))).unwrap();
        let mut cases = 0;
        for gpu in crate::ncnn::gpu_names() {
            for (w, h, gw, gh) in [
                (1, 1, 1, 1),
                (37, 29, 71, 43),
                (256, 256, 256, 256),
                (518, 294, 1280, 720),
            ] {
                let mut processor = Processor::new(Some(&gpu), (w, h)).unwrap();
                let start = Instant::now();
                let rgb: Vec<u8> = (0..gw * gh * 3)
                    .map(|i| ((i * 13 + i / gw * 7) % 256) as u8)
                    .collect();
                for (align, cleanup, tau) in [
                    (false, false, 0.),
                    (false, false, 0.055),
                    (true, false, 0.055),
                    (true, true, 0.055),
                ] {
                    processor.reset();
                    let mut cpu = crate::postprocess::PostProcessor::default();
                    cpu.depth_tau = tau;
                    let mut worst = 0;
                    let mut total = 0u64;
                    let mut changed = 0usize;
                    for frame in 0..12 {
                        let raw: Vec<f32> = (0..w * h)
                            .map(|i| {
                                if frame == 0 {
                                    2.
                                } else {
                                    ((i % w) as f32 * 0.11 + frame as f32 * 0.02).sin() * 2.
                                        + ((i / w) as f32 * 0.07).cos()
                                }
                            })
                            .collect();
                        let now = start + std::time::Duration::from_millis(frame * 41);
                        let mut expected = cpu.process(&raw, now);
                        if align {
                            expected = crate::refinement::process(
                                &expected,
                                (w, h),
                                &rgb,
                                (gw, gh),
                                cleanup,
                            );
                        }
                        let got = processor
                            .process(&raw, &rgb, (gw, gh), now, tau, align, cleanup)
                            .unwrap();
                        for (a, b) in got.iter().zip(&expected) {
                            let d = a.abs_diff(*b);
                            worst = worst.max(d);
                            total += u64::from(d);
                            changed += usize::from(d != 0);
                        }
                    }
                    let mean = total as f64 / (w * h * 12) as f64;
                    eprintln!(
                        "{gpu} {w}x{h} guide={gw}x{gh} align={align} cleanup={cleanup} tau={tau}: max={worst} mean={mean:.6} changed={changed}"
                    );
                    assert!(
                        worst <= 3 && mean < 0.03,
                        "Vulkan processing differs: max {worst} mean {mean}"
                    );
                    cases += 1;
                }
                processor.reset();
                let expected =
                    crate::postprocess::PostProcessor::default().process(&vec![42.; w * h], start);
                assert_eq!(
                    processor
                        .process(&vec![42.; w * h], &[], (0, 0), start, 0., false, false)
                        .unwrap(),
                    expected
                );
                assert!(
                    processor
                        .process(&[f32::NAN], &[], (0, 0), start, 0., false, false)
                        .is_err()
                );
            }
        }
        assert!(cases > 0, "No hardware GPUs tested");
    }
}
