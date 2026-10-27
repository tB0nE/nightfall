package com.godot.game;

import java.util.ArrayList;
import java.util.List;

/** Session-only identities. No URLs or browsing history enter diagnostics. */
final class BrowserPageTabs {
    static final int LIMIT = 8;
    static final class Page {
        final int id;
        String title = "New browser";
        Page(int id) { this.id = id; }
    }
    final List<Page> pages = new ArrayList<>();
    int selected, next = 1;
    Page find(int id) { for (Page page : pages) if (page.id == id) return page; return null; }
    int add() {
        if (pages.size() >= LIMIT) return 0;
        Page page = new Page(next++);
        pages.add(page);
        selected = page.id;
        return page.id;
    }
    boolean select(int id) { if (find(id) == null) return false; selected = id; return true; }
    void remove(int id) {
        Page page = find(id);
        if (page == null) return;
        int index = pages.indexOf(page);
        pages.remove(page);
        if (selected == id) selected = pages.isEmpty() ? 0 : pages.get(Math.min(index, pages.size()-1)).id;
    }
    void clear() { pages.clear(); selected = 0; }
}
