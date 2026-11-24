//! The Setup window (Linux and Windows): the built-in host, PCVR, Steam launch
//! options (Linux) and VDA in one place, with Install All for a single click.
//! On Windows it also shows what the installer set up — VB-CABLE, the virtual
//! display driver, the firewall rules — and fixes what's missing.
//!
//! It's its own process (`nightfall-meteor --setup`): a window toolkit wants the
//! main thread, and a window that can't open or crashes leaves Meteor running.
//! The tray starts it, and restarts Meteor when it exits with RESTART_CODE.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use eframe::egui;
use serde::Deserialize;

use crate::download::{Download, LICENCE_URL};
use crate::host::{self, Choice};

/// The window's exit code when Meteor has to restart to use its changes.
pub const RESTART_CODE: i32 = 10;

static OPEN: AtomicBool = AtomicBool::new(false);

/// Opens the window unless it's open already. Call from the tokio runtime.
pub fn open() {
    if OPEN.swap(true, Ordering::Relaxed) {
        return;
    }
    tokio::spawn(async {
        let status = tokio::task::spawn_blocking(|| {
            let mut command = Command::new(std::env::current_exe()?);
            command.arg("--setup");
            no_console(&mut command);
            // Model downloads run in Meteor, so its menu sees them too.
            if let Some(socket) = crate::control::path() {
                command.arg(socket);
            }
            command.stdin(Stdio::null()).status()
        })
        .await;
        OPEN.store(false, Ordering::Relaxed);
        match status {
            Ok(Ok(status)) if status.code() == Some(RESTART_CODE) => crate::restart(),
            Ok(Ok(status)) if status.success() => {}
            Ok(Ok(status)) => {
                log::warn!("Setup window exited with {status}");
                crate::desktop::notify("Setup window closed unexpectedly", "Open Setup from Meteor's menu to try again.").await;
            }
            Ok(Err(error)) => log::warn!("Can't open the Setup window: {error}"),
            Err(error) => log::warn!("Setup window task failed: {error}"),
        }
    });
}

/// Windows: start a window process without a console flashing up (debug builds have one).
pub(crate) fn no_console(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    let _ = command;
}

/// `--setup [control socket]`: shows the window. Returns the exit code.
pub fn run(socket: Option<PathBuf>) -> i32 {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).try_init();
    let shared = Arc::new(Shared { socket, ..Shared::default() });
    let runtime = tokio::runtime::Handle::current();
    let refresh = shared.clone();
    std::thread::spawn(move || refresh.refresh(true));
    let models = shared.clone();
    // Downloads started from here run in Meteor: follow their progress.
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_millis(1500));
            models.refresh_models();
        }
    });
    let rgba = crate::icon::nightfall_rgba(128);
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Nightfall Meteor Setup")
            .with_app_id("nightfall-meteor-setup")
            .with_inner_size([660.0, 520.0])
            .with_min_inner_size([520.0, 360.0])
            .with_icon(egui::IconData { rgba, width: 128, height: 128 }),
        ..Default::default()
    };
    let window = Window { shared: shared.clone(), runtime, frames: 0, steam_method: None };
    let Some(font) = system_font() else {
        eprintln!("Can't open the Setup window: no system font found");
        return 1;
    };
    let creator = Box::new(move |context: &eframe::CreationContext<'_>| -> Result<Box<dyn eframe::App>, Box<dyn std::error::Error + Send + Sync>> {
        context.egui_ctx.set_fonts(fonts_from(font));
        Ok(Box::new(window))
    });
    match eframe::run_native("Nightfall Meteor Setup", options, creator) {
        Ok(()) if shared.restart.load(Ordering::Relaxed) => RESTART_CODE,
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Can't open the Setup window: {error}");
            1
        }
    }
}

/// Segoe UI, the font Windows' own apps use.
#[cfg(windows)]
pub(crate) fn system_font() -> Option<Vec<u8>> {
    let fonts = PathBuf::from(std::env::var_os("WINDIR").unwrap_or_else(|| "C:\\Windows".into())).join("Fonts");
    ["segoeui.ttf", "arial.ttf", "tahoma.ttf"].iter().find_map(|name| std::fs::read(fonts.join(name)).ok())
}

/// A sans-serif font from the system, as the desktop's own apps would pick it.
#[cfg(not(windows))]
pub(crate) fn system_font() -> Option<Vec<u8>> {
    let asked = Command::new("fc-match")
        .args(["-f", "%{file}", "sans:style=Regular:fontformat=TrueType"])
        .env_remove("LD_LIBRARY_PATH")
        .output()
        .ok()
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(PathBuf::from);
    const COMMON: [&str; 4] = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
    ];
    asked.into_iter().chain(COMMON.iter().map(PathBuf::from)).find_map(|path| std::fs::read(path).ok())
}

