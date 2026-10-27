package com.godot.game;

/** Pure Moonlight/XInput -> Web Gamepad standard mapping, immutable snapshots. */
final class BrowserGamepadState {
    static int hat(float x, float y) { return (x < -0.5f ? 4 : x > 0.5f ? 8 : 0) | (y < -0.5f ? 1 : y > 0.5f ? 2 : 0); }
    static float trigger(float value, float min, float max) {
        return max > min ? Math.max(0, Math.min(1, (value - min) / (max - min))) : 0;
    }
    private static final int[] FLAGS = {0x1000,0x2000,0x4000,0x8000,0x100,0x200,0,0,
        0x20,0x10,0x40,0x80,1,2,4,8,0x400};
    static String json(int buttons, int lt, int rt, int lx, int ly, int rx, int ry, long time) {
        StringBuilder out = new StringBuilder("{\"time\":").append(time).append(",\"buttons\":[");
        for (int i = 0; i < FLAGS.length; ++i) {
            if (i != 0) out.append(',');
            if (i == 6 || i == 7) out.append(Math.max(0, Math.min(255, i == 6 ? lt : rt)) / 255.0);
            else out.append((buttons & FLAGS[i]) != 0 ? 1 : 0);
        }
        // Moonlight sticks are +Y up; the Web Gamepad standard is +Y down.
        return out.append("],\"axes\":[").append(axis(lx)).append(',').append(-axis(ly))
            .append(',').append(axis(rx)).append(',').append(-axis(ry)).append("]}").toString();
    }
    private static double axis(int value) { return Math.max(-1, Math.min(1, value / 32767.0)); }
}
