# TensorRT headers

From NVIDIA's open-source TensorRT repository, Apache-2.0 (`LICENSE`):

- `include/Nv*.h` except `NvOnnxParser.h`: https://github.com/NVIDIA/TensorRT,
  branch `release/10.16`, `include/`.
- `include/NvOnnxParser.h`: https://github.com/onnx/onnx-tensorrt, branch
  `release/10.16-GA`.

`cuda_stub/cuda_runtime_api.h` is Meteor's: it declares the two handle
types the headers need, so Meteor builds without the CUDA toolkit.

Meteor's `native/tensorrt.cpp` compiles against these and opens
`libnvinfer` and `libnvonnxparser` at run time (see `src/tensorrt.rs`).
