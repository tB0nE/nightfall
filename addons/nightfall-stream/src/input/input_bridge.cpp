#include "input_bridge.h"

#include <Limelight.h>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

using namespace godot;

InputBridge::InputBridge() {}

InputBridge::~InputBridge() {}

int InputBridge::send_mouse_move(int delta_x, int delta_y) {
    return LiSendMouseMoveEvent((short)delta_x, (short)delta_y);
}

int InputBridge::send_mouse_position(int x, int y, int ref_w, int ref_h) {
    return LiSendMousePositionEvent((short)x, (short)y, (short)ref_w, (short)ref_h);
}

int InputBridge::send_mouse_move_as_position(int delta_x, int delta_y, int ref_w, int ref_h) {
    return LiSendMouseMoveAsMousePositionEvent((short)delta_x, (short)delta_y, (short)ref_w, (short)ref_h);
}

int InputBridge::send_mouse_button_pressed(int button) {
    return LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
}

int InputBridge::send_mouse_button_released(int button) {
    return LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
}

int InputBridge::send_keyboard_event(int godot_key, int key_action, int modifiers) {
    int vk = godot_key_to_vk(godot_key);
    if (vk == 0) return 0;
    return LiSendKeyboardEvent((short)vk, (char)key_action, (char)modifiers);
}

int InputBridge::send_keyboard_event2(int godot_key, int key_action, int modifiers, int flags) {
    int vk = godot_key_to_vk(godot_key);
    if (vk == 0) return 0;
    return LiSendKeyboardEvent2((short)vk, (char)key_action, (char)modifiers, (char)flags);
}

int InputBridge::send_utf8_text(const String &text) {
    return LiSendUtf8TextEvent(text.utf8().get_data(), (unsigned int)text.length());
}

int InputBridge::send_controller_event(int button_flags, int left_trigger, int right_trigger, int left_stick_x, int left_stick_y, int right_stick_x, int right_stick_y) {
    return LiSendControllerEvent(button_flags, (unsigned char)left_trigger, (unsigned char)right_trigger,
                                 (short)left_stick_x, (short)left_stick_y, (short)right_stick_x, (short)right_stick_y);
}

int InputBridge::send_multi_controller_event(int controller_number, int active_gamepad_mask, int button_flags, int left_trigger, int right_trigger, int left_stick_x, int left_stick_y, int right_stick_x, int right_stick_y) {
    return LiSendMultiControllerEvent((short)controller_number, (short)active_gamepad_mask,
                                       button_flags, (unsigned char)left_trigger, (unsigned char)right_trigger,
                                       (short)left_stick_x, (short)left_stick_y, (short)right_stick_x, (short)right_stick_y);
}

int InputBridge::send_controller_arrival(int controller_number, int active_gamepad_mask, int type, int supported_button_flags, int capabilities) {
    return LiSendControllerArrivalEvent((uint8_t)controller_number, (uint16_t)active_gamepad_mask,
                                        (uint8_t)type, (uint32_t)supported_button_flags, (uint16_t)capabilities);
}

int InputBridge::send_controller_motion(int controller_number, int motion_type, float x, float y, float z) {
    return LiSendControllerMotionEvent((uint8_t)controller_number, (uint8_t)motion_type, x, y, z);
}

int InputBridge::send_controller_battery(int controller_number, int battery_state, int battery_percentage) {
    return LiSendControllerBatteryEvent((uint8_t)controller_number, (uint8_t)battery_state, (uint8_t)battery_percentage);
}

int InputBridge::send_scroll(int clicks) {
    return LiSendScrollEvent((signed char)clicks);
}

int InputBridge::send_high_res_scroll(int amount) {
    return LiSendHighResScrollEvent((short)amount);
}

int InputBridge::send_hscroll(int clicks) {
    return LiSendHScrollEvent((signed char)clicks);
}

int InputBridge::send_high_res_hscroll(int amount) {
    return LiSendHighResHScrollEvent((short)amount);
}

int InputBridge::get_host_feature_flags() {
    return (int)LiGetHostFeatureFlags();
}

