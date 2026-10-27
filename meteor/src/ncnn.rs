//! Single-frame depth models (EdgePad) on ncnn's Vulkan backend: any GPU
//! with a Vulkan driver, and no NVIDIA inference libraries.
//!
//! The library (ncnn's prebuilt shared build, BSD-3, with glslang inside) is
//! opened at run time through its C API, so Meteor builds and runs without
//! it. It's looked for:
//!
//! - at `ncnn_lib` in meteor.toml;
//! - next to the Meteor binary, or in `../lib` (the AppImage);
//! - in `target/ncnn/lib` (development; `tools/fetch_ncnn.sh` puts it there);
//! - on the library path.
//!
//! Models are `<name>.ncnn.param` and `<name>.ncnn.bin`, converted from the
//! ONNX export by `models/convert_ncnn.py`, which also records the input
//! size in the param file. The weights are fp32; they run with fp16 storage
//! and fp32 arithmetic, which is about as close to the fp32 model as
//! TensorRT fp16 (0.06% of the depth range on average for EdgePad 512).

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Instant;

type Opaque = *mut c_void;

/// The C API's functions we use, and four of ncnn's C++ GPU functions
/// (plain functions with stable Itanium names).
struct Api {
    version: unsafe extern "C" fn() -> *const c_char,
    option_create: unsafe extern "C" fn() -> Opaque,
    option_destroy: unsafe extern "C" fn(Opaque),
    option_set_num_threads: unsafe extern "C" fn(Opaque, c_int),
    option_set_use_vulkan_compute: unsafe extern "C" fn(Opaque, c_int),
    option_set_use_fp16_packed: unsafe extern "C" fn(Opaque, c_int),
    option_set_use_fp16_storage: unsafe extern "C" fn(Opaque, c_int),
    option_set_use_fp16_arithmetic: unsafe extern "C" fn(Opaque, c_int),
    net_create: unsafe extern "C" fn() -> Opaque,
    net_destroy: unsafe extern "C" fn(Opaque),
    net_set_option: unsafe extern "C" fn(Opaque, Opaque),
    net_set_vulkan_device: unsafe extern "C" fn(Opaque, c_int),
    net_load_param: unsafe extern "C" fn(Opaque, *const c_char) -> c_int,
    net_load_model: unsafe extern "C" fn(Opaque, *const c_char) -> c_int,
    extractor_create: unsafe extern "C" fn(Opaque) -> Opaque,
    extractor_destroy: unsafe extern "C" fn(Opaque),
    extractor_input: unsafe extern "C" fn(Opaque, *const c_char, Opaque) -> c_int,
    extractor_extract: unsafe extern "C" fn(Opaque, *const c_char, *mut Opaque) -> c_int,
    mat_create_3d: unsafe extern "C" fn(c_int, c_int, c_int, Opaque) -> Opaque,
    mat_destroy: unsafe extern "C" fn(Opaque),
    mat_get_w: unsafe extern "C" fn(Opaque) -> c_int,
    mat_get_h: unsafe extern "C" fn(Opaque) -> c_int,
    mat_get_c: unsafe extern "C" fn(Opaque) -> c_int,
    mat_get_channel_data: unsafe extern "C" fn(Opaque, c_int) -> *mut c_void,
    create_gpu_instance: unsafe extern "C" fn(*const c_char) -> c_int,
    get_gpu_count: unsafe extern "C" fn() -> c_int,
    get_default_gpu_index: unsafe extern "C" fn() -> c_int,
    /// Returns a `const GpuInfo&`.
    get_gpu_info: unsafe extern "C" fn(c_int) -> *const c_void,
    /// `GpuInfo::device_name() const`, with `this` as the argument.
    gpu_info_device_name: unsafe extern "C" fn(*const c_void) -> *const c_char,
    gpu_info_type: unsafe extern "C" fn(*const c_void) -> c_int,
}

struct Runtime {
    api: Api,
    /// The Vulkan device models run on.
    device: c_int,
    /// For logs and the tray: "ncnn 1.0.20260526, NVIDIA GeForce RTX 3090".
    description: String,
    devices: Vec<String>,
}

static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();

