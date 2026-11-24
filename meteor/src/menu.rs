//! The tray menu, described once for every OS. Each tray (tray.rs on Linux,
//! tray_macos.rs on macOS) only draws these entries and hands a chosen `Action` back to `activate`.
//!
//! Sections, top to bottom: Setup; Meteor's own status; PCVR; the game
//! streaming host; AI 3D; audio; then Start with my computer and Quit.
//! Installing things, the log, the settings file and the licences live in
//! the Setup window; depth model settings in their own window.

// macOS has no PCVR, host cursor size or udev input setup: their entries and actions are
// built on Linux only.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::sync::Arc;
use std::sync::atomic::Ordering;

use crate::depth::Depth;
use crate::mic::Mic;
use crate::proxy::Stats;
use crate::status::Status;

/// What the menu reads, and acts on.
pub struct Sources {
    pub status: Arc<Status>,
    pub stats: Arc<Stats>,
    pub depth: Option<Arc<Depth>>,
    pub mic: Option<Arc<Mic>>,
    pub host: Arc<crate::host::view::View>,
    pub xr_trust: Option<Arc<crate::xr_trust::Trust>>,
    /// Only Linux capture reads the cursor-scale file.
    #[cfg(target_os = "linux")]
    pub cursor: Arc<crate::host_cursor::Control>,
}

/// One line of the menu.
#[derive(Debug)]
#[cfg_attr(windows, allow(dead_code))] // Options: Linux's PCVR encoder list
pub enum Entry {
    /// Greyed-out text.
    Label(String),
    Separator,
    Item { title: String, action: Action, enabled: bool, checked: Option<bool> },
    /// A submenu of mutually exclusive options; `selected` is ticked.
    Choice { title: String, enabled: bool, options: Vec<(String, Action)>, selected: usize, note: Option<String> },
    /// The same options, listed inline in the menu they're in.
    Options { enabled: bool, options: Vec<(String, Action)>, selected: usize },
    Submenu { title: String, entries: Vec<Entry> },
}

fn label(text: impl Into<String>) -> Entry {
    Entry::Label(text.into())
}
fn item(title: impl Into<String>, action: Action) -> Entry {
    Entry::Item { title: title.into(), action, enabled: true, checked: None }
}
fn check(title: impl Into<String>, action: Action, checked: bool) -> Entry {
    Entry::Item { title: title.into(), action, enabled: true, checked: Some(checked) }
}

/// Everything the menu can do.
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(windows, allow(dead_code))] // the encoder, input and cursor actions are Linux's
pub enum Action {
    Setup,
    AllowFirewall,
    PcvrEncoder(&'static str),
    XrApprove([u8; 32]),
    XrReject([u8; 32]),
    PairApprove(String),
    PairReject(String),
    EnableInput,
    ToggleHost,
    CursorScale(u32),
    HostWebPage,
    CopyHostPassword,
    HostFolder,
    UseHost(crate::host::Choice),
    DownloadHost,
    CancelHostDownload,
    ToggleDepth,
    DepthSettings,
    AudioOutput(crate::audio::Output),
    ToggleMicMute,
    MicDefaultInput,
    ToggleAutostart,
    Quit,
    // Windows has these where Linux needs nothing like them.
    /// Pair-Headset.ps1: enter the headset's PIN by hand.
    #[cfg(windows)]
    PairHeadset,
    #[cfg(windows)]
    InstallVirtualDisplay,
    /// host.toml, with the web UI login.
    #[cfg(windows)]
    HostLogin,
    #[cfg(windows)]
    PcvrGames,
    #[cfg(windows)]
    EnablePcvr,
    #[cfg(windows)]
    InstallCable,
    #[cfg(windows)]
    TaskbarSettings,
}

#[cfg_attr(windows, allow(dead_code))]
pub const PCVR_ENCODERS: &[(&str, &str)] = &[("auto", "Auto (prefer NVIDIA)"), ("nvenc", "NVIDIA / NVENC"), ("vaapi", "AMD / VA-API (experimental)")];

impl Sources {
    pub fn entries(&self) -> Vec<Entry> {
        let mut out = vec![item("Setup…", Action::Setup), Entry::Separator];
        out.extend(self.meteor_section());
        out.push(Entry::Separator);
        // macOS runs no XR runtime: PCVR isn't offered there.
        #[cfg(any(target_os = "linux", windows))]
        {
            out.extend(self.pcvr_section());
            out.push(Entry::Separator);
        }
        out.extend(self.host_section());
        out.push(Entry::Separator);
        out.extend(self.depth_section());
        out.push(Entry::Separator);
        out.extend(self.audio_section());
        out.push(Entry::Separator);
        out.push(check("Start with my computer", Action::ToggleAutostart, crate::desktop::autostart_enabled()));
        #[cfg(windows)]
        out.push(item("Taskbar icon settings…", Action::TaskbarSettings));
        out.push(item("Quit", Action::Quit));
        out
    }