int InputBridge::godot_key_to_vk(int godot_key) {
    if (godot_key >= 65 && godot_key <= 90) return godot_key;
    if (godot_key >= 48 && godot_key <= 57) return godot_key;

    switch (godot_key) {
    case 32: return 0x20;
    case 33: return 0x31;
    case 64: return 0x32;
    case 35: return 0x33;
    case 36: return 0x34;
    case 37: return 0x35;
    case 94: return 0x36;
    case 38: return 0x37;
    case 42: return 0x38;
    case 40: return 0x39;
    case 41: return 0x30;
    case 45: return 0xBD;
    case 61: return 0xBB;
    case 91: return 0xDB;
    case 93: return 0xDD;
    case 92: return 0xDC;
    case 59: return 0xBA;
    case 39: return 0xDE;
    case 44: return 0xBC;
    case 46: return 0xBE;
    case 47: return 0xBF;
    case 96: return 0xC0;

    // Use Godot's named constants rather than copied enum values. The old
    // table predated Godot's Pause/Print/SysReq/Clear additions, so every
    // navigation key from Insert onward was translated as a different key.
    case KEY_ESCAPE: return 0x1B;
    case KEY_TAB:
    case KEY_BACKTAB: return 0x09;
    case KEY_BACKSPACE: return 0x08;
    case KEY_ENTER:
    case KEY_KP_ENTER: return 0x0D;
    case KEY_INSERT: return 0x2D;
    case KEY_DELETE: return 0x2E;
    case KEY_PAUSE: return 0x13;
    case KEY_PRINT:
    case KEY_SYSREQ: return 0x2C;
    case KEY_CLEAR: return 0x0C;
    case KEY_HOME: return 0x24;
    case KEY_END: return 0x23;
    case KEY_LEFT: return 0x25;
    case KEY_UP: return 0x26;
    case KEY_RIGHT: return 0x27;
    case KEY_DOWN: return 0x28;
    case KEY_PAGEUP: return 0x21;
    case KEY_PAGEDOWN: return 0x22;

    case KEY_SHIFT: return 0x10;
    case KEY_CTRL: return 0x11;
    case KEY_ALT: return 0x12;
    case KEY_META: return 0x5B;
    case KEY_CAPSLOCK: return 0x14;
    case KEY_NUMLOCK: return 0x90;
    case KEY_SCROLLLOCK: return 0x91;

    case KEY_F1: return 0x70;
    case KEY_F2: return 0x71;
    case KEY_F3: return 0x72;
    case KEY_F4: return 0x73;
    case KEY_F5: return 0x74;
    case KEY_F6: return 0x75;
    case KEY_F7: return 0x76;
    case KEY_F8: return 0x77;
    case KEY_F9: return 0x78;
    case KEY_F10: return 0x79;
    case KEY_F11: return 0x7A;
    case KEY_F12: return 0x7B;
    case KEY_F13: return 0x7C;
    case KEY_F14: return 0x7D;
    case KEY_F15: return 0x7E;
    case KEY_F16: return 0x7F;
    case KEY_F17: return 0x80;
    case KEY_F18: return 0x81;
    case KEY_F19: return 0x82;
    case KEY_F20: return 0x83;
    case KEY_F21: return 0x84;
    case KEY_F22: return 0x85;
    case KEY_F23: return 0x86;
    case KEY_F24: return 0x87;

    case KEY_KP_0: return 0x60;
    case KEY_KP_1: return 0x61;
    case KEY_KP_2: return 0x62;
    case KEY_KP_3: return 0x63;
    case KEY_KP_4: return 0x64;
    case KEY_KP_5: return 0x65;
    case KEY_KP_6: return 0x66;
    case KEY_KP_7: return 0x67;
    case KEY_KP_8: return 0x68;
    case KEY_KP_9: return 0x69;
    case KEY_KP_MULTIPLY: return 0x6A;
    case KEY_KP_ADD: return 0x6B;
    case KEY_KP_SUBTRACT: return 0x6D;
    case KEY_KP_PERIOD: return 0x6E;
    case KEY_KP_DIVIDE: return 0x6F;

    case KEY_MENU: return 0x5D;
    case KEY_HELP: return 0x2F;
    case KEY_BACK: return 0xA6;
    case KEY_FORWARD: return 0xA7;
    case KEY_REFRESH: return 0xA8;
    case KEY_STOP: return 0xA9;
    case KEY_VOLUMEMUTE: return 0xAD;
    case KEY_VOLUMEDOWN: return 0xAE;
    case KEY_VOLUMEUP: return 0xAF;
    case KEY_MEDIANEXT: return 0xB0;
    case KEY_MEDIAPREVIOUS: return 0xB1;
    case KEY_MEDIASTOP: return 0xB2;
    case KEY_MEDIAPLAY: return 0xB3;

    default: return 0;
    }
}

