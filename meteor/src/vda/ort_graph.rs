//! VDA's graphs on ONNX Runtime: CUDA while the engines build, and ONNX
//! Runtime's TensorRT provider with `METEOR_TENSORRT=ort`. Only in builds
//! with the `onnxruntime` feature.

use std::path::Path;
use std::time::Instant;

use ort::ep;
use ort::memory::{AllocationDevice, Allocator, AllocatorType, MemoryInfo, MemoryType};
use ort::session::builder::GraphOptimizationLevel;
use ort::session::{IoBinding, Session};
use ort::value::{Shape, Tensor, TensorRefMut};

use super::{Graph, HEIGHT, HISTORY, Runner, STATES, WIDTH, engine_dir, expected_inputs, output_shapes};
use crate::nvdec::CuDevicePtr;
use crate::onnx::Backend;

/// A session with its outputs bound. ONNX Runtime owns the outputs. Field
/// order is drop order: the binding holds the output tensors, which the
/// allocator must outlive.
pub struct OrtGraph {
    binding: IoBinding,
    session: Session,
    _allocator: Allocator,
}

impl OrtGraph {
    /// Binds our input buffers and runs. ONNX Runtime reads a bound input
    /// when it is bound, so the inputs are bound again for every run (as
    /// DepthModel::infer_on_device does) and released afterwards. `packed`
    /// is the step's eight histories; the cold start has none.
    pub fn run(&mut self, image_ptr: CuDevicePtr, packed: Option<[CuDevicePtr; 8]>) -> Result<(), String> {
        let err = |e: ort::Error| e.to_string();
        let binding = &mut self.binding;
        // SAFETY: the image and packed buffers are ours, sized for these
        // shapes, and outlive the run; they are unbound before returning.
        let bound = unsafe {
            let image_shape = Shape::new([1, 1, 3, HEIGHT as i64, WIDTH as i64]);
            let image = TensorRefMut::<f32>::from_raw(cuda_memory().map_err(err)?, image_ptr as usize as *mut _, image_shape)
                .map_err(err)?;
            binding.bind_input("image", &image).map_err(err)?;
            if let Some(packed) = packed {
                for (i, &(tokens, channels)) in STATES.iter().enumerate() {
                    let shape = Shape::new([tokens as i64, HISTORY as i64, channels as i64]);
                    let cache = TensorRefMut::<f32>::from_raw(cuda_memory().map_err(err)?, packed[i] as usize as *mut _, shape)
                        .map_err(err)?;
                    binding.bind_input(format!("cache_{i}"), &cache).map_err(err)?;
                }
            }
            Ok::<(), String>(())
        };
        // Run returns once the outputs are ready on the device.
        let ran = bound.and_then(|()| self.session.run_binding(binding).map(drop).map_err(err));
        binding.clear_inputs();
        ran
    }
}

fn cuda_memory() -> ort::Result<MemoryInfo<'static>> {
    MemoryInfo::new(AllocationDevice::CUDA, 0, AllocatorType::Device, MemoryType::Default)
}

/// open_graph on ONNX Runtime.
pub fn open(path: &Path, backend: Backend, fp16: bool, opt_level: u8, cache_dir: &Path, sha256: &str, gpu: &str) -> Result<Graph, String> {
    let file = path.file_name().and_then(|n| n.to_str()).unwrap_or("model");
    let fail = |err: ort::Error| format!("{file} ({}): {err}", backend.label());
    let (session, engine) = match backend {
        Backend::Cuda => {
            let cuda = ep::CUDA::default().build().error_on_failure();
            (build_session(path, [cuda]).map_err(fail)?, String::new())
        }
        Backend::TensorRt => {
            let precision = if fp16 { "fp16" } else { "fp32" };
            let trt = crate::onnx::tensorrt_version().unwrap_or_else(|| "unknown".into());
            let dir = engine_dir(cache_dir, sha256, precision, opt_level, &trt, gpu);
            let cached = has_engine(&dir);
            let started = Instant::now();
            let mut result = build_session(path, [tensorrt(&dir, fp16, opt_level), cuda_fallback()]);
            if result.is_err() && cached {
                // A cached engine this TensorRT can't load: build it again.
                log::warn!("Rebuilding the TensorRT engine in {}", dir.display());
                let _ = std::fs::remove_dir_all(&dir);
                result = build_session(path, [tensorrt(&dir, fp16, opt_level), cuda_fallback()]);
            }
            let session = result.map_err(fail)?;
            let engine = if cached && has_engine(&dir) {
                "from cache".to_string()
            } else {
                format!("built in {:.0} s", started.elapsed().as_secs_f64())
            };
            log::info!("{file}: TensorRT {precision} engine {engine} ({})", dir.display());
            (session, engine)
        }
    };
    for (name, shape) in expected_inputs(fp16) {
        let found = session
            .inputs()
            .iter()
            .find(|i| i.name() == name)
            .and_then(|i| i.dtype().tensor_shape().map(|s| s.iter().copied().collect::<Vec<i64>>()));
        if found.as_ref() != Some(&shape) {
            return Err(format!("{file}: expected input {name} {shape:?}, found {found:?}"));
        }
    }

    let err = |e: ort::Error| format!("{file}: {e}");
    let allocator = Allocator::new(&session, cuda_memory().map_err(err)?).map_err(err)?;
    let mut binding = session.create_binding().map_err(err)?;
    let mut outputs = Vec::with_capacity(9);
    for (name, shape) in output_shapes() {
        let mut tensor = Tensor::<f32>::new(&allocator, shape).map_err(err)?;
        outputs.push(tensor.data_ptr_mut() as u64);
        binding.bind_output(name, tensor).map_err(err)?;
    }
    Ok(Graph { runner: Runner::Ort(OrtGraph { binding, session, _allocator: allocator }), outputs, engine })
}

fn build_session<const N: usize>(path: &Path, providers: [ort::ep::ExecutionProviderDispatch; N]) -> ort::Result<Session> {
    Session::builder()?
        .with_optimization_level(GraphOptimizationLevel::All)
        .map_err(|e| -> ort::Error { e.into() })?
        .with_execution_providers(providers)
        .map_err(|e| -> ort::Error { e.into() })?
        .commit_from_file(path)
}

fn tensorrt(dir: &Path, fp16: bool, opt_level: u8) -> ort::ep::ExecutionProviderDispatch {
    let _ = std::fs::create_dir_all(dir);
    let dir = dir.display().to_string();
    ep::TensorRT::default()
        .with_fp16(fp16)
        .with_builder_optimization_level(opt_level)
        .with_engine_cache(true)
        .with_engine_cache_path(&dir)
        .with_timing_cache(true)
        .with_timing_cache_path(&dir)
        .build()
        .error_on_failure()
}

/// For any node TensorRT can't take.
fn cuda_fallback() -> ort::ep::ExecutionProviderDispatch {
    ep::CUDA::default().build()
}

fn has_engine(dir: &Path) -> bool {
    std::fs::read_dir(dir)
        .map(|d| d.flatten().any(|e| e.path().extension().is_some_and(|x| x == "engine")))
        .unwrap_or(false)
}