    /// "Nightfall Meteor", plus the base port when it isn't the default, so
    /// two Meteors on one PC can be told apart.
    pub fn name(&self) -> String {
        let base = self.status.map.sunshine_base;
        if base == crate::config::DEFAULT_SUNSHINE_PORT { "Nightfall Meteor".into() } else { format!("Nightfall Meteor (port {base})") }
    }

    pub fn summary(&self) -> String {
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

    /// Version, then the connection with Meteor's ports. A firewall that
    /// would hide Meteor from the Quest says so here, with the fix.
    fn meteor_section(&self) -> Vec<Entry> {
        use crate::firewall::Status as Firewall;
        let map = &self.status.map;
        let mut out = vec![
            label(format!("{} {}", self.name(), env!("METEOR_VERSION"))),
            label(format!(
                "{} · ports from {}, discovery {}",
                self.summary(),
                map.meteor(crate::ports::PortMap::channel("http")),
                self.status.side.discovery
            )),
        ];
        match self.status.firewall() {
            Firewall::Blocked { zone, ports } => {
                out.push(label(format!("Firewall is blocking the Quest ({} ports, zone {zone})", ports.len())));
                out.push(item("Allow the Quest through the firewall", Action::AllowFirewall));
            }
            Firewall::Ufw => {
                out.push(label("ufw is on; Meteor can't check that the Quest gets through"));
                out.push(item("Open Meteor's ports in ufw", Action::AllowFirewall));
            }
            Firewall::Windows { .. } => {
                out.push(label("Windows Firewall is blocking the Quest"));
                out.push(item("Allow the Quest through the firewall…", Action::AllowFirewall));
            }
            Firewall::Checking | Firewall::Open => {}
        }
        out
    }

    #[cfg(windows)]
    fn pcvr_section(&self) -> Vec<Entry> {
        let state = crate::xr_windows::state();
        let status = match &state.error {
            Some(error) => format!("PCVR: {} (see the log in Setup)", error.chars().take(100).collect::<String>()),
            None if state.ready => "PCVR: ready".into(),
            None => "PCVR: off; turn it on in Setup".into(),
        };
        // One window for the games, which can be any number: a menu can't list them.
        let games = crate::xr_windows::games(&crate::xr_windows::root()).unwrap_or_default();
        let mut entries = vec![Entry::Item { title: format!("PCVR games… ({})", games.len()), action: Action::PcvrGames, enabled: true, checked: None }];
        if !state.ready {
            entries.push(Entry::Item { title: "Enable PCVR (restarts Meteor)".into(), action: Action::EnablePcvr, enabled: !games.is_empty(), checked: None });
        }
        let mut out = vec![label(status), Entry::Submenu { title: "PCVR".into(), entries }];
        out.extend(self.xr_approval());
        out
    }

    #[cfg(target_os = "linux")]
    fn pcvr_section(&self) -> Vec<Entry> {
        let setup = crate::xr_setup::state();
        let status = match &setup.error {
            Some(error) => format!("PCVR: {} (see the log in Setup)", error.chars().take(100).collect::<String>()),
            None if setup.ready => "PCVR: ready".into(),
            None => "PCVR: off; turn it on in Setup".into(),
        };
        let encoder = crate::config::load().xr.encoder_backend;
        let selected = PCVR_ENCODERS.iter().position(|(id, _)| *id == encoder).unwrap_or(0);
        let mut out = vec![
            label(status),
            Entry::Submenu {
                title: "PCVR".into(),
                entries: vec![
                    label("Encoder (applies to the next PCVR session)"),
                    Entry::Options {
                        enabled: !setup.busy,
                        options: PCVR_ENCODERS.iter().map(|(id, name)| ((*name).to_string(), Action::PcvrEncoder(id))).collect(),
                        selected,
                    },
                ],
            },
        ];
        out.extend(self.xr_approval());
        out
    }

    /// A headset asking to use PCVR, to approve or reject.
    fn xr_approval(&self) -> Vec<Entry> {
        let Some((key, code)) = self.xr_trust.as_ref().and_then(|trust| trust.pending()) else { return Vec::new() };
        vec![
            item(format!("Approve XR headset {code} (compare headset code)"), Action::XrApprove(key)),
            item(format!("Reject XR headset {code}"), Action::XrReject(key)),
        ]
    }

    /// The game streaming host: the one the user installed, or Meteor-
    /// Vibepollo for Nightfall run by Meteor, and switching between them.
    fn host_section(&self) -> Vec<Entry> {
        use crate::host::{Choice, Phase};
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
        let mut out = Vec::new();
        if let Some(pending) = host.pairing.as_ref().and_then(|p| p.pending()) {
            out.push(label(format!("Pair headset {} — PIN {}", pending.peer, pending.pin)));
            out.push(item("Approve headset pairing", Action::PairApprove(pending.id.clone())));
            out.push(item("Reject headset pairing", Action::PairReject(pending.id)));
        }
        // Keyboard and controller input, folded into the host's own line.
        let (input, input_fix) = if host.state.choice == Choice::Bundled { self.input_status() } else { (String::new(), None) };
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
                out.push(label(line + &input));
                out.extend(input_fix);
                if !others.is_empty() && base != crate::config::DEFAULT_SUNSHINE_PORT {
                    out.push(label(format!("{other_names} is also running; Nightfall lists both")));
                }
                out.push(item(if supervisor.wanted() { "Stop the host" } else { "Start the host" }, Action::ToggleHost));
                #[cfg(windows)]
                out.push(item("Pair a headset by PIN…", Action::PairHeadset));
                out.extend(self.cursor_choice());
                #[allow(unused_mut)]
                let mut settings = vec![
                    item("Open the host's web page", Action::HostWebPage),
                    Entry::Item { title: format!("Web UI username: {}", host.state.user), action: Action::HostWebPage, enabled: false, checked: None },
                    item("Copy web UI password", Action::CopyHostPassword),
                    item("Open the host's folder (logs, config)", Action::HostFolder),
                ];
                #[cfg(windows)]
                {
                    settings.push(item("Open the host login (host.toml)", Action::HostLogin));
                    if virtual_display_script().is_some() {
                        settings.push(item("Install the virtual display driver (administrator)…", Action::InstallVirtualDisplay));
                    }
                }
                settings.push(item("Switch back to my own host (restarts Meteor)", Action::UseHost(Choice::External)));
                out.push(Entry::Submenu { title: "Host settings".into(), entries: settings });
            }
            (None, Choice::Bundled) => {
                out.push(label(format!(
                    "Host: Meteor-Vibepollo for Nightfall didn't start: {}{input}",
                    host.error.as_deref().unwrap_or("unknown")
                )));
                out.extend(input_fix);
                // A newer Meteor can pin a host version not installed yet.
                if host.binary.is_none() {
                    out.extend(self.bundled_offer(false, &other_names));
                }
                out.push(item("Use my own host instead (restarts Meteor)", Action::UseHost(Choice::External)));
            }
            (None, Choice::External) => {
                let name = if other_names.is_empty() { "Host".to_string() } else { other_names.clone() };
                out.push(label(if up { format!("{name} on port {base}: running") } else { "No game streaming host found".to_string() }));
                out.extend(self.cursor_choice());
                out.extend(self.bundled_offer(up, &other_names));
            }
        }
        out
    }