pub(crate) fn fonts_from(font: Vec<u8>) -> egui::FontDefinitions {
    let mut fonts = egui::FontDefinitions::empty();
    fonts.font_data.insert("system".to_owned(), Arc::new(egui::FontData::from_owned(font)));
    for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
        fonts.families.insert(family, vec!["system".to_owned()]);
    }
    fonts
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Row {
    Pcvr,
    Host,
    Steam,
    Vda,
    Models,
    #[cfg(windows)]
    Cable,
    #[cfg(windows)]
    Display,
    #[cfg(windows)]
    Firewall,
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
#[cfg_attr(windows, allow(dead_code))] // Steam launch options are Linux's
enum SteamMethod {
    #[default]
    LaunchOptions,
    Automatic,
}
#[cfg_attr(windows, allow(dead_code))]
impl SteamMethod {
    fn selected(automatic: bool) -> Self {
        if automatic {Self::Automatic} else {Self::LaunchOptions}
    }
    fn label(self) -> &'static str {
        match self {
            Self::LaunchOptions => "Steam launch options (Default)",
            Self::Automatic => "Automatic XR (Experimental)",
        }
    }
}

/// What each row reads from disk.
#[derive(Clone, Default, Debug)]
struct Status {
    /// None while the first look is still running.
    loaded: bool,
    pcvr_in_build: bool,
    pcvr_ready: bool,
    host_chosen: bool,
    host_available: bool,
    /// Another host is running here. One that's only installed doesn't count:
    /// nothing would answer the headset if Install All left it at that.
    other_host: bool,
    steam: Option<SteamStatus>,
    /// None: this GPU can't use TensorRT, so VDA isn't offered here.
    vda: Option<VdaStatus>,
    /// From the running Meteor; empty when Setup runs without one.
    models: ModelStatus,
    #[cfg(windows)]
    windows: WindowsStatus,
}

/// What Windows' installer set up, which Meteor depends on.
#[cfg(windows)]
#[derive(Clone, Default, Debug)]
struct WindowsStatus {
    /// VB-CABLE, which the headset microphone plays into.
    cable: bool,
    /// The virtual display driver, for virtual monitors.
    display_driver: bool,
    display_script: bool,
    /// Why the Quest can't get through, when it can't.
    firewall: Option<String>,
}

#[cfg(windows)]
fn windows_status() -> WindowsStatus {
    let beside = |name: &str| std::env::current_exe().ok().and_then(|e| e.parent().map(|p| p.join(name))).is_some_and(|p| p.is_file());
    WindowsStatus {
        cable: vb_cable_installed(),
        display_driver: crate::sunshine_vdd_probe(),
        display_script: beside("Install-VirtualDisplay.ps1"),
        firewall: match crate::firewall::check(&[]) {
            crate::firewall::Status::Windows { reason } => Some(reason),
            _ => None,
        },
    }
}

/// A VB-CABLE playback device is present.
#[cfg(windows)]
fn vb_cable_installed() -> bool {
    use wasapi::{DeviceEnumerator, Direction};
    let _ = wasapi::initialize_mta();
    let Ok(devices) = DeviceEnumerator::new().and_then(|e| e.get_device_collection(&Direction::Render)) else { return false };
    (&devices).into_iter().filter_map(Result::ok).any(|device| {
        device.get_friendlyname().is_ok_and(|name| name.to_ascii_lowercase().contains("cable") && name.to_ascii_lowercase().contains("input"))
    })
}

/// Depth models Meteor can download for this PC's GPUs.
#[derive(Clone, Debug, Default)]
struct ModelStatus {
    /// (id, name, bytes)
    offers: Vec<(String, String, u64)>,
    /// (done, total) bytes while Meteor downloads a model.
    downloading: Option<(u64, u64)>,
    error: Option<String>,
}

fn model_status(value: &serde_json::Value) -> ModelStatus {
    let download = &value["download"];
    ModelStatus {
        offers: value["vulkan_offers"].as_array().into_iter().flatten()
            .filter_map(|offer| Some((offer["id"].as_str()?.to_string(), offer["label"].as_str()?.to_string(), offer["bytes"].as_u64()?)))
            .collect(),
        downloading: download["running"].as_bool().unwrap_or(false)
            .then(|| (download["done"].as_u64().unwrap_or(0), download["total"].as_u64().unwrap_or(0))),
        error: download["error"].as_str().map(str::to_string),
    }
}

#[derive(Clone, Debug)]
struct VdaStatus {
    ready: bool,
    bytes: u64,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
struct SteamStatus {
    total: u32,
    ready: u32,
    error: Option<String>,
    game_running: bool,
    automatic_available: bool,
    automatic_selected: bool,
    automatic_configured: bool,
    steam_restart_required: bool,
}

#[derive(Default)]
struct Shared {
    /// The running Meteor's control socket (control.rs).
    socket: Option<PathBuf>,
    status: Mutex<Status>,
    /// The row being worked on and what it's doing.
    working: Mutex<Option<(Row, String)>>,
    errors: Mutex<Vec<(Row, String)>>,
    restart: AtomicBool,
    host_download: Download,
    vda_download: Download,
}

impl Shared {
    #[cfg(windows)]
    fn refresh(&self, _with_steam: bool) {
        let config = crate::config::load();
        let state = host::load_state();
        let models = config.models_dir.clone().unwrap_or_else(crate::config::default_models_dir);
        let root = crate::xr_windows::root();
        let status = Status {
            loaded: true,
            // The installer prepares PCVR (Setup-Meteor.ps1 -EnablePCVR); this only turns it on.
            pcvr_in_build: root.join("xr-windows.json").is_file() || root.join("steamvr-runtime").is_dir(),
            pcvr_ready: config.xr.enabled,
            host_chosen: state.choice == Choice::Bundled,
            host_available: host::binary(&config).is_some(),
            other_host: !host::other_hosts(None).is_empty(),
            steam: None,
            vda: crate::download::plan(&models).ok().map(|plan| VdaStatus { ready: plan.is_empty(), bytes: plan.bytes() }),
            models: self.status.lock().unwrap().models.clone(),
            windows: windows_status(),
        };
        *self.status.lock().unwrap() = status;
        self.refresh_models();
    }

