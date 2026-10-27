#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/string.hpp>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <thread>

namespace godot {

class InputBridge : public RefCounted {
    GDCLASS(InputBridge, RefCounted);

public:
    static constexpr int MBTN_PRESS = 7;
    static constexpr int MBTN_RELEASE = 8;
    static constexpr int MBTN_LEFT = 1;
    static constexpr int MBTN_MIDDLE = 2;
    static constexpr int MBTN_RIGHT = 3;
    static constexpr int MBTN_X1 = 4;
    static constexpr int MBTN_X2 = 5;

    static constexpr int KA_DOWN = 3;
    static constexpr int KA_UP = 4;
    static constexpr int MOD_SHIFT = 0x01;
    static constexpr int MOD_CTRL = 0x02;
    static constexpr int MOD_ALT = 0x04;
    static constexpr int MOD_META = 0x08;

    static constexpr int FLAG_UP = 0x0001;
    static constexpr int FLAG_DOWN = 0x0002;
    static constexpr int FLAG_LEFT = 0x0004;
    static constexpr int FLAG_RIGHT = 0x0008;
    static constexpr int FLAG_PLAY = 0x0010;
    static constexpr int FLAG_BACK = 0x0020;
    static constexpr int FLAG_LS_CLK = 0x0040;
    static constexpr int FLAG_RS_CLK = 0x0080;
    static constexpr int FLAG_LB = 0x0100;
    static constexpr int FLAG_RB = 0x0200;
    static constexpr int FLAG_SPECIAL = 0x0400;
    static constexpr int FLAG_A = 0x1000;
    static constexpr int FLAG_B = 0x2000;
    static constexpr int FLAG_X = 0x4000;
    static constexpr int FLAG_Y = 0x8000;

    static constexpr int FLAG_PADDLE1 = 0x010000;
    static constexpr int FLAG_PADDLE2 = 0x020000;
    static constexpr int FLAG_PADDLE3 = 0x040000;
    static constexpr int FLAG_PADDLE4 = 0x080000;
    static constexpr int FLAG_TOUCHPAD = 0x100000;
    static constexpr int FLAG_MISC = 0x200000;

    static constexpr int CTYPE_XBOX = 1;
    static constexpr int CTYPE_PS = 2;
    static constexpr int CTYPE_NINTENDO = 3;

    static constexpr int CCAP_ANALOG_TRIGGERS = 0x01;
    static constexpr int CCAP_RUMBLE = 0x02;
    static constexpr int CCAP_TRIGGER_RUMBLE = 0x04;
    static constexpr int CCAP_TOUCHPAD = 0x08;
    static constexpr int CCAP_ACCEL = 0x10;
    static constexpr int CCAP_GYRO = 0x20;
    static constexpr int CCAP_BATTERY_STATE = 0x40;
    static constexpr int CCAP_RGB_LED = 0x80;

    static constexpr int MOTION_ACCEL = 1;
    static constexpr int MOTION_GYRO = 2;

    static constexpr int TOUCH_HOVER = 0;
    static constexpr int TOUCH_DOWN = 1;
    static constexpr int TOUCH_UP = 2;
    static constexpr int TOUCH_MOVE = 3;
    static constexpr int TOUCH_CANCEL = 4;

    static constexpr int BATTERY_UNKNOWN = 0;
    static constexpr int BATTERY_DISCHARGING = 2;
    static constexpr int BATTERY_CHARGING = 3;
    static constexpr int BATTERY_FULL = 5;