    /// Linux: the uinput device the host injects input through.
    #[cfg(target_os = "linux")]
    fn input_status(&self) -> (String, Option<Entry>) {
        use crate::host::input::Status as Input;
        let status = crate::host::input::check();
        let text = match &status {
            Input::Ready => " · input ready".into(),
            Input::Missing => " · no virtual input device".into(),
            Input::Denied => " · input needs permission".into(),
            Input::Unavailable(error) => format!(" · input unavailable: {error}"),
        };
        let fix = (status != Input::Ready).then(|| {
            let busy = self.host.input.busy();
            Entry::Item {
                title: if busy { "Waiting for input setup…" } else { "Enable virtual input (administrator approval; restarts Meteor)…" }.into(),
                action: Action::EnableInput,
                enabled: !busy,
                checked: None,
            }
        });
        (text, fix)
    }

    /// macOS: the host captures with Screen Recording and injects input with Accessibility,
    /// both granted to Meteor.app in Setup.
    #[cfg(target_os = "macos")]
    fn input_status(&self) -> (String, Option<Entry>) {
        use crate::desktop::permissions;
        let mut missing = Vec::new();
        if !permissions::screen_recording() {
            missing.push("Screen Recording");
        }
        if !permissions::accessibility() {
            missing.push("Accessibility");
        }
        if missing.is_empty() {
            return (" · input ready".into(), None);
        }
        (format!(" · needs {}", missing.join(" and ")), Some(item("Allow in Setup…", Action::Setup)))
    }

