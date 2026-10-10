"""Native TensorRT spike for VDA-S: no ONNX Runtime, no cudart.

usage:
  trt_spike.py run   <engine>                 time an existing plan
  trt_spike.py build <onnx> <plan> [--f16io]  build a plan natively, then time it

GPU memory, streams and events come from the CUDA driver API (libcuda) via
ctypes, so the only NVIDIA user-space libraries are TensorRT's own.
"""
import ctypes
import statistics
import sys
import time

import tensorrt as trt

cu = ctypes.CDLL("libcuda.so.1")


def check(rc, what):
    if rc != 0:
        raise RuntimeError(f"{what} failed: {rc}")


check(cu.cuInit(0), "cuInit")
dev = ctypes.c_int()
check(cu.cuDeviceGet(ctypes.byref(dev), 0), "cuDeviceGet")
ctx = ctypes.c_void_p()
check(cu.cuDevicePrimaryCtxRetain(ctypes.byref(ctx), dev), "retain")
check(cu.cuCtxSetCurrent(ctx), "set ctx")

LOG = trt.Logger(trt.Logger.WARNING)


def alloc(nbytes):
    p = ctypes.c_uint64()
    check(cu.cuMemAlloc_v2(ctypes.byref(p), ctypes.c_size_t(nbytes)), "cuMemAlloc")
    check(cu.cuMemsetD8_v2(p, ctypes.c_ubyte(0), ctypes.c_size_t(nbytes)), "memset")
    return p.value


def build(onnx_path, plan_path, f16io):
    builder = trt.Builder(LOG)
    network = builder.create_network(0)
    parser = trt.OnnxParser(network, LOG)
    with open(onnx_path, "rb") as f:
        if not parser.parse(f.read(), onnx_path):
            for i in range(parser.num_errors):
                print(parser.get_error(i))
            sys.exit(1)
    if f16io:
        for i in range(network.num_inputs):
            network.get_input(i).dtype = trt.float16
        for i in range(network.num_outputs):
            network.get_output(i).dtype = trt.float16
    config = builder.create_builder_config()
    config.set_flag(trt.BuilderFlag.FP16)
    config.builder_optimization_level = 4
    started = time.time()
    plan = builder.build_serialized_network(network, config)
    if plan is None:
        sys.exit("build failed")
    print(f"built in {time.time() - started:.0f} s, {plan.nbytes / 2**20:.1f} MiB")
    with open(plan_path, "wb") as f:
        f.write(plan)
    return bytes(plan)


def run(plan):
    runtime = trt.Runtime(LOG)
    started = time.time()
    engine = runtime.deserialize_cuda_engine(plan)
    ctx_ = engine.create_execution_context()
    print(f"deserialized in {(time.time() - started) * 1000:.0f} ms")
    stream = ctypes.c_void_p()
    check(cu.cuStreamCreate(ctypes.byref(stream), 1), "stream")
    io_bytes = 0
    for i in range(engine.num_io_tensors):
        name = engine.get_tensor_name(i)
        shape = list(ctx_.get_tensor_shape(name))
        if engine.get_tensor_mode(name) == trt.TensorIOMode.INPUT:
            ctx_.set_input_shape(name, shape)
        dtype = engine.get_tensor_dtype(name)
        n = 1
        for d in shape:
            n *= max(d, 1)
        nbytes = n * dtype.itemsize
        io_bytes += nbytes
        ctx_.set_tensor_address(name, alloc(nbytes))
        if i < 3 or i == engine.num_io_tensors - 1:
            print(f"  {engine.get_tensor_mode(name).name:6} {name:16} {dtype.name:6} {shape}")
    print(f"  ({engine.num_io_tensors} tensors, {io_bytes / 2**20:.1f} MiB of I/O)")
    start, end = ctypes.c_void_p(), ctypes.c_void_p()
    check(cu.cuEventCreate(ctypes.byref(start), 0), "event")
    check(cu.cuEventCreate(ctypes.byref(end), 0), "event")
    gpu, wall = [], []
    for i in range(600):
        t0 = time.perf_counter()
        check(cu.cuEventRecord(start, stream), "record")
        assert ctx_.execute_async_v3(stream.value)
        check(cu.cuEventRecord(end, stream), "record")
        check(cu.cuEventSynchronize(end), "sync")
        t1 = time.perf_counter()
        ms = ctypes.c_float()
        check(cu.cuEventElapsedTime(ctypes.byref(ms), start, end), "elapsed")
        if i >= 100:
            gpu.append(ms.value)
            wall.append((t1 - t0) * 1000)
    q = lambda xs, p: sorted(xs)[int(len(xs) * p)]
    print(f"GPU  median {statistics.median(gpu):.2f} ms, p95 {q(gpu, 0.95):.2f} ms")
    print(f"wall median {statistics.median(wall):.2f} ms, p95 {q(wall, 0.95):.2f} ms")


if __name__ == "__main__":
    if sys.argv[1] == "run":
        with open(sys.argv[2], "rb") as f:
            run(f.read())
    else:
        run(build(sys.argv[2], sys.argv[3], "--f16io" in sys.argv))