/// Opens ncnn and its Vulkan instance once. Returns a description.
pub fn init(configured: Option<&Path>) -> Result<String, String> {
    match RUNTIME.get_or_init(|| load(configured)) {
        Ok(runtime) => Ok(runtime.description.clone()),
        Err(err) => Err(err.clone()),
    }
}

fn runtime() -> Result<&'static Runtime, String> {
    match RUNTIME.get() {
        Some(Ok(runtime)) => Ok(runtime),
        Some(Err(err)) => Err(err.clone()),
        None => Err("ncnn isn't loaded".into()),
    }
}

const LIB_NAME: &str = if cfg!(windows) { "ncnn.dll" } else { "libncnn.so.1" };

fn candidates(configured: Option<&Path>) -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = configured.map(Path::to_path_buf).into_iter().collect();
    if let Some(dir) = std::env::current_exe().ok().as_deref().and_then(Path::parent) {
        paths.push(dir.join(LIB_NAME));
        paths.push(dir.join("../lib").join(LIB_NAME));
        // target/{debug,release}/nightfall-meteor
        paths.push(dir.join("../ncnn/lib").join(LIB_NAME));
    }
    paths.retain(|p| p.exists());
    paths.push(PathBuf::from(LIB_NAME));
    paths
}

fn load(configured: Option<&Path>) -> Result<Runtime, String> {
    let mut errors = Vec::new();
    for path in candidates(configured) {
        // SAFETY: ncnn's own library; loading it runs its initializers.
        match unsafe { libloading::Library::new(&path) } {
            Ok(lib) => {
                // Kept for the process: models and the Vulkan instance live in it.
                let lib: &'static libloading::Library = Box::leak(Box::new(lib));
                return start(lib).map_err(|err| format!("{}: {err}", path.display()));
            }
            Err(err) => errors.push(err.to_string()),
        }
    }
    Err(format!("ncnn not found ({})", errors.join("; ")))
}

#[cfg(windows)]
const CREATE_GPU_INSTANCE: &[u8] = b"?create_gpu_instance@ncnn@@YAHPEBD@Z\0";
#[cfg(windows)]
const GET_GPU_COUNT: &[u8] = b"?get_gpu_count@ncnn@@YAHXZ\0";
#[cfg(windows)]
const GET_DEFAULT_GPU_INDEX: &[u8] = b"?get_default_gpu_index@ncnn@@YAHXZ\0";
#[cfg(windows)]
const GET_GPU_INFO: &[u8] = b"?get_gpu_info@ncnn@@YAAEBVGpuInfo@1@H@Z\0";
#[cfg(windows)]
const GPU_INFO_DEVICE_NAME: &[u8] = b"?device_name@GpuInfo@ncnn@@QEBAPEBDXZ\0";
#[cfg(windows)]
const GPU_INFO_TYPE: &[u8] = b"?type@GpuInfo@ncnn@@QEBAHXZ\0";
#[cfg(not(windows))]
const CREATE_GPU_INSTANCE: &[u8] = b"_ZN4ncnn19create_gpu_instanceEPKc\0";
#[cfg(not(windows))]
const GET_GPU_COUNT: &[u8] = b"_ZN4ncnn13get_gpu_countEv\0";
#[cfg(not(windows))]
const GET_DEFAULT_GPU_INDEX: &[u8] = b"_ZN4ncnn21get_default_gpu_indexEv\0";
#[cfg(not(windows))]
const GET_GPU_INFO: &[u8] = b"_ZN4ncnn12get_gpu_infoEi\0";
#[cfg(not(windows))]
const GPU_INFO_DEVICE_NAME: &[u8] = b"_ZNK4ncnn7GpuInfo11device_nameEv\0";
#[cfg(not(windows))]
const GPU_INFO_TYPE: &[u8] = b"_ZNK4ncnn7GpuInfo4typeEv\0";

