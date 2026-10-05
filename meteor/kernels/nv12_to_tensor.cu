// A full-size decoded NV12 frame to the model's input: planar RGB floats in
// 0..1, NCHW with N = 1.
//
// Each model pixel averages a 4x4 grid of bilinear samples spread over its
// footprint in the frame, the same reduction as the Quest's depth capture
// (GLES_DEPTH_CAPTURE_FRAGMENT_SHADER in
// addons/nightfall-stream/src/video/texture_uploader.cpp), so host depth sees
// the same input as on-device depth. A single sample per pixel would alias
// text and fine detail. The CPU version is nv12_box_to_rgb in src/nvdec.rs;
// keep the two in step.
//
// Built to PTX and embedded in Meteor (src/nvdec.rs). Rebuild after editing
// with tools/build_kernels.py (NVRTC; no host compiler needed).
// compute_75 (Turing) is the oldest target CUDA 13 supports; the driver
// JIT-compiles the PTX for newer GPUs.

#define TAPS 4

// Bilinear sample of one channel at (x, y) in texel units (texel centres at
// +0.5), clamped to the edge. `stride` is the distance between samples of
// this channel in a row (1 for luma, 2 for interleaved chroma).
__device__ float bilinear(const unsigned char* plane, int pitch, int stride,
                          int width, int height, float x, float y)
{
    x -= 0.5f;
    y -= 0.5f;
    float fx = floorf(x), fy = floorf(y);
    float ax = x - fx, ay = y - fy;
    int x0 = min(max((int)fx, 0), width - 1);
    int x1 = min(max((int)fx + 1, 0), width - 1);
    int y0 = min(max((int)fy, 0), height - 1);
    int y1 = min(max((int)fy + 1, 0), height - 1);
    float a = plane[pitch * y0 + stride * x0];
    float b = plane[pitch * y0 + stride * x1];
    float c = plane[pitch * y1 + stride * x0];
    float d = plane[pitch * y1 + stride * x1];
    float top = a + (b - a) * ax;
    float bottom = c + (d - c) * ax;
    return top + (bottom - top) * ay;
}

extern "C" __global__ void nv12_to_tensor(
    const unsigned char* __restrict__ nv12, int pitch, int src_width, int src_height,
    int width, int height,
    float y_offset, float y_scale, float c_scale,
    float r_v, float g_u, float g_v, float b_u,
    float* __restrict__ out)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= width || y >= height) return;

    const unsigned char* chroma = nv12 + pitch * src_height;
    int chroma_width = src_width / 2, chroma_height = src_height / 2;
    float foot_u = 1.0f / (float)width, foot_v = 1.0f / (float)height;
    float sum_r = 0.0f, sum_g = 0.0f, sum_b = 0.0f;
    for (int ty = 0; ty < TAPS; ++ty) {
        for (int tx = 0; tx < TAPS; ++tx) {
            float u = ((float)x + 0.5f) * foot_u + (((float)tx + 0.5f) / TAPS - 0.5f) * foot_u;
            float v = ((float)y + 0.5f) * foot_v + (((float)ty + 0.5f) / TAPS - 0.5f) * foot_v;
            u = fminf(fmaxf(u, 0.0f), 1.0f);
            v = fminf(fmaxf(v, 0.0f), 1.0f);
            float l = (bilinear(nv12, pitch, 1, src_width, src_height,
                                u * src_width, v * src_height) - y_offset) * y_scale;
            float cu = (bilinear(chroma, pitch, 2, chroma_width, chroma_height,
                                 u * chroma_width, v * chroma_height) - 128.0f) * c_scale;
            float cv = (bilinear(chroma + 1, pitch, 2, chroma_width, chroma_height,
                                 u * chroma_width, v * chroma_height) - 128.0f) * c_scale;
            sum_r += fminf(fmaxf(l + r_v * cv, 0.0f), 255.0f);
            sum_g += fminf(fmaxf(l - g_u * cu - g_v * cv, 0.0f), 255.0f);
            sum_b += fminf(fmaxf(l + b_u * cu, 0.0f), 255.0f);
        }
    }

    // Rounded to whole 8-bit levels, as the Quest's 8-bit capture target is.
    int plane = width * height;
    int i = y * width + x;
    out[i] = rintf(sum_r / (TAPS * TAPS)) / 255.0f;
    out[plane + i] = rintf(sum_g / (TAPS * TAPS)) / 255.0f;
    out[2 * plane + i] = rintf(sum_b / (TAPS * TAPS)) / 255.0f;
}
