//! The system tray icon (StatusNotifierItem, so KDE and GNOME with the
//! AppIndicator extension both show it). It draws the shared menu (menu.rs).

use std::time::Duration;

use ksni::TrayMethods;

use crate::menu::{Action, Entry, Sources};

pub struct MeteorTray(pub Sources);

impl ksni::Tray for MeteorTray {
    fn id(&self) -> String {
        "nightfall-meteor".into()
    }

    fn title(&self) -> String {
        self.0.name()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        static ICONS: std::sync::OnceLock<Vec<ksni::Icon>> = std::sync::OnceLock::new();
        ICONS.get_or_init(|| crate::icon::SIZES.iter().map(|&s| crate::icon::nightfall_icon(s)).collect()).clone()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: self.0.name(), description: self.0.summary(), ..Default::default() }
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        self.0.entries().into_iter().map(draw).collect()
    }
}

fn act(action: Action) -> Box<dyn Fn(&mut MeteorTray) + Send + 'static> {
    Box::new(move |tray: &mut MeteorTray| tray.0.activate(action.clone()))
}

fn draw(entry: Entry) -> ksni::MenuItem<MeteorTray> {
    use ksni::menu::*;
    match entry {
        Entry::Label(label) => StandardItem { label, enabled: false, ..Default::default() }.into(),
        Entry::Separator => MenuItem::Separator,
        Entry::Item { title, action, enabled, checked: None } => {
            let icon_name = match action {
                Action::Setup => "preferences-system",
                Action::Quit => "application-exit",
                Action::AllowFirewall => "security-medium",
                _ => "",
            };
            StandardItem { label: title, enabled, icon_name: icon_name.into(), activate: act(action), ..Default::default() }.into()
        }
        Entry::Item { title, action, enabled, checked: Some(checked) } => {
            CheckmarkItem { label: title, enabled, checked, activate: act(action), ..Default::default() }.into()
        }
        Entry::Choice { title, enabled, options, selected, note } => {
            let mut submenu = vec![radio(true, options, selected)];
            if let Some(note) = note {
                submenu.push(StandardItem { label: note, enabled: false, ..Default::default() }.into());
            }
            SubMenu { label: title, enabled, submenu, ..Default::default() }.into()
        }
        Entry::Options { enabled, options, selected } => radio(enabled, options, selected),
        Entry::Submenu { title, entries } => SubMenu { label: title, submenu: entries.into_iter().map(draw).collect(), ..Default::default() }.into(),
    }
}

fn radio(enabled: bool, options: Vec<(String, Action)>, selected: usize) -> ksni::MenuItem<MeteorTray> {
    use ksni::menu::*;
    let actions: Vec<Action> = options.iter().map(|(_, action)| action.clone()).collect();
    RadioGroup {
        selected,
        select: Box::new(move |tray: &mut MeteorTray, index| {
            if let Some(action) = actions.get(index) {
                tray.0.activate(action.clone());
            }
        }),
        options: options.into_iter().map(|(label, _)| RadioItem { label, enabled, ..Default::default() }).collect(),
    }
    .into()
}

/// Shows the tray icon and refreshes it every second. Returns false when no
/// tray host is running (e.g. a headless session), so Meteor keeps running
/// without an icon.
pub async fn run(tray: MeteorTray) -> bool {
    let handle = match tray.spawn().await {
        Ok(handle) => handle,
        Err(err) => {
            log::warn!("No system tray available ({err}); running without an icon");
            return false;
        }
    };
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            if handle.update(|_| {}).await.is_none() {
                break;
            }
        }
    });
    true
}
