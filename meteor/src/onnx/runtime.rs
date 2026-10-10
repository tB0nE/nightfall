use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Instant;

use super::Backend;

use ort::ep;
use ort::session::Session;
use ort::session::builder::GraphOptimizationLevel;
use ort::memory::{AllocationDevice, Allocator, AllocatorType, MemoryInfo, MemoryType};
use ort::session::IoBinding;
use ort::value::{Shape, Tensor, TensorRef, TensorRefMut};

static RUNTIME: OnceLock<Result<String, String>> = OnceLock::new();

/// Loads ONNX Runtime once. Returns a description of where it came from.
pub fn init(configured: Option<&Path>) -> Result<String, String> {
    RUNTIME.get_or_init(|| load_runtime(configured)).clone()
}

fn load_runtime(configured: Option<&Path>) -> Result<String, String> {
    let lib = match configured {
        Some(path) => path.to_path_buf(),
        None => find_dev_runtime().ok_or("ONNX Runtime not found; set onnxruntime_lib in meteor.toml")?,
    };
    let preloaded = preload_cuda_libraries(&lib);
    ort::init_from(&lib)
        .map_err(|err| format!("can't load {}: {err}", lib.display()))?
        .with_name("nightfall-meteor")
        .commit();
    Ok(format!("{} ({preloaded} CUDA libraries preloaded)", lib.display()))
}

/// Whether models can run on ONNX Runtime's CUDA provider. The TensorRT
/// provider needs the CUDA provider's library too, but not cuDNN, so a
/// TensorRT-only runtime (the AppImage) leaves cuDNN's engines out, and then
/// models load straight on TensorRT.
pub fn cuda_backend_present() -> bool {
    let name = if cfg!(windows) { "cudnn_ops64_9.dll" } else { "libcudnn_ops.so.9" };
    // SAFETY: cuDNN's own library (already loaded by the preload when it is
    // there); loading it runs only its initializers.
    unsafe { libloading::Library::new(name).is_ok() }
}

/// `target/bench-venv/lib/python3.*/site-packages/onnxruntime/capi/libonnxruntime.so.*`
fn find_dev_runtime() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let target = exe.parent()?.parent()?; // target/{debug,release}/meteor
    let lib_dir = target.join("bench-venv").join("lib");
    for python in std::fs::read_dir(lib_dir).ok()?.flatten() {
        let capi = python.path().join("site-packages/onnxruntime/capi");
        let Ok(entries) = std::fs::read_dir(&capi) else { continue };
        let mut libs: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("libonnxruntime.so")))
            .collect();
        libs.sort();
        if let Some(lib) = libs.pop() {
            return Some(lib);
        }
    }
    None
}

/// dlopens every library in `site-packages/nvidia/*/lib` (RTLD_GLOBAL), so
/// the CUDA provider finds cuDNN and cuBLAS by soname. Libraries that need
/// another one first are retried until no more load.
fn preload_cuda_libraries(runtime: &Path) -> usize {
    #[cfg(unix)]
    {
        use libloading::os::unix::{Library, RTLD_GLOBAL, RTLD_NOW};
        let Some(site_packages) = runtime.ancestors().nth(3) else { return 0 };
        let Ok(packages) = std::fs::read_dir(site_packages.join("nvidia")) else { return 0 };
        let mut dirs: Vec<PathBuf> = packages.flatten().map(|p| p.path().join("lib")).collect();
        dirs.push(site_packages.join("tensorrt_libs"));
        let mut pending: Vec<PathBuf> = dirs
            .iter()
            .filter_map(|dir| std::fs::read_dir(dir).ok())
            .flat_map(|dir| dir.flatten().map(|e| e.path()))
            .filter(|p| {
                p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                    // TensorRT opens its per-GPU builder resources itself.
                    n.contains(".so") && !n.contains("builder_resource")
                })
            })
            .collect();
        pending.sort();
        let mut loaded = 0;
        loop {
            let before = pending.len();
            pending.retain(|path| {
                // SAFETY: these are NVIDIA's own runtime libraries; loading
                // them runs their initializers, which is what we want.
                match unsafe { Library::open(Some(path), RTLD_NOW | RTLD_GLOBAL) } {
                    Ok(lib) => {
                        std::mem::forget(lib); // keep it loaded for the process
                        loaded += 1;
                        false
                    }
                    Err(_) => true,
                }
            });
            if pending.is_empty() || pending.len() == before {
                break;
            }
        }
        for path in &pending {
            log::debug!("couldn't preload {}", path.display());
        }
        loaded
    }
    #[cfg(not(unix))]
    {
        let _ = runtime;
        0
    }
}

