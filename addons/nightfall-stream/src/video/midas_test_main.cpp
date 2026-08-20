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

    // Mirrors the real sequence that crashed: default model (256) active,
    // then switch to 192 right as frames start flowing, repeatedly.
    for (int cycle = 0; cycle < 6; cycle++) {
        int model_index = (cycle % 2 == 0) ? 10 : 3; // 10=MiDaS-192, 3=MiDaS-256
        int size = (model_index == 10) ? 192 : 256;
        printf("[test] cycle %d: set_active_model(%d), get_model_size()=%d\n",
               cycle, model_index, engine.get_model_size());
        engine.set_active_model(model_index);
        printf("[test] cycle %d: get_model_size() after switch = %d\n", cycle, engine.get_model_size());

        for (int i = 0; i < 10; i++) {
            submit_synthetic_frame(engine, size);
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            auto depth = engine.get_latest_depth();
            printf("[test] cycle %d frame %d: submitted, got %zu depth bytes\n", cycle, i, depth.size());
        }
    }

    printf("[test] all cycles completed without crashing\n");
    return 0;
}