    #[cfg(not(windows))]
    fn refresh(&self, with_steam: bool) {
        let config = crate::config::load();
        let root = config.xr.runtime_root();
        let state = host::load_state();
        let models = config.models_dir.clone().unwrap_or_else(crate::config::default_models_dir);
        let mut steam = if with_steam {
            steam_tool(&root).map(|tool| steam_command(&tool, "status"))
        } else {
            self.status.lock().unwrap().steam.clone()
        };
        if let Some(steam)=steam.as_mut() {
            steam.automatic_selected=config.xr.automatic_launch;
            let tool=root.join("tools/meteor_steam_environment.py");
            steam.automatic_available=tool.is_file() && std::fs::read(root.join("xr-runtime/manifest.json")).ok()
                .and_then(|bytes|serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                .is_some_and(|value|value["ipc_socket"]=="nightfall-meteor/monado_comp_ipc");
            if steam.automatic_available {
                if let Ok(output)=Command::new("/usr/bin/python3").arg(tool).arg("status").stdin(Stdio::null()).output() {
                    if let Ok(value)=serde_json::from_slice::<serde_json::Value>(&output.stdout) {
                        steam.automatic_configured=config.xr.automatic_launch && value["configured"]==true;
                        steam.steam_restart_required=value["steam_restart_required"]==true;
                    }
                }
            }
        }
        let status = Status {
            loaded: true,
            pcvr_in_build: crate::xr_setup::bundle().is_ok(),
            pcvr_ready: config.xr.enabled && root.join("xr-runtime/manifest.json").is_file() && steam_tool(&root).is_some(),
            host_chosen: state.choice == Choice::Bundled,
            host_available: host::binary(&config).is_some() || host::RELEASE.is_some(),
            other_host: !host::other_hosts(None).is_empty(),
            steam,
            vda: crate::download::plan(&models).ok().map(|plan| VdaStatus { ready: plan.is_empty(), bytes: plan.bytes() }),
            models: self.status.lock().unwrap().models.clone(),
        };
        *self.status.lock().unwrap() = status;
        self.refresh_models();
    }

    fn refresh_models(&self) {
        let Some(socket) = &self.socket else { return };
        if let Ok(value) = crate::control::send(socket, &crate::control::Request::Depth) {
            self.status.lock().unwrap().models = model_status(&value);
        }
    }

    /// Asks Meteor to download or remove a model.
    fn depth_request(&self, row: Row, request: crate::control::Request) {
        let result = match &self.socket {
            Some(socket) => crate::control::send(socket, &request).map(|_| ()).map_err(|error| error.to_string()),
            None => Err("Open Setup from Meteor's menu to install models".to_string()),
        };
        if let Err(error) = result {
            self.errors.lock().unwrap().push((row, error));
        }
        self.refresh(false);
    }

    fn begin(&self, row: Row, text: &str) {
        self.errors.lock().unwrap().retain(|(r, _)| *r != row);
        *self.working.lock().unwrap() = Some((row, text.into()));
    }

    fn finish(&self, row: Row, result: Result<(), String>) {
        if let Err(error) = result {
            log::warn!("Setup {row:?}: {error}");
            self.errors.lock().unwrap().push((row, error));
        }
        self.refresh(true);
        *self.working.lock().unwrap() = None;
    }

    fn error(&self, row: Row) -> Option<String> {
        self.errors.lock().unwrap().iter().find(|(r, _)| *r == row).map(|(_, e)| e.clone())
    }

    #[cfg(windows)]
    fn install_pcvr(&self, _runtime: &tokio::runtime::Handle) {
        self.begin(Row::Pcvr, "Turning on");
        let root = crate::xr_windows::root();
        let result = crate::xr_windows::command(&["--xr-windows-enable".into(), "--root".into(), root.to_string_lossy().into_owned()])
            .map(|_| ())
            .map_err(|error| error.to_string());
        if result.is_ok() {
            self.restart.store(true, Ordering::Relaxed);
        }
        self.finish(Row::Pcvr, result);
    }

    #[cfg(windows)]
    fn turn_off_pcvr(&self) {
        self.begin(Row::Pcvr, "Turning off");
        let result = set_xr_enabled(false).map_err(|error| error.to_string());
        if result.is_ok() {
            self.restart.store(true, Ordering::Relaxed);
        }
        self.finish(Row::Pcvr, result);
    }

    /// Runs one of the installer's scripts with administrator approval and waits for it.
    #[cfg(windows)]
    fn elevated(&self, row: Row, text: &str, script: &str) {
        self.begin(row, text);
        let result = (|| {
            let path = std::env::current_exe().map_err(|e| e.to_string())?.parent().ok_or("No install folder")?.join(script);
            if !path.is_file() {
                return Err(format!("{script} is missing beside Meteor; reinstall Meteor"));
            }
            let quoted = path.display().to_string().replace('\'', "''");
            let command = format!(
                "$p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden \
                 -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"{quoted}\"'; exit $p.ExitCode"
            );
            let mut powershell = Command::new("powershell.exe");
            no_console(&mut powershell);
            let status = powershell.args(["-NoProfile", "-Command", &command]).stdin(Stdio::null()).status().map_err(|e| e.to_string())?;
            if status.success() { Ok(()) } else { Err(format!("{script} didn't finish ({status})")) }
        })();
        self.finish(row, result);
    }

    #[cfg(not(windows))]
    fn install_pcvr(&self, runtime: &tokio::runtime::Handle) {
        self.begin(Row::Pcvr, "Installing");
        let result = runtime
            .block_on(async { crate::xr_setup::enable_from(&crate::xr_setup::bundle()?, &crate::config::config_path()).await })
            .map_err(|error| error.to_string());
        if result.is_ok() {
            self.restart.store(true, Ordering::Relaxed);
        }
        self.finish(Row::Pcvr, result);
    }

    #[cfg(not(windows))]
    fn turn_off_pcvr(&self) {
        self.begin(Row::Pcvr, "Turning off");
        let result = crate::xr_setup::disable(&crate::config::config_path()).map_err(|error| error.to_string());
        if result.is_ok() {
            self.restart.store(true, Ordering::Relaxed);
        }
        self.finish(Row::Pcvr, result);
    }

    fn use_host(&self, choice: Choice) {
        self.begin(Row::Host, if choice == Choice::Bundled { "Getting the host ready" } else { "Switching" });
        let config = crate::config::load();
        let result = (|| {
            if choice == Choice::Bundled && host::binary(&config).is_none() {
                let release = host::RELEASE.as_ref().ok_or("This build has no host to download")?;
                host::Install::run(&self.host_download, release)?;
            }
            let mut state = host::load_state();
            state.choice = choice;
            host::save_state(&state)
        })();
        if result.is_ok() {
            self.restart.store(true, Ordering::Relaxed);
        }
        self.finish(Row::Host, result);
    }

    #[cfg(not(windows))]
    fn steam_options(&self, action: &'static str) {
        let config=crate::config::load();
        let root=config.xr.runtime_root();
        let automatic=matches!(action,"automatic_install"|"automatic_remove");
        self.begin(Row::Steam,if automatic {"Updating experimental XR setup"} else {"Closing Steam and updating its games"});
        let result=(|| -> Result<(),String> {
            if automatic {
                apply_automatic_setup(&root,action=="automatic_install")?;
                self.restart.store(true,Ordering::Relaxed);
                return Ok(());
            }
            // Choosing the default method restores automatic launcher changes
            // before updating the per-game wrappers. Apply is explicit; merely
            // browsing the selector never changes runtime or Steam settings.
            if action=="launch_options" && config.xr.automatic_launch {
                let tool=steam_tool(&root).ok_or_else(||"Install PCVR first".to_string())?;
                let current=steam_command(&tool,"status");
                if let Some(error)=current.error {return Err(error);}
                if current.game_running {return Err("Close the running game before changing the XR launch method".into());}
                apply_automatic_setup(&root,false)?;
                self.restart.store(true,Ordering::Relaxed);
                if current.total==0 {return Ok(());}
            }
            let tool=steam_tool(&root).ok_or_else(||"Install PCVR first".to_string())?;
            let reply=steam_command(&tool,if action=="launch_options" {"add"} else {action});
            reply.error.map_or(Ok(()),Err)
        })();
        self.finish(Row::Steam,result);
    }

    fn install_vda(&self) {
        self.begin(Row::Vda, "Downloading");
        let config = crate::config::load();
        let models = config.models_dir.clone().unwrap_or_else(crate::config::default_models_dir);
        let result = crate::download::plan(&models)
            .and_then(|plan| if plan.is_empty() { Ok(()) } else { self.vda_download.run(&plan) })
            .and_then(|()| select_vda().map_err(|error| error.to_string()));
        if result.is_ok() {
            self.restart.store(true, Ordering::Relaxed);
        }
        self.finish(Row::Vda, result);
    }

    /// Everything this PC can use, in the order that needs: PCVR before the
    /// launch options that point at it. A failure doesn't stop the other rows.
    fn install_all(&self, runtime: &tokio::runtime::Handle) {
        let status = self.status.lock().unwrap().clone();
        for row in install_all_rows(&status) {
            match row {
                Row::Pcvr => self.install_pcvr(runtime),
                Row::Host => self.use_host(Choice::Bundled),
                #[cfg(not(windows))]
                Row::Steam => self.steam_options("launch_options"),
                Row::Vda => self.install_vda(),
                _ => {}
            }
        }
    }
}

/// What Install All does here. It never replaces a host the user already has,
/// and leaves out what's already done. Steam is decided after PCVR installs.
fn install_all_rows(status: &Status) -> Vec<Row> {
    let mut rows = Vec::new();
    if status.pcvr_in_build && !status.pcvr_ready {
        rows.push(Row::Pcvr);
    }
    if status.host_available && !status.host_chosen && !status.other_host {
        rows.push(Row::Host);
    }
    // Windows games are added to PCVR by the installer, not by Steam launch options.
    let steam_done = status.steam.as_ref().is_some_and(|s| s.error.is_none() && (s.automatic_configured || (s.total > 0 && s.ready == s.total)));
    if cfg!(not(windows)) && status.pcvr_in_build && !steam_done {
        rows.push(Row::Steam);
    }
    if status.vda.as_ref().is_some_and(|vda| !vda.ready) {
        rows.push(Row::Vda);
    }
    rows
}

/// Turns PCVR on or off in meteor.toml.
#[cfg(windows)]
fn set_xr_enabled(on: bool) -> std::io::Result<()> {
    let path = crate::config::config_path();
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let mut document: toml_edit::DocumentMut = text.parse().map_err(std::io::Error::other)?;
    document["xr"]["enabled"] = toml_edit::value(on);
    std::fs::write(path, document.to_string())
}

#[cfg(not(windows))]
fn apply_automatic_setup(root: &std::path::Path, install: bool) -> Result<(),String> {
    let output=Command::new("/usr/bin/python3").arg(root.join("tools/meteor_steam_environment.py"))
        .arg(if install {"install"}else{"remove"}).arg("--root").arg(root)
        .stdin(Stdio::null()).output().map_err(|error|error.to_string())?;
    if !output.status.success() {
        let value=serde_json::from_slice::<serde_json::Value>(&output.stdout).unwrap_or_default();
        return Err(value["error"].as_str().unwrap_or("Steam launcher could not be changed; externally edited entries and backups were preserved").to_string());
    }
    crate::xr_setup::set_automatic(install).map_err(|error|error.to_string())
}

#[cfg(not(windows))]
fn steam_tool(root: &std::path::Path) -> Option<PathBuf> {
    let tool = root.join("tools/meteor_steam_options.py");
    tool.is_file().then_some(tool)
}

#[cfg(not(windows))]
fn steam_command(tool: &std::path::Path, action: &str) -> SteamStatus {
    let output = Command::new("/usr/bin/python3").arg(tool).arg(action).stdin(Stdio::null()).output();
    match output {
        Ok(output) => serde_json::from_slice(&output.stdout).unwrap_or_else(|_| SteamStatus {
            error: Some(String::from_utf8_lossy(&output.stderr).chars().take(300).collect()),
            ..Default::default()
        }),
        Err(error) => SteamStatus { error: Some(error.to_string()), ..Default::default() },
    }
}

/// Makes VDA the depth model on the next start.
fn select_vda() -> std::io::Result<()> {
    let path = crate::config::state_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(error),
    };
    let mut document: toml_edit::DocumentMut = text.parse().map_err(std::io::Error::other)?;
    document["model"] = toml_edit::value(crate::vda::ID);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, document.to_string())
}

