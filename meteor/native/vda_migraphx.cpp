// VDA on AMD GPUs through MIGraphX (ROCm), behind the same C ABI as
// vda_vulkan.cpp (meteor_vda_*), plus *_named entry points that pick the HIP
// device by the GPU name Meteor shows. Every ROCm library is loaded at run
// time: Meteor never links against ROCm, and without it this runtime reports
// itself unsupported and the model stays out of the menu.
//
// Per step, one recorded HIP graph replays: gather the 31 history states the
// model attends to (44-slot pool, the reference selection), the compiled
// MIGraphX step program, and storing the new states. Replaying the whole step
// at once matters: the step is ~1100 small kernels, and launching them one by
// one costs more than running them. The small kernels below (gather/store,
// resize+normalise, cut thumbnail, softening) are compiled with hiprtc for the
// GPU that is present, so building Meteor needs only ROCm's headers.
//
// The first load compiles both graphs with MIGraphX (a few minutes) and caches
// them under <model>/compiled/<gpu arch>-<runtime>/; later loads take seconds.
#define __HIP_PLATFORM_AMD__ 1
#include <hip/hip_runtime_api.h>
#include <hip/hiprtc.h>
#include <migraphx/migraphx.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

#define API extern "C" __attribute__((visibility("default")))

namespace {
void error_text(char* out, size_t size, const std::string& text) { if (out && size) std::snprintf(out, size, "%s", text.c_str()); }
void require(bool ok, const std::string& what) { if (!ok) throw std::runtime_error(what); }

constexpr int WIDTH = 518, HEIGHT = 294, SLOTS = 44, HISTORY = 31, STATES = 8;
constexpr int CHANNELS[STATES] = {192, 192, 384, 384, 64, 64, 64, 64};
constexpr int TOKENS[STATES] = {777, 777, 209, 209, 777, 777, 3108, 3108};

// ---- ROCm, loaded at run time ---------------------------------------------
void* open_any(std::initializer_list<const char*> names) {
    for (const char* name : names) if (void* lib = dlopen(name, RTLD_NOW | RTLD_LOCAL)) return lib;
    return nullptr;
}
struct Rocm {
    void *hip = nullptr, *rtc = nullptr, *mgx = nullptr;
    std::string failure;
#define F(name) decltype(&::name) name##_ = nullptr
    F(hipGetDeviceCount); F(hipGetDevicePropertiesR0600); F(hipSetDevice); F(hipGetErrorString);
    hipError_t (*hipMalloc_)(void**, size_t) = nullptr; F(hipFree); hipError_t (*hipHostMalloc_)(void**, size_t, unsigned int) = nullptr; F(hipHostFree); F(hipMemset); F(hipMemcpyAsync);
    F(hipStreamCreateWithFlags); F(hipStreamDestroy); F(hipStreamSynchronize);
    F(hipStreamBeginCapture); F(hipStreamEndCapture); F(hipGraphInstantiate); F(hipGraphLaunch);
    F(hipGraphExecDestroy); F(hipGraphDestroy);
    F(hipModuleLoadData); F(hipModuleGetFunction); F(hipModuleLaunchKernel); F(hipModuleUnload);
    F(hiprtcCreateProgram); F(hiprtcCompileProgram); F(hiprtcGetCodeSize); F(hiprtcGetCode);
    F(hiprtcGetProgramLogSize); F(hiprtcGetProgramLog); F(hiprtcDestroyProgram);
    F(migraphx_load); F(migraphx_save); F(migraphx_parse_onnx); F(migraphx_quantize_fp16);
    F(migraphx_program_compile); F(migraphx_target_create); F(migraphx_target_destroy);
    F(migraphx_compile_options_create); F(migraphx_compile_options_set_offload_copy); F(migraphx_compile_options_destroy);
    F(migraphx_onnx_options_create); F(migraphx_onnx_options_set_external_data_path); F(migraphx_onnx_options_destroy);
    F(migraphx_file_options_create); F(migraphx_file_options_destroy);
    F(migraphx_program_get_parameter_shapes); F(migraphx_program_parameter_shapes_size);
    F(migraphx_program_parameter_shapes_names); F(migraphx_program_parameter_shapes_get);
    F(migraphx_program_parameter_shapes_destroy); F(migraphx_shape_bytes); F(migraphx_shape_type);
    F(migraphx_argument_create); F(migraphx_argument_destroy);
    F(migraphx_program_parameters_create); F(migraphx_program_parameters_add); F(migraphx_program_parameters_destroy);
    F(migraphx_program_run_async); F(migraphx_arguments_destroy); F(migraphx_program_destroy);
#undef F
    std::string runtime_id;  // which MIGraphX build compiled a cached program
    Rocm() {
        hip = open_any({"libamdhip64.so.7", "libamdhip64.so.6", "libamdhip64.so", "/opt/rocm/lib/libamdhip64.so"});
        rtc = open_any({"libhiprtc.so.7", "libhiprtc.so.6", "libhiprtc.so", "/opt/rocm/lib/libhiprtc.so"});
        mgx = open_any({"libmigraphx_c.so.3", "libmigraphx_c.so", "/opt/rocm/lib/libmigraphx_c.so"});
        if (!hip || !rtc || !mgx) { failure = "ROCm with MIGraphX not found (libamdhip64, libhiprtc, libmigraphx_c)"; return; }
        bool ok = true;
#define L(lib, name) ok = ok && (name##_ = reinterpret_cast<decltype(name##_)>(dlsym(lib, #name)))
        L(hip, hipGetDeviceCount); L(hip, hipGetDevicePropertiesR0600); L(hip, hipSetDevice); L(hip, hipGetErrorString);
        L(hip, hipMalloc); L(hip, hipFree); L(hip, hipHostMalloc); L(hip, hipHostFree); L(hip, hipMemset); L(hip, hipMemcpyAsync);
        L(hip, hipStreamCreateWithFlags); L(hip, hipStreamDestroy); L(hip, hipStreamSynchronize);
        L(hip, hipStreamBeginCapture); L(hip, hipStreamEndCapture); L(hip, hipGraphInstantiate); L(hip, hipGraphLaunch);
        L(hip, hipGraphExecDestroy); L(hip, hipGraphDestroy);
        L(hip, hipModuleLoadData); L(hip, hipModuleGetFunction); L(hip, hipModuleLaunchKernel); L(hip, hipModuleUnload);
        L(rtc, hiprtcCreateProgram); L(rtc, hiprtcCompileProgram); L(rtc, hiprtcGetCodeSize); L(rtc, hiprtcGetCode);
        L(rtc, hiprtcGetProgramLogSize); L(rtc, hiprtcGetProgramLog); L(rtc, hiprtcDestroyProgram);
        L(mgx, migraphx_load); L(mgx, migraphx_save); L(mgx, migraphx_parse_onnx); L(mgx, migraphx_quantize_fp16);
        L(mgx, migraphx_program_compile); L(mgx, migraphx_target_create); L(mgx, migraphx_target_destroy);
        L(mgx, migraphx_compile_options_create); L(mgx, migraphx_compile_options_set_offload_copy); L(mgx, migraphx_compile_options_destroy);
        L(mgx, migraphx_onnx_options_create); L(mgx, migraphx_onnx_options_set_external_data_path); L(mgx, migraphx_onnx_options_destroy);
        L(mgx, migraphx_file_options_create); L(mgx, migraphx_file_options_destroy);
        L(mgx, migraphx_program_get_parameter_shapes); L(mgx, migraphx_program_parameter_shapes_size);
        L(mgx, migraphx_program_parameter_shapes_names); L(mgx, migraphx_program_parameter_shapes_get);
        L(mgx, migraphx_program_parameter_shapes_destroy); L(mgx, migraphx_shape_bytes); L(mgx, migraphx_shape_type);
        L(mgx, migraphx_argument_create); L(mgx, migraphx_argument_destroy);
        L(mgx, migraphx_program_parameters_create); L(mgx, migraphx_program_parameters_add); L(mgx, migraphx_program_parameters_destroy);
        L(mgx, migraphx_program_run_async); L(mgx, migraphx_arguments_destroy); L(mgx, migraphx_program_destroy);
#undef L
        if (!ok) { failure = "Incompatible ROCm/MIGraphX runtime (missing symbols)"; return; }
        // The compiled-program cache is only valid for the MIGraphX build that wrote it.
        Dl_info info{};
        if (dladdr(reinterpret_cast<void*>(migraphx_program_compile_), &info) && info.dli_fname) {
            char real[4096];
            std::string path = realpath(info.dli_fname, real) ? real : info.dli_fname;
            struct stat st{};
            stat(path.c_str(), &st);
            runtime_id = path.substr(path.rfind('/') + 1) + "-" + std::to_string(static_cast<long long>(st.st_size));
        }
    }
    void check(hipError_t e, const char* what) const { if (e != hipSuccess) throw std::runtime_error(std::string(what) + ": " + hipGetErrorString_(e)); }
    void check(migraphx_status s, const char* what) const { if (s != migraphx_status_success) throw std::runtime_error(std::string(what) + " failed (MIGraphX status " + std::to_string(int(s)) + ")"); }
};
Rocm& rocm() { static Rocm r; return r; }

// The HIP device for a GPU name as Meteor shows it (Vulkan's, e.g.
// "AMD Radeon RX 7900 XT (RADV NAVI31)", which starts with HIP's name).
// Integrated GPUs are skipped: MIGraphX VDA is for discrete cards.
struct Device { int index = -1; std::string arch; };
Device find_device(const char* gpu_name) {
    auto& r = rocm();
    require(r.failure.empty(), r.failure);
    int count = 0;
    if (r.hipGetDeviceCount_(&count) != hipSuccess) count = 0;
    std::string wanted = gpu_name ? gpu_name : "";
    for (int i = 0; i < count; ++i) {
        hipDeviceProp_t prop{};
        if (r.hipGetDevicePropertiesR0600_(&prop, i) != hipSuccess || prop.integrated) continue;
        std::string name = prop.name;
        bool match = wanted.empty() || (wanted.compare(0, name.size(), name) == 0 &&
                     (wanted.size() == name.size() || wanted[name.size()] == ' ' || wanted[name.size()] == '('));
        if (match) {
            std::string arch = prop.gcnArchName;
            return {i, arch.substr(0, arch.find(':'))};
        }
    }
    throw std::runtime_error("No discrete AMD GPU for MIGraphX VDA matches " + (wanted.empty() ? std::string("(any)") : wanted));
}

// ---- Small kernels, compiled at run time for the GPU present ---------------
const char* KERNELS = R"hip(
#define SLOTS 44
#define HISTORY 31
extern "C" __global__ void gather(const float* pool, float* dst, const int* sel, int tokens, int channels) {
    int c = blockIdx.x * blockDim.x + threadIdx.x, t = blockIdx.y, token = blockIdx.z;
    if (c >= channels) return;
    dst[((size_t)token * HISTORY + t) * channels + c] = pool[((size_t)token * SLOTS + sel[t]) * channels + c];
}
extern "C" __global__ void store(float* pool, const float* src, const int* sel, int tokens, int channels) {
    int c = blockIdx.x * blockDim.x + threadIdx.x, token = blockIdx.y;
    if (c >= channels) return;
    pool[((size_t)token * SLOTS + sel[31]) * channels + c] = src[(size_t)token * channels + c];
}
__device__ void cubic(float t, float* w) {
    const float a = -0.75f;
    w[0] = ((a * (t + 1.f) - 5.f * a) * (t + 1.f) + 8.f * a) * (t + 1.f) - 4.f * a;
    w[1] = ((a + 2.f) * t - (a + 3.f)) * t * t + 1.f;
    w[2] = ((a + 2.f) * (1.f - t) - (a + 3.f)) * (1.f - t) * (1.f - t) + 1.f;
    w[3] = 1.f - w[0] - w[1] - w[2];
}
// OpenCV INTER_CUBIC + mean/std, as vda::resize_normalize_size. src: RGB24 (planar=0) or planar float.
extern "C" __global__ void resize_normalize(const void* src, int planar, int sw, int sh, float* out, int w, int h) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y; if (x >= w) return;
    const float mean[3] = {0.485f, 0.456f, 0.406f}, stdv[3] = {0.229f, 0.224f, 0.225f};
    float fy = (y + 0.5f) * ((float)sh / h) - 0.5f, fx = (x + 0.5f) * ((float)sw / w) - 0.5f;
    int iy = (int)floorf(fy), ix = (int)floorf(fx); float wy[4], wx[4]; cubic(fy - iy, wy); cubic(fx - ix, wx);
    int rows[4], cols[4];
    for (int k = 0; k < 4; k++) { rows[k] = min(max(iy - 1 + k, 0), sh - 1); cols[k] = min(max(ix - 1 + k, 0), sw - 1); }
    for (int c = 0; c < 3; c++) {
        float sum = 0.f;
        for (int j = 0; j < 4; j++) {
            float across = 0.f;
            for (int k = 0; k < 4; k++) {
                float v = planar ? ((const float*)src)[(size_t)c * sw * sh + (size_t)rows[j] * sw + cols[k]]
                                 : ((const unsigned char*)src)[((size_t)rows[j] * sw + cols[k]) * 3 + c] / 255.f;
                across += wx[k] * v;
            }
            sum += wy[j] * across;
        }
        out[(size_t)c * w * h + (size_t)y * w + x] = (sum - mean[c]) / stdv[c];
    }
}
// 16x9 cell means per channel (vda_vulkan.rs's cut-detection thumbnail), one block per cell.
extern "C" __global__ void thumbnail(const float* img, int w, int h, float* thumb) {
    int cell = blockIdx.x, c = cell / 144, y = (cell % 144) / 16, x = cell % 16;
    int x0 = x * w / 16, x1 = (x + 1) * w / 16, y0 = y * h / 9, y1 = (y + 1) * h / 9;
    __shared__ float part[256]; float s = 0.f;
    for (int i = threadIdx.x; i < (x1 - x0) * (y1 - y0); i += blockDim.x) {
        int yy = y0 + i / (x1 - x0), xx = x0 + i % (x1 - x0);
        s += img[(size_t)c * w * h + (size_t)yy * w + xx];
    }
    part[threadIdx.x] = s; __syncthreads();
    for (int o = blockDim.x / 2; o > 0; o >>= 1) { if (threadIdx.x < o) part[threadIdx.x] += part[threadIdx.x + o]; __syncthreads(); }
    if (threadIdx.x == 0) thumb[cell] = part[0] / (float)((x1 - x0) * (y1 - y0));
}
// One pass of vda::blur_size (clamped edges, radius min(ceil(3 sigma), 8)).
extern "C" __global__ void blur_pass(const float* src, float* dst, int w, int h, float sigma, int radius, int horizontal) {
    int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y; if (x >= w) return;
    float num = 0.f, den = 0.f;
    for (int t = -radius; t <= radius; t++) {
        int sx = horizontal ? min(max(x + t, 0), w - 1) : x, sy = horizontal ? y : min(max(y + t, 0), h - 1);
        float wt = expf(-0.5f * (float)(t * t) / (sigma * sigma)); num += wt * src[(size_t)sy * w + sx]; den += wt;
    }
    dst[(size_t)y * w + x] = num / den;
}
)hip";

