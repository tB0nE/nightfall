package app.nightfall.browserlab;

import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.view.KeyEvent;
import android.view.MotionEvent;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.HashMap;
import java.util.Map;

/** Input-only connection: never requests or decodes VNC framebuffer updates. */
final class LinuxRfbInput {
    private final File base;
    private final HandlerThread thread = new HandlerThread("LinuxBrowserInput");
    private final Handler handler;
    private volatile Socket socket;
    private volatile boolean closed;
    private DataOutputStream output;
    private int width, height, x, y, buttons;
    private long pointerEvents, keyEvents, lastStatus;
    private final Map<Integer, Integer> held = new HashMap<>();

    LinuxRfbInput(File base) {
        this.base = base;
        thread.start(); handler = new Handler(thread.getLooper());
        handler.post(() -> {
            try {
                Socket transport = new Socket(); socket = transport;
                // Dedicated input-only server: the ordinary noVNC server's
                // framebuffer polling can stall pointer handling under PRoot.
                transport.setTcpNoDelay(true); transport.connect(new InetSocketAddress("127.0.0.1", 5903), 3000);
                transport.setSoTimeout(3000);
                DataInputStream input = new DataInputStream(transport.getInputStream());
                output = new DataOutputStream(transport.getOutputStream());
                byte[] version = new byte[12]; input.readFully(version);
                if (!"RFB 003.008\n".equals(new String(version, java.nio.charset.StandardCharsets.US_ASCII)))
                    throw new IllegalStateException("Unexpected RFB version");
                output.write(version); output.flush();
                int count = input.readUnsignedByte(); boolean none = false;
                for (int i = 0; i < count; i++) if (input.readUnsignedByte() == 1) none = true;
                if (!none) throw new IllegalStateException("Lab RFB security unavailable");
                output.writeByte(1); output.flush();
                if (input.readInt() != 0) throw new IllegalStateException("RFB connection rejected");
                output.writeByte(1); output.flush(); // Shared: never evict the desktop viewer.
                width = input.readUnsignedShort(); height = input.readUnsignedShort();
                byte[] format = new byte[16]; input.readFully(format);
                int nameLength = input.readInt();
                if (width < 1 || height < 1 || width > 4096 || height > 4096 || nameLength < 0 || nameLength > 65536)
                    throw new IllegalStateException("Invalid RFB dimensions");
                discard(input, nameLength);
                status("ready", true);
                // Drain protocol notifications only, with no clipboard contents retained.
                transport.setSoTimeout(0);
                new Thread(() -> drain(input), "LinuxInputNotifications").start();
            } catch (Exception error) { fail(error); }
        });
    }

    private static void discard(DataInputStream input, int size) throws java.io.IOException {
        byte[] chunk = new byte[4096];
        while (size > 0) { int n = Math.min(size, chunk.length); input.readFully(chunk, 0, n); size -= n; }
    }

    private void drain(DataInputStream input) {
        try {
            while (!closed) {
                int type = input.readUnsignedByte();
                if (type == 2) continue; // Bell.
                if (type == 3) {
                    input.readUnsignedByte(); input.readUnsignedByte(); input.readUnsignedByte();
                    int size = input.readInt();
                    if (size < 0 || size > 1048576) throw new IllegalStateException("Unexpected clipboard size");
                    discard(input, size);
                } else throw new IllegalStateException("Unexpected input-only RFB notification");
            }
        } catch (Exception error) { if (!closed) handler.post(() -> fail(error)); }
    }

