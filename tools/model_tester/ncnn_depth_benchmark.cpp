#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <string>

#include "net.h"

int main(int argc, char **argv) {
    if (argc < 4) {
        std::fprintf(stderr, "Usage: %s MODEL_PREFIX SIZE cpu|vulkan [LOOPS] [OUTPUT_F32] [nchw|nhwc] [INPUT_F32]\n", argv[0]);
        return 2;
    }

    const std::string prefix = argv[1];
    const int size = std::atoi(argv[2]);
    const bool use_vulkan = std::string(argv[3]) == "vulkan";
    const int loops = argc > 4 ? std::max(1, std::atoi(argv[4])) : 20;
    const bool nhwc = argc > 6 && std::string(argv[6]) == "nhwc";

    if (use_vulkan) {
        ncnn::create_gpu_instance();
        if (ncnn::get_gpu_count() == 0) {
            std::fprintf(stderr, "No Vulkan compute device found\n");
            return 3;
        }
        std::fprintf(stderr, "GPU: %s\n", ncnn::get_gpu_device(0)->info.device_name());
    }

    ncnn::Net net;
    net.opt.use_vulkan_compute = use_vulkan;
    net.opt.use_fp16_packed = use_vulkan;
    net.opt.use_fp16_storage = use_vulkan;
    net.opt.use_fp16_arithmetic = use_vulkan;
    net.opt.num_threads = 4;

    if (net.load_param((prefix + ".ncnn.param").c_str()) != 0 ||
        net.load_model((prefix + ".ncnn.bin").c_str()) != 0) {
        std::fprintf(stderr, "Failed to load %s\n", prefix.c_str());
        return 4;
    }

    ncnn::Mat input = nhwc ? ncnn::Mat(3, size, size) : ncnn::Mat(size, size, 3);
    if (nhwc) {
        float *values = input;
        for (int y = 0; y < size; ++y) {
            for (int x = 0; x < size; ++x) {
                for (int c = 0; c < 3; ++c) {
                    values[(y * size + x) * 3 + c] =
                            static_cast<float>((x * 3 + y * 5 + c * 17) % 256) / 255.0f;
                }
            }
        }
    } else {
        for (int c = 0; c < 3; ++c) {
            float *plane = input.channel(c);
            for (int y = 0; y < size; ++y) {
                for (int x = 0; x < size; ++x) {
                    plane[y * size + x] = static_cast<float>((x * 3 + y * 5 + c * 17) % 256) / 255.0f;
                }
            }
        }
    }
    if (argc > 7) {
        std::FILE *input_file = std::fopen(argv[7], "rb");
        const size_t count = input.total();
        if (!input_file || std::fread(static_cast<float *>(input), sizeof(float), count, input_file) != count) {
            if (input_file) std::fclose(input_file);
            std::fprintf(stderr, "Failed to read %s\n", argv[7]);
            return 7;
        }
        std::fclose(input_file);
    }

    double total_ms = 0.0;
    double min_ms = 1e30;
    double max_ms = 0.0;
    ncnn::Mat output;
    for (int i = -3; i < loops; ++i) {
        ncnn::Extractor ex = net.create_extractor();
        ex.input("in0", input);
        const auto start = std::chrono::steady_clock::now();
        const int result = ex.extract("out0", output);
        const auto stop = std::chrono::steady_clock::now();
        if (result != 0 || output.empty()) {
            std::fprintf(stderr, "Inference failed: %d\n", result);
            return 5;
        }
        if (i >= 0) {
            const double elapsed = std::chrono::duration<double, std::milli>(stop - start).count();
            total_ms += elapsed;
            min_ms = std::min(min_ms, elapsed);
            max_ms = std::max(max_ms, elapsed);
        }
    }

    const float *values = output;
    const size_t count = output.total();
    float out_min = values[0];
    float out_max = values[0];
    double out_sum = 0.0;
    for (size_t i = 0; i < count; ++i) {
        out_min = std::min(out_min, values[i]);
        out_max = std::max(out_max, values[i]);
        out_sum += values[i];
    }
    std::printf("backend=%s layout=%s size=%d loops=%d avg=%.3fms min=%.3fms max=%.3fms output=%dx%dx%d range=[%.6f,%.6f] mean=%.6f\n",
                use_vulkan ? "vulkan" : "cpu", nhwc ? "nhwc" : "nchw",
                size, loops, total_ms / loops, min_ms, max_ms,
                output.w, output.h, output.c, out_min, out_max, out_sum / count);

    if (argc > 5) {
        std::FILE *dump = std::fopen(argv[5], "wb");
        if (!dump || std::fwrite(values, sizeof(float), count, dump) != count) {
            if (dump) std::fclose(dump);
            std::fprintf(stderr, "Failed to write %s\n", argv[5]);
            return 6;
        }
        std::fclose(dump);
    }

    // Vulkan-backed layers must release their pipelines before ncnn's global
    // GPU instance is destroyed. Larger graphs can otherwise crash at exit.
    net.clear();
    if (use_vulkan) ncnn::destroy_gpu_instance();
    return 0;
}