    static constexpr int VK_LBUTTON = 0x01;
    static constexpr int VK_RBUTTON = 0x02;
    static constexpr int VK_CANCEL = 0x03;
    static constexpr int VK_MBUTTON = 0x04;
    static constexpr int VK_XBUTTON1 = 0x05;
    static constexpr int VK_XBUTTON2 = 0x06;
    static constexpr int VK_BACK = 0x08;
    static constexpr int VK_TAB = 0x09;
    static constexpr int VK_CLEAR = 0x0C;
    static constexpr int VK_RETURN = 0x0D;
    static constexpr int VK_SHIFT = 0x10;
    static constexpr int VK_CONTROL = 0x11;
    static constexpr int VK_MENU = 0x12;
    static constexpr int VK_PAUSE = 0x13;
    static constexpr int VK_CAPITAL = 0x14;
    static constexpr int VK_KANA = 0x15;
    static constexpr int VK_HANGUL = 0x15;
    static constexpr int VK_JUNJA = 0x17;
    static constexpr int VK_FINAL = 0x18;
    static constexpr int VK_HANJA = 0x19;
    static constexpr int VK_KANJI = 0x19;
    static constexpr int VK_ESCAPE = 0x1B;
    static constexpr int VK_CONVERT = 0x1C;
    static constexpr int VK_NONCONVERT = 0x1D;
    static constexpr int VK_ACCEPT = 0x1E;
    static constexpr int VK_MODECHANGE = 0x1F;
    static constexpr int VK_SPACE = 0x20;
    static constexpr int VK_PRIOR = 0x21;
    static constexpr int VK_NEXT = 0x22;
    static constexpr int VK_END = 0x23;
    static constexpr int VK_HOME = 0x24;
    static constexpr int VK_LEFT = 0x25;
    static constexpr int VK_UP = 0x26;
    static constexpr int VK_RIGHT = 0x27;
    static constexpr int VK_DOWN = 0x28;
    static constexpr int VK_SELECT = 0x29;
    static constexpr int VK_PRINT = 0x2A;
    static constexpr int VK_EXECUTE = 0x2B;
    static constexpr int VK_SNAPSHOT = 0x2C;
    static constexpr int VK_INSERT = 0x2D;
    static constexpr int VK_DELETE = 0x2E;
    static constexpr int VK_HELP = 0x2F;
    static constexpr int VK_0 = 0x30;
    static constexpr int VK_1 = 0x31;
    static constexpr int VK_2 = 0x32;
    static constexpr int VK_3 = 0x33;
    static constexpr int VK_4 = 0x34;
    static constexpr int VK_5 = 0x35;
    static constexpr int VK_6 = 0x36;
    static constexpr int VK_7 = 0x37;
    static constexpr int VK_8 = 0x38;
    static constexpr int VK_9 = 0x39;
    static constexpr int VK_A = 0x41;
    static constexpr int VK_B = 0x42;
    static constexpr int VK_C = 0x43;
    static constexpr int VK_D = 0x44;
    static constexpr int VK_E = 0x45;
    static constexpr int VK_F = 0x46;
    static constexpr int VK_G = 0x47;
    static constexpr int VK_H = 0x48;
    static constexpr int VK_I = 0x49;
    static constexpr int VK_J = 0x4A;
    static constexpr int VK_K = 0x4B;
    static constexpr int VK_L = 0x4C;
    static constexpr int VK_M = 0x4D;
    static constexpr int VK_N = 0x4E;
    static constexpr int VK_O = 0x4F;
    static constexpr int VK_P = 0x50;
    static constexpr int VK_Q = 0x51;
    static constexpr int VK_R = 0x52;
    static constexpr int VK_S = 0x53;
    static constexpr int VK_T = 0x54;
    static constexpr int VK_U = 0x55;
    static constexpr int VK_V = 0x56;
    static constexpr int VK_W = 0x57;
    static constexpr int VK_X = 0x58;
    static constexpr int VK_Y = 0x59;
    static constexpr int VK_Z = 0x5A;
    static constexpr int VK_LWIN = 0x5B;
    static constexpr int VK_RWIN = 0x5C;
    static constexpr int VK_APPS = 0x5D;
    static constexpr int VK_SLEEP = 0x5F;
    static constexpr int VK_NUMPAD0 = 0x60;
    static constexpr int VK_NUMPAD1 = 0x61;
    static constexpr int VK_NUMPAD2 = 0x62;
    static constexpr int VK_NUMPAD3 = 0x63;
    static constexpr int VK_NUMPAD4 = 0x64;
    static constexpr int VK_NUMPAD5 = 0x65;
    static constexpr int VK_NUMPAD6 = 0x66;
    static constexpr int VK_NUMPAD7 = 0x67;
    static constexpr int VK_NUMPAD8 = 0x68;
    static constexpr int VK_NUMPAD9 = 0x69;
    static constexpr int VK_MULTIPLY = 0x6A;
    static constexpr int VK_ADD = 0x6B;
    static constexpr int VK_SEPARATOR = 0x6C;
    static constexpr int VK_SUBTRACT = 0x6D;
    static constexpr int VK_DECIMAL = 0x6E;
    static constexpr int VK_DIVIDE = 0x6F;
    static constexpr int VK_F1 = 0x70;
    static constexpr int VK_F2 = 0x71;
    static constexpr int VK_F3 = 0x72;
    static constexpr int VK_F4 = 0x73;
    static constexpr int VK_F5 = 0x74;
    static constexpr int VK_F6 = 0x75;
    static constexpr int VK_F7 = 0x76;
    static constexpr int VK_F8 = 0x77;
    static constexpr int VK_F9 = 0x78;
    static constexpr int VK_F10 = 0x79;
    static constexpr int VK_F11 = 0x7A;
    static constexpr int VK_F12 = 0x7B;
    static constexpr int VK_F13 = 0x7C;
    static constexpr int VK_F14 = 0x7D;
    static constexpr int VK_F15 = 0x7E;
    static constexpr int VK_F16 = 0x7F;
    static constexpr int VK_F17 = 0x80;
    static constexpr int VK_F18 = 0x81;
    static constexpr int VK_F19 = 0x82;
    static constexpr int VK_F20 = 0x83;
    static constexpr int VK_F21 = 0x84;
    static constexpr int VK_F22 = 0x85;
    static constexpr int VK_F23 = 0x86;
    static constexpr int VK_F24 = 0x87;
    static constexpr int VK_NUMLOCK = 0x90;
    static constexpr int VK_SCROLL = 0x91;
    static constexpr int VK_OEM_1 = 0xBA;
    static constexpr int VK_OEM_PLUS = 0xBB;
    static constexpr int VK_OEM_COMMA = 0xBC;
    static constexpr int VK_OEM_MINUS = 0xBD;
    static constexpr int VK_OEM_PERIOD = 0xBE;
    static constexpr int VK_OEM_2 = 0xBF;
    static constexpr int VK_OEM_3 = 0xC0;
    static constexpr int VK_OEM_4 = 0xDB;
    static constexpr int VK_OEM_5 = 0xDC;
    static constexpr int VK_OEM_6 = 0xDD;
    static constexpr int VK_OEM_7 = 0xDE;
    static constexpr int VK_OEM_8 = 0xDF;
    static constexpr int VK_OEM_102 = 0xE2;
    static constexpr int VK_PROCESSKEY = 0xE5;
    static constexpr int VK_PACKET = 0xE7;
    static constexpr int VK_ATTN = 0xF6;
    static constexpr int VK_CRSEL = 0xF7;
    static constexpr int VK_EXSEL = 0xF8;
    static constexpr int VK_EREOF = 0xF9;
    static constexpr int VK_PLAY = 0xFA;
    static constexpr int VK_ZOOM = 0xFB;
    static constexpr int VK_NONAME = 0xFC;
    static constexpr int VK_PA1 = 0xFD;
    static constexpr int VK_OEM_CLEAR = 0xFE;
    static constexpr int VK_VOLUME_MUTE = 0xAD;
    static constexpr int VK_VOLUME_DOWN = 0xAE;
    static constexpr int VK_VOLUME_UP = 0xAF;
    static constexpr int VK_MEDIA_NEXT = 0xB0;
    static constexpr int VK_MEDIA_PREV = 0xB1;
    static constexpr int VK_MEDIA_PLAY = 0xB2;
    static constexpr int VK_BROWSER_BACK = 0xA6;
    static constexpr int VK_BROWSER_FORWARD = 0xA7;
    static constexpr int VK_BROWSER_REFRESH = 0xA8;
    static constexpr int VK_BROWSER_STOP = 0xA9;
    static constexpr int VK_BROWSER_SEARCH = 0xAA;
    static constexpr int VK_BROWSER_FAVORITES = 0xAB;
    static constexpr int VK_BROWSER_HOME = 0xAC;
    static constexpr int VK_LAUNCH_MAIL = 0xB4;
    static constexpr int VK_LAUNCH_MEDIA = 0xB5;
    static constexpr int VK_LAUNCH_APP1 = 0xB6;
    static constexpr int VK_LAUNCH_APP2 = 0xB7;