    void pointer(float nx, float ny, int action) {
        if (closed || !Float.isFinite(nx) || !Float.isFinite(ny)) return;
        handler.post(() -> {
            if (closed || output == null) return;
            try {
                x = Math.max(0, Math.min(width - 1, Math.round(nx * (width - 1))));
                y = Math.max(0, Math.min(height - 1, Math.round(ny * (height - 1))));
                if (action == MotionEvent.ACTION_DOWN) buttons = 1;
                if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL
                        || action == MotionEvent.ACTION_HOVER_EXIT) buttons = 0;
                sendPointer(); pointerEvents++; status("ready", false);
            } catch (Exception error) { fail(error); }
        });
    }

    void key(int code, boolean down, int modifiers) {
        if (closed) return;
        handler.post(() -> {
            if (closed || output == null) return;
            try {
                int symbol;
                if (down) {
                    symbol = keysym(code, modifiers);
                    if (symbol == 0) return;
                    held.put(code, symbol);
                } else {
                    Integer pressed = held.remove(code);
                    if (pressed == null) return;
                    symbol = pressed;
                }
                sendKey(symbol, down); keyEvents++; status("ready", false);
            } catch (Exception error) { fail(error); }
        });
    }

    static int keysym(int code, int modifiers) {
        if (code >= 131 && code <= 142) return 0xffbe + code - 131;
        switch (code) {
            case 4: case 111: return 0xff1b;
            case 19: return 0xff52; case 20: return 0xff54;
            case 21: return 0xff51; case 22: return 0xff53;
            case 61: return 0xff09; case 66: case 160: return 0xff0d;
            case 67: return 0xff08; case 112: return 0xffff;
            case 122: return 0xff50; case 123: return 0xff57;
            case 92: return 0xff55; case 93: return 0xff56; case 124: return 0xff63;
            case 57: return 0xffe9; case 58: return 0xffea;
            case 59: return 0xffe1; case 60: return 0xffe2;
            case 113: return 0xffe3; case 114: return 0xffe4;
            case 117: return 0xffeb; case 118: return 0xffec;
            case 115: return 0xffe5; case 143: return 0xff7f; case 116: return 0xff14;
        }
        int character = new KeyEvent(0, 0, KeyEvent.ACTION_DOWN, code, 0,
                modifiers & (KeyEvent.META_SHIFT_MASK | KeyEvent.META_CAPS_LOCK_ON)).getUnicodeChar();
        return character == 0 ? 0 : character <= 255 ? character : 0x01000000 | character;
    }

    private void sendPointer() throws java.io.IOException {
        output.writeByte(5); output.writeByte(buttons); output.writeShort(x); output.writeShort(y); output.flush();
    }
    private void sendKey(int symbol, boolean down) throws java.io.IOException {
        output.writeByte(4); output.writeByte(down ? 1 : 0); output.writeShort(0); output.writeInt(symbol); output.flush();
    }
    void release() {
        if (closed) return;
        handler.post(() -> {
            if (closed || output == null) return;
            try { releaseHeld(); } catch (Exception error) { fail(error); }
        });
    }
    private void releaseHeld() throws java.io.IOException {
        for (int symbol : held.values()) sendKey(symbol, false);
        held.clear(); buttons = 0; sendPointer();
    }
    private void fail(Exception error) {
        if (!closed) status("error: " + error.getClass().getSimpleName(), true);
        close();
    }
    private void status(String state, boolean force) {
        long now = SystemClock.uptimeMillis();
        if (!force && now - lastStatus < 1000) return;
        lastStatus = now;
        try {
            org.json.JSONObject data = new org.json.JSONObject();
            data.put("state", state).put("port", 5903).put("width", width).put("height", height)
                    .put("pointer_events", pointerEvents).put("key_events", keyEvents);
            File temporary = new File(base, "direct-input-status.tmp");
            try (java.io.FileOutputStream file = new java.io.FileOutputStream(temporary)) {
                file.write(data.toString(2).getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            temporary.renameTo(new File(base, "direct-input-status.json"));
        } catch (Exception ignored) { }
    }
    void close() {
        if (closed) return;
        handler.post(() -> {
            if (closed) return;
            try { if (output != null) releaseHeld(); } catch (Exception ignored) { }
            closed = true;
            try { if (socket != null) socket.close(); } catch (Exception ignored) { }
            thread.quitSafely();
        });
    }
}
