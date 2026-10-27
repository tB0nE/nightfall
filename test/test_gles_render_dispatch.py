#!/usr/bin/env python3
"""Compile the real GLES scheduling function against an inline-renderer stub.

Requires a host C++ compiler, not Godot or Android. Exercises the scheduling
mutex/coalescing boundary; it does not emulate GL, JNI or WebView rendering.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "addons/nightfall-stream/src/video/texture_uploader.cpp"
STUB = r"""
#include <atomic>
#include <cassert>
#include <functional>
#include <mutex>
#define NF_LOG(...) ((void)0)
template<class T> std::function<void()> callable_mp(T *p, void (T::*f)()) {
    return [=] { (p->*f)(); };
}
struct RenderingServer {
    bool inline_dispatch = true;
    std::function<void()> pending;
    static RenderingServer *get_singleton() { static RenderingServer server; return &server; }
    void call_on_render_thread(std::function<void()> f) {
        if (inline_dispatch) f(); else pending = f;
    }
};
struct TextureUploader {
    std::mutex gles_surface_mutex_;
    int gles_decode_call_count_ = 0, gles_decode_coalesced_count_ = 0;
    bool gles_surface_ready_ = false, gles_update_queued_ = false;
    int rendered = 0;
    void update_android_gles_external_texture();
    void _render_thread_update_android_gles_texture() {
        std::lock_guard<std::mutex> lock(gles_surface_mutex_);
        gles_update_queued_ = false;
        ++rendered;
    }
};
"""
MAIN = r"""
int main() {
    TextureUploader uploader;
    uploader.update_android_gles_external_texture();
    assert(uploader.rendered == 0);
    uploader.gles_surface_ready_ = true;
    uploader.update_android_gles_external_texture();
    assert(uploader.rendered == 1 && !uploader.gles_update_queued_);
    auto server = RenderingServer::get_singleton();
    server->inline_dispatch = false;
    uploader.update_android_gles_external_texture();
    assert(uploader.gles_update_queued_);
    uploader.update_android_gles_external_texture();
    assert(uploader.rendered == 1 && uploader.gles_decode_coalesced_count_ == 1);
    server->pending();
    assert(uploader.rendered == 2 && !uploader.gles_update_queued_);
}
"""


class DispatchTest(unittest.TestCase):
    def test_inline_and_deferred_dispatch(self):
        compiler = shutil.which("c++")
        if not compiler:
            self.skipTest("A host C++ compiler is required")
        source = SOURCE.read_text()
        begin = source.index("void TextureUploader::update_android_gles_external_texture() {")
        end = source.index("\nbool TextureUploader::_render_thread_ensure_depth_capture", begin)
        function = source[begin:end]
        with tempfile.TemporaryDirectory(prefix="nightfall-gles-dispatch-") as directory:
            cpp = Path(directory) / "dispatch.cpp"
            exe = Path(directory) / "dispatch"
            cpp.write_text(STUB + function + MAIN)
            subprocess.run([compiler, "-std=c++17", "-pthread", str(cpp), "-o", str(exe)], check=True)
            subprocess.run([str(exe)], check=True, timeout=3)
            # Prove this harness detects the original regression, rather than
            # merely completing without exercising the inline callback.
            self.assertIn("lock.unlock();", function)
            cpp.write_text(STUB + function.replace("lock.unlock();", "") + MAIN)
            subprocess.run([compiler, "-std=c++17", "-pthread", str(cpp), "-o", str(exe)], check=True)
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run([str(exe)], check=True, timeout=1)


if __name__ == "__main__":
    unittest.main()