    /// Windows: the host injects input itself; nothing to report.
    #[cfg(windows)]
    fn input_status(&self) -> (String, Option<Entry>) {
        (String::new(), None)
    }

    /// Host cursor size: Meteor-Vibepollo scales the cursor on Linux captures only.
    #[cfg(not(target_os = "linux"))]
    fn cursor_choice(&self) -> Option<Entry> {
        None
    }

    #[cfg(target_os = "linux")]
    fn cursor_choice(&self) -> Option<Entry> {
        let scale = self.cursor.scale();
        Some(Entry::Choice {
            title: format!("Host cursor size: {}", if scale == 1 { "Unchanged".into() } else { format!("{scale}×") }),
            enabled: self.cursor.available(),
            options: ["Unchanged", "2×", "3×", "4×"].iter().zip(1..).map(|(name, scale)| ((*name).to_string(), Action::CursorScale(scale))).collect(),
            selected: (scale.clamp(1, 4) - 1) as usize,
            note: Some(self.cursor.status()),
        })
    }

    /// Offers Meteor-Vibepollo for Nightfall: set up when there's no host,
    /// or switch to it next to another host.
    fn bundled_offer(&self, host_up: bool, other_names: &str) -> Vec<Entry> {
        use crate::download::State;
        let host = &self.host;
        if host.download.state() == State::Running {
            let mb = |a: &std::sync::atomic::AtomicU64| a.load(Ordering::Relaxed) / 1_000_000;
            return vec![
                label(format!("Downloading Meteor-Vibepollo for Nightfall: {} of {} MB", mb(&host.download.done), mb(&host.download.total))),
                item("Cancel download", Action::CancelHostDownload),
            ];
        }
        let title = if host_up { "Use Meteor-Vibepollo for Nightfall instead" } else { "Set up Meteor-Vibepollo for Nightfall" };
        let mut offer = vec![label("Meteor runs its own game streaming host, kept apart from any other")];
        if host_up && !other_names.is_empty() {
            offer.push(label(format!("Close {other_names} afterwards so only one host runs")));
        }
        if let State::Failed(err) = host.download.state() {
            offer.push(label(format!("Last download failed: {err}")));
        }
        if host.binary.is_some() {
            offer.push(item("Switch (restarts Meteor)", Action::UseHost(crate::host::Choice::Bundled)));
        } else if let Some(release) = crate::host::RELEASE.as_ref() {
            offer.push(item(format!("Download ({} MB) and switch", release.size.div_ceil(1_000_000)), Action::DownloadHost));
        } else {
            offer.push(label("Not published yet; set host_binary in the settings file to try a build"));
        }
        vec![Entry::Submenu { title: title.into(), entries: offer }]
    }

