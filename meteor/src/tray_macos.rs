//! The macOS menu-bar item: Meteor's status and controls, as in the Windows tray.
//!
//! An `NSStatusItem` whose menu is rebuilt each time it opens (`menuNeedsUpdate:`),
//! so status lines are current without a timer. AppKit needs the main thread:
//! `run` takes it over and never returns; Quit ends the process through
//! Meteor's usual shutdown, which runs on a Tokio worker.

use std::cell::RefCell;
use std::sync::Arc;
use std::sync::atomic::Ordering;

use objc2::rc::Retained;
use objc2::runtime::{NSObject, NSObjectProtocol, ProtocolObject};
use objc2::{MainThreadMarker, MainThreadOnly, define_class, msg_send, sel};
use objc2_app_kit::{
    NSApplication, NSApplicationActivationPolicy, NSControlStateValueOff, NSControlStateValueOn, NSImage, NSMenu, NSMenuDelegate,
    NSMenuItem, NSStatusBar, NSVariableStatusItemLength,
};
use objc2_foundation::{NSString, ns_string};

/// What the menu shows and controls.
pub struct Tray {
    pub status: Arc<crate::status::Status>,
    pub stats: Arc<crate::proxy::Stats>,
    pub depth: Option<Arc<crate::depth::Depth>>,
    pub mic: Option<Arc<crate::mic::Mic>>,
    pub host: Arc<crate::host::view::View>,
    /// For actions that spawn async work (pairing approval).
    pub runtime: tokio::runtime::Handle,
}

#[derive(Clone)]
enum Action {
    OpenLog,
    OpenSettings,
    OpenModels,
    Quit,
    Autostart,
    MuteMic,
    PairApprove(String),
    PairReject(String),
    HostBundled,
    HostExternal,
    HostToggle,
    HostWeb,
    HostFolder,
    DepthEnabled,
    Rate(u32),
    Choice(crate::depth::DepthChoice),
    Smoothing,
    EdgeAlignment,
    ContourCleanup,
    Softening(usize),
    Setup,
}

/// One line of the menu.
enum Entry {
    Label(String),
    Item { title: String, action: Action, checked: bool, enabled: bool },
    Submenu { title: String, entries: Vec<Entry> },
    Separator,
}

fn item(title: impl Into<String>, action: Action) -> Entry {
    Entry::Item { title: title.into(), action, checked: false, enabled: true }
}

fn check(title: impl Into<String>, action: Action, checked: bool) -> Entry {
    Entry::Item { title: title.into(), action, checked, enabled: true }
}

thread_local! {
    static TRAY: RefCell<Option<Tray>> = const { RefCell::new(None) };
    /// The actions of the open menu, by item tag.
    static ACTIONS: RefCell<Vec<Action>> = const { RefCell::new(Vec::new()) };
}

impl Tray {
    fn entries(&self) -> Vec<Entry> {
        let mut out = vec![Entry::Label(format!("Nightfall Meteor {}", env!("CARGO_PKG_VERSION")))];
        out.extend(permission_entries());
        let udp = self.stats.udp_flows.load(Ordering::Relaxed);
        let tcp = self.stats.tcp_connections.load(Ordering::Relaxed);
        out.push(Entry::Label(if udp > 0 {
            format!("Streaming ({udp} UDP flows, {tcp} TCP)")
        } else if tcp > 0 {
            format!("Client connected ({tcp} TCP)")
        } else {
            "Waiting for a client".into()
        }));
        if let Some(pending) = self.host.pairing.as_ref().and_then(|p| p.pending()) {
            out.push(Entry::Separator);
            out.push(Entry::Label(format!("Pair Nightfall headset — PIN {}", pending.pin)));
            out.push(item("Approve pairing", Action::PairApprove(pending.id.clone())));
            out.push(item("Reject pairing", Action::PairReject(pending.id)));
        }
        out.push(Entry::Separator);
        out.push(Entry::Submenu { title: "Game streaming host".into(), entries: self.host_entries() });
        if let Some(depth) = &self.depth {
            out.push(Entry::Separator);
            out.extend(depth_entries(depth));
        }
        out.push(Entry::Separator);
        match &self.mic {
            Some(mic) => {
                out.push(Entry::Label(format!("Microphone: {} (BlackHole)", mic.status())));
                out.push(check("Mute microphone", Action::MuteMic, mic.muted.load(Ordering::Relaxed)));
            }
            None => {
                out.push(Entry::Label("Microphone: needs BlackHole".into()));
                out.push(item("Install in Setup…", Action::Setup));
            }
        }
        out.push(Entry::Separator);
        out.push(item("Setup…", Action::Setup));
        out.push(check("Start at login", Action::Autostart, crate::desktop::autostart_enabled()));
        out.push(item("Open log", Action::OpenLog));
        out.push(item("Open settings", Action::OpenSettings));
        out.push(item("Open models folder", Action::OpenModels));
        out.push(Entry::Separator);
        out.push(item("Quit Nightfall Meteor", Action::Quit));
        out
    }

