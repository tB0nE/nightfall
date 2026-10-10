//! The system tray icon (StatusNotifierItem, so KDE and GNOME with the
//! AppIndicator extension both show it).

use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use ksni::TrayMethods;

use crate::depth::{Depth, RATES};
use crate::mic::Mic;
use crate::proxy::Stats;
use crate::status::Status;

pub struct MeteorTray {
    pub status: Arc<Status>,
    pub stats: Arc<Stats>,
    pub depth: Option<Arc<Depth>>,
    pub mic: Option<Arc<Mic>>,
}

impl ksni::Tray for MeteorTray {
    fn id(&self) -> String {
        "nightfall-meteor".into()
    }

    fn title(&self) -> String {
        "Nightfall Meteor".into()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        static ICONS: std::sync::OnceLock<Vec<ksni::Icon>> = std::sync::OnceLock::new();
        ICONS.get_or_init(|| crate::icon::SIZES.iter().map(|&s| crate::icon::nightfall_icon(s)).collect()).clone()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "Nightfall Meteor".into(),
            description: self.summary(),
            ..Default::default()
        }
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::*;
        let info = |label: String| -> ksni::MenuItem<Self> {
            StandardItem { label, enabled: false, ..Default::default() }.into()
        };
        let mb = |bytes: u64| bytes as f64 / 1_000_000.0;
        vec![
            info(format!("Nightfall Meteor {}", env!("CARGO_PKG_VERSION"))),
            MenuItem::Separator,
            info(self.summary()),
            info(format!(
                "Sunshine {}:{} - {}",
                self.status.sunshine_host,
                self.status.map.sunshine_base,
                if self.status.sunshine_up.load(Ordering::Relaxed) { "running" } else { "not running" }
            )),
            info(format!(
                "Proxy ports from {} (Sunshine + {}), discovery {}",
                self.status.map.meteor(crate::ports::PortMap::channel("http")),
                self.status.map.offset,
                self.status.discovery_port
            )),
            info(format!(
                "Traffic: {:.1} MB to client, {:.1} MB to Sunshine",
                mb(self.stats.bytes_to_client.load(Ordering::Relaxed)),
                mb(self.stats.bytes_to_sunshine.load(Ordering::Relaxed))
            )),
        ]
        .into_iter()
        .chain(self.firewall_menu())
        .chain([MenuItem::Separator])
        .chain(self.depth_menu())
        .chain([MenuItem::Separator])
        .chain(self.mic_menu())
        .chain([
            MenuItem::Separator,
            CheckmarkItem {
                label: "Start with my computer".into(),
                checked: crate::desktop::autostart_enabled(),
                activate: Box::new(|_| {
                    let on = !crate::desktop::autostart_enabled();
                    match crate::desktop::set_autostart(on) {
                        Ok(()) => log::info!("Autostart {}", if on { "on" } else { "off" }),
                        Err(err) => log::warn!("Can't change autostart: {err}"),
                    }
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Open log".into(),
                activate: Box::new(|_| open_url(&crate::logfile::path().to_string_lossy())),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Open settings file".into(),
                activate: Box::new(|_| crate::open_config_file()),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Quit".into(),
                icon_name: "application-exit".into(),
                activate: Box::new(|_| crate::quit()),
                ..Default::default()
            }
            .into(),
        ])
        .collect()
    }
}

impl MeteorTray {
    /// Host depth: on/off, Model and Rate submenus, and a live readout.
    fn depth_menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::*;
        let info = |label: String| -> ksni::MenuItem<Self> {
            StandardItem { label, enabled: false, ..Default::default() }.into()
        };
        let Some(depth) = &self.depth else { return vec![info("Host depth: off (--no-depth)".into())] };
        if !depth.available() {
            return vec![info(format!("Host depth: {}", depth.status()))];
        }
        let s = &depth.stats;
        let ms = |us: &std::sync::atomic::AtomicU32| f64::from(us.load(Ordering::Relaxed)) / 1000.0;
        let rate_x10 = s.rate_x10.load(Ordering::Relaxed);
        let readout = if !depth.enabled() {
            "Host depth is off".to_string()
        } else if rate_x10 == 0 {
            format!("Depth idle - {}", depth.status())
        } else {
            format!(
                "Depth {:.1} fps - decode {:.1} ms, model {:.1} ms, frame to map {:.1} ms",
                f64::from(rate_x10) / 10.0,
                ms(&s.decode_us),
                ms(&s.infer_us),
                ms(&s.total_us)
            )
        };