fn start(lib: &'static libloading::Library) -> Result<Runtime, String> {
    macro_rules! sym {
        ($name:expr) => {
            // SAFETY: the symbol's type matches c_api.h / gpu.h for the
            // field it's assigned to.
            *unsafe { lib.get($name) }.map_err(|e| e.to_string())?
        };
    }
    let api = Api {
        version: sym!(b"ncnn_version"),
        option_create: sym!(b"ncnn_option_create"),
        option_destroy: sym!(b"ncnn_option_destroy"),
        option_set_num_threads: sym!(b"ncnn_option_set_num_threads"),
        option_set_use_vulkan_compute: sym!(b"ncnn_option_set_use_vulkan_compute"),
        option_set_use_fp16_packed: sym!(b"ncnn_option_set_use_fp16_packed"),
        option_set_use_fp16_storage: sym!(b"ncnn_option_set_use_fp16_storage"),
        option_set_use_fp16_arithmetic: sym!(b"ncnn_option_set_use_fp16_arithmetic"),
        net_create: sym!(b"ncnn_net_create"),
        net_destroy: sym!(b"ncnn_net_destroy"),
        net_set_option: sym!(b"ncnn_net_set_option"),
        net_set_vulkan_device: sym!(b"ncnn_net_set_vulkan_device"),
        net_load_param: sym!(b"ncnn_net_load_param"),
        net_load_model: sym!(b"ncnn_net_load_model"),
        extractor_create: sym!(b"ncnn_extractor_create"),
        extractor_destroy: sym!(b"ncnn_extractor_destroy"),
        extractor_input: sym!(b"ncnn_extractor_input"),
        extractor_extract: sym!(b"ncnn_extractor_extract"),
        mat_create_3d: sym!(b"ncnn_mat_create_3d"),
        mat_destroy: sym!(b"ncnn_mat_destroy"),
        mat_get_w: sym!(b"ncnn_mat_get_w"),
        mat_get_h: sym!(b"ncnn_mat_get_h"),
        mat_get_c: sym!(b"ncnn_mat_get_c"),
        mat_get_channel_data: sym!(b"ncnn_mat_get_channel_data"),
        create_gpu_instance: sym!(CREATE_GPU_INSTANCE),
        get_gpu_count: sym!(GET_GPU_COUNT),
        get_default_gpu_index: sym!(GET_DEFAULT_GPU_INDEX),
        get_gpu_info: sym!(GET_GPU_INFO),
        gpu_info_device_name: sym!(GPU_INFO_DEVICE_NAME),
        gpu_info_type: sym!(GPU_INFO_TYPE),
    };
    // SAFETY: plain calls into ncnn; the strings it returns are static.
    unsafe {
        let version = CStr::from_ptr((api.version)()).to_string_lossy().into_owned();
        if (api.create_gpu_instance)(std::ptr::null()) != 0 || (api.get_gpu_count)() == 0 {
            return Ok(Runtime { api, device: -1, devices: Vec::new(), description: format!("ncnn {version}, CPU only (no Vulkan GPU)") });
        }
        // ncnn prefers a discrete GPU.
        let devices: Vec<String> = (0..(api.get_gpu_count)()).map(|i|
            CStr::from_ptr((api.gpu_info_device_name)((api.get_gpu_info)(i))).to_string_lossy().into_owned()).collect();
        let device = if (0..devices.len()).all(|i|(api.gpu_info_type)((api.get_gpu_info)(i as c_int))==3) {-1}
            else {resolve_device(&devices, (api.get_default_gpu_index)(), None)?};
        if device<0 {return Ok(Runtime {api,device,devices,description:format!("ncnn {version}, CPU only (no hardware Vulkan GPU)")});}
        let name = CStr::from_ptr((api.gpu_info_device_name)((api.get_gpu_info)(device))).to_string_lossy().into_owned();
        Ok(Runtime { api, device, devices, description: format!("ncnn {version}, {name}") })
    }
}