struct Kernels {
    hipModule_t module = nullptr;
    hipFunction_t gather = nullptr, store = nullptr, resize = nullptr, thumbnail = nullptr, blur = nullptr;
    void build(const std::string& arch) {
        auto& r = rocm();
        hiprtcProgram program;
        require(r.hiprtcCreateProgram_(&program, KERNELS, "vda_migraphx.hip", 0, nullptr, nullptr) == HIPRTC_SUCCESS, "hiprtc program");
        std::string option = "--offload-arch=" + arch;
        const char* options[] = {option.c_str(), "-O3"};
        if (r.hiprtcCompileProgram_(program, 2, options) != HIPRTC_SUCCESS) {
            size_t size = 0; r.hiprtcGetProgramLogSize_(program, &size);
            std::string log(size, '\0'); if (size) r.hiprtcGetProgramLog_(program, log.data());
            r.hiprtcDestroyProgram_(&program);
            throw std::runtime_error("hiprtc failed for " + arch + ": " + log);
        }
        size_t size = 0; r.hiprtcGetCodeSize_(program, &size);
        std::vector<char> code(size); r.hiprtcGetCode_(program, code.data());
        r.hiprtcDestroyProgram_(&program);
        r.check(r.hipModuleLoadData_(&module, code.data()), "Load VDA kernels");
        r.check(r.hipModuleGetFunction_(&gather, module, "gather"), "gather");
        r.check(r.hipModuleGetFunction_(&store, module, "store"), "store");
        r.check(r.hipModuleGetFunction_(&resize, module, "resize_normalize"), "resize_normalize");
        r.check(r.hipModuleGetFunction_(&thumbnail, module, "thumbnail"), "thumbnail");
        r.check(r.hipModuleGetFunction_(&blur, module, "blur_pass"), "blur_pass");
    }
    ~Kernels() { if (module) (void)rocm().hipModuleUnload_(module); }
};
template <class... A> void launch(hipFunction_t f, dim3 grid, dim3 block, hipStream_t stream, A... args) {
    void* params[] = {&args...};
    rocm().check(rocm().hipModuleLaunchKernel_(f, grid.x, grid.y, grid.z, block.x, block.y, block.z, 0, stream, params, nullptr), "Kernel launch");
}

