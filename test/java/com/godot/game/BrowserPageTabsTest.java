package com.godot.game;

public final class BrowserPageTabsTest {
    private static void check(boolean value) { if (!value) throw new AssertionError("Page tab lifecycle"); }
    public static void main(String[] args) {
        BrowserPageTabs tabs = new BrowserPageTabs();
        int first = tabs.add(), second = tabs.add();
        check(tabs.selected == second && tabs.pages.size() == 2);
        check(tabs.select(first));
        check(!tabs.select(999) && tabs.selected == first);
        tabs.remove(second);
        check(tabs.selected == first && tabs.pages.size() == 1);
        for (int i = 1; i < BrowserPageTabs.LIMIT; i++) check(tabs.add() != 0);
        int selected = tabs.selected;
        check(tabs.add() == 0 && tabs.selected == selected);
        tabs.remove(selected);
        check(tabs.selected != selected && tabs.find(tabs.selected) != null);
        tabs.clear();
        check(tabs.selected == 0 && tabs.pages.isEmpty());
        check(tabs.add() > second); // Never reuse an identity from this session.
        tabs.remove(tabs.selected);
        check(tabs.selected == 0 && tabs.pages.isEmpty());
        System.out.println("Browser page tab lifecycle tests passed");
    }
}