    /// AI 3D: what depth is doing, on/off, and the model settings window.
    fn depth_section(&self) -> Vec<Entry> {
        let Some(depth) = &self.depth else { return vec![label("AI 3D: off (--no-depth)")] };
        if !depth.available() {
            return vec![label(format!("AI 3D: {}", depth.status()))];
        }
        let mut out = vec![
            label(depth_readout(depth)),
            check("Host depth", Action::ToggleDepth, depth.enabled()),
            item("Depth model configuration…", Action::DepthSettings),
        ];
        out.extend(download_progress(depth).map(label));
        out
    }

    /// Where the sound plays, and the headset microphone.
    fn audio_section(&self) -> Vec<Entry> {
        let output = crate::audio::output();
        // Windows plays the microphone into VB-CABLE, which Meteor can't install itself;
        // macOS hands it to other apps through the BlackHole driver, from Setup.
        let missing = if cfg!(windows) {
            ": install VB-CABLE"
        } else if cfg!(target_os = "macos") {
            " needs BlackHole (install it in Setup)"
        } else {
            " off"
        };
        let mic = self.mic.as_ref().map_or_else(|| missing.to_string(), |mic| format!(" {}", mic.status()));
        let mut out = vec![
            label(format!("Audio: plays on {} · microphone{mic}", output.label().to_lowercase().replace("pc", "PC"))),
            Entry::Choice {
                title: format!("Audio plays on: {}", output.label()),
                enabled: true,
                options: crate::audio::Output::ALL.iter().map(|o| (o.label().to_string(), Action::AudioOutput(*o))).collect(),
                selected: crate::audio::Output::ALL.iter().position(|o| *o == output).unwrap_or(0),
                note: Some("Changing it restarts an open stream".into()),
            },
        ];
        if let Some(mic) = &self.mic {
            out.push(check("Mute microphone", Action::ToggleMicMute, mic.muted.load(Ordering::Relaxed)));
            // Windows apps record from CABLE Output; Meteor can't set the default device.
            #[cfg(windows)]
            out.push(item("Choose CABLE Output in Sound settings…", Action::MicDefaultInput));
            #[cfg(target_os = "linux")]
            out.push(item("Set as default input", Action::MicDefaultInput));
        }
        #[cfg(windows)]
        if self.mic.is_none() {
            out.push(item("Get VB-CABLE (opens its web page)…", Action::InstallCable));
        }
        out
    }

