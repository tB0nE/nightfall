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

// P016 contains 10-bit samples left-aligned in 16-bit words. The HDR stream
// uses BT.2020/PQ, so feeding its encoded values straight to the SDR-trained
// depth model gives incorrect maps. Use the same PQ decode, gamut conversion,
// luminance-preserving tonemap and sRGB encode as yuv_display_hdr.gdshader.
__device__ float bilinear_p016(const unsigned short* plane, int pitch, int stride,
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
    float a = (float)(plane[pitch * y0 + stride * x0] >> 6);
    float b = (float)(plane[pitch * y0 + stride * x1] >> 6);
    float c = (float)(plane[pitch * y1 + stride * x0] >> 6);
    float d = (float)(plane[pitch * y1 + stride * x1] >> 6);
    float top = a + (b - a) * ax;
    float bottom = c + (d - c) * ax;
    return top + (bottom - top) * ay;
}

__device__ float pq_decode(float e) {
    const float m1 = 0.1593017578125f, m2 = 78.84375f;
    const float c1 = 0.8359375f, c2 = 18.8515625f, c3 = 18.6875f;
    float ep = powf(fminf(fmaxf(e, 0.0f), 1.0f), 1.0f / m2);
    float n = fmaxf(ep - c1, 0.0f);
    float d = fmaxf(c2 - c3 * ep, 1e-6f);
    return powf(n / d, 1.0f / m1) / 0.0203f;
}

__device__ float srgb_encode(float c) {
    c = fminf(fmaxf(c, 0.0f), 1.0f);
    return c <= 0.0031308f ? c * 12.92f : 1.055f * powf(c, 1.0f / 2.4f) - 0.055f;
}

extern "C" __global__ void p016_to_tensor(
    const unsigned short* __restrict__ p016, int pitch_bytes, int src_width, int src_height,
    int width, int height,
    float y_offset, float y_scale, float c_scale,
    float r_v, float g_u, float g_v, float b_u,
    int hdr_pq, float* __restrict__ out)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= width || y >= height) return;

    int pitch = pitch_bytes / 2;
    const unsigned short* chroma = p016 + pitch * src_height;
    int chroma_width = src_width / 2, chroma_height = src_height / 2;
    float foot_u = 1.0f / (float)width, foot_v = 1.0f / (float)height;
    float sum_r = 0.0f, sum_g = 0.0f, sum_b = 0.0f;
    for (int ty = 0; ty < TAPS; ++ty) {
        for (int tx = 0; tx < TAPS; ++tx) {
            float u = ((float)x + ((float)tx + 0.5f) / TAPS) * foot_u;
            float v = ((float)y + ((float)ty + 0.5f) / TAPS) * foot_v;
            float l = (bilinear_p016(p016, pitch, 1, src_width, src_height,
                                     u * src_width, v * src_height) - y_offset * 4.0f) * y_scale;
            float cu = (bilinear_p016(chroma, pitch, 2, chroma_width, chroma_height,
                                      u * chroma_width, v * chroma_height) - 512.0f) * c_scale;
            float cv = (bilinear_p016(chroma + 1, pitch, 2, chroma_width, chroma_height,
                                      u * chroma_width, v * chroma_height) - 512.0f) * c_scale;
            sum_r += fminf(fmaxf(l + r_v * cv, 0.0f), 1023.0f);
            sum_g += fminf(fmaxf(l - g_u * cu - g_v * cv, 0.0f), 1023.0f);
            sum_b += fminf(fmaxf(l + b_u * cu, 0.0f), 1023.0f);
        }
    }
    float r = sum_r / (TAPS * TAPS * 1023.0f);
    float g = sum_g / (TAPS * TAPS * 1023.0f);
    float b = sum_b / (TAPS * TAPS * 1023.0f);
    if (hdr_pq) {
        float pr = pq_decode(r), pg = pq_decode(g), pb = pq_decode(b);
        r = 1.6604910f * pr - 0.5876411f * pg - 0.0728499f * pb;
        g = -0.1245505f * pr + 1.1328999f * pg - 0.0083494f * pb;
        b = -0.0181508f * pr - 0.1005789f * pg + 1.1187297f * pb;
        float lum = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        float scale = lum > 0.0001f ? 1.0f / (1.0f + lum) : 1.0f;
        r = srgb_encode(r * scale);
        g = srgb_encode(g * scale);
        b = srgb_encode(b * scale);
    }
    int plane = width * height;
    int i = y * width + x;
    out[i] = rintf(r * 255.0f) / 255.0f;
    out[plane + i] = rintf(g * 255.0f) / 255.0f;
    out[2 * plane + i] = rintf(b * 255.0f) / 255.0f;
}
