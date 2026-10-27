package com.godot.game;

import java.io.*;
import java.util.*;

/** App-private bookmark data; no cookies, host settings or navigation logging. */
final class BrowserBookmarks {
    static final int LIMIT = 100;
    static final class Entry {
        final String title, url;
        Entry(String title, String url) { this.title = title; this.url = url; }
    }
    private final ArrayList<Entry> entries = new ArrayList<>();
    List<Entry> entries() { return Collections.unmodifiableList(new ArrayList<>(entries)); }

    void save(String oldUrl, String title, String url) {
        title = title == null ? "" : title.trim();
        url = url == null ? "" : url.trim();
        if (title.isEmpty() || title.length() > 120 || url.length() > 4096
                || !BrowserNavigation.allowed(url) || BrowserNavigation.HOME_URL.equals(url))
            throw new IllegalArgumentException("Use a name (up to 120 characters) and a valid HTTP(S) address.");
        int old = index(oldUrl), duplicate = index(url);
        if (duplicate >= 0 && old >= 0 && duplicate != old)
            throw new IllegalArgumentException("That address is already bookmarked.");
        int target = old >= 0 ? old : duplicate;
        if (target >= 0) entries.set(target, new Entry(title, url));
        else {
            if (entries.size() >= LIMIT) throw new IllegalArgumentException("Bookmark limit reached (100).");
            entries.add(new Entry(title, url));
        }
    }
    private int index(String url) {
        for (int i = 0; i < entries.size(); i++) if (entries.get(i).url.equals(url)) return i;
        return -1;
    }
    void remove(String url) { int i = index(url); if (i >= 0) entries.remove(i); }
    void move(String url, int delta) {
        int i = index(url), target = i + delta;
        if (i >= 0 && target >= 0 && target < entries.size()) Collections.swap(entries, i, target);
    }
    String encode() {
        try {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            DataOutputStream out = new DataOutputStream(bytes);
            out.writeInt(1); // Versioned, bounded format stored as one preference.
            out.writeInt(entries.size());
            for (Entry e : entries) { out.writeUTF(e.title); out.writeUTF(e.url); }
            out.flush();
            return Base64.getEncoder().encodeToString(bytes.toByteArray());
        } catch (IOException impossible) { throw new IllegalStateException(impossible); }
    }
    static BrowserBookmarks decode(String value) {
        BrowserBookmarks result = new BrowserBookmarks();
        if (value == null || value.isEmpty()) return result;
        if (value.length() > 1024 * 1024) throw new IllegalArgumentException("Invalid bookmark data");
        try {
            DataInputStream in = new DataInputStream(new ByteArrayInputStream(Base64.getDecoder().decode(value)));
            if (in.readInt() != 1) throw new IOException();
            int count = in.readInt();
            if (count < 0 || count > LIMIT) throw new IOException();
            for (int i = 0; i < count; i++) {
                String title = in.readUTF(), url = in.readUTF();
                if (result.index(url) >= 0) throw new IOException();
                result.save(null, title, url);
            }
            if (in.available() != 0) throw new IOException();
            return result;
        } catch (IOException | IllegalArgumentException failure) {
            throw new IllegalArgumentException("Saved bookmarks could not be read.");
        }
    }
    static String escape(String value) {
        return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
                .replace("\"", "&quot;").replace("'", "&#39;");
    }
    String homeLinks() {
        StringBuilder html = new StringBuilder();
        for (Entry e : entries) html.append("<a href=\"").append(escape(e.url)).append("\">")
                .append(escape(e.title)).append("</a>");
        return html.toString();
    }
}
