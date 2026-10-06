// Video Depth Anything (src/vda.rs): input preparation and temporal-state
// bookkeeping, so frames, depth and the eight state histories stay on the GPU.
//
//   vda_clear             zeroes the step's non-finite flag
//   vda_resize_normalize  decoded frame (planar RGB 0..1) to the model input:
//                         OpenCV INTER_CUBIC, then the DINO mean/std
//   vda_thumb             16x9 cell means of the model input, for cut detection
//   vda_append            one new state (f32) into a history slot (f16), and
//                         flags any non-finite value
//   vda_check             flags non-finite values in the depth output
//   vda_pack              gathers the 31 selected history slots into the
//                         model's [tokens, 31, channels] f32 cache input
//   vda_blur              one direction of a Gaussian blur (edge softening)
//
// Built to PTX and embedded in Meteor. Rebuild after editing with
// tools/build_kernels.py. The CPU versions of vda_resize_normalize and
// vda_blur are resize_normalize and blur in src/vda.rs; keep them in step.

#define HISTORY 31
#define THUMB_W 16
#define THUMB_H 9

__constant__ float MEAN[3] = {0.485f, 0.456f, 0.406f};
__constant__ float STD[3] = {0.229f, 0.224f, 0.225f};

// OpenCV's bicubic kernel (A = -0.75), weights for taps at -1, 0, 1, 2.
__device__ void cubic_weights(float t, float w[4])
{
    const float A = -0.75f;
    w[0] = ((A * (t + 1.0f) - 5.0f * A) * (t + 1.0f) + 8.0f * A) * (t + 1.0f) - 4.0f * A;
    w[1] = ((A + 2.0f) * t - (A + 3.0f)) * t * t + 1.0f;
    w[2] = ((A + 2.0f) * (1.0f - t) - (A + 3.0f)) * (1.0f - t) * (1.0f - t) + 1.0f;
    w[3] = 1.0f - w[0] - w[1] - w[2];
}

__device__ unsigned short to_half(float f)
{
    unsigned short h;
    asm("cvt.rn.f16.f32 %0, %1;" : "=h"(h) : "f"(f));
    return h;
}

__device__ float from_half(unsigned short h)
{
    float f;
    asm("cvt.f32.f16 %0, %1;" : "=f"(f) : "h"(h));
    return f;
}

extern "C" __global__ void vda_clear(unsigned int* flag)
{
    *flag = 0;
}

// Pixel centres map as in cv2.resize: src = (dst + 0.5) * scale - 0.5, with
// out-of-range taps clamped to the edge. No clamping of the result: the
// reference resizes float images, which keeps the cubic overshoot.
extern "C" __global__ void vda_resize_normalize(
    const float* __restrict__ src, int src_width, int src_height,
    int width, int height, float* __restrict__ out)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= width || y >= height) return;

    float fx = ((float)x + 0.5f) * ((float)src_width / (float)width) - 0.5f;
    float fy = ((float)y + 0.5f) * ((float)src_height / (float)height) - 0.5f;
    int ix = (int)floorf(fx), iy = (int)floorf(fy);
    float wx[4], wy[4];
    cubic_weights(fx - (float)ix, wx);
    cubic_weights(fy - (float)iy, wy);
    int cols[4], rows[4];
    for (int k = 0; k < 4; ++k) {
        cols[k] = min(max(ix - 1 + k, 0), src_width - 1);
        rows[k] = min(max(iy - 1 + k, 0), src_height - 1);
    }
    int src_plane = src_width * src_height;
    int plane = width * height;
    for (int c = 0; c < 3; ++c) {
        const float* channel = src + c * src_plane;
        float sum = 0.0f;
        for (int j = 0; j < 4; ++j) {
            const float* row = channel + rows[j] * src_width;
            float across = 0.0f;
            for (int k = 0; k < 4; ++k) across += wx[k] * row[cols[k]];
            sum += wy[j] * across;
        }
        out[c * plane + y * width + x] = (sum - MEAN[c]) / STD[c];
    }
}

// One block per cell; thumb is [3][THUMB_H][THUMB_W].
extern "C" __global__ void vda_thumb(const float* __restrict__ image, int width, int height,
                                     float* __restrict__ thumb)
{
    __shared__ float partial[3][256];
    int cx = blockIdx.x, cy = blockIdx.y;
    int x0 = cx * width / THUMB_W, x1 = (cx + 1) * width / THUMB_W;
    int y0 = cy * height / THUMB_H, y1 = (cy + 1) * height / THUMB_H;
    int cell_w = x1 - x0, count = cell_w * (y1 - y0);
    int plane = width * height;
    float sum[3] = {0.0f, 0.0f, 0.0f};
    for (int i = threadIdx.x; i < count; i += blockDim.x) {
        int p = (y0 + i / cell_w) * width + x0 + i % cell_w;
        for (int c = 0; c < 3; ++c) sum[c] += image[c * plane + p];
    }
    for (int c = 0; c < 3; ++c) partial[c][threadIdx.x] = sum[c];
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (threadIdx.x < s) {
            for (int c = 0; c < 3; ++c) partial[c][threadIdx.x] += partial[c][threadIdx.x + s];
        }
        __syncthreads();
    }
    if (threadIdx.x == 0) {
        for (int c = 0; c < 3; ++c) {
            thumb[(c * THUMB_H + cy) * THUMB_W + cx] = partial[c][0] / (float)count;
        }
    }
}

extern "C" __global__ void vda_append(const float* __restrict__ state, int n,
                                      unsigned short* __restrict__ slot, unsigned int* flag)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float v = state[i];
    if (!isfinite(v)) atomicOr(flag, 1u);
    slot[i] = to_half(v);
}

extern "C" __global__ void vda_check(const float* __restrict__ values, int n, unsigned int* flag)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n && !isfinite(values[i])) atomicOr(flag, 2u);
}

#define BLUR_MAX_RADIUS 8

// One pass of a separable Gaussian blur (horizontal when `horizontal` is
// set), radius ceil(3 sigma), clamped to the edges. Run across then down,
// it turns a hard depth edge into a slope a few texels wide, which the
// headset's stereo warp stretches smoothly instead of in grid-sized steps.
extern "C" __global__ void vda_blur(const float* __restrict__ in, float* __restrict__ out,
                                    int width, int height, float sigma, int horizontal)
{
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x >= width || y >= height) return;
    int radius = min((int)ceilf(3.0f * sigma), BLUR_MAX_RADIUS);
    float k = -0.5f / (sigma * sigma);
    float num = 0.0f, den = 0.0f;
    for (int t = -radius; t <= radius; ++t) {
        int sx = horizontal ? min(max(x + t, 0), width - 1) : x;
        int sy = horizontal ? y : min(max(y + t, 0), height - 1);
        float w = __expf(k * (float)(t * t));
        num += w * in[sy * width + sx];
        den += w;
    }
    out[y * width + x] = num / den;
}

struct Selection {
    int slot[HISTORY];
};

// pool is [slots][tokens][channels]; out is [tokens][HISTORY][channels].
extern "C" __global__ void vda_pack(const unsigned short* __restrict__ pool, int tokens, int channels,
                                    Selection selection, float* __restrict__ out)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    int total = tokens * HISTORY * channels;
    if (i >= total) return;
    int c = i % channels;
    int t = (i / channels) % HISTORY;
    int token = i / (channels * HISTORY);
    long slot_size = (long)tokens * channels;
    out[i] = from_half(pool[selection.slot[t] * slot_size + (long)token * channels + c]);
}
