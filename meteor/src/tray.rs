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
    pub host: Arc<crate::host::view::View>,
    pub xr_trust: Option<Arc<crate::xr_trust::Trust>>,
    pub cursor: Arc<crate::host_cursor::Control>,
}

impl ksni::Tray for MeteorTray {
    fn id(&self) -> String {
        "nightfall-meteor".into()
    }

    fn title(&self) -> String {
        self.name()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        static ICONS: std::sync::OnceLock<Vec<ksni::Icon>> = std::sync::OnceLock::new();
        ICONS.get_or_init(|| crate::icon::SIZES.iter().map(|&s| crate::icon::nightfall_icon(s)).collect()).clone()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: self.name(),
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
        const XR_ENCODERS: &[(&str,&str)]=&[("auto","Auto (prefer NVIDIA)"),("nvenc","NVIDIA / NVENC"),("vaapi","AMD / VA-API (experimental)")];
        let encoder=crate::config::load().xr.encoder_backend;
        let encoder_index=XR_ENCODERS.iter().position(|(id,_)|*id==encoder).unwrap_or(0);
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
                label: if setup.ready { "PCVR ready (Linux / NVIDIA or AMD)" }
                    else if setup.busy { "Setting up PCVR…" }
                    else if setup.error.is_some() { "Retry PCVR setup — install & restart Meteor" }
                    else { "Enable PCVR — install & restart Meteor" }.into(),
                icon_name: if setup.ready { "emblem-default" } else { "applications-games" }.into(),
                enabled: !setup.ready && !setup.busy,
                activate: Box::new(|_| crate::xr_setup::request_enable()),
                ..Default::default()
            }.into(),
            SubMenu {
                label: format!("PCVR encoder: {}",XR_ENCODERS[encoder_index].1),
                enabled: !setup.busy,
                submenu: vec![RadioGroup {
                    selected: encoder_index,
                    select:Box::new(|_:&mut Self,index| {
                        if let Some((id,_))=XR_ENCODERS.get(index) {
                            let result=crate::xr_setup::select_encoder(id);
                            tokio::spawn(async move {match result {
                                Ok(())=>crate::desktop::notify("PCVR encoder saved","Applies to the next XR session. Unsupported encoder controls are disabled automatically.").await,
                                Err(error)=>crate::desktop::notify("Could not save PCVR encoder",&error.to_string()).await,
                            }});
                        }
                    }),
                    options:XR_ENCODERS.iter().map(|(_,label)|RadioItem{label:(*label).into(),..Default::default()}).collect(),
                }.into()],..Default::default()
            }.into(),
            info(setup.error.as_deref().map(|error| format!("PCVR: {} (see Open log)", error.chars().take(100).collect::<String>()))
                .unwrap_or_else(|| "PCVR requires Linux / NVIDIA or AMD; Steam launch options are per game".into())),
            MenuItem::Separator,
            info(format!("{} {}", self.name(), env!("CARGO_PKG_VERSION"))),
            MenuItem::Separator,
            info(self.summary()),
            info(format!(
                "Proxy ports from {} (Sunshine + {}), discovery {}",
                self.status.map.meteor(crate::ports::PortMap::channel("http")),
                self.status.map.offset,
                self.status.side.discovery
            )),
            info(format!(
                "Traffic: {:.1} MB to client, {:.1} MB to Sunshine",
                mb(self.stats.bytes_to_client.load(Ordering::Relaxed)),
                mb(self.stats.bytes_to_sunshine.load(Ordering::Relaxed))
            )),
        ]
        .into_iter()
        .chain(self.host_menu())
        .chain(self.firewall_menu())
        .chain([MenuItem::Separator])
        .chain([StandardItem {
            label:"VR Apps".into(),
            activate:Box::new(|_| {if let Err(error)=crate::xr_library::request_open(){log::warn!("Cannot open VR Apps: {error}");}}),
            ..Default::default()
        }.into()])
        .chain(self.xr_pairing_menu())
        .chain(self.depth_menu())
        .chain(self.cursor_menu())
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
    fn cursor_menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::*;
        let scale = self.cursor.scale();
        vec![SubMenu {
            label: format!("Host cursor size: {}", if scale == 1 { "Unchanged".into() } else { format!("{scale}×") }),
            enabled: self.cursor.available(),
            submenu: vec![RadioGroup {
                selected: (scale - 1) as usize,
                options: ["Unchanged", "2×", "3×", "4×"].iter().map(|label| RadioItem { label: (*label).into(), ..Default::default() }).collect(),
                select: Box::new(|tray: &mut Self, index| {
                    if let Err(error) = tray.cursor.select(index as u32 + 1) {
                        log::warn!("Cannot save host cursor size: {error}");
                        tokio::spawn(async move { crate::desktop::notify("Could not save host cursor size", &error.to_string()).await; });
                    }
                }),
            }.into(), StandardItem {
                label: self.cursor.status(), enabled: false, ..Default::default()
            }.into()], ..Default::default()
        }.into()]
    }
    /// "Nightfall Meteor", plus the base port when it isn't the default, so
    /// two Meteors on one PC can be told apart.
    fn name(&self) -> String {
        let base = self.status.map.sunshine_base;
        if base == crate::config::DEFAULT_SUNSHINE_PORT {
            "Nightfall Meteor".into()
        } else {
            format!("Nightfall Meteor (port {base})")
        }
    }

    /// The game streaming host: the one the user installed, or Vibepollo
    /// for Nightfall run by Meteor, and switching between them.
    fn host_menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use crate::host::{Choice, Phase};
        use ksni::menu::*;
        let info = |label: String| -> ksni::MenuItem<Self> {
            StandardItem { label, enabled: false, ..Default::default() }.into()
        };
        let host = &self.host;
        let base = self.status.map.sunshine_base;
        let up = self.status.sunshine_up.load(Ordering::Relaxed);
        let own_pid = host.supervisor.as_ref().and_then(|s| s.pid());
        let others = crate::host::other_hosts(own_pid);
        let other_names = {
            let mut names: Vec<&str> = others.iter().map(|(_, n)| n.as_str()).collect();
            names.dedup();
            names.join(" and ")
        };
        let mut items = vec![MenuItem::Separator];
        if let Some(pairing) = &host.pairing
            && let Some(pending) = pairing.pending()
        {
            items.push(info(format!("Pair headset {} — PIN {}",pending.peer,pending.pin)));
            let approve=pairing.clone(); let request=pending.id.clone();
            items.push(StandardItem { label:"Approve headset pairing".into(),
                activate:Box::new(move |_|approve.approve(&request)), ..Default::default() }.into());
            let reject=pairing.clone(); let request=pending.id;
            items.push(StandardItem { label:"Reject headset pairing".into(),
                activate:Box::new(move |_|reject.reject(&request)), ..Default::default() }.into());
        }
        if host.state.choice == Choice::Bundled {
            use crate::host::input::Status as InputStatus;
            let input=crate::host::input::check();
            if input == InputStatus::Ready {
                items.push(info("Virtual input: ready".into()));
            } else {
                let label=match input {
                    InputStatus::Missing=>"Virtual input device is not available".into(),
                    InputStatus::Denied=>"Keyboard/controller input needs permission".into(),
                    InputStatus::Unavailable(error)=>format!("Virtual input unavailable: {error}"),
                    InputStatus::Ready=>unreachable!(),
                };
                items.push(info(label));
                let busy=host.input.busy();
                items.push(StandardItem {
                    label:if busy {"Waiting for input setup…"} else {"Enable virtual input (administrator approval; restarts Meteor)…"}.into(),
                    enabled:!busy,
                    activate:Box::new(|tray:&mut Self|tray.host.input.setup()), ..Default::default()
                }.into());
            }
        }
        match (&host.supervisor, host.state.choice) {
            (Some(supervisor), _) => {
                let line = match supervisor.phase() {
                    Phase::Running => format!("Host: Meteor-Vibepollo for Nightfall, port {base}"),
                    Phase::WaitingForPort if !others.is_empty() => format!("Host: waiting for port {base}; close {other_names}"),
                    Phase::WaitingForPort => format!("Host: waiting for port {base} to be free"),
                    Phase::Restarting { failures } => format!("Host: restarting after a crash ({failures})"),
                    Phase::Stopped => "Host: Meteor-Vibepollo for Nightfall is stopped".into(),
                    Phase::Failed(reason) => format!("Host stopped: {reason}"),
                };
                items.push(info(line));
                if !others.is_empty() && base != crate::config::DEFAULT_SUNSHINE_PORT {
                    items.push(info(format!("{other_names} is also running; Nightfall lists both")));
                }
                let running = supervisor.wanted();
                items.push(
                    StandardItem {
                        label: if running { "Stop the host" } else { "Start the host" }.into(),
                        activate: Box::new(|tray: &mut Self| {
                            if let Some(s) = &tray.host.supervisor {
                                s.set_wanted(!s.wanted());
                            }
                        }),
                        ..Default::default()
                    }
                    .into(),
                );
                let appdata = supervisor.instance.appdata();
                items.push(
                    SubMenu {
                        label: "Host settings".into(),
                        submenu: vec![
                            StandardItem {
                                label: "Open the host's web page".into(),
                                activate: Box::new(move |_| open_url(&format!("https://localhost:{}", base + 1))),
                                ..Default::default()
                            }
                            .into(),
                            StandardItem {
                                label: format!("Web UI username: {}", host.state.user),
                                enabled: false,
                                ..Default::default()
                            }.into(),
                            StandardItem {
                                label: "Copy web UI password".into(),
                                activate: Box::new(|tray: &mut Self| {
                                    let password=tray.host.state.password.clone();
                                    tokio::spawn(async move {
                                        let result=crate::desktop::copy_text(&password).await;
                                        let message=if result.is_ok() {"Password copied. Paste it into the host's web login."}
                                            else {"Could not copy the password. Check that your desktop clipboard manager is running."};
                                        crate::desktop::notify("Meteor-Vibepollo web login",message).await;
                                    });
                                }),
                                ..Default::default()
                            }.into(),
                            StandardItem {
                                label: "Open the host's folder (logs, config)".into(),
                                activate: Box::new(move |_| open_url(&appdata.to_string_lossy())),
                                ..Default::default()
                            }
                            .into(),
                            StandardItem {
                                label: "Switch back to my own host (restarts Meteor)".into(),
                                activate: Box::new(|tray: &mut Self| tray.host.switch(Choice::External)),
                                ..Default::default()
                            }
                            .into(),
                        ],
                        ..Default::default()
                    }
                    .into(),
                );
            }
            (None, Choice::Bundled) => {
                items.push(info(format!(
                    "Host: Meteor-Vibepollo for Nightfall didn't start: {}",
                    host.error.as_deref().unwrap_or("unknown")
                )));
                // A newer Meteor can pin a host version not installed yet.
                // Keep setup/retry accessible without changing host choice.
                if host.binary.is_none() {
                    items.extend(self.bundled_offer(false, &other_names));
                }
                items.push(
                    StandardItem {
                        label: "Use my own host instead (restarts Meteor)".into(),
                        activate: Box::new(|tray: &mut Self| tray.host.switch(Choice::External)),
                        ..Default::default()
                    }
                    .into(),
                );
            }
            (None, Choice::External) => {
                let name = if other_names.is_empty() { "Host".to_string() } else { other_names.clone() };
                items.push(info(if up {
                    format!("{name} on port {base}: running")
                } else {
                    "No game streaming host found".to_string()
                }));
                items.extend(self.bundled_offer(up, &other_names));
            }
        }
        items
    }

    /// Offers Meteor-Vibepollo for Nightfall: set up when there's no host, or
    /// switch to it next to another host.
    fn bundled_offer(&self, host_up: bool, other_names: &str) -> Vec<ksni::MenuItem<Self>> {
        use crate::download::State;
        use ksni::menu::*;
        let info = |label: String| -> ksni::MenuItem<Self> {
            StandardItem { label, enabled: false, ..Default::default() }.into()
        };
        let host = &self.host;
        if host.download.state() == State::Running {
            let mb = |a: &std::sync::atomic::AtomicU64| a.load(Ordering::Relaxed) / 1_000_000;
            return vec![
                info(format!("Downloading Meteor-Vibepollo for Nightfall: {} of {} MB", mb(&host.download.done), mb(&host.download.total))),
                StandardItem {
                    label: "Cancel download".into(),
                    activate: Box::new(|tray: &mut Self| tray.host.download.cancel.store(true, Ordering::Relaxed)),
                    ..Default::default()
                }
                .into(),
            ];
        }
        let label = if host_up { "Use Meteor-Vibepollo for Nightfall instead" } else { "Set up Meteor-Vibepollo for Nightfall" };
        let mut offer = vec![info("Meteor runs its own game streaming host, kept apart from any other".into())];
        if host_up && !other_names.is_empty() {
            offer.push(info(format!("Close {other_names} afterwards so only one host runs")));
        }
        if let State::Failed(err) = host.download.state() {
            offer.push(info(format!("Last download failed: {err}")));
        }
        if host.binary.is_some() {
            offer.push(
                StandardItem {
                    label: "Switch (restarts Meteor)".into(),
                    activate: Box::new(|tray: &mut Self| tray.host.switch(crate::host::Choice::Bundled)),
                    ..Default::default()
                }
                .into(),
            );
        } else if let Some(release) = crate::host::RELEASE.as_ref() {
            offer.push(
                StandardItem {
                    label: format!("Download ({} MB) and switch", release.size.div_ceil(1_000_000)),
                    activate: Box::new(|tray: &mut Self| tray.host.download_and_switch()),
                    ..Default::default()
                }
                .into(),
            );
        } else {
            offer.push(info("Not published yet; set host_binary in the settings file to try a build".into()));
        }
        vec![SubMenu { label: label.into(), submenu: offer, ..Default::default() }.into()]
    }

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
    if url.starts_with("https://") || url.starts_with("http://") {
        crate::desktop::open_web_url(url.to_string());
        return;
    }
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