        let models = depth.list_models();
        let current = depth.model();
        let model_names = models.clone();
        let mut model_items: Vec<ksni::MenuItem<Self>> = vec![
                RadioGroup {
                    selected: current.as_ref().and_then(|c| models.iter().position(|m| m == c)).unwrap_or(0),
                    select: Box::new(move |tray: &mut Self, i| {
                        if let (Some(depth), Some(name)) = (&tray.depth, model_names.get(i)) {
                            depth.select_model(name);
                        }
                    }),
                    options: models
                        .iter()
                        .map(|m| RadioItem { label: crate::depth::model_label(m), ..Default::default() })
                        .collect(),
                }
                .into(),
        ];
        model_items.extend(self.vda_download_items(depth));
        let model_menu = SubMenu {
            label: format!("Model: {}", current.as_deref().map_or_else(|| "none".to_string(), crate::depth::model_label)),
            submenu: model_items,
            ..Default::default()
        };
        let rate_label = |hz: u32| if hz == 0 { "Match stream".to_string() } else { format!("{hz} Hz") };
        let rate_menu = SubMenu {
            label: format!("Rate: {}", rate_label(depth.rate())),
            submenu: vec![
                RadioGroup {
                    selected: RATES.iter().position(|&r| r == depth.rate()).unwrap_or(0),
                    select: Box::new(|tray: &mut Self, i| {
                        if let (Some(depth), Some(&hz)) = (&tray.depth, RATES.get(i)) {
                            depth.set_rate(hz);
                        }
                    }),
                    options: RATES.iter().map(|&hz| RadioItem { label: rate_label(hz), ..Default::default() }).collect(),
                }
                .into(),
            ],
            ..Default::default()
        };
        let softening_menu = SubMenu {
            label: format!("Edge softening (VDA): {}", crate::vda::SOFTENING[depth.edge_softening()].0),
            submenu: vec![
                RadioGroup {
                    selected: depth.edge_softening(),
                    select: Box::new(|tray: &mut Self, i| {
                        if let Some(depth) = &tray.depth {
                            depth.set_edge_softening(i);
                        }
                    }),
                    options: crate::vda::SOFTENING
                        .iter()
                        .map(|(label, _)| RadioItem { label: (*label).into(), ..Default::default() })
                        .collect(),
                }
                .into(),
            ],
            ..Default::default()
        };
        vec![
            CheckmarkItem {
                label: "Host depth".into(),
                checked: depth.enabled(),
                activate: Box::new(|tray: &mut Self| {
                    if let Some(depth) = &tray.depth {
                        depth.set_enabled(!depth.enabled());
                    }
                }),
                ..Default::default()
            }
            .into(),
            model_menu.into(),
            rate_menu.into(),
            CheckmarkItem {
                label: "Depth smoothing".into(),
                checked: depth.smoothing(),
                activate: Box::new(|tray: &mut Self| {
                    if let Some(depth) = &tray.depth {
                        depth.set_smoothing(!depth.smoothing());
                    }
                }),
                ..Default::default()
            }
            .into(),
            softening_menu.into(),
            info(readout),
        ]
        .into_iter()
        .chain(download_progress(depth).map(info))
        .collect()
    }