void InputBridge::_bind_methods() {
    BIND_CONSTANT(MBTN_PRESS);
    BIND_CONSTANT(MBTN_RELEASE);
    BIND_CONSTANT(MBTN_LEFT);
    BIND_CONSTANT(MBTN_MIDDLE);
    BIND_CONSTANT(MBTN_RIGHT);
    BIND_CONSTANT(MBTN_X1);
    BIND_CONSTANT(MBTN_X2);

    BIND_CONSTANT(KA_DOWN);
    BIND_CONSTANT(KA_UP);
    BIND_CONSTANT(MOD_SHIFT);
    BIND_CONSTANT(MOD_CTRL);
    BIND_CONSTANT(MOD_ALT);
    BIND_CONSTANT(MOD_META);

    BIND_CONSTANT(FLAG_UP);
    BIND_CONSTANT(FLAG_DOWN);
    BIND_CONSTANT(FLAG_LEFT);
    BIND_CONSTANT(FLAG_RIGHT);
    BIND_CONSTANT(FLAG_PLAY);
    BIND_CONSTANT(FLAG_BACK);
    BIND_CONSTANT(FLAG_LS_CLK);
    BIND_CONSTANT(FLAG_RS_CLK);
    BIND_CONSTANT(FLAG_LB);
    BIND_CONSTANT(FLAG_RB);
    BIND_CONSTANT(FLAG_SPECIAL);
    BIND_CONSTANT(FLAG_A);
    BIND_CONSTANT(FLAG_B);
    BIND_CONSTANT(FLAG_X);
    BIND_CONSTANT(FLAG_Y);
    BIND_CONSTANT(FLAG_PADDLE1);
    BIND_CONSTANT(FLAG_PADDLE2);
    BIND_CONSTANT(FLAG_PADDLE3);
    BIND_CONSTANT(FLAG_PADDLE4);
    BIND_CONSTANT(FLAG_TOUCHPAD);
    BIND_CONSTANT(FLAG_MISC);

    BIND_CONSTANT(CTYPE_XBOX);
    BIND_CONSTANT(CTYPE_PS);
    BIND_CONSTANT(CTYPE_NINTENDO);

    BIND_CONSTANT(CCAP_ANALOG_TRIGGERS);
    BIND_CONSTANT(CCAP_RUMBLE);
    BIND_CONSTANT(CCAP_TRIGGER_RUMBLE);
    BIND_CONSTANT(CCAP_TOUCHPAD);
    BIND_CONSTANT(CCAP_ACCEL);
    BIND_CONSTANT(CCAP_GYRO);
    BIND_CONSTANT(CCAP_BATTERY_STATE);
    BIND_CONSTANT(CCAP_RGB_LED);

    BIND_CONSTANT(MOTION_ACCEL);
    BIND_CONSTANT(MOTION_GYRO);

    BIND_CONSTANT(TOUCH_HOVER);
    BIND_CONSTANT(TOUCH_DOWN);
    BIND_CONSTANT(TOUCH_UP);
    BIND_CONSTANT(TOUCH_MOVE);
    BIND_CONSTANT(TOUCH_CANCEL);

    BIND_CONSTANT(BATTERY_UNKNOWN);
    BIND_CONSTANT(BATTERY_DISCHARGING);
    BIND_CONSTANT(BATTERY_CHARGING);
    BIND_CONSTANT(BATTERY_FULL);

    BIND_CONSTANT(VK_LBUTTON);
    BIND_CONSTANT(VK_RBUTTON);
    BIND_CONSTANT(VK_CANCEL);
    BIND_CONSTANT(VK_MBUTTON);
    BIND_CONSTANT(VK_XBUTTON1);
    BIND_CONSTANT(VK_XBUTTON2);
    BIND_CONSTANT(VK_BACK);
    BIND_CONSTANT(VK_TAB);
    BIND_CONSTANT(VK_CLEAR);
    BIND_CONSTANT(VK_RETURN);
    BIND_CONSTANT(VK_SHIFT);
    BIND_CONSTANT(VK_CONTROL);
    BIND_CONSTANT(VK_MENU);
    BIND_CONSTANT(VK_PAUSE);
    BIND_CONSTANT(VK_CAPITAL);
    BIND_CONSTANT(VK_KANA);
    BIND_CONSTANT(VK_HANGUL);
    BIND_CONSTANT(VK_JUNJA);
    BIND_CONSTANT(VK_FINAL);
    BIND_CONSTANT(VK_HANJA);
    BIND_CONSTANT(VK_KANJI);
    BIND_CONSTANT(VK_ESCAPE);
    BIND_CONSTANT(VK_CONVERT);
    BIND_CONSTANT(VK_NONCONVERT);
    BIND_CONSTANT(VK_ACCEPT);
    BIND_CONSTANT(VK_MODECHANGE);
    BIND_CONSTANT(VK_SPACE);
    BIND_CONSTANT(VK_PRIOR);
    BIND_CONSTANT(VK_NEXT);
    BIND_CONSTANT(VK_END);
    BIND_CONSTANT(VK_HOME);
    BIND_CONSTANT(VK_LEFT);
    BIND_CONSTANT(VK_UP);
    BIND_CONSTANT(VK_RIGHT);
    BIND_CONSTANT(VK_DOWN);
    BIND_CONSTANT(VK_SELECT);
    BIND_CONSTANT(VK_PRINT);
    BIND_CONSTANT(VK_EXECUTE);
    BIND_CONSTANT(VK_SNAPSHOT);
    BIND_CONSTANT(VK_INSERT);
    BIND_CONSTANT(VK_DELETE);
    BIND_CONSTANT(VK_HELP);
    BIND_CONSTANT(VK_0);
    BIND_CONSTANT(VK_1);
    BIND_CONSTANT(VK_2);
    BIND_CONSTANT(VK_3);
    BIND_CONSTANT(VK_4);
    BIND_CONSTANT(VK_5);
    BIND_CONSTANT(VK_6);
    BIND_CONSTANT(VK_7);
    BIND_CONSTANT(VK_8);
    BIND_CONSTANT(VK_9);
    BIND_CONSTANT(VK_A);
    BIND_CONSTANT(VK_B);
    BIND_CONSTANT(VK_C);
    BIND_CONSTANT(VK_D);
    BIND_CONSTANT(VK_E);
    BIND_CONSTANT(VK_F);
    BIND_CONSTANT(VK_G);
    BIND_CONSTANT(VK_H);
    BIND_CONSTANT(VK_I);
    BIND_CONSTANT(VK_J);
    BIND_CONSTANT(VK_K);
    BIND_CONSTANT(VK_L);
    BIND_CONSTANT(VK_M);
    BIND_CONSTANT(VK_N);
    BIND_CONSTANT(VK_O);
    BIND_CONSTANT(VK_P);
    BIND_CONSTANT(VK_Q);
    BIND_CONSTANT(VK_R);
    BIND_CONSTANT(VK_S);
    BIND_CONSTANT(VK_T);
    BIND_CONSTANT(VK_U);
    BIND_CONSTANT(VK_V);
    BIND_CONSTANT(VK_W);
    BIND_CONSTANT(VK_X);
    BIND_CONSTANT(VK_Y);
    BIND_CONSTANT(VK_Z);
    BIND_CONSTANT(VK_LWIN);
    BIND_CONSTANT(VK_RWIN);
    BIND_CONSTANT(VK_APPS);
    BIND_CONSTANT(VK_SLEEP);
    BIND_CONSTANT(VK_NUMPAD0);
    BIND_CONSTANT(VK_NUMPAD1);
    BIND_CONSTANT(VK_NUMPAD2);
    BIND_CONSTANT(VK_NUMPAD3);
    BIND_CONSTANT(VK_NUMPAD4);
    BIND_CONSTANT(VK_NUMPAD5);
    BIND_CONSTANT(VK_NUMPAD6);
    BIND_CONSTANT(VK_NUMPAD7);
    BIND_CONSTANT(VK_NUMPAD8);
    BIND_CONSTANT(VK_NUMPAD9);
    BIND_CONSTANT(VK_MULTIPLY);
    BIND_CONSTANT(VK_ADD);
    BIND_CONSTANT(VK_SEPARATOR);
    BIND_CONSTANT(VK_SUBTRACT);
    BIND_CONSTANT(VK_DECIMAL);
    BIND_CONSTANT(VK_DIVIDE);
    BIND_CONSTANT(VK_F1);
    BIND_CONSTANT(VK_F2);
    BIND_CONSTANT(VK_F3);
    BIND_CONSTANT(VK_F4);
    BIND_CONSTANT(VK_F5);
    BIND_CONSTANT(VK_F6);
    BIND_CONSTANT(VK_F7);
    BIND_CONSTANT(VK_F8);
    BIND_CONSTANT(VK_F9);
    BIND_CONSTANT(VK_F10);
    BIND_CONSTANT(VK_F11);
    BIND_CONSTANT(VK_F12);
    BIND_CONSTANT(VK_F13);
    BIND_CONSTANT(VK_F14);
    BIND_CONSTANT(VK_F15);
    BIND_CONSTANT(VK_F16);
    BIND_CONSTANT(VK_F17);
    BIND_CONSTANT(VK_F18);
    BIND_CONSTANT(VK_F19);
    BIND_CONSTANT(VK_F20);
    BIND_CONSTANT(VK_F21);
    BIND_CONSTANT(VK_F22);
    BIND_CONSTANT(VK_F23);
    BIND_CONSTANT(VK_F24);
    BIND_CONSTANT(VK_NUMLOCK);
    BIND_CONSTANT(VK_SCROLL);
    BIND_CONSTANT(VK_OEM_1);
    BIND_CONSTANT(VK_OEM_PLUS);
    BIND_CONSTANT(VK_OEM_COMMA);
    BIND_CONSTANT(VK_OEM_MINUS);
    BIND_CONSTANT(VK_OEM_PERIOD);
    BIND_CONSTANT(VK_OEM_2);
    BIND_CONSTANT(VK_OEM_3);
    BIND_CONSTANT(VK_OEM_4);
    BIND_CONSTANT(VK_OEM_5);
    BIND_CONSTANT(VK_OEM_6);
    BIND_CONSTANT(VK_OEM_7);
    BIND_CONSTANT(VK_OEM_8);
    BIND_CONSTANT(VK_OEM_102);
    BIND_CONSTANT(VK_PROCESSKEY);
    BIND_CONSTANT(VK_PACKET);
    BIND_CONSTANT(VK_ATTN);
    BIND_CONSTANT(VK_CRSEL);
    BIND_CONSTANT(VK_EXSEL);
    BIND_CONSTANT(VK_EREOF);
    BIND_CONSTANT(VK_PLAY);
    BIND_CONSTANT(VK_ZOOM);
    BIND_CONSTANT(VK_NONAME);
    BIND_CONSTANT(VK_PA1);
    BIND_CONSTANT(VK_OEM_CLEAR);
    BIND_CONSTANT(VK_VOLUME_MUTE);
    BIND_CONSTANT(VK_VOLUME_DOWN);
    BIND_CONSTANT(VK_VOLUME_UP);
    BIND_CONSTANT(VK_MEDIA_NEXT);
    BIND_CONSTANT(VK_MEDIA_PREV);
    BIND_CONSTANT(VK_MEDIA_PLAY);
    BIND_CONSTANT(VK_BROWSER_BACK);
    BIND_CONSTANT(VK_BROWSER_FORWARD);
    BIND_CONSTANT(VK_BROWSER_REFRESH);
    BIND_CONSTANT(VK_BROWSER_STOP);
    BIND_CONSTANT(VK_BROWSER_SEARCH);
    BIND_CONSTANT(VK_BROWSER_FAVORITES);
    BIND_CONSTANT(VK_BROWSER_HOME);
    BIND_CONSTANT(VK_LAUNCH_MAIL);
    BIND_CONSTANT(VK_LAUNCH_MEDIA);
    BIND_CONSTANT(VK_LAUNCH_APP1);
    BIND_CONSTANT(VK_LAUNCH_APP2);

    ClassDB::bind_method(D_METHOD("send_mouse_move", "delta_x", "delta_y"), &InputBridge::send_mouse_move);
    ClassDB::bind_method(D_METHOD("send_mouse_position", "x", "y", "ref_w", "ref_h"), &InputBridge::send_mouse_position);
    ClassDB::bind_method(D_METHOD("send_mouse_move_as_position", "delta_x", "delta_y", "ref_w", "ref_h"), &InputBridge::send_mouse_move_as_position);
    ClassDB::bind_method(D_METHOD("send_mouse_button_pressed", "button"), &InputBridge::send_mouse_button_pressed);
    ClassDB::bind_method(D_METHOD("send_mouse_button_released", "button"), &InputBridge::send_mouse_button_released);
    ClassDB::bind_method(D_METHOD("send_keyboard_event", "godot_key", "key_action", "modifiers"), &InputBridge::send_keyboard_event);
    ClassDB::bind_method(D_METHOD("send_keyboard_event2", "godot_key", "key_action", "modifiers", "flags"), &InputBridge::send_keyboard_event2);
    ClassDB::bind_method(D_METHOD("send_utf8_text", "text"), &InputBridge::send_utf8_text);
    ClassDB::bind_method(D_METHOD("send_controller_event", "button_flags", "left_trigger", "right_trigger", "left_stick_x", "left_stick_y", "right_stick_x", "right_stick_y"), &InputBridge::send_controller_event);
    ClassDB::bind_method(D_METHOD("send_multi_controller_event", "controller_number", "active_gamepad_mask", "button_flags", "left_trigger", "right_trigger", "left_stick_x", "left_stick_y", "right_stick_x", "right_stick_y"), &InputBridge::send_multi_controller_event);
    ClassDB::bind_method(D_METHOD("send_controller_arrival", "controller_number", "active_gamepad_mask", "type", "supported_button_flags", "capabilities"), &InputBridge::send_controller_arrival);
    ClassDB::bind_method(D_METHOD("send_controller_motion", "controller_number", "motion_type", "x", "y", "z"), &InputBridge::send_controller_motion);
    ClassDB::bind_method(D_METHOD("send_controller_battery", "controller_number", "battery_state", "battery_percentage"), &InputBridge::send_controller_battery);
    ClassDB::bind_method(D_METHOD("send_scroll", "clicks"), &InputBridge::send_scroll);
    ClassDB::bind_method(D_METHOD("send_high_res_scroll", "amount"), &InputBridge::send_high_res_scroll);
    ClassDB::bind_method(D_METHOD("send_hscroll", "clicks"), &InputBridge::send_hscroll);
    ClassDB::bind_method(D_METHOD("send_high_res_hscroll", "amount"), &InputBridge::send_high_res_hscroll);
    ClassDB::bind_method(D_METHOD("get_host_feature_flags"), &InputBridge::get_host_feature_flags);
    ClassDB::bind_static_method("InputBridge", D_METHOD("godot_key_to_vk", "godot_key"), &InputBridge::godot_key_to_vk);
}