/// Names persist across driver enumeration changes; never silently substitute
/// another device for an explicit user selection.
pub fn gpu_names() -> Vec<String> {
    runtime().map(|r|r.devices.iter().enumerate().filter(|(i,_)| {
        // SAFETY: indices refer to this runtime's immutable GPU enumeration.
        unsafe {(r.api.gpu_info_type)((r.api.get_gpu_info)(*i as c_int))!=3}
    }).map(|(_,name)|name.clone()).collect()).unwrap_or_default()
}
pub fn gpu_index(requested: Option<&str>) -> Result<c_int,String> {
    let r=runtime()?;resolve_device(&r.devices,r.device,requested)
}
pub fn resolved_gpu_name(requested: Option<&str>) -> Result<String,String> {
    let r=runtime()?;
    if r.device<0 {return Err("No hardware Vulkan GPU available".into());}
    let device=resolve_device(&r.devices,r.device,requested)?;
    Ok(r.devices[device as usize].clone())
}
fn resolve_device(names: &[String], default: c_int, requested: Option<&str>) -> Result<c_int,String> {
    if let Some(name)=requested {
        return names.iter().position(|n|n==name).map(|i|i as c_int)
            .ok_or_else(||format!("Selected Vulkan GPU is unavailable: {name}"));
    }
    if names.is_empty() { return Err("No Vulkan GPU available".into()); }
    // Prefer NVIDIA when present to keep NVDEC and inference on the same GPU.
    Ok(names.iter().position(|n|n.to_ascii_lowercase().contains("nvidia"))
        .map(|i|i as c_int).unwrap_or(if default>=0 && (default as usize)<names.len() {default} else {0}))
}

/// The param file of a model, and its weights next to it.
pub const PARAM_SUFFIX: &str = ".ncnn.param";
const BIN_SUFFIX: &str = ".ncnn.bin";
const INPUT: &CStr = c"in0";
const OUTPUT: &CStr = c"out0";

/// The input size convert_ncnn.py records on the Input layer
/// (`Input in0 0 1 in0 0=512 1=288 2=3`).
fn input_size(param: &str) -> Option<(usize, usize)> {
    let line = param.lines().find(|l| l.split_whitespace().next() == Some("Input"))?;
    let value = |key: &str| line.split_whitespace().find_map(|kv| kv.strip_prefix(key)?.parse::<usize>().ok());
    match (value("0="), value("1="), value("2=")) {
        (Some(w), Some(h), Some(3)) if w > 0 && h > 0 => Some((w, h)),
        _ => None,
    }
}

/// A converted single-frame model: planar RGB 0..1 in, one depth channel
/// of the same size out.
pub struct NcnnModel {
    api: &'static Api,
    net: Opaque,
    pub name: String,
    pub width: usize,
    pub height: usize,
    pub cpu: bool,
    pub gpu_name: Option<String>,
    input: Vec<f32>,
}

// SAFETY: the net is used from one thread at a time (the depth thread);
// ncnn doesn't tie it to the thread that loaded it.
unsafe impl Send for NcnnModel {}

impl NcnnModel {
    pub(crate) fn infer_resident(&mut self,rgb:&[u8],processor:&mut crate::vulkan_processing::Processor)->Result<crate::vulkan_processing::ResidentDepth,String> {
        if self.cpu || processor.size!=(self.width,self.height) || self.gpu_name.as_deref()!=Some(processor.gpu.as_str()) {return Err("Resident ncnn model/device mismatch".into());}
        // The published ncnn C handle exposes pthis in c_api.h. Our native
        // bridge uses that declaration and verifies runtime/SDK compatibility.
        unsafe{processor.infer_edge(self.net,rgb)}
    }
    /// `param` is `<name>.ncnn.param`; the weights are `<name>.ncnn.bin`.
    #[cfg(test)]
    pub fn load(param: &Path) -> Result<NcnnModel, String> {
        Self::load_backend(param, false)
    }

    pub fn load_backend(param: &Path, cpu: bool) -> Result<NcnnModel, String> {
        Self::load_on_gpu(param,cpu,None)
    }

