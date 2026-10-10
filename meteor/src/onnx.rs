//! ONNX Runtime with the CUDA execution provider.
//!
//! The runtime is loaded at run time (`ort`'s load-dynamic), so Meteor builds
//! without it and runs as a plain proxy when it isn't installed. For now it
//! comes from the `onnxruntime-gpu` pip package, which also provides the CUDA
//! and cuDNN libraries (see `tools/bench_depth.py` for the setup):
//!
//! - `onnxruntime_lib` in meteor.toml, or
//! - `target/bench-venv` next to the Meteor binary (development).
//!
//! The CUDA libraries are preloaded from the `nvidia/*/lib` folders next to
//! the runtime, like onnxruntime's own Python `preload_dlls()`, so nothing
//! needs `LD_LIBRARY_PATH`. TensorRT (`tensorrt-cu13<11` from pip, because
//! ONNX Runtime 1.30 links TensorRT 10) is preloaded from `tensorrt_libs`
//! when it is installed.
//!
//! Two backends: CUDA loads in a fraction of a second; TensorRT fp16 runs
//! ZipDepth 384 about twice as fast (0.85 ms against 1.8 ms on an RTX 3090)
//! but builds an engine for about 90 s the first time it sees a model on a
//! GPU. The engine is cached, and later loads take about 0.4 s.

//!
//! Without the `onnxruntime` feature (the AppImage), a stub stands in: init()
//! says why, and no model loads.

#[cfg(feature = "onnxruntime")]
mod runtime;
#[cfg(feature = "onnxruntime")]
pub use runtime::*;

#[cfg(not(feature = "onnxruntime"))]
mod stub;
#[cfg(not(feature = "onnxruntime"))]
pub use stub::*;

/// Where an ONNX model runs. VDA uses it too, for its native TensorRT path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Cuda,
    TensorRt,
}

impl Backend {
    pub fn label(self) -> &'static str {
        match self {
            Backend::Cuda => "CUDA",
            Backend::TensorRt => "TensorRT fp16",
        }
    }
}