fn gigabytes(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

fn progress(download: &Download) -> Option<f32> {
    let total = download.total.load(Ordering::Relaxed);
    (total > 0).then(|| download.done.load(Ordering::Relaxed) as f32 / total as f32)
}

/// What Install All's button should say about NVIDIA's licence and size.
fn install_all_note(status: &Status) -> Option<String> {
    let vda = status.vda.as_ref().filter(|vda| !vda.ready)?;
    Some(format!("Includes NVIDIA TensorRT ({}). By clicking you accept NVIDIA's licence:", gigabytes(vda.bytes)))
}

struct Window {
    shared: Arc<Shared>,
    runtime: tokio::runtime::Handle,
    frames: u32,
    #[cfg_attr(windows, allow(dead_code))]
    steam_method: Option<SteamMethod>,
}

impl Window {
    fn spawn(&self, task: impl FnOnce(&Shared, &tokio::runtime::Handle) + Send + 'static) {
        let shared = self.shared.clone();
        let runtime = self.runtime.clone();
        std::thread::spawn(move || task(&shared, &runtime));
    }

    /// One row: name, what it's for, its state, and its buttons.
    #[allow(clippy::too_many_arguments)]
    fn row(&self, ui: &mut egui::Ui, row: Row, name: &str, about: &str, state: &str, busy: bool, buttons: impl FnOnce(&mut egui::Ui)) {
        let working = self.shared.working.lock().unwrap().clone().filter(|(r, _)| *r == row);
        ui.horizontal(|ui| {
            ui.vertical(|ui| {
                ui.strong(name);
                ui.small(about);
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if working.is_none() {
                    ui.add_enabled_ui(!busy, buttons);
                }
                match &working {
                    Some((_, text)) => {
                        ui.label(text);
                        ui.spinner();
                    }
                    None => {
                        ui.label(state);
                    }
                }
            });
        });
        let download = match row {
            Row::Host => Some(&self.shared.host_download),
            Row::Vda => Some(&self.shared.vda_download),
            _ => None,
        };
        if working.is_some()
            && let Some(download) = download
            && let Some(fraction) = progress(download)
        {
            ui.horizontal(|ui| {
                ui.add(egui::ProgressBar::new(fraction).show_percentage().desired_width(ui.available_width() - 80.0));
                if ui.small_button("Cancel").clicked() {
                    download.cancel.store(true, Ordering::Relaxed);
                }
            });
        }
        if let Some(error) = self.shared.error(row) {
            ui.colored_label(egui::Color32::from_rgb(235, 110, 100), error);
        }
        ui.separator();
    }
}

impl Window {
    /// METEOR_SETUP_SCREENSHOT=<file.png> saves the window once it has loaded,
    /// then closes it, so a test can look at it without a person.
    fn screenshot_for_tests(&mut self, ctx: &egui::Context, busy: bool) {
        let Some(path) = std::env::var_os("METEOR_SETUP_SCREENSHOT") else { return };
        ctx.request_repaint_after(Duration::from_millis(100));
        self.frames += 1;
        if !busy && self.frames == 5 {
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::UserData::default()));
        }
        let image = ctx.input(|i| i.events.iter().find_map(|event| match event {
            egui::Event::Screenshot { image, .. } => Some(image.clone()),
            _ => None,
        }));
        if let Some(image) = image {
            if let Err(error) = save_png(&PathBuf::from(path), &image) {
                eprintln!("Can't save the screenshot: {error}");
            }
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }
}