// ---- MIGraphX programs ------------------------------------------------------
std::string cache_dir(const std::string& model, const Device& device) {
    return model + "/compiled/" + device.arch + "-" + rocm().runtime_id;
}
bool exists(const std::string& path) { struct stat st{}; return stat(path.c_str(), &st) == 0; }
void make_dirs(const std::string& path) {
    for (size_t at = 1; (at = path.find('/', at)) != std::string::npos; ++at) mkdir(path.substr(0, at).c_str(), 0755);
    mkdir(path.c_str(), 0755);
}

struct Program {
    migraphx_program_t program = nullptr;
    migraphx_program_parameters_t params = nullptr;
    std::vector<migraphx_argument_t> arguments;
    std::map<std::string, std::pair<void*, size_t>> buffers;
    // Loads the cached program, or compiles the ONNX graph (fp16) and caches it.
    void open(const std::string& model, const std::string& graph, const std::string& cache) {
        auto& r = rocm();
        std::string compiled = cache + "/" + graph + ".mxr";
        migraphx_file_options_t files; r.check(r.migraphx_file_options_create_(&files), "file options");
        bool loaded = exists(compiled) && r.migraphx_load_(&program, compiled.c_str(), files) == migraphx_status_success;
        if (!loaded) {
            migraphx_onnx_options_t onnx; r.check(r.migraphx_onnx_options_create_(&onnx), "onnx options");
            r.check(r.migraphx_onnx_options_set_external_data_path_(onnx, model.c_str()), "external data path");
            std::string source = model + "/" + graph + ".onnx";
            migraphx_status parsed = r.migraphx_parse_onnx_(&program, source.c_str(), onnx);
            r.migraphx_onnx_options_destroy_(onnx);
            r.check(parsed, ("Parse " + source).c_str());
            r.check(r.migraphx_quantize_fp16_(program), "fp16 quantisation");
            migraphx_target_t target; r.check(r.migraphx_target_create_(&target, "gpu"), "gpu target");
            migraphx_compile_options_t options; r.check(r.migraphx_compile_options_create_(&options), "compile options");
            r.migraphx_compile_options_set_offload_copy_(options, false);
            migraphx_status compiled_ok = r.migraphx_program_compile_(program, target, options);
            r.migraphx_compile_options_destroy_(options); r.migraphx_target_destroy_(target);
            r.check(compiled_ok, ("Compile " + graph).c_str());
            make_dirs(cache);
            std::string partial = compiled + ".partial";
            if (r.migraphx_save_(program, partial.c_str(), files) == migraphx_status_success) std::rename(partial.c_str(), compiled.c_str());
        }
        r.migraphx_file_options_destroy_(files);
        migraphx_program_parameter_shapes_t shapes; r.check(r.migraphx_program_get_parameter_shapes_(&shapes, program), "parameter shapes");
        size_t count = 0; r.migraphx_program_parameter_shapes_size_(&count, shapes);
        std::vector<const char*> names(count); r.migraphx_program_parameter_shapes_names_(names.data(), shapes);
        r.check(r.migraphx_program_parameters_create_(&params), "parameters");
        for (const char* name : names) {
            const_migraphx_shape_t shape; r.check(r.migraphx_program_parameter_shapes_get_(&shape, shapes, name), "shape");
            migraphx_shape_datatype_t type; r.migraphx_shape_type_(&type, shape);
            require(type == migraphx_shape_float_type, std::string("Unexpected non-fp32 parameter ") + name);
            size_t bytes = 0; r.migraphx_shape_bytes_(&bytes, shape);
            void* data = nullptr; r.check(r.hipMalloc_(&data, bytes), "Allocate parameter"); r.check(r.hipMemset_(data, 0, bytes), "Clear parameter");
            migraphx_argument_t argument; r.check(r.migraphx_argument_create_(&argument, shape, data), "argument");
            r.check(r.migraphx_program_parameters_add_(params, name, argument), "add parameter");
            arguments.push_back(argument); buffers[name] = {data, bytes};
        }
        r.migraphx_program_parameter_shapes_destroy_(shapes);
    }
    float* at(const std::string& name, size_t bytes) {
        auto it = buffers.find(name);
        require(it != buffers.end(), "VDA graph has no parameter " + name);
        require(it->second.second == bytes, "VDA graph parameter " + name + " has an unexpected size");
        return static_cast<float*>(it->second.first);
    }
    void run(hipStream_t stream) {
        migraphx_arguments_t out = nullptr;
        rocm().check(rocm().migraphx_program_run_async_(&out, program, params, stream, "ihipStream_t"), "VDA inference");
        if (out) rocm().migraphx_arguments_destroy_(out);
    }
    ~Program() {
        auto& r = rocm();
        for (auto& b : buffers) (void)r.hipFree_(b.second.first);
        for (auto a : arguments) r.migraphx_argument_destroy_(a);
        if (params) r.migraphx_program_parameters_destroy_(params);
        if (program) r.migraphx_program_destroy_(program);
    }
};