    pub fn load_on_gpu(param: &Path, cpu: bool, requested: Option<&str>) -> Result<NcnnModel, String> {
        let started = Instant::now();
        let runtime = runtime()?;
        let api = &runtime.api;
        if !cpu && runtime.device < 0 {
            return Err("ncnn GPU inference requires a Vulkan GPU; select CPU instead".into());
        }
        let device = if cpu {-1} else {resolve_device(&runtime.devices,runtime.device,requested)?};
        if !cpu && unsafe {(api.gpu_info_type)((api.get_gpu_info)(device))==3} {
            return Err("Selected Vulkan device is a software CPU renderer".into());
        }
        let gpu_name = if cpu {None} else {Some(runtime.devices[device as usize].clone())};
        let file = param.file_name().and_then(|n| n.to_str()).unwrap_or_default();
        let name = file.strip_suffix(PARAM_SUFFIX).ok_or_else(|| format!("{}: not an ncnn model", param.display()))?;
        let bin = param.with_file_name(format!("{name}{BIN_SUFFIX}"));
        let text = std::fs::read_to_string(param).map_err(|e| format!("{}: {e}", param.display()))?;
        let (width, height) = input_size(&text).ok_or_else(|| {
            format!("{}: no RGB input size on the Input layer (convert it with models/convert_ncnn.py)", param.display())
        })?;
        let c = |p: &Path| CString::new(p.as_os_str().as_encoded_bytes()).map_err(|_| format!("{}: NUL in path", p.display()));
        let (param_c, bin_c) = (c(param)?, c(&bin)?);
        // SAFETY: a fresh net and option set, configured before loading;
        // the option set is copied into the net.
        let net = unsafe {
            let net = (api.net_create)();
            let opt = (api.option_create)();
            (api.option_set_use_vulkan_compute)(opt, if cpu { 0 } else { 1 });
            (api.option_set_use_fp16_packed)(opt, if cpu { 0 } else { 1 });
            (api.option_set_use_fp16_storage)(opt, if cpu { 0 } else { 1 });
            (api.option_set_use_fp16_arithmetic)(opt, 0);
            // The CPU only packs the input and unpacks the output; more
            // threads only spin.
            (api.option_set_num_threads)(opt, if cpu { crate::onnx::cpu_threads() as c_int } else { 1 });
            (api.net_set_option)(net, opt);
            (api.option_destroy)(opt);
            if !cpu {
                (api.net_set_vulkan_device)(net, device);
            }
            net
        };
        let model = NcnnModel { api, net, name: name.to_string(), width, height, cpu, gpu_name, input: vec![0.0; 3 * width * height] };
        // SAFETY: NUL-terminated paths; the net is ours.
        unsafe {
            if (api.net_load_param)(net, param_c.as_ptr()) != 0 {
                return Err(format!("{}: ncnn can't read it", param.display()));
            }
            if (api.net_load_model)(net, bin_c.as_ptr()) != 0 {
                return Err(format!("{}: ncnn can't read it", bin.display()));
            }
        }
        log::info!(
            "Loaded depth model {} ({width}x{height}, {}, {}) in {} ms",
            model.name,
            if cpu { "CPU fp32" } else { "Vulkan fp16" },
            model.gpu_name.as_deref().unwrap_or("CPU"),
            started.elapsed().as_millis()
        );
        Ok(model)
    }

    /// `rgb` is packed RGB24 at the model's size. Returns the depth.
    pub fn infer(&mut self, rgb: &[u8]) -> Result<Vec<f32>, String> {
        let plane = self.width * self.height;
        if rgb.len() != plane * 3 {
            return Err(format!("frame is {} bytes, expected {}", rgb.len(), plane * 3));
        }
        let mut input = std::mem::take(&mut self.input);
        let (r, rest) = input.split_at_mut(plane);
        let (g, b) = rest.split_at_mut(plane);
        for (i, px) in rgb.chunks_exact(3).enumerate() {
            r[i] = f32::from(px[0]) / 255.0;
            g[i] = f32::from(px[1]) / 255.0;
            b[i] = f32::from(px[2]) / 255.0;
        }
        let result = self.infer_planar(&input);
        self.input = input;
        result
    }

