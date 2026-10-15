package com.godot.game;

import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;

/** Browser-only Android pad snapshot, independent of Godot's positional axes. */
final class BrowserPhysicalGamepad {
    final int deviceId;
    final String name;
    private int keys, hats;
    private float lt, rt, lx, ly, rx, ry;
    private boolean digitalLt, digitalRt;

    BrowserPhysicalGamepad(InputDevice device) { deviceId = device.getId(); name = device.getName(); }

    static boolean accepts(KeyEvent event) {
        InputDevice device = event.getDevice();
        boolean source = event.isFromSource(InputDevice.SOURCE_GAMEPAD) || event.isFromSource(InputDevice.SOURCE_JOYSTICK);
        // Some Android drivers label D-pad key events as SOURCE_DPAD only.
        return source || (device != null && (device.supportsSource(InputDevice.SOURCE_GAMEPAD)
            || device.supportsSource(InputDevice.SOURCE_JOYSTICK)) && flag(event.getKeyCode()) != 0);
    }

    void key(KeyEvent event) {
        boolean down = event.getAction() == KeyEvent.ACTION_DOWN;
        int flag = flag(event.getKeyCode());
        keys = down ? keys | flag : keys & ~flag;
        if (event.getKeyCode() == KeyEvent.KEYCODE_BUTTON_L2) digitalLt = down;
        if (event.getKeyCode() == KeyEvent.KEYCODE_BUTTON_R2) digitalRt = down;
    }
    static int flag(int key) {
        switch (key) {
            case KeyEvent.KEYCODE_BUTTON_A: return 0x1000;
            case KeyEvent.KEYCODE_BUTTON_B: return 0x2000;
            case KeyEvent.KEYCODE_BUTTON_X: return 0x4000;
            case KeyEvent.KEYCODE_BUTTON_Y: return 0x8000;
            case KeyEvent.KEYCODE_BUTTON_L1: return 0x100;
            case KeyEvent.KEYCODE_BUTTON_R1: return 0x200;
            case KeyEvent.KEYCODE_BUTTON_SELECT: return 0x20;
            case KeyEvent.KEYCODE_BUTTON_START: return 0x10;
            case KeyEvent.KEYCODE_BUTTON_THUMBL: return 0x40;
            case KeyEvent.KEYCODE_BUTTON_THUMBR: return 0x80;
            case KeyEvent.KEYCODE_BUTTON_MODE: return 0x400;
            case KeyEvent.KEYCODE_DPAD_UP: return 1;
            case KeyEvent.KEYCODE_DPAD_DOWN: return 2;
            case KeyEvent.KEYCODE_DPAD_LEFT: return 4;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return 8;
            default: return 0;
        }
    }
    private static int select(InputDevice device, int... axes) {
        for (int axis : axes) if (device.getMotionRange(axis) != null) return axis;
        return -1;
    }
    private static float stick(MotionEvent event, InputDevice device, int axis) {
        if (axis < 0) return 0;
        InputDevice.MotionRange range = device.getMotionRange(axis);
        float value = event.getAxisValue(axis);
        return range != null && Math.abs(value) <= range.getFlat() ? 0 : Math.max(-1, Math.min(1, value));
    }
    private static float trigger(MotionEvent event, InputDevice device, int axis) {
        if (axis < 0) return 0;
        InputDevice.MotionRange range = device.getMotionRange(axis);
        return BrowserGamepadState.trigger(event.getAxisValue(axis), range.getMin(), range.getMax());
    }
    void motion(MotionEvent event) {
        InputDevice device = event.getDevice();
        if (device == null) return;
        lx = stick(event, device, MotionEvent.AXIS_X);
        ly = stick(event, device, MotionEvent.AXIS_Y);
        boolean zStick = device.getMotionRange(MotionEvent.AXIS_Z) != null && device.getMotionRange(MotionEvent.AXIS_RZ) != null;
        rx = stick(event, device, zStick ? MotionEvent.AXIS_Z : MotionEvent.AXIS_RX);
        ry = stick(event, device, zStick ? MotionEvent.AXIS_RZ : MotionEvent.AXIS_RY);
        lt = trigger(event, device, select(device, MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_BRAKE,
            zStick ? MotionEvent.AXIS_RX : -1));
        rt = trigger(event, device, select(device, MotionEvent.AXIS_RTRIGGER, MotionEvent.AXIS_GAS,
            zStick ? MotionEvent.AXIS_RY : -1));
        hats = BrowserGamepadState.hat(event.getAxisValue(MotionEvent.AXIS_HAT_X), event.getAxisValue(MotionEvent.AXIS_HAT_Y));
    }
    String json() {
        String state = BrowserGamepadState.json(keys | hats, Math.round(Math.max(lt, digitalLt ? 1 : 0) * 255),
            Math.round(Math.max(rt, digitalRt ? 1 : 0) * 255), Math.round(lx * 32767), -Math.round(ly * 32767),
            Math.round(rx * 32767), -Math.round(ry * 32767), android.os.SystemClock.uptimeMillis());
        return "{\"id\":" + org.json.JSONObject.quote("Nightfall " + name)
            + ",\"nativeName\":" + org.json.JSONObject.quote(name) + "," + state.substring(1);
    }
}
