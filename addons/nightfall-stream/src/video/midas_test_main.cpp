// Standalone reproduction harness for the 2026-08-20 Linux AI-3D segfault -
// exercises MidasDepthEngine directly (no Godot/GDExtension/X11 capture
// involved) so it can be run/debugged (gdb) without needing a live Sunshine
// stream or driving the app's UI. Only built when NIGHTFALL_BUILD_MIDAS_TEST
// is set (see CMakeLists.txt) - not part of the normal build.
#include "midas_depth_engine.h"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

static void submit_synthetic_frame(MidasDepthEngine &engine, int size) {
    std::vector<uint8_t> rgba(static_cast<size_t>(size) * size * 4);
    for (size_t i = 0; i < rgba.size(); i += 4) {
        rgba[i + 0] = static_cast<uint8_t>(i % 256);
        rgba[i + 1] = static_cast<uint8_t>((i / 4) % 256);
        rgba[i + 2] = static_cast<uint8_t>((i / 7) % 256);
        rgba[i + 3] = 255;
    }
    engine.submit_frame(rgba.data(), rgba.size(), size, size);
}

int main(int argc, char **argv) {
    std::string model_dir = argc > 1 ? argv[1] : "depth_models";
    printf("[test] initializing with model_dir=%s\n", model_dir.c_str());

    MidasDepthEngine engine;
    engine.initialize(model_dir);

    struct ModelCase {
        int index;
        int expected_size;
    };
    const ModelCase models[] = {
        {3, 256}, {10, 192}, {7, 256}, {8, 320}, {4, 384}, {11, 196}, {1, 252},
    };
    constexpr int model_count = sizeof(models) / sizeof(models[0]);
    for (int cycle = 0; cycle < model_count; cycle++) {
        int model_index = models[cycle].index;
        printf("[test] cycle %d: set_active_model(%d), get_model_size()=%d\n",
               cycle, model_index, engine.get_model_size());
        engine.set_active_model(model_index);
        int size = engine.get_model_size();
        printf("[test] cycle %d: get_model_size() after switch = %d\n", cycle, size);
        if (size != models[cycle].expected_size) {
            fprintf(stderr, "[test] model %d did not load (expected %d, got %d)\n",
                    model_index, models[cycle].expected_size, size);
            return 1;
        }

        bool received_depth = false;
        const size_t expected_depth_bytes = static_cast<size_t>(size) * size;
        for (int i = 0; i < 100; i++) {
            submit_synthetic_frame(engine, size);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            auto depth = engine.get_latest_depth();
            printf("[test] cycle %d frame %d: submitted, got %zu depth bytes\n", cycle, i, depth.size());
            if (depth.size() == expected_depth_bytes) {
                received_depth = true;
                break;
            }
        }
        if (!received_depth) {
            fprintf(stderr, "[test] model %d produced no %zu-byte depth frame\n",
                    model_index, expected_depth_bytes);
            return 1;
        }
    }

    printf("[test] all cycles completed without crashing\n");
    return 0;
}