    pub fn activate(&self, action: Action) {
        match action {
            Action::Setup => crate::setup_window::open(),
            Action::AllowFirewall => self.status.allow_firewall(),
            // Windows picks NVENC or AMF itself; macOS has no PCVR.
            #[cfg(not(target_os = "linux"))]
            Action::PcvrEncoder(_) => {}
            #[cfg(target_os = "linux")]
            Action::PcvrEncoder(id) => {
                let result = crate::xr_setup::select_encoder(id);
                tokio::spawn(async move {
                    match result {
                        Ok(()) => crate::desktop::notify("PCVR encoder saved", "Applies to the next XR session. Unsupported encoder controls are disabled automatically.").await,
                        Err(error) => crate::desktop::notify("Could not save PCVR encoder", &error.to_string()).await,
                    }
                });
            }
            Action::XrApprove(key) => {
                if let Some(trust) = &self.xr_trust
                    && let Err(error) = trust.approve(key)
                {
                    log::warn!("XR approval failed: {error}");
                }
            }
            Action::XrReject(key) => {
                if let Some(trust) = &self.xr_trust {
                    trust.reject(key);
                }
            }
            Action::PairApprove(id) => {
                if let Some(pairing) = &self.host.pairing {
                    pairing.approve(&id);
                }
            }
            Action::PairReject(id) => {
                if let Some(pairing) = &self.host.pairing {
                    pairing.reject(&id);
                }
            }
            #[cfg(target_os = "linux")]
            Action::EnableInput => self.host.input.setup(),
            #[cfg(not(target_os = "linux"))]
            Action::EnableInput => crate::setup_window::open(),
            Action::ToggleHost => {
                if let Some(supervisor) = &self.host.supervisor {
                    supervisor.set_wanted(!supervisor.wanted());
                }
            }
            #[cfg(not(target_os = "linux"))]
            Action::CursorScale(_) => {}
            #[cfg(target_os = "linux")]
            Action::CursorScale(scale) => {
                if let Err(error) = self.cursor.select(scale) {
                    log::warn!("Cannot save host cursor size: {error}");
                    tokio::spawn(async move { crate::desktop::notify("Could not save host cursor size", &error.to_string()).await });
                }
            }
            Action::HostWebPage => open(&format!("https://localhost:{}", self.status.map.sunshine_base + 1)),
            Action::CopyHostPassword => {
                let password = self.host.state.password.clone();
                tokio::spawn(async move {
                    let message = if crate::desktop::copy_text(&password).await.is_ok() {
                        "Password copied. Paste it into the host's web login."
                    } else {
                        "Could not copy the password. Check that your desktop clipboard manager is running."
                    };
                    crate::desktop::notify("Meteor-Vibepollo web login", message).await;
                });
            }
            Action::HostFolder => {
                if let Some(supervisor) = &self.host.supervisor {
                    open(&supervisor.instance.appdata().to_string_lossy());
                }
            }
            Action::UseHost(choice) => self.host.switch(choice),
            Action::DownloadHost => self.host.download_and_switch(),
            Action::CancelHostDownload => self.host.download.cancel.store(true, Ordering::Relaxed),
            Action::ToggleDepth => {
                if let Some(depth) = &self.depth {
                    depth.set_enabled(!depth.enabled());
                }
            }
            Action::DepthSettings => crate::depth_window::open(),
            Action::AudioOutput(output) => {
                if let Err(error) = crate::audio::set(output) {
                    log::warn!("Cannot save the audio choice: {error}");
                    tokio::spawn(async move { crate::desktop::notify("Could not save where audio plays", &error.to_string()).await });
                }
            }
            Action::ToggleMicMute => {
                if let Some(mic) = &self.mic {
                    mic.muted.fetch_xor(true, Ordering::Relaxed);
                }
            }
            #[cfg(windows)]
            Action::MicDefaultInput => run_detached("control.exe", &["mmsys.cpl,,1"]),
            #[cfg(not(windows))]
            Action::MicDefaultInput => {
                #[cfg(target_os = "linux")]
                if let Some(mic) = &self.mic {
                    mic.set_default_input();
                }
            }
            Action::ToggleAutostart => {
                let on = !crate::desktop::autostart_enabled();
                match crate::desktop::set_autostart(on) {
                    Ok(()) => log::info!("Autostart {}", if on { "on" } else { "off" }),
                    Err(err) => log::warn!("Can't change autostart: {err}"),
                }
            }
            Action::Quit => crate::quit(),
            #[cfg(windows)]
            Action::PairHeadset => {
                if let Some(script) = beside_exe("Pair-Headset.ps1") {
                    run_detached("powershell.exe", &["-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", &script]);
                }
            }
            #[cfg(windows)]
            Action::InstallVirtualDisplay => {
                if let Some(script) = virtual_display_script() {
                    // Start-Process -Verb RunAs asks for administrator approval.
                    let command = format!("Start-Process powershell.exe -Verb RunAs -ArgumentList \"-NoProfile -ExecutionPolicy Bypass -File '{}'\"", script.replace('\'', "''"));
                    run_detached("powershell.exe", &["-NoProfile", "-Command", &command]);
                }
            }
            #[cfg(windows)]
            Action::HostLogin => run_detached("notepad.exe", &[&crate::host::state_path().to_string_lossy()]),
            #[cfg(windows)]
            Action::PcvrGames => crate::pcvr_window::open(),
            #[cfg(windows)]
            Action::EnablePcvr => {
                let root = crate::xr_windows::root();
                match crate::xr_windows::command(&["--xr-windows-enable".into(), "--root".into(), root.to_string_lossy().into_owned()]) {
                    Ok(_) => crate::restart(),
                    Err(error) => log::warn!("PCVR setup: {error}"),
                }
            }
            #[cfg(windows)]
            Action::InstallCable => crate::desktop::open_web_url("https://vb-audio.com/Cable/index.htm".into()),
            #[cfg(windows)]
            Action::TaskbarSettings => crate::desktop::open_web_url("ms-settings:taskbar".into()),
        }
    }
}