/// The TensorRT library's version (for example `10.16.1`), once ONNX
/// Runtime's TensorRT libraries are loaded (see preload_cuda_libraries).
pub fn tensorrt_version() -> Option<String> {
    let name = if cfg!(windows) { "nvinfer_10.dll" } else { "libnvinfer.so.10" };
    // SAFETY: TensorRT's own library, already loaded by the preload;
    // getInferLibVersion takes no arguments and returns an int.
    unsafe {
        let lib = libloading::Library::new(name).ok()?;
        let version: libloading::Symbol<unsafe extern "C" fn() -> i32> = lib.get(b"getInferLibVersion").ok()?;
        let v = version();
        Some(format!("{}.{}.{}", v / 10000, v / 100 % 100, v % 100))
    }
}

/// Input and output bound to GPU memory, for running with no copies.
struct DeviceIo {
    // Field order is drop order: the binding holds the output tensor, which
    // the allocator must outlive.
    binding: IoBinding,
    output: u64,
    input_name: String,
    _allocator: Allocator,
}

pub struct DepthModel {
    session: Session,
    device_io: Option<DeviceIo>,
    pub backend: Backend,
    pub name: String,
    pub width: usize,
    pub height: usize,
    input: Vec<f32>,
}

impl DepthModel {
    /// `cache_dir` holds TensorRT engines.
    pub fn load(path: &Path, backend: Backend, cache_dir: &Path) -> Result<DepthModel, String> {
        let started = Instant::now();
        let fail = |err: ort::Error| format!("{} ({}): {err}", path.display(), backend.label());
        let provider = match backend {
            Backend::Cuda => ep::CUDA::default().build().error_on_failure(),
            Backend::TensorRt => {
                let _ = std::fs::create_dir_all(cache_dir);
                let cache = cache_dir.display().to_string();
                ep::TensorRT::default()
                    .with_fp16(true)
                    .with_engine_cache(true)
                    .with_engine_cache_path(&cache)
                    .with_timing_cache(true)
                    .with_timing_cache_path(&cache)
                    .build()
                    .error_on_failure()
            }
        };
        let session = Session::builder()
            .map_err(fail)?
            .with_optimization_level(GraphOptimizationLevel::All)
            .map_err(|e| fail(e.into()))?
            .with_execution_providers([provider])
            .map_err(|e| fail(e.into()))?
            .commit_from_file(path)
            .map_err(fail)?;
        let shape: Vec<i64> = session
            .inputs()
            .first()
            .and_then(|i| i.dtype().tensor_shape())
            .map(|s| s.iter().copied().collect())
            .ok_or_else(|| format!("{}: no tensor input", path.display()))?;
        let [1, 3, height, width] = shape[..] else {
            return Err(format!("{}: expected a 1x3xHxW input, got {shape:?}", path.display()));
        };
        if height <= 0 || width <= 0 {
            return Err(format!("{}: the input size must be fixed, got {shape:?}", path.display()));
        }
        let name = path.file_stem().and_then(|s| s.to_str()).unwrap_or("model").to_string();
        log::info!(
            "Loaded depth model {name} ({width}x{height}, {}) in {} ms",
            backend.label(),
            started.elapsed().as_millis()
        );
        let (width, height) = (width as usize, height as usize);
        Ok(DepthModel { session, device_io: None, backend, name, width, height, input: vec![0.0; 3 * width * height] })
    }

