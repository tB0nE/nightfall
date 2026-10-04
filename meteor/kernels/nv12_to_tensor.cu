// NV12 (as NVDEC outputs it, already scaled to the model size) to the
// model's input: planar RGB floats in 0..1, NCHW with N = 1.
//
// Built to PTX and embedded in Meteor (src/nvdec.rs). Rebuild after editing
// with tools/build_kernels.py (NVRTC; no host compiler needed).
// compute_75 (Turing) is the oldest target CUDA 13 supports; the driver
// JIT-compiles the PTX for newer GPUs.

extern "C" __global__ void nv12_to_tensor(
    const unsigned char* __restrict__ nv12, int pitch, int width, int height,
    float y_offset, float y_scale, float c_scale,
    float r_v, float g_u, float g_v, float b_u,
    float* __restrict__ out)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= width || y >= height) return;

    const unsigned char* chroma = nv12 + pitch * height + pitch * (y / 2);
    float l = ((float)nv12[pitch * y + x] - y_offset) * y_scale;
    float u = ((float)chroma[x & ~1] - 128.0f) * c_scale;
    float v = ((float)chroma[x | 1] - 128.0f) * c_scale;

    // Rounded to whole 8-bit levels, matching the CPU path (nv12_to_rgb).
    float r = fminf(fmaxf(rintf(l + r_v * v), 0.0f), 255.0f);
    float g = fminf(fmaxf(rintf(l - g_u * u - g_v * v), 0.0f), 255.0f);
    float b = fminf(fmaxf(rintf(l + b_u * u), 0.0f), 255.0f);

    int plane = width * height;
    int i = y * width + x;
    out[i] = r / 255.0f;
    out[plane + i] = g / 255.0f;
    out[2 * plane + i] = b / 255.0f;
}
