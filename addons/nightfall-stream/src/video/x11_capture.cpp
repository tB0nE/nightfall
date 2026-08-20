#include "x11_capture.h"
#include "nf_log.h"

#ifdef NIGHTFALL_HAS_X11
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#ifdef NIGHTFALL_HAS_XRANDR
#include <X11/extensions/Xrandr.h>
#endif
#include <sys/shm.h>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace godot {

#ifdef NIGHTFALL_HAS_XRANDR
namespace {

// Best-effort: Sunshine's own "output_name" config value is an NvFBC output
// INDEX (NVIDIA's own head enumeration, e.g. "0"), not an X11 RandR
// connector name - there's no guarantee the two enumeration orders match,
// so this is a heuristic, not a guarantee (see CMakeLists.txt/plan notes).
// Checks both plausible install locations: a native/AppImage install's
// ~/.config/sunshine/sunshine.conf, and a Flatpak install's
// ~/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/sunshine.conf
// (confirmed real on the dev machine this was built against). Simple
// line-based "key = value" parsing matches Sunshine's actual config format
// exactly - no need for a real config-file parser for one integer field.
bool read_sunshine_output_index(int &out_index) {
    const char *home = getenv("HOME");
    if (!home) return false;

    std::vector<std::string> candidate_paths = {
        std::string(home) + "/.var/app/dev.lizardbyte.app.Sunshine/config/sunshine/sunshine.conf",
        std::string(home) + "/.config/sunshine/sunshine.conf",
    };

    for (const auto &path : candidate_paths) {
        std::ifstream f(path);
        if (!f.is_open()) continue;

        std::string line;
        while (std::getline(f, line)) {
            size_t eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::string key = line.substr(0, eq);
            std::string value = line.substr(eq + 1);
            // Trim whitespace both sides of key/value.
            auto trim = [](std::string &s) {
                size_t a = s.find_first_not_of(" \t\r\n");
                size_t b = s.find_last_not_of(" \t\r\n");
                s = (a == std::string::npos) ? "" : s.substr(a, b - a + 1);
            };
            trim(key);
            trim(value);
            if (key == "output_name" && !value.empty()) {
                // strtol, not std::stoi - this project builds with
                // -fno-exceptions, so std::stoi's throw-on-invalid-input
                // behavior isn't usable here.
                char *end = nullptr;
                long parsed = strtol(value.c_str(), &end, 10);
                if (end == value.c_str() || *end != '\0') {
                    return false; // non-numeric output_name (e.g. a real device name) - not usable here
                }
                out_index = (int)parsed;
                return true;
            }
        }
    }
    return false;
}

// Active (connected + has a live CRTC) RandR outputs, in RandR's own
// enumeration order - the list read_sunshine_output_index()'s value is
// positionally matched against.
struct MonitorRect {
    int x = 0, y = 0, w = 0, h = 0;
};

bool get_primary_monitor_rect(::Display *display, ::Window root, MonitorRect &out) {
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(display, root);
    if (!res) return false;
    bool found = false;

    RROutput primary = XRRGetOutputPrimary(display, root);
    if (primary != None) {
        XRROutputInfo *info = XRRGetOutputInfo(display, res, primary);
        if (info && info->connection == RR_Connected && info->crtc != None) {
            XRRCrtcInfo *crtc = XRRGetCrtcInfo(display, res, info->crtc);
            if (crtc) {
                out = {crtc->x, crtc->y, (int)crtc->width, (int)crtc->height};
                found = true;
                XRRFreeCrtcInfo(crtc);
            }
        }
        if (info) XRRFreeOutputInfo(info);
    }

    if (!found) {
        // No primary set (or it's disconnected/inactive) - fall back to the
        // first active output found, still better than the whole desktop.
        for (int i = 0; i < res->noutput && !found; i++) {
            XRROutputInfo *info = XRRGetOutputInfo(display, res, res->outputs[i]);
            if (info && info->connection == RR_Connected && info->crtc != None) {
                XRRCrtcInfo *crtc = XRRGetCrtcInfo(display, res, info->crtc);
                if (crtc) {
                    out = {crtc->x, crtc->y, (int)crtc->width, (int)crtc->height};
                    found = true;
                    XRRFreeCrtcInfo(crtc);
                }
            }
            if (info) XRRFreeOutputInfo(info);
        }
    }

    XRRFreeScreenResources(res);
    return found;
}

bool get_monitor_rect_by_index(::Display *display, ::Window root, int index, MonitorRect &out) {
    XRRScreenResources *res = XRRGetScreenResourcesCurrent(display, root);
    if (!res) return false;

    int active_idx = 0;
    bool found = false;
    for (int i = 0; i < res->noutput; i++) {
        XRROutputInfo *info = XRRGetOutputInfo(display, res, res->outputs[i]);
        if (!info) continue;
        if (info->connection == RR_Connected && info->crtc != None) {
            if (active_idx == index) {
                XRRCrtcInfo *crtc = XRRGetCrtcInfo(display, res, info->crtc);
                if (crtc) {
                    out = {crtc->x, crtc->y, (int)crtc->width, (int)crtc->height};
                    found = true;
                    XRRFreeCrtcInfo(crtc);
                }
                XRRFreeOutputInfo(info);
                break;
            }
            active_idx++;
        }
        XRRFreeOutputInfo(info);
    }

    XRRFreeScreenResources(res);
    return found;
}

} // namespace
#endif // NIGHTFALL_HAS_XRANDR