    fn host_entries(&self) -> Vec<Entry> {
        use crate::host::{Choice, Phase};
        let host = &self.host;
        let label = match (&host.supervisor, host.state.choice) {
            (Some(supervisor), _) => match supervisor.phase() {
                Phase::Running => format!("Meteor-Vibepollo running on {}", supervisor.instance.base),
                Phase::WaitingForPort => format!("Waiting for host port {}", supervisor.instance.base),
                Phase::Restarting { failures } => format!("Host restarting ({failures})"),
                Phase::Stopped => "Meteor-Vibepollo stopped".into(),
                Phase::Failed(error) => format!("Host failed: {error}"),
            },
            (None, Choice::Bundled) => format!("Host unavailable: {}", host.error.as_deref().unwrap_or("unknown error")),
            (None, Choice::External) => format!(
                "Using your own host on {} ({})",
                self.status.map.sunshine_base,
                if self.status.sunshine_up.load(Ordering::Relaxed) { "running" } else { "not answering" }
            ),
        };
        let mut out = vec![Entry::Label(label), Entry::Separator];
        out.push(Entry::Item {
            title: "Use Meteor-Vibepollo".into(),
            action: Action::HostBundled,
            checked: host.state.choice == Choice::Bundled,
            enabled: host.binary.is_some(),
        });
        out.push(check("Use my own host", Action::HostExternal, host.state.choice == Choice::External));
        if let Some(supervisor) = &host.supervisor {
            out.push(Entry::Separator);
            out.push(item(if supervisor.wanted() { "Stop host" } else { "Start host" }, Action::HostToggle));
            out.push(item("Open host web page", Action::HostWeb));
            out.push(item("Open host folder", Action::HostFolder));
        }
        out
    }
}

/// What's missing for streaming, first in the menu, pointing to Setup.
fn permission_entries() -> Vec<Entry> {
    use crate::desktop::permissions;
    let mut missing = Vec::new();
    if !permissions::screen_recording() {
        missing.push("Screen Recording");
    }
    if !permissions::accessibility() {
        missing.push("Accessibility");
    }
    if missing.is_empty() {
        return Vec::new();
    }
    vec![
        Entry::Separator,
        Entry::Label(format!("⚠️ Needs {}", missing.join(" and "))),
        item("Open Setup…", Action::Setup),
    ]
}

fn depth_entries(depth: &crate::depth::Depth) -> Vec<Entry> {
    let mut out = vec![Entry::Label(format!(
        "Host depth: {}",
        if depth.available() { depth.status() } else { "loading".into() }
    ))];
    out.push(check("Host depth enabled", Action::DepthEnabled, depth.enabled()));
    let rates = crate::depth::RATES
        .iter()
        .map(|&hz| check(if hz == 0 { "Match stream".to_string() } else { format!("{hz} Hz") }, Action::Rate(hz), depth.rate() == hz))
        .collect();
    out.push(Entry::Submenu { title: "Depth rate".into(), entries: rates });
    let groups = depth
        .choice_groups()
        .into_iter()
        .map(|group| Entry::Submenu {
            title: group.label,
            entries: group
                .choices
                .into_iter()
                .map(|choice| {
                    let selected = depth.choice_selected(&choice);
                    check(crate::depth::model_label(&choice.model), Action::Choice(choice), selected)
                })
                .collect(),
        })
        .collect();
    out.push(Entry::Submenu { title: format!("GPU / model: {}", depth.selection_label()), entries: groups });
    out.push(check("Depth smoothing", Action::Smoothing, depth.smoothing()));
    out.push(check("Edge alignment (experimental)", Action::EdgeAlignment, depth.edge_alignment()));
    out.push(Entry::Item {
        title: "Contour cleanup (requires alignment)".into(),
        action: Action::ContourCleanup,
        checked: depth.contour_cleanup(),
        enabled: depth.edge_alignment(),
    });
    let softening = crate::vda::SOFTENING
        .iter()
        .enumerate()
        .map(|(i, (label, _))| check(*label, Action::Softening(i), depth.edge_softening() == i))
        .collect();
    out.push(Entry::Submenu { title: "Edge softening (VDA)".into(), entries: softening });
    let s = &depth.stats;
    out.push(Entry::Label(format!(
        "Depth {:.1} fps | decode {:.1} ms | model {:.1} ms | total {:.1} ms",
        s.rate_x10.load(Ordering::Relaxed) as f32 / 10.0,
        s.decode_us.load(Ordering::Relaxed) as f32 / 1000.0,
        s.infer_us.load(Ordering::Relaxed) as f32 / 1000.0,
        s.total_us.load(Ordering::Relaxed) as f32 / 1000.0
    )));
    out
}