    /// `planar` is the model's input tensor: R, G and B planes, 0..1.
    pub fn infer_planar(&mut self, planar: &[f32]) -> Result<Vec<f32>, String> {
        let (w, h) = (self.width, self.height);
        let plane = w * h;
        if planar.len() != plane * 3 {
            return Err(format!("input has {} values, expected {}", planar.len(), plane * 3));
        }
        let api = self.api;
        // SAFETY: the Mat is created at this size and each channel holds at
        // least `plane` floats (ncnn pads channels, never shrinks them); the
        // extractor and both Mats are destroyed before returning.
        unsafe {
            let input = (api.mat_create_3d)(w as c_int, h as c_int, 3, std::ptr::null_mut());
            if input.is_null() {
                return Err("ncnn couldn't allocate the input".into());
            }
            for c in 0..3 {
                let dst = (api.mat_get_channel_data)(input, c as c_int).cast::<f32>();
                std::ptr::copy_nonoverlapping(planar[c * plane..].as_ptr(), dst, plane);
            }
            let ex = (api.extractor_create)(self.net);
            let mut output: Opaque = std::ptr::null_mut();
            let rc = if (api.extractor_input)(ex, INPUT.as_ptr(), input) == 0 {
                (api.extractor_extract)(ex, OUTPUT.as_ptr(), &mut output)
            } else {
                -1
            };
            (api.extractor_destroy)(ex);
            (api.mat_destroy)(input);
            if rc != 0 || output.is_null() {
                if !output.is_null() {
                    (api.mat_destroy)(output);
                }
                return Err("ncnn couldn't run the model".into());
            }
            let shape = ((api.mat_get_w)(output), (api.mat_get_h)(output), (api.mat_get_c)(output));
            let depth = if shape == (w as c_int, h as c_int, 1) {
                let src = (api.mat_get_channel_data)(output, 0).cast::<f32>();
                Ok(std::slice::from_raw_parts(src, plane).to_vec())
            } else {
                Err(format!("model output is {}x{}x{}, expected {w}x{h}x1", shape.0, shape.1, shape.2))
            };
            (api.mat_destroy)(output);
            depth
        }
    }
}

impl Drop for NcnnModel {
    fn drop(&mut self) {
        // SAFETY: our net, destroyed once.
        unsafe { (self.api.net_destroy)(self.net) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_recorded_input_size() {
        let param = "7767517\n145 171\nInput                    in0                      0 1 in0 0=512 1=288 2=3\n";
        assert_eq!(input_size(param), Some((512, 288)));
        assert_eq!(input_size("7767517\n1 1\nInput in0 0 1 in0\n"), None);
        assert_eq!(input_size("7767517\n1 1\nInput in0 0 1 in0 0=8 1=8 2=1\n"), None);
    }

    /// Uses installed models/runtime; CPU output against ONNX Runtime CPU,
    /// and a short inference-only benchmark. No stream or server is started.
    #[cfg(feature = "onnxruntime")]
    #[test]
    #[ignore]
    fn edgepad_cpu_parity() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR"));
        let lib = root.join("target/ncnn/lib").join(LIB_NAME);
        init(Some(&lib)).unwrap();
        let runtime = std::fs::read_dir(root.join("target/bench-venv/lib")).unwrap()
            .flatten().flat_map(|python| std::fs::read_dir(python.path().join("site-packages/onnxruntime/capi")).into_iter().flatten().flatten())
            .map(|entry| entry.path()).find(|path| path.file_name().unwrap().to_string_lossy().starts_with("libonnxruntime.so")).unwrap();
        crate::onnx::init(Some(&runtime)).unwrap();
        let models = crate::config::default_models_dir();
        for name in ["zipdepth_edgepad_256", "zipdepth_edgepad_384", "zipdepth_wide_512x288"] {
            let mut cpu = NcnnModel::load_backend(&models.join(format!("{name}{PARAM_SUFFIX}")), true).unwrap();
            let mut reference = crate::onnx::DepthModel::load(&models.join(format!("{name}.onnx")), crate::onnx::Backend::Cpu, &root.join("target/cpu-test")).unwrap();
            assert!(cpu.cpu);
            let rgb: Vec<u8> = if let Some(folder) = std::env::var_os("EDGEPAD_TEST_RGB") {
                std::fs::read(Path::new(&folder).join(format!("{}x{}.rgb", cpu.width, cpu.height))).unwrap()
            } else {
                (0..cpu.width*cpu.height).flat_map(|i| [(i%cpu.width*255/cpu.width) as u8, (i/cpu.width*255/cpu.height) as u8, 128]).collect()
            };
            let expected = reference.infer(&rgb).unwrap();
            let actual = cpu.infer(&rgb).unwrap();
            assert_eq!(actual.len(), expected.len());
            assert!(actual.iter().all(|v| v.is_finite()));
            let (mean, _, max) = error(&actual, &expected);
            eprintln!("{name}: CPU ncnn vs ONNX CPU mean {mean:.5}%, max {max:.5}% of range");
            assert!(mean < 0.1 && max < 1.0);
            let mut times = Vec::new();
            for _ in 0..12 {
                let start = Instant::now();
                cpu.infer(&rgb).unwrap();
                times.push(start.elapsed().as_secs_f64()*1000.0);
            }
            times.sort_by(f64::total_cmp);
            eprintln!("{name}: {} CPU threads, median {:.2}ms, p95 {:.2}ms",crate::onnx::cpu_threads(),times[times.len()/2],times[times.len()-1]);
            if std::env::var_os("EDGEPAD_TEST_GPU").is_some() {
                let mut gpu = NcnnModel::load_backend(&models.join(format!("{name}{PARAM_SUFFIX}")), false).unwrap();
                let actual = gpu.infer(&rgb).unwrap();
                let (mean, _, max) = error(&actual, &expected);
                assert!(mean < 0.3 && max < 3.0, "{name}: GPU mean {mean}%, max {max}%");
                let mut times = Vec::new();
                for _ in 0..20 {
                    let start = Instant::now();
                    gpu.infer(&rgb).unwrap();
                    times.push(start.elapsed().as_secs_f64()*1000.0);
                }
                times.sort_by(f64::total_cmp);
                eprintln!("{name}: Vulkan median {:.2}ms, p95 {:.2}ms; mean error {mean:.5}%", times[10], times[19]);
            }
        }
    }

    fn read_f32(path: &Path) -> Vec<f32> {
        std::fs::read(path).unwrap().chunks_exact(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())).collect()
    }

