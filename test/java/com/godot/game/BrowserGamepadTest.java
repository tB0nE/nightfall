package com.godot.game;

public final class BrowserGamepadTest {
    public static void main(String[] args) {
        if (args.length > 0 && args[0].equals("--script")) { System.out.print(BrowserGamepadScript.source()); return; }
        if (args.length > 0 && args[0].equals("--state")) {
            System.out.print(BrowserGamepadState.json(0x1001,255,128,32767,32767,-32767,-32767,100)); return;
        }
        String zero = BrowserGamepadState.json(0,0,0,0,0,0,0,1);
        if (BrowserGamepadState.hat(-1,-1) != 5 || BrowserGamepadState.hat(1,1) != 10
                || BrowserGamepadState.hat(0,0) != 0) throw new AssertionError("Hat mapping");
        if (BrowserGamepadState.trigger(-1,-1,1) != 0 || BrowserGamepadState.trigger(0,-1,1) != 0.5f
                || BrowserGamepadState.trigger(1,0,1) != 1 || BrowserGamepadState.trigger(5,0,1) != 1)
            throw new AssertionError("Trigger normalization");
        if (!zero.contains("\"buttons\":[0,0,0,0,0,0,0.0,0.0,0,0,0,0,0,0,0,0,0]")) throw new AssertionError(zero);
        String clipped = BrowserGamepadState.json(0,999,-20,99999,-99999,0,0,1);
        if (!clipped.contains("1.0,0.0,0,0,0,0,0,0,0,0,0") || !clipped.contains("\"axes\":[1.0,1.0,0.0,-0.0]")) throw new AssertionError(clipped);
        System.out.println("Browser gamepad mapping tests passed");
    }
}