void X11Capture::select_capture_region(::Display *display, int screen, ::Window root,
                                        int &out_x, int &out_y, int &out_w, int &out_h) {
#ifdef NIGHTFALL_HAS_XRANDR
    int sunshine_index = -1;
    bool have_index = read_sunshine_output_index(sunshine_index);

    MonitorRect rect;
    if (have_index && sunshine_index >= 0 && get_monitor_rect_by_index(display, root, sunshine_index, rect)) {
        NF_LOG("X11Capture", "Selected monitor by Sunshine output_name=%d: %dx%d+%d+%d",
               sunshine_index, rect.w, rect.h, rect.x, rect.y);
        out_x = rect.x; out_y = rect.y; out_w = rect.w; out_h = rect.h;
        return;
    }

    if (get_primary_monitor_rect(display, root, rect)) {
        NF_LOG("X11Capture", "Selected primary monitor (%s): %dx%d+%d+%d",
               have_index ? "Sunshine output_name index out of range" : "no usable Sunshine config found",
               rect.w, rect.h, rect.x, rect.y);
        out_x = rect.x; out_y = rect.y; out_w = rect.w; out_h = rect.h;
        return;
    }

    NF_LOGE("X11Capture", "RandR found no active outputs - falling back to full desktop capture");
#else
    (void)display; (void)screen; (void)root;
    NF_LOG("X11Capture", "Built without RandR support - capturing full desktop (all monitors)");
#endif
    // Full-desktop fallback - matches the previous (pre-2026-08-20) behavior
    // exactly, so an unusual/broken X setup never regresses to capturing
    // nothing.
    XWindowAttributes attrs;
    XGetWindowAttributes(display, root, &attrs);
    out_x = 0;
    out_y = 0;
    out_w = attrs.width;
    out_h = attrs.height;
}

X11Capture::X11Capture() = default;

X11Capture::~X11Capture() {
    stop();
}

