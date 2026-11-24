//! The macOS menu-bar item. It draws the shared menu (menu.rs), as tray.rs does on Linux.
//!
//! An `NSStatusItem` whose menu is rebuilt each time it opens (`menuNeedsUpdate:`),
//! so status lines are current without a timer. AppKit needs the main thread:
//! `run` takes it over and never returns; Quit ends the process through
//! Meteor's usual shutdown, which runs on a Tokio worker.

use std::cell::RefCell;

use objc2::rc::Retained;
use objc2::runtime::{NSObject, NSObjectProtocol, ProtocolObject};
use objc2::{MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSControlStateValueOff, NSControlStateValueOn, NSImage, NSMenu, NSMenuDelegate,
    NSMenuItem, NSStatusBar, NSVariableStatusItemLength,
};
use objc2_foundation::{NSString, ns_string};

use crate::menu::{Action, Entry, Sources};

/// What the menu shows and controls.
pub struct Tray {
    pub sources: Sources,
    /// Actions start windows and async work, which need the Tokio context; AppKit's
    /// main thread isn't a Tokio thread.
    pub runtime: tokio::runtime::Handle,
}

thread_local! {
    static TRAY: RefCell<Option<Tray>> = const { RefCell::new(None) };
    /// The actions of the open menu, by item tag.
    static ACTIONS: RefCell<Vec<Action>> = const { RefCell::new(Vec::new()) };
}

fn activate(tray: &Tray, action: Action) {
    let _guard = tray.runtime.enter();
    tray.sources.activate(action);
}

/// Adds `entries` to `menu`, recording each action under its item's tag.
fn fill(menu: &NSMenu, entries: Vec<Entry>, target: &MenuController, actions: &mut Vec<Action>, mtm: MainThreadMarker) {
    for entry in entries {
        match entry {
            Entry::Separator => menu.addItem(&NSMenuItem::separatorItem(mtm)),
            Entry::Label(title) => menu.addItem(&label(&title, mtm)),
            Entry::Item { title, action, enabled, checked } => {
                menu.addItem(&clickable(&title, action, enabled, checked.unwrap_or(false), target, actions, mtm));
            }
            // A submenu of ticked options, then its note.
            Entry::Choice { title, enabled, options, selected, note } => {
                let parent = new_item(&title, None, mtm);
                parent.setEnabled(enabled);
                let submenu = NSMenu::new(mtm);
                submenu.setAutoenablesItems(false);
                add_options(&submenu, options, selected, enabled, target, actions, mtm);
                if let Some(note) = note {
                    submenu.addItem(&NSMenuItem::separatorItem(mtm));
                    submenu.addItem(&label(&note, mtm));
                }
                parent.setSubmenu(Some(&submenu));
                menu.addItem(&parent);
            }
            Entry::Options { enabled, options, selected } => add_options(menu, options, selected, enabled, target, actions, mtm),
            Entry::Submenu { title, entries } => {
                let parent = new_item(&title, None, mtm);
                let submenu = NSMenu::new(mtm);
                submenu.setAutoenablesItems(false);
                fill(&submenu, entries, target, actions, mtm);
                parent.setSubmenu(Some(&submenu));
                menu.addItem(&parent);
            }
        }
    }
}

/// Mutually exclusive options: the selected one is ticked, as in a radio group.
fn add_options(
    menu: &NSMenu,
    options: Vec<(String, Action)>,
    selected: usize,
    enabled: bool,
    target: &MenuController,
    actions: &mut Vec<Action>,
    mtm: MainThreadMarker,
) {
    for (index, (title, action)) in options.into_iter().enumerate() {
        menu.addItem(&clickable(&title, action, enabled, index == selected, target, actions, mtm));
    }
}

