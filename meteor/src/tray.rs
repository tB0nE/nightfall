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
    pub xr_trust: Option<Arc<crate::xr_trust::Trust>>,
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
        let setup = crate::xr_setup::state();
        vec![
            StandardItem {
                label: "Custom Steam Launch Options required: Copy".into(),
                icon_name: "edit-copy".into(),
                enabled: crate::xr_library::steam_launch_options().is_ok(),
                activate: Box::new(|_| { tokio::spawn(async {
                    match crate::xr_library::steam_launch_options() {
                        Ok(options) => match crate::desktop::copy_text(&options).await {
                            Ok(()) => crate::desktop::notify("Steam launch options copied",
                                "In Steam, right-click your VR game → Properties → General → Launch Options. Paste the copied line. Use the same line for each VR game.").await,
                            Err(error) => { log::warn!("Cannot copy Steam launch options: {error}");
                                crate::desktop::notify("Could not copy Steam launch options", &error.to_string()).await; }
                        },
                        Err(error) => log::warn!("Cannot create Steam launch options: {error}"),
                    }
                }); }),
                ..Default::default()
            }.into(),
            StandardItem {
                label: if setup.ready { "PCVR ready (Linux / NVIDIA)" }
                    else if setup.busy { "Setting up PCVR…" }
                    else if setup.error.is_some() { "Retry PCVR setup — install & restart Meteor" }
                    else { "Enable PCVR — install & restart Meteor" }.into(),
                icon_name: if setup.ready { "emblem-default" } else { "applications-games" }.into(),
                enabled: !setup.ready && !setup.busy,
                activate: Box::new(|_| crate::xr_setup::request_enable()),
                ..Default::default()
            }.into(),
            info(setup.error.as_deref().map(|error| format!("PCVR: {} (see Open log)", error.chars().take(100).collect::<String>()))
                .unwrap_or_else(|| "PCVR requires Linux / NVIDIA; Steam launch options are per game".into())),
            MenuItem::Separator,
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
        .chain([StandardItem {
            label:"VR Apps".into(),
            activate:Box::new(|_| {if let Err(error)=crate::xr_library::request_open(){log::warn!("Cannot open VR Apps: {error}");}}),
            ..Default::default()
        }.into()])
        .chain(self.xr_pairing_menu())
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
                label: "Release information & licenses".into(),
                activate: Box::new(|_| {
                    if let Ok(executable)=std::env::current_exe() {
                        if let Some(prefix)=executable.parent().and_then(std::path::Path::parent) {
                            open_url(&prefix.join("share/doc/nightfall-meteor/RELEASE.md").to_string_lossy());
                        }
                    }
                }),
                ..Default::default()
            }.into(),
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
    fn xr_pairing_menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::StandardItem;
        let Some(trust) = &self.xr_trust else { return vec![] };
        let Some((key, code)) = trust.pending() else { return vec![] };
        let approve = trust.clone(); let reject = trust.clone();
        vec![
            StandardItem { label: format!("Approve XR headset {code} (compare headset code)"),
                activate: Box::new(move |_| { if let Err(error)=approve.approve(key) {log::warn!("XR approval failed: {error}");} }),
                ..Default::default() }.into(),
            StandardItem { label: format!("Reject XR headset {code}"),
                activate: Box::new(move |_| reject.reject(key)), ..Default::default() }.into(),
        ]
    }

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

        let mut model_items:Vec<ksni::MenuItem<Self>>=depth.choice_groups().into_iter().map(|group| {
            SubMenu {label:group.label,submenu:group.choices.into_iter().map(|choice| {
                CheckmarkItem {label:crate::depth::model_label(&choice.model),checked:depth.choice_selected(&choice),
                    activate:Box::new(move |tray:&mut Self| {if let Some(depth)=&tray.depth {depth.select_choice(&choice);}}),
                    ..Default::default()}.into()
            }).collect(),..Default::default()}.into()
        }).collect();
        model_items.extend(self.vda_download_items(depth));
        for (id,bytes) in depth.vulkan_vda_offers() {
            model_items.push(SubMenu {
                label:format!("Download {} ({} MB)",crate::depth::model_label(id),bytes.div_ceil(1_000_000)),
                submenu:vec![
                    info("Vulkan GPU inference — no TensorRT download required".into()),
                    info("VDA Small weights: Apache 2.0; license included".into()),
                    info("Adds the model to compatible GPU lists; keeps your current selection".into()),
                    StandardItem { label:"Download model".into(), activate:Box::new(move |tray:&mut Self| {
                        if let Some(depth)=&tray.depth { depth.download_vulkan_vda(id); }
                    }),..Default::default() }.into(),
                ],..Default::default()
            }.into());
        }
        if let crate::download::State::Failed(error)=depth.download.state() {
            model_items.push(info(format!("Download failed: {}",error.chars().take(120).collect::<String>())));
        }
        let model_menu = SubMenu {
            label: format!("GPU / model: {}",depth.selection_label()),
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
            SubMenu {
                label:"Advanced depth pipeline".into(),
                submenu:{
                    use crate::video_decoder::{Backend,vaapi_devices};
                    let settings=depth.decode_settings();
                    let devices=vaapi_devices();
                    let mut device_options=vec![RadioItem {label:"Auto".into(),..Default::default()}];
                    device_options.extend(devices.iter().map(|(_,label)|RadioItem {label:label.clone(),..Default::default()}));
                    vec![
                        info(format!("Active: {}",depth.decoder_status())),
                        info("Decoder/device changes apply at the next keyframe or stream".into()),
                        SubMenu {
                            label:format!("Video decoder: {}",settings.backend.label()),
                            submenu:vec![RadioGroup {
                                selected:Backend::ALL.iter().position(|b|*b==settings.backend).unwrap_or(0),
                                options:Backend::ALL.iter().map(|b|RadioItem {label:b.label().into(),..Default::default()}).collect(),
                                select:Box::new(|tray:&mut Self,i|if let (Some(depth),Some(backend))=(&tray.depth,Backend::ALL.get(i)) {depth.set_decode_backend(*backend);}),
                            }.into()],..Default::default()
                        }.into(),
                        SubMenu {
                            label:"VAAPI decode GPU".into(),
                            enabled:matches!(settings.backend,Backend::Auto|Backend::Vaapi),
                            submenu:vec![RadioGroup {
                                selected:settings.vaapi_device.as_ref().and_then(|p|devices.iter().position(|(path,_)|path==p)).map_or(0,|i|i+1),
                                options:device_options,
                                select:Box::new(move |tray:&mut Self,i|if let Some(depth)=&tray.depth {depth.set_vaapi_device(if i==0 {None} else {devices.get(i-1).map(|(path,_)|path.clone())});}),
                            }.into()],..Default::default()
                        }.into(),
                        CheckmarkItem {
                            label:"CPU frame processing (reference path)".into(),
                            checked:settings.cpu_processing,
                            activate:Box::new(|tray:&mut Self|if let Some(depth)=&tray.depth {depth.set_cpu_processing(!depth.decode_settings().cpu_processing);}),
                            ..Default::default()
                        }.into(),
                    ]
                },..Default::default()
            }.into(),
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
            CheckmarkItem {
                label: "Edge alignment (experimental)".into(),
                checked: depth.edge_alignment(),
                activate: Box::new(|tray: &mut Self| {
                    if let Some(depth) = &tray.depth { depth.set_edge_alignment(!depth.edge_alignment()); }
                }),
                ..Default::default()
            }.into(),
            CheckmarkItem {
                label: "Contour cleanup (requires alignment)".into(),
                checked: depth.contour_cleanup(),
                enabled: depth.edge_alignment(),
                activate: Box::new(|tray: &mut Self| {
                    if let Some(depth) = &tray.depth { depth.set_contour_cleanup(!depth.contour_cleanup()); }
                }),
                ..Default::default()
            }.into(),
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
                    label: format!("Download VDA (NVIDIA TensorRT, {} MB)", bytes.div_ceil(1_000_000)),
                    submenu: offer,
                    ..Default::default()
                }
                .into(),
            );
        } else if crate::download::installed() {
            items.push(action("Remove TensorRT VDA download", |d| d.remove_vda_download()));
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