    /// The VDA download's items at the end of the Model menu: an offer
    /// (with NVIDIA's licence), progress and Cancel, or Remove.
    fn vda_download_items(&self, depth: &Arc<Depth>) -> Vec<ksni::MenuItem<Self>> {
        use crate::download::State;
        use ksni::menu::*;
        let info = |label: String| -> ksni::MenuItem<Self> {
            StandardItem { label, enabled: false, ..Default::default() }.into()
        };
        let action = |label: &str, f: fn(&Arc<Depth>)| -> ksni::MenuItem<Self> {
            StandardItem {
                label: label.into(),
                activate: Box::new(move |tray: &mut Self| {
                    if let Some(depth) = &tray.depth {
                        f(depth);
                    }
                }),
                ..Default::default()
            }
            .into()
        };
        let mut items = vec![MenuItem::Separator];
        if let Some(progress) = download_progress(depth) {
            items.push(info(progress));
            items.push(action("Cancel download", |d| d.download.cancel.store(true, Ordering::Relaxed)));
        } else if let Some(bytes) = depth.vda_offer() {
            let mut offer = vec![
                info("Video Depth Anything: steadier, more detailed depth".into()),
                info("Needs NVIDIA TensorRT, downloaded from NVIDIA under NVIDIA's licence".into()),
                info("Then about 3 minutes to prepare it for your GPU, once".into()),
                StandardItem {
                    label: "Read NVIDIA's TensorRT licence".into(),
                    activate: Box::new(|_| open_url(crate::download::LICENCE_URL)),
                    ..Default::default()
                }
                .into(),
                action("Accept and download", |d| d.download_vda()),
            ];
            if let State::Failed(err) = depth.download.state() {
                offer.insert(0, info(format!("Last download failed: {err}")));
            }
            items.push(
                SubMenu {
                    label: format!("Download Video Depth Anything ({} MB)", bytes.div_ceil(1_000_000)),
                    submenu: offer,
                    ..Default::default()
                }
                .into(),
            );
        } else if crate::download::installed() {
            items.push(action("Remove the VDA download", |d| d.remove_vda_download()));
        } else {
            items.pop();
        }
        items
    }

    /// A warning, with a fix, when the firewall would stop the Quest from
    /// finding Meteor.
    fn firewall_menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use crate::firewall::Status;
        use ksni::menu::*;
        let info = |label: String| -> ksni::MenuItem<Self> {
            StandardItem { label, enabled: false, ..Default::default() }.into()
        };
        let allow = |label: &str| -> ksni::MenuItem<Self> {
            StandardItem {
                label: label.into(),
                icon_name: "security-medium".into(),
                activate: Box::new(|tray: &mut Self| tray.status.allow_firewall()),
                ..Default::default()
            }
            .into()
        };
        match self.status.firewall() {
            Status::Checking | Status::Open => vec![],
            Status::Blocked { zone, ports } => vec![
                info(format!("Firewall is blocking the Quest ({} ports, zone {zone})", ports.len())),
                allow("Allow the Quest through the firewall"),
            ],
            Status::Ufw => vec![
                info("ufw is on; Meteor can't check that the Quest gets through".into()),
                allow("Open Meteor's ports in ufw"),
            ],
        }
    }

    fn mic_menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::*;
        let Some(mic) = &self.mic else {
            return vec![StandardItem { label: "Microphone: off".into(), enabled: false, ..Default::default() }.into()];
        };
        vec![
            StandardItem { label: format!("Microphone: {}", mic.status()), enabled: false, ..Default::default() }.into(),
            CheckmarkItem {
                label: "Mute microphone".into(),
                checked: mic.muted.load(Ordering::Relaxed),
                activate: Box::new(|tray: &mut Self| {
                    if let Some(mic) = &tray.mic {
                        mic.muted.fetch_xor(true, Ordering::Relaxed);
                    }
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Set as default input".into(),
                activate: Box::new(|tray: &mut Self| {
                    if let Some(mic) = &tray.mic {
                        mic.set_default_input();
                    }
                }),
                ..Default::default()
            }
            .into(),
        ]
    }

    fn summary(&self) -> String {
        let tcp = self.stats.tcp_connections.load(Ordering::Relaxed);
        let udp = self.stats.udp_flows.load(Ordering::Relaxed);
        if udp > 0 {
            format!("Streaming ({udp} UDP flows, {tcp} TCP)")
        } else if tcp > 0 {
            format!("Client connected ({tcp} TCP)")
        } else {
            "Waiting for a client".into()
        }
    }
}

/// "Downloading VDA: 210 of 640 MB" while the download runs.
fn download_progress(depth: &Depth) -> Option<String> {
    (depth.download.state() == crate::download::State::Running).then(|| {
        let mb = |a: &std::sync::atomic::AtomicU64| a.load(Ordering::Relaxed) / 1_000_000;
        format!("Downloading VDA: {} of {} MB", mb(&depth.download.done), mb(&depth.download.total))
    })
}

fn open_url(url: &str) {
    let opener = if cfg!(windows) { "explorer" } else { "xdg-open" };
    if let Err(err) = std::process::Command::new(opener).arg(url).spawn() {
        log::warn!("Can't open {url}: {err}");
    }
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