    /// Error against `reference` as a percentage of its depth range: mean,
    /// 99th percentile and worst.
    fn error(out: &[f32], reference: &[f32]) -> (f64, f64, f64) {
        let (lo, hi) = reference.iter().fold((f32::MAX, f32::MIN), |(lo, hi), &v| (lo.min(v), hi.max(v)));
        let range = f64::from(hi - lo);
        let mut d: Vec<f64> = out.iter().zip(reference).map(|(a, b)| f64::from((a - b).abs()) / range * 100.0).collect();
        let mean = d.iter().sum::<f64>() / d.len() as f64;
        d.sort_by(f64::total_cmp);
        (mean, d[d.len() * 99 / 100], d[d.len() - 1])
    }

    /// EdgePad 512 on 30 frames of a 2560x1440 game capture, against ONNX
    /// Runtime CUDA fp32 (and TensorRT fp16, what Meteor ran before, for
    /// comparison). Needs the converted model in the models folder and ncnn
    /// in target/ncnn (tools/fetch_ncnn.sh), so it's ignored by default:
    ///
    /// ```sh
    /// EDGEPAD_TEST_DATA=<dir with input.f32, cuda32.f32, trt16.f32> \
    ///     cargo test --release -- --ignored --nocapture edgepad
    /// ```
    #[test]
    #[ignore]
    fn edgepad_parity() {
        let data = PathBuf::from(std::env::var("EDGEPAD_TEST_DATA").expect("EDGEPAD_TEST_DATA"));
        let lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/ncnn/lib").join(LIB_NAME);
        eprintln!("{}", init(Some(&lib)).unwrap());
        let param = crate::config::default_models_dir().join(format!("zipdepth_wide_512x288{PARAM_SUFFIX}"));
        let mut model = NcnnModel::load(&param).unwrap();
        let plane = model.width * model.height;
        let inputs = read_f32(&data.join("input.f32"));
        let count = inputs.len() / (3 * plane);
        let mut out = Vec::with_capacity(count * plane);
        for k in 0..count {
            out.extend(model.infer_planar(&inputs[k * 3 * plane..(k + 1) * 3 * plane]).unwrap());
        }
        let reference = read_f32(&data.join("cuda32.f32"));
        let tensorrt = read_f32(&data.join("trt16.f32"));
        let (mean, p99, max) = error(&out, &reference);
        let (t_mean, t_p99, t_max) = error(&tensorrt, &reference);
        eprintln!("ncnn:     mean {mean:.3}%, p99 {p99:.3}%, max {max:.2}% of the depth range");
        eprintln!("TensorRT: mean {t_mean:.3}%, p99 {t_p99:.3}%, max {t_max:.2}%");
        assert!(out.iter().all(|v| v.is_finite()));
        // The numbers depend on the frames, so ncnn is held to TensorRT fp16's
        // error on the same frames, with a loose absolute bound.
        assert!(mean <= 1.25 * t_mean && mean < 0.3 && max < 2.0, "ncnn is further from fp32 than expected");

        let mut ms = Vec::new();
        for i in 0..600 {
            let k = i % count;
            let started = Instant::now();
            model.infer_planar(&inputs[k * 3 * plane..(k + 1) * 3 * plane]).unwrap();
            if i >= 100 {
                ms.push(started.elapsed().as_secs_f64() * 1000.0);
            }
        }
        ms.sort_by(f64::total_cmp);
        eprintln!(
            "run (upload, model, download): median {:.2} ms, p95 {:.2} ms, max {:.2} ms",
            ms[ms.len() / 2],
            ms[ms.len() * 95 / 100],
            ms[ms.len() - 1]
        );
    }
}