fn open(path: impl AsRef<std::ffi::OsStr>) {
    if let Err(error) = std::process::Command::new("/usr/bin/open").arg(path.as_ref()).spawn() {
        log::warn!("Can't open {}: {error}", path.as_ref().to_string_lossy());
    }
}

fn activate(tray: &Tray, action: Action) {
    let depth = tray.depth.as_deref();
    match action {
        Action::OpenLog => open(crate::logfile::path()),
        Action::OpenSettings => crate::open_config_file(),
        Action::OpenModels => {
            let dir = crate::config::default_models_dir();
            let _ = std::fs::create_dir_all(&dir);
            open(dir);
        }
        Action::Quit => crate::quit(),
        Action::Autostart => {
            let on = !crate::desktop::autostart_enabled();
            if let Err(error) = crate::desktop::set_autostart(on) {
                log::warn!("Can't change Start at login: {error}");
            }
        }
        Action::MuteMic => {
            if let Some(mic) = &tray.mic {
                mic.muted.fetch_xor(true, Ordering::Relaxed);
            }
        }
        Action::PairApprove(id) => {
            if let Some(pairing) = tray.host.pairing.clone() {
                // approve() spawns async work, which needs the Tokio context.
                tray.runtime.spawn(async move { pairing.approve(&id) });
            }
        }
        Action::PairReject(id) => {
            if let Some(pairing) = &tray.host.pairing {
                pairing.reject(&id);
            }
        }
        Action::HostBundled => tray.host.switch(crate::host::Choice::Bundled),
        Action::HostExternal => tray.host.switch(crate::host::Choice::External),
        Action::HostToggle => {
            if let Some(supervisor) = &tray.host.supervisor {
                supervisor.set_wanted(!supervisor.wanted());
            }
        }
        Action::HostWeb => {
            if let Some(supervisor) = &tray.host.supervisor {
                open(format!("https://localhost:{}", supervisor.instance.base + 1));
            }
        }
        Action::HostFolder => {
            if let Some(supervisor) = &tray.host.supervisor {
                open(supervisor.instance.appdata());
            }
        }
        Action::DepthEnabled => depth.into_iter().for_each(|d| d.set_enabled(!d.enabled())),
        Action::Rate(hz) => depth.into_iter().for_each(|d| d.set_rate(hz)),
        Action::Choice(choice) => depth.into_iter().for_each(|d| d.select_choice(&choice)),
        Action::Smoothing => depth.into_iter().for_each(|d| d.set_smoothing(!d.smoothing())),
        Action::EdgeAlignment => depth.into_iter().for_each(|d| d.set_edge_alignment(!d.edge_alignment())),
        Action::ContourCleanup => depth.into_iter().for_each(|d| {
            if d.edge_alignment() {
                d.set_contour_cleanup(!d.contour_cleanup());
            }
        }),
        Action::Softening(level) => depth.into_iter().for_each(|d| d.set_edge_softening(level)),
        // The window is a child process started from the Tokio runtime.
        Action::Setup => {
            let _guard = tray.runtime.enter();
            crate::setup_window::open();
        }
    }
}

/// Adds `entries` to `menu`, recording each action under its item's tag.
fn fill(menu: &NSMenu, entries: Vec<Entry>, target: &MenuController, actions: &mut Vec<Action>, mtm: MainThreadMarker) {
    for entry in entries {
        match entry {
            Entry::Separator => menu.addItem(&NSMenuItem::separatorItem(mtm)),
            Entry::Label(title) => {
                let line = new_item(&title, None, mtm);
                line.setEnabled(false);
                menu.addItem(&line);
            }
            Entry::Item { title, action, checked, enabled } => {
                let line = new_item(&title, Some(sel!(itemClicked:)), mtm);
                // SAFETY: the target is the controller, which lives for the process's life.
                unsafe { line.setTarget(Some(target)) };
                line.setTag(actions.len() as isize);
                line.setState(if checked { NSControlStateValueOn } else { NSControlStateValueOff });
                line.setEnabled(enabled);
                actions.push(action);
                menu.addItem(&line);
            }
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
            let entries = TRAY.with_borrow(|tray| tray.as_ref().map(Tray::entries).unwrap_or_default());
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
        button.setToolTip(Some(ns_string!("Nightfall Meteor")));
    }
    status_item.setMenu(Some(&menu));
    log::info!("Menu bar item ready");
    app.run();
    // Not reached: Quit ends the process. Keep the item alive regardless.
    drop((status_item, menu, controller));
}