pub(crate) fn save_png(path: &std::path::Path, image: &egui::ColorImage) -> Result<(), Box<dyn std::error::Error>> {
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut encoder = png::Encoder::new(file, image.size[0] as u32, image.size[1] as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let bytes: Vec<u8> = image.pixels.iter().flat_map(|p| p.to_array()).collect();
    encoder.write_header()?.write_image_data(&bytes)?;
    Ok(())
}

impl eframe::App for Window {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let status = self.shared.status.lock().unwrap().clone();
        let busy = self.shared.working.lock().unwrap().is_some() || !status.loaded;
        // Closing mid-download would leave a half-finished step behind.
        if ctx.input(|i| i.viewport().close_requested()) && busy {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
        }
        if busy {
            ctx.request_repaint_after(Duration::from_millis(150));
        }
        self.screenshot_for_tests(ctx, busy);
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.add_space(4.0);
            ui.heading("Set up Nightfall Meteor");
            ui.add_space(8.0);
            let rows = install_all_rows(&status);
            let label = if rows.is_empty() && status.loaded { "All set" } else { "Install All" };
            let size = egui::vec2(ui.available_width(), 42.0);
            let clicked = ui.add_enabled_ui(!busy && !rows.is_empty(), |ui| {
                ui.add_sized(size, egui::Button::new(egui::RichText::new(label).size(18.0))).clicked()
            }).inner;
            if clicked {
                self.spawn(|shared, runtime| shared.install_all(runtime));
            }
            if rows.contains(&Row::Steam) {
                ui.small("Closes and reopens Steam to add the launch options.");
            }
            if let Some(note) = install_all_note(&status) {
                ui.horizontal_wrapped(|ui| {
                    ui.small(note);
                    ui.hyperlink_to(egui::RichText::new("read it").small(), LICENCE_URL);
                });
            }
            ui.add_space(8.0);
            ui.separator();

            #[cfg(windows)]
            if !status.pcvr_in_build && status.loaded {
                self.row(ui, Row::Pcvr, "PCVR", "Play your Steam VR games in the headset", "Not set up", busy, |ui| {
                    ui.small("Reinstall Meteor with \"Set up PCVR\" ticked");
                });
            }
            if status.pcvr_in_build {
                self.row(ui, Row::Pcvr, "PCVR", "Play your Steam VR games in the headset", if status.pcvr_ready { "Installed" } else { "Not installed" }, busy, |ui| {
                    if status.pcvr_ready {
                        if ui.button("Turn off").clicked() {
                            self.spawn(|shared, _| shared.turn_off_pcvr());
                        }
                    } else if ui.button("Install").clicked() {
                        self.spawn(|shared, runtime| shared.install_pcvr(runtime));
                    }
                });
            }

            let host_state = if status.host_chosen {
                "In use"
            } else if status.other_host {
                "Your own host is running"
            } else {
                "Not in use"
            };
            self.row(ui, Row::Host, "Built-in host", "Streams your desktop, with nothing else to install", host_state, busy, |ui| {
                if status.host_chosen {
                    if ui.button("Stop using").clicked() {
                        self.spawn(|shared, _| shared.use_host(Choice::External));
                    }
                } else if ui.add_enabled(status.host_available, egui::Button::new("Use")).clicked() {
                    self.spawn(|shared, _| shared.use_host(Choice::Bundled));
                }
            });

            #[cfg(windows)]
            self.windows_rows(ui, &status, busy);

            #[cfg(not(windows))]
            if status.pcvr_in_build {
                let steam_state = match &status.steam {
                    None => "Needs PCVR".to_string(),
                    Some(steam) if steam.total == 0 => "No VR games found".to_string(),
                    Some(steam) => format!("{} of {} games", steam.ready, steam.total),
                };
                let steam = status.steam.clone().unwrap_or_default();
                let method=self.steam_method.get_or_insert_with(||SteamMethod::selected(steam.automatic_selected));
                ui.add_enabled_ui(!busy,|ui| { ui.horizontal(|ui| {
                    ui.label("Steam XR method:");
                    egui::ComboBox::from_id_salt("steam_xr_method").selected_text(method.label()).show_ui(ui,|ui| {
                        ui.selectable_value(method,SteamMethod::LaunchOptions,SteamMethod::LaunchOptions.label());
                        ui.add_enabled_ui(steam.automatic_available,|ui| {
                            ui.selectable_value(method,SteamMethod::Automatic,SteamMethod::Automatic.label());
                        }).response.on_hover_text("Experimental automatic launch requires the updated PCVR runtime and native Steam.");
                    });
                }); });
                let method=*method;
                match method {
                    SteamMethod::LaunchOptions => {
                        self.row(ui,Row::Steam,"Steam launch options","Default method: update launch options for your VR games",&steam_state,busy,|ui| {
                            if ui.add_enabled(status.steam.is_some() && (steam.total>0 || steam.automatic_selected),egui::Button::new("Update launch options")).clicked() {
                                self.spawn(|shared,_|shared.steam_options("launch_options"));
                            }
                            if !steam.automatic_selected && steam.ready>0 && ui.button("Remove").clicked() {
                                self.spawn(|shared,_|shared.steam_options("remove"));
                            }
                        });
                        ui.small("Closes and reopens Steam. Switching back restores the experimental launcher changes; game-specific options are kept.");
                    }
                    SteamMethod::Automatic => {
                        let state=if steam.automatic_configured {
                            if steam.steam_restart_required {"Restart Steam to apply"} else {"Enabled"}
                        } else {"Not enabled"};
                        self.row(ui,Row::Steam,"Automatic XR (Experimental)","Set up Steam once instead of adding Meteor options to each game",state,busy,|ui| {
                            if !steam.automatic_configured && ui.add_enabled(steam.automatic_available,egui::Button::new("Enable experimental method")).clicked() {
                                self.spawn(|shared,_|shared.steam_options("automatic_install"));
                            }
                        });
                        ui.small("Restarts Meteor when you close Setup. Restart Steam afterward. Native Steam only; existing game options stay.");
                        ui.small("For testing, remove Meteor's wrapper from one game's launch options. Keep its other flags and mods.");
                    }
                }

            }

            if let Some(vda) = &status.vda {
                let vda_state = if vda.ready { "Installed".to_string() } else { format!("{} download", gigabytes(vda.bytes)) };
                self.row(ui, Row::Vda, "VDA depth (NVIDIA TensorRT)", "Steadier, more detailed 3D. Takes about 3 minutes to prepare, once", &vda_state, busy, |ui| {
                    if !vda.ready && ui.button("Install").clicked() {
                        self.spawn(|shared, _| shared.install_vda());
                    } else if vda.ready && self.shared.socket.is_some() && ui.button("Remove").clicked() {
                        self.spawn(|shared, _| shared.depth_request(Row::Vda, crate::control::Request::RemoveVda));
                    }
                });
            }

            // Other depth models, downloaded by Meteor itself.
            let models = &status.models;
            for (id, name, bytes) in &models.offers {
                let state = format!("{} download", gigabytes(*bytes));
                let downloading = models.downloading.is_some();
                self.row(ui, Row::Models, name, "Depth model on Vulkan, for this PC's GPU; no TensorRT download", &state, busy || downloading, |ui| {
                    if ui.button("Install").clicked() {
                        let id = id.clone();
                        self.spawn(move |shared, _| shared.depth_request(Row::Models, crate::control::Request::DownloadVulkanVda(id)));
                    }
                });
            }
            if let Some((done, total)) = models.downloading {
                ui.horizontal(|ui| {
                    ui.add(egui::ProgressBar::new(done as f32 / total.max(1) as f32).show_percentage()
                        .text(format!("Downloading a depth model: {} of {} MB", done / 1_000_000, total / 1_000_000))
                        .desired_width(ui.available_width() - 80.0));
                    if ui.small_button("Cancel").clicked() {
                        self.spawn(|shared, _| shared.depth_request(Row::Models, crate::control::Request::CancelDownload));
                    }
                });
                ui.ctx().request_repaint_after(Duration::from_millis(500));
            } else if let Some(error) = &models.error {
                ui.colored_label(egui::Color32::from_rgb(235, 110, 100), format!("Last model download failed: {error}"));
            }

            ui.add_space(6.0);
            ui.horizontal_wrapped(|ui| {
                ui.label("Support:");
                if ui.button("Release information & licenses").clicked() {
                    open_release_information();
                }
                if ui.button("Open log").clicked() {
                    crate::menu::open(&crate::logfile::path().to_string_lossy());
                }
                if ui.button("Open settings file").clicked() {
                    crate::open_config_file();
                }
                if ui.button("Open models folder").clicked() {
                    let models = crate::config::load().models_dir.unwrap_or_else(crate::config::default_models_dir);
                    let _ = std::fs::create_dir_all(&models);
                    crate::menu::open(&models.to_string_lossy());
                }
            });

            ui.add_space(6.0);
            if self.shared.restart.load(Ordering::Relaxed) {
                ui.label("Meteor restarts when you close this window. Open streams will disconnect.");
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::TOP), |ui| {
                if ui.add_enabled(!busy, egui::Button::new("Close")).clicked() {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            });
        });
    }
}