// ---- Runner -----------------------------------------------------------------
struct Runner {
    Device device;
    hipStream_t stream = nullptr;
    Kernels kernels;
    Program step, cold;
    std::array<float*, STATES> pool{};
    int* selection = nullptr; int* selection_host = nullptr;
    hipGraphExec_t graph = nullptr;
    void* staging = nullptr; size_t staging_bytes = 0;
    float *prepared = nullptr, *thumb = nullptr, *blur = nullptr;
    bool have_prepared = false, seeded = false;
    std::vector<int> list; int steps = 0;

    Runner(const std::string& model, const char* gpu_name) : device(find_device(gpu_name)) {
        auto& r = rocm();
        r.check(r.hipSetDevice_(device.index), "Select HIP device");
        r.check(r.hipStreamCreateWithFlags_(&stream, hipStreamNonBlocking), "HIP stream");
        kernels.build(device.arch);
        std::string cache = cache_dir(model, device);
        step.open(model, "step", cache);
        cold.open(model, "cold", cache);
        for (int i = 0; i < STATES; ++i) {
            size_t bytes = size_t(TOKENS[i]) * SLOTS * CHANNELS[i] * 4;
            r.check(r.hipMalloc_(reinterpret_cast<void**>(&pool[i]), bytes), "History pool"); r.check(r.hipMemset_(pool[i], 0, bytes), "Clear pool");
        }
        r.check(r.hipMalloc_(reinterpret_cast<void**>(&selection), 32 * sizeof(int)), "Selection");
        r.check(r.hipHostMalloc_(reinterpret_cast<void**>(&selection_host), 32 * sizeof(int), 0), "Selection (host)");
        r.check(r.hipMalloc_(reinterpret_cast<void**>(&prepared), size_t(WIDTH) * HEIGHT * 3 * 4), "Prepared frame");
        r.check(r.hipMalloc_(reinterpret_cast<void**>(&thumb), 432 * 4), "Thumbnail");
        r.check(r.hipMalloc_(reinterpret_cast<void**>(&blur), size_t(WIDTH) * HEIGHT * 4 * 2), "Softening");
        // One step = gather -> step program -> store, recorded once and replayed per frame.
        hipGraph_t recorded;
        r.check(r.hipStreamBeginCapture_(stream, hipStreamCaptureModeRelaxed), "Begin capture");
        for (int i = 0; i < STATES; ++i)
            launch(kernels.gather, dim3((CHANNELS[i] + 63) / 64, HISTORY, TOKENS[i]), dim3(64), stream,
                   (const float*)pool[i], step.at("cache_" + std::to_string(i), size_t(TOKENS[i]) * HISTORY * CHANNELS[i] * 4),
                   (const int*)selection, TOKENS[i], CHANNELS[i]);
        step.run(stream);
        for (int i = 0; i < STATES; ++i) store_state(i, step.at("main:#output_" + std::to_string(i + 1), size_t(TOKENS[i]) * CHANNELS[i] * 4));
        r.check(r.hipStreamEndCapture_(stream, &recorded), "End capture");
        r.check(r.hipGraphInstantiate_(&graph, recorded, nullptr, nullptr, 0), "Instantiate step graph");
        (void)r.hipGraphDestroy_(recorded);
    }
    ~Runner() {
        auto& r = rocm();
        if (stream) (void)r.hipStreamSynchronize_(stream);
        if (graph) (void)r.hipGraphExecDestroy_(graph);
        for (auto p : pool) if (p) (void)r.hipFree_(p);
        if (selection) (void)r.hipFree_(selection);
        if (selection_host) (void)r.hipHostFree_(selection_host);
        if (staging) (void)r.hipFree_(staging);
        if (prepared) (void)r.hipFree_(prepared);
        if (thumb) (void)r.hipFree_(thumb);
        if (blur) (void)r.hipFree_(blur);
        if (stream) (void)r.hipStreamDestroy_(stream);
    }
    void store_state(int i, const float* source) {
        launch(kernels.store, dim3((CHANNELS[i] + 63) / 64, TOKENS[i]), dim3(64), stream,
               pool[i], source, (const int*)selection, TOKENS[i], CHANNELS[i]);
    }
    std::array<int, 31> selected() const {
        std::array<int, 31> out{}; out[0] = list[0]; out[1] = list[1];
        for (int i = 0; i < 29; ++i) out[i + 2] = list[list.size() - 29 + i];
        return out;
    }
    int free_slot() const {
        for (int i = 0; i < SLOTS; ++i) if (std::find(list.begin(), list.end(), i) == list.end()) return i;
        return -1;
    }
    void prepare(const void* source, int sw, int sh, bool planar, float* thumbnail_out) {
        auto& r = rocm();
        size_t bytes = size_t(sw) * sh * 3 * (planar ? 4 : 1);
        if (bytes > staging_bytes) {
            if (staging) (void)r.hipFree_(staging);
            staging = nullptr; staging_bytes = 0;
            r.check(r.hipMalloc_(&staging, bytes), "Frame staging"); staging_bytes = bytes;
        }
        r.check(r.hipMemcpyAsync_(staging, source, bytes, hipMemcpyHostToDevice, stream), "Upload frame");
        launch(kernels.resize, dim3((WIDTH + 127) / 128, HEIGHT), dim3(128), stream,
               (const void*)staging, int(planar), sw, sh, prepared, WIDTH, HEIGHT);
        launch(kernels.thumbnail, dim3(432), dim3(256), stream, (const float*)prepared, WIDTH, HEIGHT, thumb);
        r.check(r.hipMemcpyAsync_(thumbnail_out, thumb, 432 * 4, hipMemcpyDeviceToHost, stream), "Thumbnail readback");
        r.check(r.hipStreamSynchronize_(stream), "Prepare frame");
        have_prepared = true;
    }
    // input: a normalised 3x294x518 frame on the host, or nullptr for the prepared one.
    void infer(const float* input, float* depth, bool reset, float sigma) {
        auto& r = rocm();
        const size_t image = size_t(WIDTH) * HEIGHT * 3 * 4, out = size_t(WIDTH) * HEIGHT * 4;
        require(input || have_prepared, "No prepared VDA frame");
        auto copy_in = [&](float* dst) {
            r.check(r.hipMemcpyAsync_(dst, input ? (const void*)input : (const void*)prepared, image,
                                     input ? hipMemcpyHostToDevice : hipMemcpyDeviceToDevice, stream), "Frame to model");
        };
        const float* result;
        bool first = reset || !seeded;
        int slot = first ? 0 : free_slot();
        require(slot >= 0, "No VDA history slot");
        if (first) {
            copy_in(cold.at("image", image));
            cold.run(stream);
            selection_host[31] = 0;
            r.check(r.hipMemcpyAsync_(selection, selection_host, 32 * sizeof(int), hipMemcpyHostToDevice, stream), "Selection");
            for (int i = 0; i < STATES; ++i) store_state(i, cold.at("main:#output_" + std::to_string(i + 1), size_t(TOKENS[i]) * CHANNELS[i] * 4));
            result = cold.at("main:#output_0", out);
        } else {
            auto chosen = selected();
            for (int i = 0; i < 31; ++i) selection_host[i] = chosen[i];
            selection_host[31] = slot;
            r.check(r.hipMemcpyAsync_(selection, selection_host, 32 * sizeof(int), hipMemcpyHostToDevice, stream), "Selection");
            copy_in(step.at("image", image));
            r.check(r.hipGraphLaunch_(graph, stream), "VDA step");
            result = step.at("main:#output_0", out);
        }
        if (sigma > 0.f) {
            int radius = std::min(int(std::ceil(3.f * sigma)), 8);
            float* a = blur; float* b = blur + size_t(WIDTH) * HEIGHT;
            launch(kernels.blur, dim3((WIDTH + 127) / 128, HEIGHT), dim3(128), stream, result, a, WIDTH, HEIGHT, sigma, radius, 1);
            launch(kernels.blur, dim3((WIDTH + 127) / 128, HEIGHT), dim3(128), stream, (const float*)a, b, WIDTH, HEIGHT, sigma, radius, 0);
            result = b;
        }
        r.check(r.hipMemcpyAsync_(depth, result, out, hipMemcpyDeviceToHost, stream), "Depth readback");
        r.check(r.hipStreamSynchronize_(stream), "VDA step");
        if (first) { list.assign(32, 0); steps = 0; seeded = true; }
        else { ++steps; list.push_back(slot); if (steps + 32 > 42) list.erase(list.begin() + 1); }
    }
};
std::mutex create_lock;  // one MIGraphX compile at a time
}  // namespace