#[cfg(test)]
mod gpu_selection_tests {
    use super::*;
    #[test] fn preference_survives_gpu_reordering_and_missing_gpu_is_explicit() {
        let names=vec!["AMD Radeon RX480".into(),"NVIDIA RTX3090".into()];
        assert_eq!(resolve_device(&names,0,None).unwrap(),1);
        assert_eq!(resolve_device(&names,0,Some("AMD Radeon RX480")).unwrap(),0);
        let reversed=vec![names[1].clone(),names[0].clone()];
        assert_eq!(resolve_device(&reversed,0,Some("AMD Radeon RX480")).unwrap(),1);
        assert!(resolve_device(&names,0,Some("Missing GPU")).is_err());
        assert_eq!(resolve_device(&names[..1],0,None).unwrap(),0);
    }

    /// Opt-in hardware test: explicitly load the same model on every visible
    /// Vulkan GPU, run inference, and compare finite outputs across devices.
    #[test]
    #[ignore]
    fn selected_gpu_inference_smoke() {
        let root=Path::new(env!("CARGO_MANIFEST_DIR"));
        init(Some(&root.join("target/ncnn/lib").join(LIB_NAME))).unwrap();
        let param=root.parent().unwrap().join(".build-cache/meteor-library-preview/usr/share/nightfall-meteor/models/zipdepth_wide_512x288.ncnn.param");
        let names=gpu_names();assert!(!names.is_empty());
        let mut reference:Option<Vec<f32>>=None;
        for name in names {
            let mut model=NcnnModel::load_on_gpu(&param,false,Some(&name)).unwrap();
            assert_eq!(model.gpu_name.as_deref(),Some(name.as_str()));
            let rgb:Vec<u8>=(0..model.width*model.height).flat_map(|i|[(i%model.width*255/model.width) as u8,(i/model.width*255/model.height) as u8,128]).collect();
            let out=model.infer(&rgb).unwrap();
            assert_eq!(out.len(),model.width*model.height);
            assert!(out.iter().all(|v|v.is_finite()));
            let lo=out.iter().copied().fold(f32::INFINITY,f32::min);
            let hi=out.iter().copied().fold(f32::NEG_INFINITY,f32::max);
            assert!(hi>lo);
            if let Some(expected)=&reference {
                let scale=expected.iter().copied().fold(f32::NEG_INFINITY,f32::max)-expected.iter().copied().fold(f32::INFINITY,f32::min);
                let error=out.iter().zip(expected).map(|(a,b)|(a-b).abs() as f64).sum::<f64>()/out.len() as f64/scale as f64;
                eprintln!("{name}: normalized mean difference {error:.6}");
                assert!(error<0.01,"Cross-GPU outputs differ by more than 1% of reference range");
            } else {reference=Some(out);}
            let start=Instant::now();
            for _ in 0..10 {model.infer(&rgb).unwrap();}
            eprintln!("{name}: {:.2} ms/inference (10 warm iterations, synthetic input, not end-to-end)",start.elapsed().as_secs_f64()*100.0);
        }
    }
}
