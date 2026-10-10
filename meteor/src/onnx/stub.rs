//! Stands in for ONNX Runtime in builds without the `onnxruntime` feature.

use std::convert::Infallible;
use std::path::Path;

use super::Backend;

const MISSING: &str = "this build has no ONNX Runtime";

pub fn init(_configured: Option<&Path>) -> Result<String, String> {
    Err(MISSING.into())
}

pub fn cuda_backend_present() -> bool {
    false
}

/// Never exists in this build: `load` always fails.
pub struct DepthModel {
    pub backend: Backend,
    pub name: String,
    pub width: usize,
    pub height: usize,
    never: Infallible,
}

impl DepthModel {
    pub fn load(path: &Path, _backend: Backend, _cache_dir: &Path) -> Result<DepthModel, String> {
        Err(format!("{}: {MISSING}", path.display()))
    }

    pub fn infer(&mut self, _rgb: &[u8]) -> Result<Vec<f32>, String> {
        match self.never {}
    }

    pub fn infer_on_device(&mut self, _device_ptr: u64) -> Result<u64, String> {
        match self.never {}
    }

    pub fn infer_gpu(&mut self, _device_ptr: u64) -> Result<Vec<f32>, String> {
        match self.never {}
    }
}