bool X11Capture::start() {
    if (running_.load()) return true;

    display_ = XOpenDisplay(nullptr);
    if (!display_) {
        NF_LOGE("X11Capture", "Failed to open X display");
        return false;
    }

    screen_ = DefaultScreen(display_);
    Window root = RootWindow(display_, screen_);

    int sel_x = 0, sel_y = 0, sel_w = 0, sel_h = 0;
    select_capture_region(display_, screen_, root, sel_x, sel_y, sel_w, sel_h);
    x_offset_ = sel_x;
    y_offset_ = sel_y;
    width_ = sel_w;
    height_ = sel_h;

    NF_LOG("X11Capture", "Capture region: %dx%d+%d+%d", width_, height_, x_offset_, y_offset_);

    if (width_ == 0 || height_ == 0) {
        NF_LOGE("X11Capture", "Invalid screen dimensions");
        XCloseDisplay(display_);
        display_ = nullptr;
        return false;
    }

    // Create shared memory XImage
    image_ = XShmCreateImage(display_, DefaultVisual(display_, screen_),
                             DefaultDepth(display_, screen_), ZPixmap, nullptr,
                             &shm_info_, width_, height_);
    if (!image_) {
        NF_LOGE("X11Capture", "XShmCreateImage failed");
        XCloseDisplay(display_);
        display_ = nullptr;
        return false;
    }

    shm_info_.shmid = shmget(IPC_PRIVATE, image_->bytes_per_line * image_->height,
                              IPC_CREAT | 0777);
    if (shm_info_.shmid < 0) {
        NF_LOGE("X11Capture", "shmget failed");
        XDestroyImage(image_);
        image_ = nullptr;
        XCloseDisplay(display_);
        display_ = nullptr;
        return false;
    }

    shm_info_.shmaddr = (char *)shmat(shm_info_.shmid, 0, 0);
    if (shm_info_.shmaddr == (char *)-1) {
        NF_LOGE("X11Capture", "shmat failed");
        XDestroyImage(image_);
        image_ = nullptr;
        XCloseDisplay(display_);
        display_ = nullptr;
        return false;
    }

    shm_info_.readOnly = false;
    image_->data = shm_info_.shmaddr;

    XShmAttach(display_, &shm_info_);
    XSync(display_, false);
    shmctl(shm_info_.shmid, IPC_RMID, 0); // mark for deletion after detach

    NF_LOG("X11Capture", "SHM created: %d bytes, %dx%d stride=%d",
           image_->bytes_per_line * image_->height,
           image_->width, image_->height, image_->bytes_per_line);

    running_.store(true);
    worker_thread_ = std::thread(&X11Capture::capture_loop, this);
    return true;
}

void X11Capture::stop() {
    running_.store(false);
    if (worker_thread_.joinable()) {
        worker_thread_.join();
    }

    if (image_) {
        XShmDetach(display_, &shm_info_);
        XDestroyImage(image_);
        image_ = nullptr;
        shmdt(shm_info_.shmaddr);
    }
    if (display_) {
        XCloseDisplay(display_);
        display_ = nullptr;
    }
    has_new_frame_ = false;
}

bool X11Capture::has_new_frame() const {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    return has_new_frame_;
}

bool X11Capture::get_latest_frame(FrameData &out_frame) {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (!has_new_frame_) return false;
    out_frame = latest_frame_;
    has_new_frame_ = false;
    return true;
}

void X11Capture::release_frame() {
    // X11 SHM frames don't need queue management - the next capture
    // overwrites the shared memory buffer. Nothing to do here.
}

void X11Capture::capture_loop() {
    Window root = RootWindow(display_, screen_);
    int frame_num = 0;
    auto last_report = std::chrono::steady_clock::now();

    while (running_.load()) {
        XShmGetImage(display_, root, image_, x_offset_, y_offset_, AllPlanes);

        XSync(display_, false);

        frame_num++;
        {
            std::lock_guard<std::mutex> lock(frame_mutex_);
            latest_frame_.data = (uint8_t *)image_->data;
            latest_frame_.width = width_;
            latest_frame_.height = height_;
            latest_frame_.stride = image_->bytes_per_line;
            has_new_frame_ = true;
        }

        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_report).count();
        if (elapsed >= 5000) {
            NF_LOG("X11Capture", "Captured %d frames in %lldms (%.1f fps)",
                   frame_num, (long long)elapsed, frame_num * 1000.0 / elapsed);
            frame_num = 0;
            last_report = now;
        }
    }
}

} // namespace godot

#else // NIGHTFALL_HAS_X11

namespace godot {
X11Capture::X11Capture() = default;
X11Capture::~X11Capture() = default;
bool X11Capture::start() { return false; }
void X11Capture::stop() {}
bool X11Capture::has_new_frame() const { return false; }
bool X11Capture::get_latest_frame(FrameData&) { return false; }
void X11Capture::release_frame() {}
} // namespace godot

#endif // NIGHTFALL_HAS_X11
