#!/usr/bin/env python3
"""Compiles meteor/kernels/*.cu to PTX with NVRTC (no host compiler needed).

The PTX files are checked in and embedded in Meteor (src/nvdec.rs), so this
only needs running after editing a kernel. It uses the NVRTC library from the
benchmark venv (see tools/bench_depth.py):

    meteor/target/bench-venv/bin/python meteor/tools/build_kernels.py

compute_75 (Turing) is the oldest target CUDA 13 supports; the driver
JIT-compiles the PTX for newer GPUs.
"""

import ctypes
import glob
import os
import sys

ARCH = b"--gpu-architecture=compute_75"
HERE = os.path.dirname(os.path.abspath(__file__))
KERNELS = os.path.join(HERE, "..", "kernels")


def load_nvrtc():
    import nvidia  # the pip CUDA packages

    for root in nvidia.__path__:
        for lib in sorted(glob.glob(os.path.join(root, "*", "lib", "libnvrtc.so*"))):
            if "builtins" not in lib:
                return ctypes.CDLL(lib)
    sys.exit("libnvrtc not found; install nvidia-cuda-nvrtc into the venv")


def compile_ptx(nvrtc, path):
    source = open(path, "rb").read()
    prog = ctypes.c_void_p()
    check = lambda rc, what: rc == 0 or sys.exit(f"{what} failed ({rc})")
    check(nvrtc.nvrtcCreateProgram(ctypes.byref(prog), source, os.path.basename(path).encode(), 0, None, None),
          "nvrtcCreateProgram")
    # No --use_fast_math and no fused multiply-add, so the results match the
    # CPU code (src/nvdec.rs, src/postprocess.rs) exactly.
    options = (ctypes.c_char_p * 3)(ARCH, b"-default-device", b"--fmad=false")
    rc = nvrtc.nvrtcCompileProgram(prog, len(options), options)
    log_size = ctypes.c_size_t()
    nvrtc.nvrtcGetProgramLogSize(prog, ctypes.byref(log_size))
    log = ctypes.create_string_buffer(log_size.value)
    nvrtc.nvrtcGetProgramLog(prog, log)
    if log.value.strip():
        print(log.value.decode())
    check(rc, "nvrtcCompileProgram")
    size = ctypes.c_size_t()
    nvrtc.nvrtcGetPTXSize(prog, ctypes.byref(size))
    ptx = ctypes.create_string_buffer(size.value)
    nvrtc.nvrtcGetPTX(prog, ptx)
    out = path[:-3] + ".ptx"
    open(out, "wb").write(ptx.value)
    print(f"{os.path.relpath(out)}: {len(ptx.value)} bytes")


nvrtc = load_nvrtc()
for cu in sorted(glob.glob(os.path.join(KERNELS, "*.cu"))):
    compile_ptx(nvrtc, cu)