/// RELEASE.md on Linux; on Windows the folder with the licences and notices.
fn open_release_information() {
    let Some(exe) = std::env::current_exe().ok() else { return };
    #[cfg(windows)]
    let target = exe.parent().map(|dir| dir.join("share\\doc\\nightfall-meteor"));
    #[cfg(not(windows))]
    let target = exe.parent().and_then(std::path::Path::parent).map(|prefix| prefix.join("share/doc/nightfall-meteor/RELEASE.md"));
    if let Some(target) = target {
        crate::menu::open(&target.to_string_lossy());
    }
}

#[cfg(windows)]
impl Window {
    /// What Windows' installer set up: the microphone cable, the virtual display driver, the firewall.
    fn windows_rows(&self, ui: &mut egui::Ui, status: &Status, busy: bool) {
        let windows = &status.windows;
        let cable = if windows.cable { "Installed" } else { "Not installed" };
        self.row(ui, Row::Cable, "Headset microphone (VB-CABLE)", "Apps record the headset from CABLE Output", cable, busy, |ui| {
            if !windows.cable && ui.button("Get VB-CABLE").clicked() {
                crate::desktop::open_web_url("https://vb-audio.com/Cable/index.htm".into());
            } else if windows.cable && ui.button("Sound settings").clicked() {
                let _ = Command::new("control.exe").arg("mmsys.cpl,,1").spawn();
            }
        });
        let display = if windows.display_driver { "Installed" } else { "Not installed" };
        self.row(ui, Row::Display, "Virtual monitors", "Extra screens in VR, made by the virtual display driver", display, busy, |ui| {
            if !windows.display_driver && windows.display_script && ui.button("Install").on_hover_text("Asks for administrator approval").clicked() {
                self.spawn(|shared, _| shared.elevated(Row::Display, "Installing the driver", "Install-VirtualDisplay.ps1"));
            }
        });
        let firewall = match &windows.firewall {
            None => "The Quest can connect".to_string(),
            Some(reason) => format!("Blocked: {reason}"),
        };
        self.row(ui, Row::Firewall, "Windows Firewall", "Lets the Quest find and reach Meteor", &firewall, busy, |ui| {
            if windows.firewall.is_some() && ui.button("Allow").on_hover_text("Asks for administrator approval").clicked() {
                self.spawn(|shared, _| shared.elevated(Row::Firewall, "Adding the rules", "Firewall-Meteor.ps1"));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> Status {
        Status {
            loaded: true,
            pcvr_in_build: true,
            host_available: true,
            vda: Some(VdaStatus { ready: false, bytes: 4_800_000_000 }),
            ..Default::default()
        }
    }

    #[cfg(windows)]
    #[test]
    fn install_all_on_windows_has_no_steam_step() {
        assert_eq!(install_all_rows(&fresh()), [Row::Pcvr, Row::Host, Row::Vda]);
    }

    #[test]
    fn steam_method_defaults_to_original_and_preserves_explicit_experimental_selection() {
        assert_eq!(SteamMethod::default(),SteamMethod::LaunchOptions);
        assert_eq!(SteamMethod::selected(false),SteamMethod::LaunchOptions);
        assert_eq!(SteamMethod::selected(true),SteamMethod::Automatic);
        assert!(SteamMethod::LaunchOptions.label().contains("Default"));
        assert!(SteamMethod::Automatic.label().contains("Experimental"));
    }

    #[cfg(not(windows))]
    #[test]
    fn automatic_steam_setup_does_not_add_per_game_wrappers_again() {
        let mut status=fresh();
        status.pcvr_ready=true;
        status.steam=Some(SteamStatus {automatic_configured:true,..Default::default()});
        assert!(!install_all_rows(&status).contains(&Row::Steam));
    }

    #[cfg(not(windows))]
    #[test]
    fn install_all_covers_a_fresh_pc_with_pcvr_before_steam() {
        assert_eq!(install_all_rows(&fresh()), [Row::Pcvr, Row::Host, Row::Steam, Row::Vda]);
    }

    #[test]
    fn install_all_leaves_another_host_alone() {
        let status = Status { other_host: true, ..fresh() };
        assert!(!install_all_rows(&status).contains(&Row::Host));
    }

    #[cfg(not(windows))]
    #[test]
    fn install_all_skips_what_this_pc_cant_use_or_already_has() {
        let status = Status {
            pcvr_ready: true,
            host_chosen: true,
            steam: Some(SteamStatus { total: 3, ready: 3, error: None, ..Default::default() }),
            vda: None,
            ..fresh()
        };
        assert!(install_all_rows(&status).is_empty());
        let status = Status { steam: Some(SteamStatus { total: 3, ready: 1, error: None, ..Default::default() }), ..status };
        assert_eq!(install_all_rows(&status), [Row::Steam]);
    }

    #[test]
    fn the_licence_note_only_appears_when_tensorrt_would_download() {
        assert!(install_all_note(&fresh()).unwrap().contains("4.8 GB"));
        let ready = Status { vda: Some(VdaStatus { ready: true, bytes: 0 }), ..fresh() };
        assert!(install_all_note(&ready).is_none());
        assert!(install_all_note(&Status { vda: None, ..fresh() }).is_none());
    }
}