/// A script installed next to nightfall-meteor.exe.
#[cfg(windows)]
fn beside_exe(name: &str) -> Option<String> {
    let path = std::env::current_exe().ok()?.parent()?.join(name);
    path.is_file().then(|| path.to_string_lossy().into_owned())
}

#[cfg(windows)]
fn virtual_display_script() -> Option<String> {
    beside_exe("Install-VirtualDisplay.ps1")
}

/// Starts a helper without a console window.
#[cfg(windows)]
fn run_detached(program: &str, args: &[&str]) {
    use std::os::windows::process::CommandExt;
    let result = std::process::Command::new(program)
        .args(args)
        .creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
    if let Err(error) = result {
        log::warn!("Can't run {program}: {error}");
    }
}

/// "Depth 29.8 fps · VDA — RTX 3090", or what it's waiting for.
fn depth_readout(depth: &Depth) -> String {
    let s = &depth.stats;
    let rate_x10 = s.rate_x10.load(Ordering::Relaxed);
    if !depth.enabled() {
        "AI 3D: host depth is off".to_string()
    } else if rate_x10 == 0 {
        format!("AI 3D: idle · {}", depth.selection_label())
    } else {
        format!("AI 3D: {:.1} fps · {}", f64::from(rate_x10) / 10.0, depth.selection_label())
    }
}

/// "Downloading VDA: 210 of 640 MB" while a model download runs.
pub fn download_progress(depth: &Depth) -> Option<String> {
    (depth.download.state() == crate::download::State::Running).then(|| {
        let mb = |a: &std::sync::atomic::AtomicU64| a.load(Ordering::Relaxed) / 1_000_000;
        format!("Downloading depth model: {} of {} MB", mb(&depth.download.done), mb(&depth.download.total))
    })
}

pub fn open(target: &str) {
    if target.starts_with("https://") || target.starts_with("http://") {
        crate::desktop::open_web_url(target.to_string());
        return;
    }
    let opener = if cfg!(windows) { "explorer" } else if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    if let Err(err) = std::process::Command::new(opener).arg(target).spawn() {
        log::warn!("Can't open {target}: {err}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    fn titles(entries: &[Entry]) -> Vec<String> {
        entries
            .iter()
            .filter_map(|entry| match entry {
                Entry::Item { title, .. } | Entry::Choice { title, .. } | Entry::Submenu { title, .. } => Some(title.clone()),
                Entry::Label(_) | Entry::Separator | Entry::Options { .. } => None,
            })
            .collect()
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn the_cursor_choice_ticks_its_scale() {
        let cursor = crate::host_cursor::Control::new(3, None);
        let options = ["Unchanged", "2×", "3×", "4×"];
        let entry = Entry::Choice {
            title: String::new(),
            enabled: cursor.available(),
            options: options.iter().zip(1..).map(|(n, s)| ((*n).to_string(), Action::CursorScale(s))).collect(),
            selected: (cursor.scale() - 1) as usize,
            note: None,
        };
        let Entry::Choice { options, selected, enabled, .. } = entry else { unreachable!() };
        assert_eq!(options[selected].1, Action::CursorScale(3));
        assert!(!enabled, "Only the bundled host can scale its cursor");
        assert!(titles(&[item("A", Action::Quit), label("x"), Entry::Separator]) == ["A"]);
    }
}
