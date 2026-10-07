// A small C API over TensorRT's C++ API, for src/tensorrt.rs.
//
// TensorRT's classes are interfaces: their methods are virtual, so calling
// them needs only the headers (third_party/tensorrt). The three objects we
// start from come from the libraries' exported C factory functions, found
// with dlsym, so Meteor builds and starts without TensorRT installed.
//
// Every function returns 0 on success; on failure it returns -1 and writes
// a message to `err` (NUL-terminated, truncated to `err_len`).

#include <dlfcn.h>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

#include "NvInfer.h"
#include "NvOnnxParser.h"

using namespace nvinfer1;

namespace {

typedef void (*LogFn)(int severity, const char* message);

class Logger : public ILogger {
public:
    LogFn fn = nullptr;
    void log(Severity severity, const char* msg) noexcept override {
        if (fn) fn(static_cast<int>(severity), msg);
    }
};

Logger g_logger;
void* (*g_create_builder)(void*, int32_t) = nullptr;
void* (*g_create_runtime)(void*, int32_t) = nullptr;
void* (*g_create_parser)(void*, void*, int) = nullptr;
int32_t (*g_lib_version)() = nullptr;

int fail(char* err, size_t err_len, const std::string& message) {
    if (err && err_len) std::snprintf(err, err_len, "%s", message.c_str());
    return -1;
}

template <typename T>
struct Deleter {
    void operator()(T* p) const { delete p; }
};
template <typename T>
using Owned = std::unique_ptr<T, Deleter<T>>;

}  // namespace

struct TrtEngine {
    Owned<IRuntime> runtime;
    Owned<ICudaEngine> engine;
    Owned<IExecutionContext> context;
};