    InputBridge();
    ~InputBridge();

    int send_mouse_move(int delta_x, int delta_y);
    int send_mouse_position(int x, int y, int ref_w, int ref_h);
    int send_mouse_move_as_position(int delta_x, int delta_y, int ref_w, int ref_h);
    int follow_mouse_position(int x, int y, int ref_w, int ref_h);
    void stop_mouse_follow();
    int send_mouse_button_pressed(int button);
    int send_mouse_button_released(int button);
    int send_keyboard_event(int godot_key, int key_action, int modifiers);
    int send_keyboard_event2(int godot_key, int key_action, int modifiers, int flags);
    int send_utf8_text(const String &text);
    int send_controller_event(int button_flags, int left_trigger, int right_trigger, int left_stick_x, int left_stick_y, int right_stick_x, int right_stick_y);
    int send_multi_controller_event(int controller_number, int active_gamepad_mask, int button_flags, int left_trigger, int right_trigger, int left_stick_x, int left_stick_y, int right_stick_x, int right_stick_y);
    int send_controller_arrival(int controller_number, int active_gamepad_mask, int type, int supported_button_flags, int capabilities);
    int send_controller_motion(int controller_number, int motion_type, float x, float y, float z);
    int send_controller_battery(int controller_number, int battery_state, int battery_percentage);
    int send_scroll(int clicks);
    int send_high_res_scroll(int amount);
    int send_hscroll(int clicks);
    int send_high_res_hscroll(int amount);
    int get_host_feature_flags();

    static int godot_key_to_vk(int godot_key);

protected:
    static void _bind_methods();

private:
    using Clock = std::chrono::steady_clock;

    // Mouse Follows Pointer gets one pointer sample per rendered frame (60-120
    // Hz), which beats against the host's capture rate and looks jumpy. A
    // thread sends at FOLLOW_HZ in between, moving along the pointer's
    // velocity for at most one frame interval, so it adds no latency and
    // overshoots by at most one frame of motion when the pointer stops.
    static constexpr int FOLLOW_HZ = 250;
    static constexpr double FOLLOW_IDLE_SECONDS = 0.1;

    void follow_loop();
    int send_follow_point_locked(double x, double y);

    std::mutex follow_mutex_;
    std::thread follow_thread_;
    bool follow_thread_running_ = false;
    bool follow_active_ = false;
    double follow_x_ = 0.0;
    double follow_y_ = 0.0;
    double follow_vx_ = 0.0;
    double follow_vy_ = 0.0;
    double follow_interval_ = 1.0 / 60.0;
    int follow_ref_w_ = 0;
    int follow_ref_h_ = 0;
    int follow_sent_x_ = -1;
    int follow_sent_y_ = -1;
    Clock::time_point follow_sample_time_;
};

} // namespace godot