    /// `rgb` is packed RGB24 at the model's size. Returns the raw output.
    pub fn infer(&mut self, rgb: &[u8]) -> Result<Vec<f32>, String> {
        let plane = self.width * self.height;
        if rgb.len() != plane * 3 {
            return Err(format!("frame is {} bytes, expected {}", rgb.len(), plane * 3));
        }
        let (r, rest) = self.input.split_at_mut(plane);
        let (g, b) = rest.split_at_mut(plane);
        for (i, px) in rgb.chunks_exact(3).enumerate() {
            r[i] = f32::from(px[0]) / 255.0;
            g[i] = f32::from(px[1]) / 255.0;
            b[i] = f32::from(px[2]) / 255.0;
        }
        let shape = [1usize, 3, self.height, self.width];
        let tensor = TensorRef::from_array_view((shape, &self.input[..])).map_err(|e| e.to_string())?;
        let outputs = self.session.run(ort::inputs![tensor]).map_err(|e| e.to_string())?;
        let (_, depth) = outputs[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
        let depth = depth.to_vec();
        if depth.len() != plane {
            return Err(format!("model output has {} values, expected {plane}", depth.len()));
        }
        Ok(depth)
    }

    /// Like `infer_gpu`, but the output stays in GPU memory too (a buffer
    /// owned by the model, reused every run). Returns its device address,
    /// valid until the next run.
    pub fn infer_on_device(&mut self, device_ptr: u64) -> Result<u64, String> {
        let err = |e: ort::Error| e.to_string();
        let cuda = || MemoryInfo::new(AllocationDevice::CUDA, 0, AllocatorType::Device, MemoryType::Default);
        if self.device_io.is_none() {
            let allocator = Allocator::new(&self.session, cuda().map_err(err)?).map_err(err)?;
            let mut output = Tensor::<f32>::new(&allocator, [1usize, 1, self.height, self.width]).map_err(err)?;
            let output_ptr = output.data_ptr_mut() as u64;
            let mut binding = self.session.create_binding().map_err(err)?;
            let output_name = self.session.outputs()[0].name().to_string();
            binding.bind_output(output_name, output).map_err(err)?;
            let input_name = self.session.inputs()[0].name().to_string();
            self.device_io = Some(DeviceIo { binding, output: output_ptr, input_name, _allocator: allocator });
        }
        let io = self.device_io.as_mut().expect("just created");
        let shape = Shape::new([1, 3, self.height as i64, self.width as i64]);
        // SAFETY: the caller's GpuTensor holds the input and outlives the run;
        // the input is unbound again before returning.
        let input = unsafe { TensorRefMut::<f32>::from_raw(cuda().map_err(err)?, device_ptr as usize as *mut _, shape) }
            .map_err(err)?;
        io.binding.bind_input(io.input_name.clone(), &input).map_err(err)?;
        // Run returns once the outputs are ready on the device.
        let ran = self.session.run_binding(&io.binding).map(drop).map_err(err);
        io.binding.clear_inputs();
        ran.map(|()| io.output)
    }

    /// Runs on an input tensor already in GPU memory (CUDA device 0, the
    /// primary context): planar RGB floats at the model's size, as written
    /// by the NVDEC conversion kernel. The output comes back to the CPU.
    pub fn infer_gpu(&mut self, device_ptr: u64) -> Result<Vec<f32>, String> {
        let plane = self.width * self.height;
        let info = MemoryInfo::new(AllocationDevice::CUDA, 0, AllocatorType::Device, MemoryType::Default)
            .map_err(|e| e.to_string())?;
        let shape = Shape::new([1, 3, self.height as i64, self.width as i64]);
        // SAFETY: the caller's GpuTensor holds 3 * plane floats at
        // device_ptr and outlives this call.
        let tensor = unsafe { TensorRefMut::<f32>::from_raw(info, device_ptr as usize as *mut _, shape) }
            .map_err(|e| e.to_string())?;
        let outputs = self.session.run(ort::inputs![tensor]).map_err(|e| e.to_string())?;
        let (_, depth) = outputs[0].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
        if depth.len() != plane {
            return Err(format!("model output has {} values, expected {plane}", depth.len()));
        }
        Ok(depth.to_vec())
    }
}
