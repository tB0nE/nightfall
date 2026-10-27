//! Persistent ncnn Vulkan VDA, with the same 31-sample projected history as TensorRT.
//! Model assets are checksum-verified; the optional native runtime is loaded lazily.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::{
    ffi::{CStr, CString, c_char, c_int, c_void},
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};
pub const FULL: &str = "vda_vulkan_518x294";
pub const FAST: &str = "vda_vulkan_392x224";
pub fn is_model(id: &str) -> bool {
    matches!(id, FULL | FAST)
}
pub fn size(id: &str) -> (usize, usize) {
    if id == FAST { (392, 224) } else { (518, 294) }
}
pub fn directory(root: &Path, id: &str) -> PathBuf {
    root.join(id)
}
#[derive(Deserialize)]
struct Manifest {
    schema: u32,
    width: usize,
    height: usize,
    files: std::collections::BTreeMap<String, String>,
}
pub fn present(root: &Path, id: &str) -> bool {
    is_model(id)
        && [
            "manifest.json",
            "cold.ncnn.param",
            "cold.ncnn.bin",
            "step.ncnn.param",
            "step.ncnn.bin",
        ]
        .iter()
        .all(|f| directory(root, id).join(f).is_file())
}
pub(crate) fn verify(root: &Path, id: &str) -> Result<(), String> {
    use std::io::Read;
    let path = directory(root, id);
    let manifest: Manifest = serde_json::from_slice(
        &std::fs::read(path.join("manifest.json")).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    if manifest.schema != 1 || (manifest.width, manifest.height) != size(id) {
        return Err("VDA Vulkan manifest dimensions/version mismatch".into());
    }
    for name in [
        "cold.ncnn.param",
        "cold.ncnn.bin",
        "step.ncnn.param",
        "step.ncnn.bin",
    ] {
        let expected = manifest
            .files
            .get(name)
            .ok_or_else(|| format!("VDA manifest missing {name}"))?;
        let mut file = std::fs::File::open(path.join(name)).map_err(|e| e.to_string())?;
        let mut hash = Sha256::new();
        let mut buf = vec![0; 1024 * 1024];
        loop {
            let n = file.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            hash.update(&buf[..n]);
        }
        if hash
            .finalize()
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
            != *expected
        {
            return Err(format!("VDA Vulkan checksum mismatch: {name}"));
        }
    }
    Ok(())
}
type Create =
    unsafe extern "C" fn(*const c_char, c_int, c_int, c_int, *mut c_char, usize) -> *mut c_void;
type Infer =
    unsafe extern "C" fn(*mut c_void, *const f32, *mut f32, c_int, *mut c_char, usize) -> c_int;
type Destroy = unsafe extern "C" fn(*mut c_void);
struct Api {
    _library: libloading::Library,
    create: Create,
    infer: Infer,
    infer_resident: unsafe extern "C" fn(
        *mut c_void,
        *mut *mut c_void,
        c_int,
        f32,
        *mut c_char,
        usize,
    ) -> c_int,
    depth_destroy: crate::vulkan_processing::ResidentDestroy,
    depth_download: crate::vulkan_processing::ResidentDownload,
    prepare: unsafe extern "C" fn(
        *mut c_void,
        *const c_void,
        c_int,
        c_int,
        c_int,
        *mut f32,
        *mut c_char,
        usize,
    ) -> c_int,
    infer_prepared:
        unsafe extern "C" fn(*mut c_void, *mut f32, c_int, f32, *mut c_char, usize) -> c_int,
    destroy: Destroy,
    supported: unsafe extern "C" fn(c_int) -> c_int,
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
            .and_then(|p| p.parent().map(Path::to_owned))
        {
            paths.extend([exe.join(name), exe.join("../lib").join(name)]);
        }
        if let Some(path) = option_env!("METEOR_VDA_VULKAN_LIBRARY") {
            paths.push(PathBuf::from(path));
        }
        paths.push(PathBuf::from(name));
        let mut errors = Vec::new();
        for path in paths {
            // SAFETY: this is our versioned C ABI, not ncnn's C++ ABI.
            unsafe {
                let library = match libloading::Library::new(&path) {
                    Ok(l) => l,
                    Err(e) => {
                        errors.push(e.to_string());
                        continue;
                    }
                };
                let version = *library
                    .get::<unsafe extern "C" fn() -> u32>(b"meteor_vda_abi\0")
                    .map_err(|e| e.to_string())?;
                if version() != 1 {
                    return Err("Incompatible VDA Vulkan runtime ABI".into());
                }
                let create = *library
                    .get(b"meteor_vda_create\0")
                    .map_err(|e| e.to_string())?;
                let infer = *library
                    .get(b"meteor_vda_infer\0")
                    .map_err(|e| e.to_string())?;
                let infer_resident = *library
                    .get(b"meteor_vda_infer_resident\0")
                    .map_err(|e| e.to_string())?;
                let depth_destroy = *library
                    .get(b"meteor_processing_depth_destroy\0")
                    .map_err(|e| e.to_string())?;
                let depth_download = *library
                    .get(b"meteor_processing_depth_download\0")
                    .map_err(|e| e.to_string())?;
                let prepare = *library
                    .get(b"meteor_vda_prepare\0")
                    .map_err(|e| e.to_string())?;
                let infer_prepared = *library
                    .get(b"meteor_vda_infer_prepared\0")
                    .map_err(|e| e.to_string())?;
                let destroy = *library
                    .get(b"meteor_vda_destroy\0")
                    .map_err(|e| e.to_string())?;
                let supported = *library
                    .get(b"meteor_vda_supported\0")
                    .map_err(|e| e.to_string())?;
                return Ok(Arc::new(Api {
                    _library: library,
                    create,
                    infer,
                    infer_resident,
                    depth_destroy,
                    depth_download,
                    prepare,
                    infer_prepared,
                    destroy,
                    supported,
                }));
            }
        }
        Err(format!(
            "VDA Vulkan runtime unavailable: {}",
            errors.join("; ")
        ))
    })
    .clone()
}
pub fn available() -> bool {
    api().is_ok()
}
pub fn gpu_supported(gpu: Option<&str>) -> bool {
    match (api(), crate::ncnn::gpu_index(gpu)) {
        (Ok(api), Ok(index)) => unsafe { (api.supported)(index) != 0 },
        _ => false,
    }
}
pub struct Model {
    api: Arc<Api>,
    handle: *mut c_void,
    pub id: String,
    pub gpu_name: String,
    pub width: usize,
    pub height: usize,
    pub cpu_processing: bool,
    preparation_failed: bool,
    last: Option<Instant>,
    thumb: Option<Vec<f32>>,
    reset: bool,
}
// SAFETY: each model is accessed exclusively by one inference worker. Vulkan
// permits moving its externally synchronized resources between threads.
unsafe impl Send for Model {}
impl Drop for Model {
    fn drop(&mut self) {
        unsafe { (self.api.destroy)(self.handle) }
    }
}
impl Model {
    pub fn load(root: &Path, id: &str, gpu: Option<&str>) -> Result<Self, String> {
        verify(root, id)?;
        let api = api()?;
        let gpu_name = crate::ncnn::resolved_gpu_name(gpu)?;
        let index = crate::ncnn::gpu_index(Some(&gpu_name))?;
        let (width, height) = size(id);
        let path = CString::new(
            directory(root, id)
                .to_str()
                .ok_or("VDA path is not UTF-8")?,
        )
        .map_err(|e| e.to_string())?;
        let mut error = [0 as c_char; 1024];
        let handle = unsafe {
            (api.create)(
                path.as_ptr(),
                index,
                width as c_int,
                height as c_int,
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
            id: id.into(),
            gpu_name,
            width,
            height,
            cpu_processing: false,
            preparation_failed: false,
            last: None,
            thumb: None,
            reset: true,
        })
    }
    pub fn reset(&mut self) {
        self.reset = true;
        self.last = None;
        self.thumb = None;
    }
    /// None means preparation fell back before inference; the caller can use
    /// infer_rgb once through the existing reference path for this frame.
    pub(crate) fn infer_rgb_resident(
        &mut self,
        rgb: &[u8],
        size: (usize, usize),
        timestamp: Instant,
        sigma: f32,
    ) -> Result<Option<crate::vulkan_processing::ResidentDepth>, String> {
        if self.cpu_processing || self.preparation_failed {
            return Ok(None);
        }
        if size.0 == 0
            || size.1 == 0
            || size.0 > 8192
            || size.1 > 8192
            || rgb.len() != size.0 * size.1 * 3
            || !sigma.is_finite()
            || !(0.0..=4.0).contains(&sigma)
        {
            return Err("Invalid resident VDA input".into());
        }
        let mut thumb = vec![0.; 432];
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.api.prepare)(
                self.handle,
                rgb.as_ptr().cast(),
                size.0 as c_int,
                size.1 as c_int,
                0,
                thumb.as_mut_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 {
            log::warn!(
                "Resident VDA preparation unavailable: {}; using CPU reference until model reload",
                unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy()
            );
            self.preparation_failed = true;
            return Ok(None);
        }
        let cut = self.thumb.as_ref().is_some_and(|prev| {
            prev.iter()
                .zip(&thumb)
                .map(|(a, b)| (a - b).abs())
                .sum::<f32>()
                / 432.
                > 1.
        });
        let gap = self.last.is_some_and(|last| {
            timestamp
                .checked_duration_since(last)
                .is_none_or(|g| g > Duration::from_millis(500))
        });
        let mut handle = std::ptr::null_mut();
        let code = unsafe {
            (self.api.infer_resident)(
                self.handle,
                &mut handle,
                (self.reset || cut || gap) as c_int,
                sigma,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 || handle.is_null() {
            self.reset = true;
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        self.thumb = Some(thumb);
        self.last = Some(timestamp);
        self.reset = false;
        Ok(Some(unsafe {
            crate::vulkan_processing::ResidentDepth::from_native(
                handle,
                self.api.clone(),
                self.api.depth_destroy,
                self.api.depth_download,
                (self.width, self.height),
                self.gpu_name.clone(),
            )
        }))
    }
    pub fn infer_rgb(
        &mut self,
        rgb: &[u8],
        size: (usize, usize),
        timestamp: Instant,
        sigma: f32,
    ) -> Result<Vec<f32>, String> {
        if rgb.len() != size.0 * size.1 * 3 || size.0 == 0 || size.1 == 0 {
            return Err("Invalid VDA RGB input".into());
        }
        if self.cpu_processing || self.preparation_failed {
            let plane = size.0 * size.1;
            let mut planar = vec![0.; plane * 3];
            for (i, pixel) in rgb.chunks_exact(3).enumerate() {
                for c in 0..3 {
                    planar[c * plane + i] = pixel[c] as f32 / 255.;
                }
            }
            return self.run_cpu(&planar, size, timestamp, sigma);
        }
        self.run_prepared(rgb.as_ptr().cast(), size, false, timestamp, sigma)
    }
    pub fn infer_planar(
        &mut self,
        rgb: &[f32],
        size: (usize, usize),
        timestamp: Instant,
        sigma: f32,
    ) -> Result<Vec<f32>, String> {
        if rgb.len() != size.0 * size.1 * 3
            || size.0 == 0
            || size.1 == 0
            || rgb.iter().any(|v| !v.is_finite())
        {
            return Err("Invalid VDA planar input".into());
        }
        if self.cpu_processing || self.preparation_failed {
            self.run_cpu(rgb, size, timestamp, sigma)
        } else {
            self.run_prepared(rgb.as_ptr().cast(), size, true, timestamp, sigma)
        }
    }
    fn run_cpu(
        &mut self,
        rgb: &[f32],
        size: (usize, usize),
        timestamp: Instant,
        sigma: f32,
    ) -> Result<Vec<f32>, String> {
        if size.0 > 8192 || size.1 > 8192 || !sigma.is_finite() || !(0.0..=4.0).contains(&sigma) {
            return Err("Invalid VDA CPU preparation input".into());
        }
        let normalized =
            crate::vda::resize_normalize_size(rgb, size.0, size.1, self.width, self.height);
        let mut thumb = Vec::with_capacity(432);
        for c in 0..3 {
            for y in 0..9 {
                for x in 0..16 {
                    let (x0, x1, y0, y1) = (
                        x * self.width / 16,
                        (x + 1) * self.width / 16,
                        y * self.height / 9,
                        (y + 1) * self.height / 9,
                    );
                    let mut sum = 0.;
                    for yy in y0..y1 {
                        for xx in x0..x1 {
                            sum += normalized[c * self.width * self.height + yy * self.width + xx];
                        }
                    }
                    thumb.push(sum / ((x1 - x0) * (y1 - y0)) as f32);
                }
            }
        }
        let cut = self.thumb.as_ref().is_some_and(|prev| {
            prev.iter()
                .zip(&thumb)
                .map(|(a, b)| (a - b).abs())
                .sum::<f32>()
                / 432.
                > 1.
        });
        let gap = self.last.is_some_and(|last| {
            timestamp
                .checked_duration_since(last)
                .is_none_or(|d| d > Duration::from_millis(500))
        });
        let depth = self.infer_normalized(&normalized, self.reset || cut || gap)?;
        self.thumb = Some(thumb);
        self.last = Some(timestamp);
        self.reset = false;
        Ok(crate::vda::blur_size(
            &depth,
            sigma,
            self.width,
            self.height,
        ))
    }
    fn run_prepared(
        &mut self,
        source: *const c_void,
        size: (usize, usize),
        planar: bool,
        timestamp: Instant,
        sigma: f32,
    ) -> Result<Vec<f32>, String> {
        if size.0 > 8192 || size.1 > 8192 || !sigma.is_finite() || !(0.0..=4.0).contains(&sigma) {
            return Err("Invalid VDA preparation dimensions or softening".into());
        }
        let mut thumb = vec![0.; 432];
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.api.prepare)(
                self.handle,
                source,
                size.0 as c_int,
                size.1 as c_int,
                planar as c_int,
                thumb.as_mut_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 {
            let message = unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy();
            log::warn!(
                "VDA Vulkan preparation unavailable: {message}; using CPU reference preparation until model reload"
            );
            self.preparation_failed = true;
            // SAFETY: this private method is called only by infer_rgb/planar,
            // with a borrowed slice whose exact dimensions were checked there.
            let count = size.0 * size.1 * 3;
            if planar {
                return self.run_cpu(
                    unsafe { std::slice::from_raw_parts(source.cast::<f32>(), count) },
                    size,
                    timestamp,
                    sigma,
                );
            }
            let rgb = unsafe { std::slice::from_raw_parts(source.cast::<u8>(), count) };
            let plane = size.0 * size.1;
            let mut planar = vec![0.; count];
            for (i, pixel) in rgb.chunks_exact(3).enumerate() {
                for c in 0..3 {
                    planar[c * plane + i] = pixel[c] as f32 / 255.;
                }
            }
            return self.run_cpu(&planar, size, timestamp, sigma);
        }
        let cut = self.thumb.as_ref().is_some_and(|prev| {
            prev.iter()
                .zip(&thumb)
                .map(|(a, b)| (a - b).abs())
                .sum::<f32>()
                / 432.
                > 1.
        });
        let gap = self.last.is_some_and(|last| {
            timestamp
                .checked_duration_since(last)
                .is_none_or(|gap| gap > Duration::from_millis(500))
        });
        let mut depth = vec![0.; self.width * self.height];
        let code = unsafe {
            (self.api.infer_prepared)(
                self.handle,
                depth.as_mut_ptr(),
                (self.reset || cut || gap) as c_int,
                sigma,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if code != 0 {
            self.reset = true;
            return Err(unsafe { CStr::from_ptr(error.as_ptr()) }
                .to_string_lossy()
                .into_owned());
        }
        self.thumb = Some(thumb);
        self.last = Some(timestamp);
        self.reset = false;
        Ok(depth)
    }
    pub fn infer_normalized(&mut self, input: &[f32], reset: bool) -> Result<Vec<f32>, String> {
        if input.len() != self.width * self.height * 3 || input.iter().any(|v| !v.is_finite()) {
            return Err("Invalid normalized VDA tensor".into());
        }
        let mut depth = vec![0.; self.width * self.height];
        let mut error = [0 as c_char; 1024];
        let code = unsafe {
            (self.api.infer)(
                self.handle,
                input.as_ptr(),
                depth.as_mut_ptr(),
                i32::from(reset),
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
        Ok(depth)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn resolution_ids_are_explicit() {
        assert_eq!(size(FULL), (518, 294));
        assert_eq!(size(FAST), (392, 224));
        assert!(!is_model(crate::vda::ID));
        assert!(is_model(FAST));
    }
    #[test]
    fn malformed_manifest_is_rejected_before_native_loading() {
        let root = std::env::temp_dir().join(format!("meteor-vda-manifest-{}", std::process::id()));
        let dir = directory(&root, FAST);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("manifest.json"),
            r#"{"schema":1,"width":518,"height":294,"files":{}}"#,
        )
        .unwrap();
        assert!(verify(&root, FAST).unwrap_err().contains("dimensions"));
        std::fs::write(
            dir.join("manifest.json"),
            r#"{"schema":1,"width":392,"height":224,"files":{}}"#,
        )
        .unwrap();
        assert!(verify(&root, FAST).unwrap_err().contains("missing"));
        std::fs::remove_dir_all(root).unwrap();
    }
    /// Production FFI + persistent state, real fixtures, both sizes and each
    /// detected GPU. Does not depend on CUDA/TensorRT or modify saved settings.
    #[test]
    #[ignore = "requires staged VDA models, Vulkan GPU and video fixtures"]
    fn production_video_parity() {
        let lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/ncnn/lib/libncnn.so.1");
        crate::ncnn::init(Some(&lib)).unwrap();
        let assets =
            PathBuf::from(std::env::var_os("METEOR_TEST_VDA_MODELS").expect("model directory"));
        let fixtures =
            PathBuf::from(std::env::var_os("METEOR_TEST_VDA_FIXTURES").expect("fixture directory"));
        for gpu in crate::ncnn::gpu_names() {
            for (id, folder, reference) in [
                (FULL, "video-sequence-01", "rx480-518-no-local"),
                (FAST, "video-392x224", "rx480-target-392-1"),
            ] {
                let mut model = Model::load(&assets, id, Some(&gpu)).unwrap();
                let sequence = fixtures.join(folder);
                let mut times = Vec::new();
                let mut worst = 0f32;
                let mut cold_output = None;
                for line in std::fs::read_to_string(sequence.join("frames.tsv"))
                    .unwrap()
                    .lines()
                {
                    let fields: Vec<_> = line.split_whitespace().collect();
                    let i: usize = fields[0].parse().unwrap();
                    let name = format!("frame_{i:04}");
                    let read = |file: PathBuf| -> Vec<f32> {
                        std::fs::read(file)
                            .unwrap()
                            .chunks_exact(4)
                            .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
                            .collect()
                    };
                    let input = read(sequence.join(format!("{name}.f32")));
                    let begin = Instant::now();
                    let output = model.infer_normalized(&input, fields[2] != "none").unwrap();
                    if i >= 8 && fields[2] == "none" {
                        times.push(begin.elapsed().as_secs_f64() * 1000.);
                    }
                    if i == 0 {
                        cold_output = Some(output.clone());
                    }
                    let expected = read(sequence.join(reference).join(format!("{name}.depth.f32")));
                    let scale = expected.iter().copied().fold(f32::NEG_INFINITY, f32::max)
                        - expected.iter().copied().fold(f32::INFINITY, f32::min);
                    let mae = output
                        .iter()
                        .zip(&expected)
                        .map(|(a, b)| (a - b).abs())
                        .sum::<f32>()
                        / output.len() as f32
                        / scale.max(1e-6);
                    worst = worst.max(mae);
                    assert!(mae < 0.01, "{gpu} {id} frame {i}: normalized MAE={mae}");
                }
                times.sort_by(f64::total_cmp);
                eprintln!(
                    "Production {gpu} {id}: 80 frames; median core {:.2}ms, worst normalized difference {:.5}%",
                    times[times.len() / 2],
                    worst * 100.
                );
                assert!(model.infer_normalized(&[], false).is_err());
                // Bypass the Rust input guard to exercise native GPU state
                // validation and recovery, rather than only its input checks.
                let bad = vec![f32::NAN; model.width * model.height * 3];
                let mut output = vec![0.; model.width * model.height];
                let mut error = [0 as c_char; 1024];
                let code = unsafe {
                    (model.api.infer)(
                        model.handle,
                        bad.as_ptr(),
                        output.as_mut_ptr(),
                        1,
                        error.as_mut_ptr(),
                        error.len(),
                    )
                };
                let error = unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy();
                assert_ne!(code, 0);
                assert!(error.contains("Nonfinite VDA temporal state"), "{error}");
                let read = |file: PathBuf| -> Vec<f32> {
                    std::fs::read(file)
                        .unwrap()
                        .chunks_exact(4)
                        .map(|b| f32::from_le_bytes(b.try_into().unwrap()))
                        .collect()
                };
                let valid = read(sequence.join("frame_0000.f32"));
                let recovered = model.infer_normalized(&valid, false).unwrap();
                let expected = cold_output.unwrap();
                assert!(
                    recovered == expected,
                    "cold recovery differs from same-GPU cold output"
                );
                model.reset();
            }
        }
    }

    #[test]
    #[ignore = "requires installed models, Vulkan GPU and benchmark RGB video"]
    fn prepared_video_matches_reference() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        crate::ncnn::init(Some(&root.join("target/ncnn/lib/libncnn.so.1"))).unwrap();
        let folder =
            PathBuf::from(std::env::var_os("METEOR_BENCH_DIR").expect("RGB fixture directory"));
        let frames = std::fs::read(folder.join("frames.rgb")).unwrap();
        let (sw, sh) = crate::vda::DECODE_SIZE;
        let stride = sw * sh * 3;
        assert!(frames.len() >= stride * 16 && frames.len() % stride == 0);
        let gpus = crate::ncnn::gpu_names();
        assert!(!gpus.is_empty());
        for gpu in gpus {
            for id in [FULL, FAST] {
                let mut reference =
                    Model::load(&crate::config::default_models_dir(), id, Some(&gpu)).unwrap();
                let mut optimized =
                    Model::load(&crate::config::default_models_dir(), id, Some(&gpu)).unwrap();
                let mut previous: Option<Vec<f32>> = None;
                let mut worst_mean = 0f32;
                let mut worst_max = 0f32;
                let base = Instant::now();
                let size = (reference.width, reference.height);
                let mut final_processor =
                    crate::vulkan_processing::Processor::new(Some(&gpu), size).unwrap();
                let mut final_reference = crate::postprocess::PostProcessor::default();
                final_reference.depth_tau = 0.;
                let mut retained = None;
                let mut retained_raw = Vec::new();
                for i in 0..80 {
                    // The advanced CPU reference override must remain usable,
                    // including switching back to GPU preparation without restart.
                    optimized.cpu_processing = i == 40 || i == 41;
                    let frame = i % (frames.len() / stride);
                    let mut rgb = frames[frame * stride..(frame + 1) * stride].to_vec();
                    if i == 20 {
                        rgb.fill(255);
                    }
                    let mut planar = vec![0.; sw * sh * 3];
                    for (j, pixel) in rgb.chunks_exact(3).enumerate() {
                        for c in 0..3 {
                            planar[c * sw * sh + j] = pixel[c] as f32 / 255.;
                        }
                    }
                    let normalized = crate::vda::resize_normalize_size(
                        &planar,
                        sw,
                        sh,
                        reference.width,
                        reference.height,
                    );
                    let mut thumb = Vec::new();
                    for c in 0..3 {
                        for y in 0..9 {
                            for x in 0..16 {
                                let (x0, x1, y0, y1) = (
                                    x * reference.width / 16,
                                    (x + 1) * reference.width / 16,
                                    y * reference.height / 9,
                                    (y + 1) * reference.height / 9,
                                );
                                let mut sum = 0.;
                                for yy in y0..y1 {
                                    for xx in x0..x1 {
                                        sum += normalized[c * reference.width * reference.height
                                            + yy * reference.width
                                            + xx];
                                    }
                                }
                                thumb.push(sum / ((x1 - x0) * (y1 - y0)) as f32);
                            }
                        }
                    }
                    let cut = previous.as_ref().is_some_and(|p| {
                        p.iter()
                            .zip(&thumb)
                            .map(|(a, b)| (a - b).abs())
                            .sum::<f32>()
                            / 432.
                            > 1.
                    });
                    let sigma = [0., 0.75, 0.85, 1.][i % 4];
                    let expected = reference
                        .infer_normalized(&normalized, i == 0 || i == 50 || cut)
                        .unwrap();
                    let expected =
                        crate::vda::blur_size(&expected, sigma, reference.width, reference.height);
                    let now = base
                        + Duration::from_millis(i as u64 * 50 + if i >= 50 { 1000 } else { 0 });
                    let actual = if i % 2 == 0 {
                        match optimized
                            .infer_rgb_resident(&rgb, (sw, sh), now, sigma)
                            .unwrap()
                        {
                            Some(depth) => {
                                let raw = depth.download().unwrap();
                                let actual = final_processor
                                    .process_resident(&depth, &rgb, (sw, sh), now, 0., true, true)
                                    .unwrap();
                                let expected = final_reference.process(&raw, now);
                                let expected = crate::refinement::process(
                                    &expected,
                                    size,
                                    &rgb,
                                    (sw, sh),
                                    true,
                                );
                                let differences: Vec<_> = actual
                                    .iter()
                                    .zip(&expected)
                                    .map(|(a, b)| a.abs_diff(*b))
                                    .collect();
                                let mean = differences.iter().map(|v| *v as f64).sum::<f64>()
                                    / differences.len() as f64;
                                assert!(
                                    *differences.iter().max().unwrap() <= 3 && mean < 0.03,
                                    "{gpu} {id} resident post mean {mean}"
                                );
                                retained_raw = raw.clone();
                                retained = Some(depth);
                                Ok(raw)
                            }
                            None => {
                                let raw = optimized.infer_rgb(&rgb, (sw, sh), now, sigma).unwrap();
                                final_processor
                                    .process(&raw, &rgb, (sw, sh), now, 0., true, true)
                                    .unwrap();
                                final_reference.process(&raw, now);
                                Ok(raw)
                            }
                        }
                    } else {
                        optimized.infer_planar(&planar, (sw, sh), now, sigma)
                    }
                    .unwrap();
                    let range = (expected.iter().copied().fold(f32::NEG_INFINITY, f32::max)
                        - expected.iter().copied().fold(f32::INFINITY, f32::min))
                    .max(1e-6);
                    let differences: Vec<_> = actual
                        .iter()
                        .zip(&expected)
                        .map(|(a, b)| (a - b).abs() / range)
                        .collect();
                    let mean = differences.iter().sum::<f32>() / differences.len() as f32;
                    let maximum = differences.iter().copied().fold(0., f32::max);
                    assert!(actual.iter().all(|v| v.is_finite()));
                    assert!(
                        mean < 0.001 && maximum < 0.02,
                        "{gpu} {id} frame {i}: mean={mean} maximum={maximum}"
                    );
                    worst_mean = worst_mean.max(mean);
                    worst_max = worst_max.max(maximum);
                    previous = Some(thumb);
                }
                eprintln!(
                    "Prepared {gpu} {id}: 80 frames with RGB/planar, cuts, gap, history rollover; maximum frame MAE {:.5}%, worst pixel {:.5}%",
                    worst_mean * 100.,
                    worst_max * 100.
                );
                drop(reference);
                drop(optimized);
                drop(final_processor);
                assert_eq!(retained.unwrap().download().unwrap(), retained_raw);
            }
        }
    }
}
