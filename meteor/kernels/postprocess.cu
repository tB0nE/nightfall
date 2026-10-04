// Depth post-processing on the GPU: the same steps, in the same order and
// with the same float arithmetic, as src/postprocess.rs (the CPU port of
// DepthEstimator.postProcess()), so both give identical 8-bit maps.
// Built without FMA contraction (tools/build_kernels.py) for that reason.
//
// Per frame, on one stream:
//   depth_minmax     one block: min and max of the raw output, clears the histogram
//   depth_histogram  512-bin histogram between min and max
//   depth_range      one thread: percentile range, then its time smoothing
//   depth_normalize  per pixel: stretch, time smoothing, convert to 8-bit

#define BINS 512
#define MINMAX_THREADS 1024

extern "C" __global__ void depth_minmax(const float* __restrict__ raw, int n,
                                        float* __restrict__ range, unsigned int* __restrict__ hist)
{
    __shared__ float smin[MINMAX_THREADS];
    __shared__ float smax[MINMAX_THREADS];
    int t = threadIdx.x;
    float lo = __int_as_float(0x7f800000), hi = -__int_as_float(0x7f800000); // +-infinity
    for (int i = t; i < n; i += blockDim.x) {
        float v = raw[i];
        lo = fminf(lo, v);
        hi = fmaxf(hi, v);
    }
    smin[t] = lo;
    smax[t] = hi;
    for (int i = t; i < BINS; i += blockDim.x) hist[i] = 0;
    __syncthreads();
    for (int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (t < s) {
            smin[t] = fminf(smin[t], smin[t + s]);
            smax[t] = fmaxf(smax[t], smax[t + s]);
        }
        __syncthreads();
    }
    if (t == 0) {
        range[0] = smin[0];
        range[1] = smax[0];
    }
}

extern "C" __global__ void depth_histogram(const float* __restrict__ raw, int n,
                                           const float* __restrict__ range, unsigned int* __restrict__ hist)
{
    __shared__ unsigned int local[BINS];
    for (int i = threadIdx.x; i < BINS; i += blockDim.x) local[i] = 0;
    __syncthreads();
    float lo = range[0], hi = range[1];
    if (hi > lo) {
        float bin_scale = (float)BINS / (hi - lo);
        for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n; i += gridDim.x * blockDim.x) {
            int b = (int)((raw[i] - lo) * bin_scale);
            b = b < 0 ? 0 : (b > BINS - 1 ? BINS - 1 : b);
            atomicAdd(&local[b], 1u);
        }
    }
    __syncthreads();
    for (int i = threadIdx.x; i < BINS; i += blockDim.x) {
        if (local[i]) atomicAdd(&hist[i], local[i]);
    }
}

// state[0..1]: the smoothed range, kept between frames.
extern "C" __global__ void depth_range(const float* __restrict__ range, const unsigned int* __restrict__ hist,
                                       unsigned int lo_target, unsigned int hi_target,
                                       int first, float alpha, float* __restrict__ state)
{
    float lo = range[0], hi = range[1];
    float robust_lo, robust_hi;
    if (!(hi > lo)) {
        robust_lo = lo;
        robust_hi = lo + 1.0f;
    } else {
        int lo_bin = BINS - 1, hi_bin = BINS - 1;
        unsigned int acc = 0;
        for (int b = 0; b < BINS; b++) {
            acc += hist[b];
            if (acc >= lo_target) { lo_bin = b; break; }
        }
        acc = 0;
        for (int b = 0; b < BINS; b++) {
            acc += hist[b];
            if (acc >= hi_target) { hi_bin = b; break; }
        }
        float bin_width = (hi - lo) / (float)BINS;
        robust_lo = lo + (float)lo_bin * bin_width;
        robust_hi = lo + (float)(hi_bin + 1) * bin_width;
        if (robust_hi <= robust_lo) robust_hi = robust_lo + 1e-3f;
    }
    if (first) {
        state[0] = robust_lo;
        state[1] = robust_hi;
    } else {
        state[0] += alpha * (robust_lo - state[0]);
        state[1] += alpha * (robust_hi - state[1]);
    }
}

extern "C" __global__ void depth_normalize(const float* __restrict__ raw, int n,
                                           const float* __restrict__ state, int first, float alpha,
                                           float* __restrict__ smoothed, unsigned char* __restrict__ out)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= n) return;
    float lo = state[0];
    float scale = 1.0f / fmaxf(state[1] - state[0], 1e-6f);
    float v = fminf(fmaxf((raw[i] - lo) * scale, 0.0f), 1.0f);
    float s = first ? v : smoothed[i] + alpha * (v - smoothed[i]);
    smoothed[i] = s;
    // Truncation, as the Java/Rust cast does.
    out[i] = (unsigned char)(fminf(fmaxf(s, 0.0f), 1.0f) * 255.0f);
}
