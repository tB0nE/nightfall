package com.godot.game;

import java.io.*;
import java.net.URI;
import java.util.*;

/** Optional app-private visit list. Never a source of diagnostics or credentials. */
final class BrowserHistory {
    static final int LIMIT = 200;
    static final class Entry {
        final String title, url;
        final long time;
        Entry(String title, String url, long time) { this.title = title; this.url = url; this.time = time; }
    }
    private final ArrayList<Entry> entries = new ArrayList<>();
    List<Entry> entries() { return Collections.unmodifiableList(new ArrayList<>(entries)); }
    static String address(String url) {
        if (!BrowserNavigation.allowed(url) || BrowserNavigation.HOME_URL.equals(url)) return null;
        URI uri = URI.create(url);
        String path = uri.getRawPath();
        String value = uri.getScheme().toLowerCase(Locale.ROOT) + "://" + uri.getRawAuthority()
                + (path == null || path.isEmpty() ? "/" : path);
        return value.length() <= 2048 && !BrowserNavigation.HOME_URL.equals(value) ? value : null;
    }
    void visit(String title, String url, long time) {
        String safe = address(url);
        if (safe == null || time < 0) return;
        String label = title == null || title.trim().isEmpty() ? safe : title.trim();
        if (label.length() > 160) label = label.substring(0, 160);
        entries.removeIf(entry -> entry.url.equals(safe));
        entries.add(0, new Entry(label, safe, time));
        while (entries.size() > LIMIT) entries.remove(entries.size() - 1);
    }
    void clear() { entries.clear(); }
    String encode() {
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream out = new DataOutputStream(bytes);
            out.writeInt(1); out.writeInt(entries.size());
            for (Entry e : entries) { out.writeUTF(e.title); out.writeUTF(e.url); out.writeLong(e.time); }
            out.flush();
            return Base64.getEncoder().encodeToString(bytes.toByteArray());
        } catch (IOException impossible) { throw new IllegalStateException(impossible); }
    }
    static BrowserHistory decode(String value) {
        BrowserHistory history = new BrowserHistory();
        if (value == null || value.isEmpty()) return history;
        if (value.length() > 1024 * 1024) throw new IllegalArgumentException("Invalid history data");
        try {
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(Base64.getDecoder().decode(value)));
            if (in.readInt() != 1) throw new IOException();
            int count = in.readInt();
            if (count < 0 || count > LIMIT) throw new IOException();
            for (int i = 0; i < count; i++) {
                String title = in.readUTF(), url = in.readUTF();
                long time = in.readLong();
                if (title.length() > 160 || !url.equals(address(url)) || time < 0
                        || history.entries.stream().anyMatch(e -> e.url.equals(url))) throw new IOException();
                history.entries.add(new Entry(title, url, time));
            }
            if (in.available() != 0) throw new IOException();
            return history;
        } catch (IOException | IllegalArgumentException invalid) {
            throw new IllegalArgumentException("Saved history could not be read.");
        }
    }
}
