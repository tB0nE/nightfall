package app.nightfall.browserlab;

import android.os.Handler;
import android.os.HandlerThread;
import android.view.MotionEvent;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;

/** LAB ONLY: page control over Chrome's loopback DevTools socket. No screenshot
 * transport, site modification, profile access, mobile UA or DRM manipulation. */
final class LinuxBrowserControl {
    private final HandlerThread worker = new HandlerThread("LinuxBrowserTouch");
    private final Handler handler;
    private final File base;
    private volatile boolean closed, closing;
    private volatile String snapshot = "{\"ready\":false}";
    private volatile Socket socket;
    private DataInputStream in;
    private OutputStream out;
    private int sequence, width = 1920, height = 1080;
    private boolean touching, dragScrolling;
    private float startX, startY, lastY;
    private int dragScrollEvents, hoverEvents, reconnects;
    private long lastHover;
    private String operation = "connect";
    private int touches, scrolls;
    private float moveX, moveY;
    private int moveAction;
    private boolean movePending, scrollPending;
    private int inputGesture, pendingGesture, activeGesture, scrollDirection;
    private final SecureRandom random = new SecureRandom();
    private final Runnable move = () -> {
        float x, y; int gesture, action;
        synchronized (this) { movePending = false; x = moveX; y = moveY; gesture = pendingGesture; action = moveAction; }
        perform(() -> {
            if (action == MotionEvent.ACTION_HOVER_MOVE) {
                long now = android.os.SystemClock.uptimeMillis();
                if (!touching && now - lastHover >= 30) { mouseHover(x, y); lastHover = now; }
            } else if (touching && gesture == activeGesture) {
                float dx = (x - startX) * width, dy = (y - startY) * height;
                if (!dragScrolling && Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx) * 1.2) {
                    touch("touchCancel", 0, 0); dragScrolling = true;
                }
                if (dragScrolling) wheel(startX, startY, (lastY - y) * height);
                else touch("touchMove", x, y);
                lastY = y;
            }
        });
    };
    private interface Work { void run() throws Exception; }

    LinuxBrowserControl(File base) {
        this.base = base;
        worker.start(); handler = new Handler(worker.getLooper());
        handler.post(this::reconnect);
    }
    private void reconnect() {
        if (closed || closing) return;
        try {
            operation = "connect"; connect();
            call("Emulation.setTouchEmulationEnabled", new JSONObject().put("enabled", true).put("maxTouchPoints", 1));
            call("Emulation.setScrollbarsHidden", new JSONObject().put("hidden", true));
            updateState(); handler.post(poll);
        } catch (Exception error) { fail(error); }
    }

    private void perform(Work work) {
        if (closed || out == null) return;
        try { work.run(); } catch (Exception error) { fail(error); }
    }
    private final Runnable poll = new Runnable() {
        @Override public void run() {
            perform(() -> updateNavigationState());
            if (!closed && !closing && out != null) handler.postDelayed(this, 1000);
        }
    };
    private void connect() throws Exception {
        HttpURLConnection http = (HttpURLConnection)new URL("http://127.0.0.1:9222/json/list").openConnection();
        http.setConnectTimeout(2000); http.setReadTimeout(2000);
        String endpoint = null;
        String ownedId = "";
        File identity = new File(base, "chrome-page-id");
        try { ownedId = new String(java.nio.file.Files.readAllBytes(identity.toPath()), StandardCharsets.US_ASCII); }
        catch (IOException ignored) { }
        try (InputStream input = http.getInputStream()) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream(); byte[] chunk = new byte[4096]; int n;
            while ((n = input.read(chunk)) != -1) {
                if (bytes.size() + n > 262144) throw new IOException("Oversized target list");
                bytes.write(chunk, 0, n);
            }
            JSONArray pages = new JSONArray(bytes.toString("UTF-8"));
            // Only attach to our own explicitly launched app window. Don't pick
            // an arbitrary restored account tab from the profile.
            search: for (int pass = 0; pass < 2; pass++) for (int i = 0; i < pages.length(); i++) {
                JSONObject page = pages.getJSONObject(i);
                boolean matches = pass == 0 ? !ownedId.isEmpty() && ownedId.equals(page.optString("id"))
                        : "http://127.0.0.1:6082/lab.html?nightfall-compat=1".equals(page.optString("url"));
                if ("page".equals(page.optString("type")) && matches) {
                    endpoint = page.getString("webSocketDebuggerUrl");
                    try (FileOutputStream saved = new FileOutputStream(identity)) {
                        saved.write(page.getString("id").getBytes(StandardCharsets.US_ASCII));
                    }
                    break search;
                }
            }
        } finally { http.disconnect(); }
        if (endpoint == null) throw new IOException("Owned browser page not found");
        URI uri = new URI(endpoint);
        if (!"ws".equals(uri.getScheme()) || !"127.0.0.1".equals(uri.getHost()) || uri.getPort() != 9222)
            throw new IOException("Unexpected control endpoint");
        Socket transport = new Socket(); socket = transport;
        transport.connect(new InetSocketAddress("127.0.0.1", 9222), 2000);
        transport.setSoTimeout(2000); transport.setTcpNoDelay(true);
        in = new DataInputStream(transport.getInputStream()); out = transport.getOutputStream();
        byte[] nonce = new byte[16]; random.nextBytes(nonce);
        String key = android.util.Base64.encodeToString(nonce, android.util.Base64.NO_WRAP);
        out.write(("GET " + uri.getRawPath() + " HTTP/1.1\r\nHost: 127.0.0.1:9222\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n").getBytes(StandardCharsets.US_ASCII)); out.flush();
        ByteArrayOutputStream headers = new ByteArrayOutputStream();
        while (headers.size() < 16384) {
            headers.write(in.readUnsignedByte());
            byte[] b = headers.toByteArray(); int len = b.length;
            if (len >= 4 && b[len-4] == 13 && b[len-3] == 10 && b[len-2] == 13 && b[len-1] == 10) break;
        }
        String response = headers.toString("US-ASCII");
        String accept = android.util.Base64.encodeToString(MessageDigest.getInstance("SHA-1")
                .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").getBytes(StandardCharsets.US_ASCII)), android.util.Base64.NO_WRAP);
        boolean validAccept = false;
        for (String line : response.split("\r\n"))
            if (line.toLowerCase(java.util.Locale.ROOT).startsWith("sec-websocket-accept:"))
                validAccept = accept.equals(line.substring(line.indexOf(':')+1).trim());
        if (!response.startsWith("HTTP/1.1 101 ") || !validAccept) throw new IOException("Control handshake rejected");
    }
    private void send(int opcode, byte[] data) throws IOException {
        out.write(0x80 | opcode);
        int size = data.length;
        if (size < 126) out.write(0x80 | size);
        else if (size <= 65535) { out.write(0xfe); out.write(size >> 8); out.write(size); }
        else throw new IOException("Oversized command");
        byte[] mask = new byte[4]; random.nextBytes(mask); out.write(mask);
        byte[] encoded = data.clone(); for (int i = 0; i < encoded.length; i++) encoded[i] ^= mask[i % 4];
        out.write(encoded); out.flush();
    }
    private JSONObject receive() throws Exception {
        ByteArrayOutputStream message = new ByteArrayOutputStream();
        while (true) {
            int first = in.readUnsignedByte(), second = in.readUnsignedByte(), opcode = first & 15;
            long size = second & 127;
            if (size == 126) size = in.readUnsignedShort(); else if (size == 127) size = in.readLong();
            if (size < 0 || size > 1048576 || message.size() + size > 1048576 || (second & 128) != 0)
                throw new IOException("Invalid control frame");
            byte[] data = new byte[(int)size]; in.readFully(data);
            if (opcode == 8) throw new EOFException("Control closed");
            if (opcode == 9) { send(10, data); continue; }
            if (opcode == 10) continue;
            if (opcode != 0 && opcode != 1) throw new IOException("Unexpected control frame");
            message.write(data);
            if ((first & 128) != 0) return new JSONObject(message.toString("UTF-8"));
        }
    }
    private JSONObject call(String method, JSONObject params) throws Exception {
        operation = method;
        int id = ++sequence;
        send(1, new JSONObject().put("id", id).put("method", method).put("params", params).toString().getBytes(StandardCharsets.UTF_8));
        long until = android.os.SystemClock.uptimeMillis() + 3000;
        while (android.os.SystemClock.uptimeMillis() < until) {
            JSONObject response = receive();
            if (response.optInt("id", -1) != id) continue;
            if (response.has("error")) throw new IOException("Browser command rejected: " + method);
            return response.getJSONObject("result");
        }
        throw new IOException("Control reply timeout");
    }
    private void updateState() throws Exception {
        // LayoutViewport excludes scrollbars, whereas pointer coordinates refer
        // to the full inner window. Read only these two numeric dimensions.
        JSONObject viewport = call("Runtime.evaluate", new JSONObject()
                .put("expression", "({width:window.innerWidth,height:window.innerHeight})")
                .put("returnByValue", true)).getJSONObject("result").getJSONObject("value");
        width = viewport.getInt("width"); height = viewport.getInt("height");
        updateNavigationState();
    }
    private void updateNavigationState() throws Exception {
        JSONObject history = call("Page.getNavigationHistory", new JSONObject());
        int index = history.getInt("currentIndex"); JSONArray entries = history.getJSONArray("entries");
        JSONObject current = index >= 0 && index < entries.length() ? entries.getJSONObject(index) : new JSONObject();
        snapshot = new JSONObject().put("ready", true).put("url", current.optString("url"))
                .put("title", current.optString("title", "Compatibility"))
                .put("back", index > 0).put("forward", index + 1 < entries.length()).toString();
        status("ready");
    }
    private void touch(String type, float nx, float ny) throws Exception {
        JSONArray points = new JSONArray();
        if (!"touchEnd".equals(type) && !"touchCancel".equals(type))
            points.put(new JSONObject().put("x", Math.max(0, Math.min(width-1, nx*width)))
                    .put("y", Math.max(0, Math.min(height-1, ny*height)))
                    .put("id", 1).put("radiusX", 1).put("radiusY", 1).put("force", 1));
        call("Input.dispatchTouchEvent", new JSONObject().put("type", type).put("touchPoints", points)); touches++;
    }
    void pointer(float x, float y, int action) {
        if (closed || !Float.isFinite(x) || !Float.isFinite(y)) return;
        final int gesture;
        synchronized (this) { if (action == MotionEvent.ACTION_DOWN) inputGesture++; gesture = inputGesture; }
        if (action == MotionEvent.ACTION_MOVE || action == MotionEvent.ACTION_HOVER_MOVE) {
            synchronized (this) { moveX = x; moveY = y; moveAction = action; pendingGesture = gesture; if (movePending) return; movePending = true; }
            handler.post(move); return;
        }
        handler.post(() -> perform(() -> {
            if (action == MotionEvent.ACTION_DOWN) {
                if (touching) touch("touchCancel", 0, 0);
                mouseHover(x, y); // Desktop menus may require mouseover before a tap.
                touch("touchStart", x, y); touching = true; activeGesture = gesture;
                dragScrolling = false; startX = x; startY = lastY = y;
            } else if (touching && activeGesture == gesture) {
                if (!dragScrolling) {
                    if (action == MotionEvent.ACTION_UP) { touch("touchMove", x, y); touch("touchEnd", 0, 0); }
                    else touch("touchCancel", 0, 0);
                }
                touching = false;
            }
        }));
    }
    private void mouseHover(float x, float y) throws Exception {
        call("Input.dispatchMouseEvent", new JSONObject().put("type", "mouseMoved")
                .put("x", Math.max(0, Math.min(width-1, x*width))).put("y", Math.max(0, Math.min(height-1, y*height))));
        hoverEvents++;
    }
    private void wheel(float x, float y, float distance) throws Exception {
        if (Math.abs(distance) < .5f) return;
        call("Input.dispatchMouseEvent", new JSONObject().put("type", "mouseWheel")
                .put("x", Math.max(0, Math.min(width-1, x*width))).put("y", Math.max(0, Math.min(height-1, y*height)))
                .put("deltaX", 0).put("deltaY", distance)); dragScrollEvents++;
    }
    void scroll(int direction) {
        if (closed) return;
        synchronized (this) { scrollDirection = direction; if (scrollPending) return; scrollPending = true; }
        handler.post(() -> perform(() -> {
            int latest;
            synchronized (this) { scrollPending = false; latest = scrollDirection; }
            if (touching) return;
            call("Input.synthesizeScrollGesture", new JSONObject().put("x", width*.5).put("y", height*.5)
                    .put("yDistance", latest * height*.55).put("speed", 3600)
                    .put("gestureSourceType", "touch").put("preventFling", true)); scrolls++;
        }));
    }
    void release() { handler.post(() -> perform(() -> { if (touching && !dragScrolling) touch("touchCancel", 0, 0); touching = false; })); }
    void navigate(String action, String value) {
        handler.post(() -> perform(() -> {
            releaseTouch();
            if ("go".equals(action) || "home".equals(action)) {
                String url = "home".equals(action) ? "http://127.0.0.1:6082/lab.html?nightfall-compat=1" : value;
                URI uri = new URI(url);
                if (!("http".equals(uri.getScheme()) || "https".equals(uri.getScheme())) || uri.getHost() == null)
                    throw new IllegalArgumentException("HTTP(S) page required");
                call("Page.navigate", new JSONObject().put("url", url));
            } else if ("reload".equals(action)) call("Page.reload", new JSONObject());
            else if ("back".equals(action) || "forward".equals(action)) {
                JSONObject history = call("Page.getNavigationHistory", new JSONObject());
                int index = history.getInt("currentIndex") + ("back".equals(action) ? -1 : 1);
                JSONArray entries = history.getJSONArray("entries");
                if (index >= 0 && index < entries.length())
                    call("Page.navigateToHistoryEntry", new JSONObject().put("entryId", entries.getJSONObject(index).getInt("id")));
            }
            updateState();
        }));
    }
    private void releaseTouch() throws Exception { if (touching && !dragScrolling) touch("touchCancel", 0, 0); touching = false; }
    String snapshot() { return snapshot; }
    private void status(String state) {
        try {
            // Never persist URLs, titles, input contents or DevTools responses.
            JSONObject data = new JSONObject().put("state", state).put("touch_events", touches)
                    .put("scroll_gestures", scrolls).put("drag_scroll_events", dragScrollEvents)
                    .put("hover_events", hoverEvents).put("reconnects", reconnects).put("operation", operation).put("viewport_width", width).put("viewport_height", height);
            File temp = new File(base, "touch-status.tmp");
            try (FileOutputStream output = new FileOutputStream(temp)) { output.write(data.toString(2).getBytes(StandardCharsets.UTF_8)); }
            temp.renameTo(new File(base, "touch-status.json"));
        } catch (Exception ignored) { }
    }
    private void fail(Exception error) {
        if (closed) return;
        if (closing) {
            closed = true;
            try { if (socket != null) socket.close(); } catch (IOException ignored) { }
            handler.removeCallbacksAndMessages(null); worker.quitSafely(); return;
        }
        snapshot = "{\"ready\":false}"; status("error: " + error.getClass().getSimpleName());
        try { if (socket != null) socket.close(); } catch (IOException ignored) { }
        out = null; touching = false; dragScrolling = false;
        synchronized (this) { movePending = false; scrollPending = false; }
        handler.removeCallbacksAndMessages(null);
        reconnects++; handler.postDelayed(this::reconnect, 1000);
    }
    void close() {
        if (closed || closing) return;
        closing = true;
        handler.post(() -> {
            if (closed) return;
            try {
                if (out == null) connect();
                releaseTouch();
                // Close/switch suspends playback too, rather than just hiding it.
                call("Runtime.evaluate", new JSONObject().put("expression",
                        "document.querySelectorAll('video,audio').forEach(media=>media.pause())"));
            } catch (Exception ignored) { /* AudioTrack is stopped independently. */ }
            closed = true; handler.removeCallbacksAndMessages(null);
            try { if (socket != null) socket.close(); } catch (IOException ignored) { }
            worker.quitSafely();
        });
    }
}