fn clickable(
    title: &str,
    action: Action,
    enabled: bool,
    checked: bool,
    target: &MenuController,
    actions: &mut Vec<Action>,
    mtm: MainThreadMarker,
) -> Retained<NSMenuItem> {
    let line = new_item(title, Some(sel!(itemClicked:)), mtm);
    // SAFETY: the target is the controller, which lives for the process's life.
    unsafe { line.setTarget(Some(target)) };
    line.setTag(actions.len() as isize);
    line.setState(if checked { NSControlStateValueOn } else { NSControlStateValueOff });
    line.setEnabled(enabled);
    actions.push(action);
    line
}

/// Greyed-out text.
fn label(title: &str, mtm: MainThreadMarker) -> Retained<NSMenuItem> {
    let line = new_item(title, None, mtm);
    line.setEnabled(false);
    line
}

fn new_item(title: &str, action: Option<objc2::runtime::Sel>, mtm: MainThreadMarker) -> Retained<NSMenuItem> {
    // SAFETY: a plain menu item; the action is only sent to a target that implements it.
    unsafe { NSMenuItem::initWithTitle_action_keyEquivalent(NSMenuItem::alloc(mtm), &NSString::from_str(title), action, ns_string!("")) }
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "NightfallMeteorMenuController"]
    struct MenuController;

    unsafe impl NSObjectProtocol for MenuController {}

    unsafe impl NSMenuDelegate for MenuController {
        #[unsafe(method(menuNeedsUpdate:))]
        fn menu_needs_update(&self, menu: &NSMenu) {
            let mtm = self.mtm();
            menu.removeAllItems();
            let entries = TRAY.with_borrow(|tray| tray.as_ref().map(|tray| tray.sources.entries()).unwrap_or_default());
            let mut actions = Vec::new();
            fill(menu, entries, self, &mut actions, mtm);
            ACTIONS.set(actions);
        }
    }

    impl MenuController {
        #[unsafe(method(itemClicked:))]
        fn item_clicked(&self, item: &NSMenuItem) {
            let action = ACTIONS.with_borrow(|actions| usize::try_from(item.tag()).ok().and_then(|i| actions.get(i).cloned()));
            if let Some(action) = action {
                TRAY.with_borrow(|tray| {
                    if let Some(tray) = tray {
                        activate(tray, action);
                    }
                });
            }
        }
    }
);

impl MenuController {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        // SAFETY: NSObject's init.
        unsafe { msg_send![Self::alloc(mtm), init] }
    }
}

/// Shows the menu-bar item and runs AppKit on this thread (the main thread). Never returns.
pub fn run(tray: Tray) {
    let Some(mtm) = MainThreadMarker::new() else {
        log::error!("The menu bar needs the main thread; running without it");
        loop {
            std::thread::park();
        }
    };
    TRAY.set(Some(tray));
    let app = NSApplication::sharedApplication(mtm);
    // A menu-bar app: no Dock icon or app menu, even when run outside Meteor.app.
    app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);

    let controller = MenuController::new(mtm);
    let menu = NSMenu::new(mtm);
    menu.setAutoenablesItems(false);
    menu.setDelegate(Some(ProtocolObject::from_ref(&*controller)));

    let status_item = NSStatusBar::systemStatusBar().statusItemWithLength(NSVariableStatusItemLength);
    if let Some(button) = status_item.button(mtm) {
        let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(ns_string!("moon.stars.fill"), Some(ns_string!("Nightfall Meteor")));
        match image {
            Some(image) => {
                // Template images follow the menu bar's light/dark appearance.
                image.setTemplate(true);
                button.setImage(Some(&image));
            }
            None => button.setTitle(ns_string!("Meteor")),
        }
        let name = TRAY.with_borrow(|tray| tray.as_ref().map(|tray| tray.sources.name()).unwrap_or_default());
        button.setToolTip(Some(&NSString::from_str(&name)));
    }
    status_item.setMenu(Some(&menu));
    log::info!("Menu bar item ready");
    app.run();
    // Not reached: Quit ends the process. Keep the item alive regardless.
    drop((status_item, menu, controller));
}