API unsigned meteor_vda_abi() { return 1; }
// The index form is the Vulkan library's; MIGraphX picks its device by name.
API int meteor_vda_supported(int) { return 0; }
API int meteor_vda_supported_named(const char* gpu_name) {
    try { find_device(gpu_name); return 1; } catch (...) { return 0; }
}
// 1 when loading this model on that GPU will compile it first (minutes).
API int meteor_vda_needs_compile(const char* path, const char* gpu_name) {
    try {
        auto device = find_device(gpu_name);
        std::string cache = cache_dir(path, device);
        return exists(cache + "/step.mxr") && exists(cache + "/cold.mxr") ? 0 : 1;
    } catch (...) { return 0; }
}
API void* meteor_vda_create_named(const char* path, const char* gpu_name, int width, int height, char* error, size_t capacity) {
    try {
        require(path && width == WIDTH && height == HEIGHT, "MIGraphX VDA supports 518x294 only");
        std::lock_guard<std::mutex> guard(create_lock);
        return new Runner(path, gpu_name);
    } catch (const std::exception& e) { error_text(error, capacity, e.what()); return nullptr; }
}
API void* meteor_vda_create(const char* path, int, int width, int height, char* error, size_t capacity) {
    return meteor_vda_create_named(path, nullptr, width, height, error, capacity);
}
API int meteor_vda_infer(void* handle, const float* rgb, float* depth, int reset, char* error, size_t capacity) {
    if (!handle || !rgb || !depth) { error_text(error, capacity, "Invalid VDA arguments"); return -1; }
    auto* runner = static_cast<Runner*>(handle);
    try { runner->infer(rgb, depth, reset != 0, 0.f); return 0; }
    catch (const std::exception& e) { runner->seeded = false; error_text(error, capacity, e.what()); return -1; }
}
API int meteor_vda_prepare(void* handle, const void* source, int sw, int sh, int planar, float* thumbnail, char* error, size_t capacity) {
    if (!handle || !source || !thumbnail || sw < 1 || sh < 1 || sw > 8192 || sh > 8192) { error_text(error, capacity, "Invalid VDA preparation input"); return -1; }
    try { static_cast<Runner*>(handle)->prepare(source, sw, sh, planar != 0, thumbnail); return 0; }
    catch (const std::exception& e) { error_text(error, capacity, e.what()); return -1; }
}
API int meteor_vda_infer_prepared(void* handle, float* output, int reset, float sigma, char* error, size_t capacity) {
    if (!handle || !output || !std::isfinite(sigma) || sigma < 0 || sigma > 4) { error_text(error, capacity, "Invalid prepared VDA input"); return -1; }
    auto* runner = static_cast<Runner*>(handle);
    try { runner->infer(nullptr, output, reset != 0, sigma); return 0; }
    catch (const std::exception& e) { runner->seeded = false; error_text(error, capacity, e.what()); return -1; }
}
API void meteor_vda_destroy(void* handle) { delete static_cast<Runner*>(handle); }