extern "C" {

// Opens libnvinfer and libnvonnxparser (paths or sonames) and returns the
// library's version (for example 101601), or -1.
int32_t trt_init(const char* nvinfer, const char* parser, LogFn log, char* err, size_t err_len) {
    g_logger.fn = log;
    void* infer = dlopen(nvinfer, RTLD_NOW | RTLD_GLOBAL);
    if (!infer) return fail(err, err_len, dlerror());
    void* onnx = dlopen(parser, RTLD_NOW | RTLD_GLOBAL);
    if (!onnx) return fail(err, err_len, dlerror());
    g_create_builder = reinterpret_cast<void* (*)(void*, int32_t)>(dlsym(infer, "createInferBuilder_INTERNAL"));
    g_create_runtime = reinterpret_cast<void* (*)(void*, int32_t)>(dlsym(infer, "createInferRuntime_INTERNAL"));
    g_lib_version = reinterpret_cast<int32_t (*)()>(dlsym(infer, "getInferLibVersion"));
    g_create_parser = reinterpret_cast<void* (*)(void*, void*, int)>(dlsym(onnx, "createNvOnnxParser_INTERNAL"));
    if (!g_create_builder || !g_create_runtime || !g_lib_version || !g_create_parser) {
        return fail(err, err_len, "TensorRT's factory functions are missing");
    }
    int32_t version = g_lib_version();
    if (version / 10000 != NV_TENSORRT_MAJOR) {
        return fail(err, err_len, "TensorRT " + std::to_string(version) + " doesn't match the headers' major version " +
                                      std::to_string(NV_TENSORRT_MAJOR));
    }
    return version;
}

// Parses an ONNX file and builds a serialized engine. `timing_cache` is a
// file path (read if it exists, written after the build), or null. On
// success, *plan is a buffer for the caller to free with trt_free().
int trt_build(const char* onnx_path, int fp16, int opt_level, const char* timing_cache, void** plan, size_t* plan_size,
              char* err, size_t err_len) {
    try {
        Owned<IBuilder> builder(static_cast<IBuilder*>(g_create_builder(&g_logger, NV_TENSORRT_VERSION)));
        if (!builder) return fail(err, err_len, "can't create the TensorRT builder");
        Owned<INetworkDefinition> network(builder->createNetworkV2(0));
        Owned<nvonnxparser::IParser> parser(
            static_cast<nvonnxparser::IParser*>(g_create_parser(network.get(), &g_logger, NV_ONNX_PARSER_VERSION)));
        if (!network || !parser) return fail(err, err_len, "can't create the network or ONNX parser");
        if (!parser->parseFromFile(onnx_path, static_cast<int32_t>(ILogger::Severity::kWARNING))) {
            std::string message = "can't parse the ONNX file";
            for (int32_t i = 0; i < parser->getNbErrors(); ++i) message += std::string("; ") + parser->getError(i)->desc();
            return fail(err, err_len, message);
        }
        Owned<IBuilderConfig> config(builder->createBuilderConfig());
        // kFP16 is deprecated in favour of strongly typed networks, but it's
        // the setting ONNX Runtime's TensorRT provider builds with, and the
        // one our models are validated at.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        if (fp16) config->setFlag(BuilderFlag::kFP16);
#pragma GCC diagnostic pop
        config->setBuilderOptimizationLevel(opt_level);

        std::vector<char> cache_blob;
        if (timing_cache) {
            std::ifstream in(timing_cache, std::ios::binary);
            if (in) cache_blob.assign(std::istreambuf_iterator<char>(in), {});
        }
        Owned<ITimingCache> cache(config->createTimingCache(cache_blob.data(), cache_blob.size()));
        if (cache) config->setTimingCache(*cache, false);

        Owned<IHostMemory> serialized(builder->buildSerializedNetwork(*network, *config));
        if (!serialized) return fail(err, err_len, "the engine build failed (see the TensorRT log)");

        if (timing_cache && cache) {
            Owned<IHostMemory> blob(config->getTimingCache()->serialize());
            if (blob) {
                std::ofstream out(timing_cache, std::ios::binary | std::ios::trunc);
                out.write(static_cast<const char*>(blob->data()), static_cast<std::streamsize>(blob->size()));
            }
        }
        *plan_size = serialized->size();
        *plan = std::malloc(*plan_size);
        if (!*plan) return fail(err, err_len, "out of memory");
        std::memcpy(*plan, serialized->data(), *plan_size);
        return 0;
    } catch (const std::exception& e) {
        return fail(err, err_len, e.what());
    }
}

// Frees a plan from trt_build.
void trt_free(void* plan) { std::free(plan); }

// Loads a serialized engine. Needs the CUDA context current.
TrtEngine* trt_load(const void* plan, size_t plan_size, char* err, size_t err_len) {
    try {
        auto out = std::make_unique<TrtEngine>();
        out->runtime.reset(static_cast<IRuntime*>(g_create_runtime(&g_logger, NV_TENSORRT_VERSION)));
        if (!out->runtime) return fail(err, err_len, "can't create the TensorRT runtime"), nullptr;
        out->engine.reset(out->runtime->deserializeCudaEngine(plan, plan_size));
        if (!out->engine) return fail(err, err_len, "can't load the engine (see the TensorRT log)"), nullptr;
        out->context.reset(out->engine->createExecutionContext());
        if (!out->context) return fail(err, err_len, "can't create an execution context"), nullptr;
        return out.release();
    } catch (const std::exception& e) {
        fail(err, err_len, e.what());
        return nullptr;
    }
}

void trt_destroy(TrtEngine* engine) { delete engine; }

int32_t trt_io_count(TrtEngine* e) { return e->engine->getNbIOTensors(); }

const char* trt_io_name(TrtEngine* e, int32_t i) { return e->engine->getIOTensorName(i); }

int trt_io_is_input(TrtEngine* e, const char* name) {
    return e->engine->getTensorIOMode(name) == TensorIOMode::kINPUT ? 1 : 0;
}

// TensorRT's DataType: 0 float, 1 half, 2 int8, 3 int32, 4 bool, ...
int32_t trt_io_dtype(TrtEngine* e, const char* name) { return static_cast<int32_t>(e->engine->getTensorDataType(name)); }

// Writes up to `max` dimensions; returns the tensor's rank.
int32_t trt_io_shape(TrtEngine* e, const char* name, int64_t* dims, int32_t max) {
    Dims shape = e->engine->getTensorShape(name);
    for (int32_t i = 0; i < shape.nbDims && i < max; ++i) dims[i] = shape.d[i];
    return shape.nbDims;
}

int trt_set_address(TrtEngine* e, const char* name, uint64_t address) {
    return e->context->setTensorAddress(name, reinterpret_cast<void*>(address)) ? 0 : -1;
}

// Queues one inference on `stream` (a CUstream). Needs the context current.
int trt_enqueue(TrtEngine* e, void* stream) {
    return e->context->enqueueV3(static_cast<cudaStream_t>(stream)) ? 0 : -1;
}

}  // extern "C"
