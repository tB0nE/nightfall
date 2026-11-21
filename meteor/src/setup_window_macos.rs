//! The Setup window (macOS): the permissions streaming needs, the microphone's BlackHole driver
//! and Start at login in one place, with Install All, as on Linux (setup_window.rs).
//!
//! Its own process (`nightfall-meteor --setup [control socket]`): AppKit's menu bar already holds Meteor's main
//! thread, which a window toolkit also wants. The menu opens it; Meteor opens it by itself when
//! a permission is missing or on the first run, and restarts when it exits with RESTART_CODE.
//!
//! macOS reports a new Screen Recording grant only to processes started after it, so the
//! window checks permissions in a fresh `--setup-check` process every couple of seconds.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use eframe::egui;

use crate::desktop::permissions;
use crate::download::Download;

/// The window's exit code when Meteor has to restart to use its changes.
pub const RESTART_CODE: i32 = 10;
/// Written once the window has opened by itself, so a first run opens it only once.
const OFFERED: &str = "setup-offered";

/// BlackHole 2ch, Existential Audio's notarized installer (GPL-3.0), pinned like Meteor's
/// other downloads; the same version and hash as Homebrew's cask.
const BLACKHOLE_URL: &str = "https://existential.audio/downloads/BlackHole2ch-0.7.1.pkg";
const BLACKHOLE_BYTES: u64 = 103_021;
const BLACKHOLE_SHA256: &str = "57b540f27a3e29c37e310e01bee0fdfab76733087e47f997ef9dccf851400dcf";
/// Existential Audio Inc.'s Apple team, which must have signed the package.
const BLACKHOLE_TEAM: &str = "Q5C99V536K";

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

/// Opens the window at startup when streaming can't work yet, or on the first run.
pub fn offer() {
    let marker = crate::config::config_dir().join(OFFERED);
    let missing = !permissions::screen_recording() || !permissions::accessibility();
    if missing || !marker.exists() {
        let _ = std::fs::create_dir_all(crate::config::config_dir());
        let _ = std::fs::write(&marker, "");
        open();
    }
}

/// `--setup-check`: prints this moment's permissions for the window (a fresh process sees them).
pub fn check_command() -> i32 {
    let audio = match permissions::system_audio() { Some(true) => "1", Some(false) => "0", None => "?" };
    println!("screen={} accessibility={} audio={audio}", permissions::screen_recording() as u8, permissions::accessibility() as u8);
    0
}

/// Screen Recording, Accessibility and system audio (None: not asked yet or unknown).
fn fresh_permissions() -> Option<(bool, bool, Option<bool>)> {
    let output = Command::new(std::env::current_exe().ok()?).arg("--setup-check").stdin(Stdio::null()).output().ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    let value = |name: &str| text.split_whitespace().find_map(|word| word.strip_prefix(name)).map(str::to_owned);
    let audio = match value("audio=").as_deref() { Some("1") => Some(true), Some("0") => Some(false), _ => None };
    Some((value("screen=")? == "1", value("accessibility=")? == "1", audio))
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Row {
    Screen,
    Accessibility,
    SystemAudio,
    Microphone,
    Login,
    /// Status only: host depth ships with Meteor.app.
    Depth,
    /// Depth models Meteor downloads (control.rs).
    Models,
}

#[derive(Clone, Default, PartialEq, Debug)]
struct Status {
    loaded: bool,
    screen: bool,
    accessibility: bool,
    /// None until macOS has asked (the host's first stream does).
    system_audio: Option<bool>,
    microphone: bool,
    login: bool,
    /// ncnn and a depth model are in Meteor.app.
    depth_included: bool,
}

/// What Install All does, in order. Permissions last: they open System Settings.
fn install_all_rows(status: &Status) -> Vec<Row> {
    let mut rows = Vec::new();
    if !status.microphone {
        rows.push(Row::Microphone);
    }
    if !status.login {
        rows.push(Row::Login);
    }
    if !status.screen {
        rows.push(Row::Screen);
    }
    if !status.accessibility {
        rows.push(Row::Accessibility);
    }
    rows
}

/// Depth models Meteor can download for this Mac's GPU, from the running Meteor.
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

#[derive(Default)]
struct Shared {
    /// The running Meteor's control socket (control.rs); None when Setup runs without one.
    socket: Option<PathBuf>,
    models: Mutex<ModelStatus>,
    status: Mutex<Status>,
    working: Mutex<Option<(Row, String)>>,
    errors: Mutex<Vec<(Row, String)>>,
    /// Set when a change takes effect only in a restarted Meteor.
    restart: AtomicBool,
    download: Download,
}

impl Shared {
    fn refresh(&self) {
        let (screen, accessibility, system_audio) =
            fresh_permissions().unwrap_or((permissions::screen_recording(), permissions::accessibility(), permissions::system_audio()));
        let next = Status {
            loaded: true,
            screen,
            accessibility,
            system_audio,
            microphone: crate::mic::loopback_installed(),
            login: crate::desktop::autostart_enabled(),
            depth_included: depth_included(),
        };
        let mut status = self.status.lock().unwrap();
        // Meteor took its permissions and microphone when it started.
        if status.loaded
            && ((next.screen && !status.screen) || (next.accessibility && !status.accessibility) || (next.microphone && !status.microphone))
        {
            self.restart.store(true, Ordering::Relaxed);
        }
        *status = next;
    }

    fn refresh_models(&self) {
        let Some(socket) = &self.socket else { return };
        if let Ok(value) = crate::control::send(socket, &crate::control::Request::Depth) {
            *self.models.lock().unwrap() = model_status(&value);
        }
    }

    /// Asks Meteor to download a model, or cancel the download.
    fn depth_request(&self, request: crate::control::Request) {
        let result = match &self.socket {
            Some(socket) => crate::control::send(socket, &request).map(|_| ()).map_err(|error| error.to_string()),
            None => Err("Open Setup from Meteor's menu to install models".to_string()),
        };
        if let Err(error) = result {
            self.errors.lock().unwrap().push((Row::Models, error));
        }
        self.refresh_models();
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
        *self.working.lock().unwrap() = None;
        self.refresh();
    }

    fn error(&self, row: Row) -> Option<String> {
        self.errors.lock().unwrap().iter().find(|(r, _)| *r == row).map(|(_, e)| e.clone())
    }

    fn run(&self, row: Row) {
        match row {
            Row::Screen => {
                self.begin(row, "Opening System Settings");
                permissions::request_screen_recording();
                open_url(permissions::SCREEN_RECORDING_PANE);
                self.finish(row, Ok(()));
            }
            Row::Accessibility => {
                self.begin(row, "Opening System Settings");
                permissions::request_accessibility();
                open_url(permissions::ACCESSIBILITY_PANE);
                self.finish(row, Ok(()));
            }
            Row::Microphone => {
                self.begin(row, "Downloading BlackHole");
                let result = install_blackhole(&self.download, |text| *self.working.lock().unwrap() = Some((row, text.into())));
                self.finish(row, result);
            }
            Row::Login => {
                self.begin(row, "Turning on");
                self.finish(row, crate::desktop::set_autostart(true));
            }
            // macOS asks when the host first captures; afterwards it's a switch in Settings.
            Row::SystemAudio => {
                self.begin(row, "Opening System Settings");
                open_url(permissions::SYSTEM_AUDIO_PANE);
                self.finish(row, Ok(()));
            }
            Row::Depth | Row::Models => {}
        }
    }

    fn install_all(&self) {
        let rows = install_all_rows(&self.status.lock().unwrap());
        for row in rows {
            self.run(row);
        }
    }
}

fn depth_included() -> bool {
    let Some(contents) = std::env::current_exe().ok().and_then(|exe| exe.parent()?.parent().map(|p| p.to_path_buf())) else {
        return false;
    };
    let models = contents.join("share/nightfall-meteor/models");
    contents.join("lib/libncnn.1.dylib").is_file()
        && std::fs::read_dir(models).is_ok_and(|entries| {
            entries.flatten().any(|e| e.file_name().to_string_lossy().ends_with(".ncnn.param"))
        })
}

fn open_url(url: &str) {
    if let Err(error) = Command::new("/usr/bin/open").arg(url).spawn() {
        log::warn!("Can't open {url}: {error}");
    }
}

/// Downloads the pinned BlackHole package, checks its hash and signer, and installs it with
/// one administrator prompt. Restarting coreaudiod makes the device appear without a reboot.
fn install_blackhole(download: &Download, status: impl Fn(&str)) -> Result<(), String> {
    let dir = crate::config::cache_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let package = dir.join("BlackHole2ch-0.7.1.pkg");
    if !crate::download::verified_file(&package, BLACKHOLE_SHA256, BLACKHOLE_BYTES) {
        let _ = std::fs::remove_file(&package);
        download.run_task(BLACKHOLE_BYTES, |d| d.resumable(&crate::download::agent(), BLACKHOLE_URL, 0, BLACKHOLE_BYTES, &package))?;
        if !crate::download::verified_file(&package, BLACKHOLE_SHA256, BLACKHOLE_BYTES) {
            let _ = std::fs::remove_file(&package);
            return Err("The BlackHole download didn't match its pinned checksum".into());
        }
    }
    let signature = Command::new("/usr/sbin/pkgutil")
        .arg("--check-signature")
        .arg(&package)
        .output()
        .map_err(|e| format!("Can't check BlackHole's signature: {e}"))?;
    let signature = String::from_utf8_lossy(&signature.stdout);
    if !signature.contains(&format!("({BLACKHOLE_TEAM})")) || !signature.contains("Notarization: trusted") {
        return Err("BlackHole's installer isn't signed by Existential Audio".into());
    }
    status("Installing (enter your password)");
    // The path is an argument, never part of the script.
    let output = Command::new("/usr/bin/osascript")
        .args([
            "-e", "on run argv",
            "-e", "do shell script \"/usr/sbin/installer -pkg \" & quoted form of (item 1 of argv) & \" -target / && /usr/bin/killall coreaudiod\" with prompt \"Nightfall Meteor wants to install the BlackHole audio driver for the headset's microphone.\" with administrator privileges",
            "-e", "end run",
        ])
        .arg(&package)
        .output()
        .map_err(|e| format!("Can't run the installer: {e}"))?;
    if !output.status.success() {
        let error = String::from_utf8_lossy(&output.stderr);
        return Err(if error.contains("-128") { "Cancelled".into() } else { format!("The installer failed: {}", error.trim()) });
    }
    // coreaudiod comes back within a few seconds.
    for _ in 0..20 {
        if crate::mic::loopback_installed() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    Err("BlackHole installed, but its device hasn't appeared yet; restarting the Mac will finish it".into())
}

struct Window {
    shared: Arc<Shared>,
}

impl Window {
    fn spawn(&self, task: impl FnOnce(&Shared) + Send + 'static) {
        let shared = self.shared.clone();
        std::thread::spawn(move || task(&shared));
    }

    /// One row: name, what it's for, its state, and its buttons.
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
        if let Some(error) = self.shared.error(row) {
            ui.colored_label(egui::Color32::from_rgb(220, 90, 70), error);
        }
        ui.separator();
    }
}

impl eframe::App for Window {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let status = self.shared.status.lock().unwrap().clone();
        let busy = self.shared.working.lock().unwrap().is_some() || !status.loaded;
        // Closing mid-install would leave a half-finished step behind.
        if ctx.input(|i| i.viewport().close_requested()) && busy {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
        }
        // Permissions change in System Settings while the window is open.
        ctx.request_repaint_after(Duration::from_millis(if busy { 150 } else { 1000 }));
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.add_space(4.0);
            ui.heading("Set up Nightfall Meteor");
            ui.add_space(8.0);
            let rows = install_all_rows(&status);
            let label = if rows.is_empty() && status.loaded { "All set" } else { "Install All" };
            let size = egui::vec2(ui.available_width(), 42.0);
            let clicked = ui
                .add_enabled_ui(!busy && !rows.is_empty(), |ui| {
                    ui.add_sized(size, egui::Button::new(egui::RichText::new(label).size(18.0))).clicked()
                })
                .inner;
            if clicked {
                self.spawn(|shared| shared.install_all());
            }
            if rows.contains(&Row::Screen) || rows.contains(&Row::Accessibility) {
                ui.small("macOS asks you to switch permissions on in System Settings yourself; this window updates when you do.");
            }
            if rows.contains(&Row::Microphone) {
                ui.small("BlackHole asks for your password once: it adds an audio driver to the Mac.");
            }
            ui.add_space(8.0);
            ui.separator();

            let allowed = |on: bool| if on { "Allowed" } else { "Not allowed" };
            self.row(ui, Row::Screen, "Screen Recording", "Required: lets Meteor stream your screens", allowed(status.screen), busy, |ui| {
                if !status.screen && ui.button("Allow…").clicked() {
                    self.spawn(|shared| shared.run(Row::Screen));
                }
            });
            self.row(ui, Row::Accessibility, "Accessibility", "Your headset's mouse and keyboard", allowed(status.accessibility), busy, |ui| {
                if !status.accessibility && ui.button("Allow…").clicked() {
                    self.spawn(|shared| shared.run(Row::Accessibility));
                }
            });
            let audio = match status.system_audio {
                Some(true) => "Allowed",
                Some(false) => "Not allowed",
                None => "Asked on your first stream",
            };
            self.row(ui, Row::SystemAudio, "System audio", "The Mac's sound in your headset", audio, busy, |ui| {
                if status.system_audio == Some(false) && ui.button("Allow…").clicked() {
                    self.spawn(|shared| shared.run(Row::SystemAudio));
                }
            });
            let mic = if status.microphone { "Installed" } else { "Not installed" };
            self.row(ui, Row::Microphone, "Microphone (BlackHole 2ch)", "Your headset's microphone, as \"BlackHole 2ch\" in apps", mic, busy, |ui| {
                if !status.microphone && ui.button("Install").clicked() {
                    self.spawn(|shared| shared.run(Row::Microphone));
                }
            });
            let login = if status.login { "On" } else { "Off" };
            self.row(ui, Row::Login, "Start at login", "Meteor is ready whenever the Mac is", login, busy, |ui| {
                if status.login {
                    if ui.button("Turn off").clicked() {
                        self.spawn(|shared| {
                            shared.begin(Row::Login, "Turning off");
                            shared.finish(Row::Login, crate::desktop::set_autostart(false));
                        });
                    }
                } else if ui.button("Turn on").clicked() {
                    self.spawn(|shared| shared.run(Row::Login));
                }
            });
            let depth = if status.depth_included { "Included" } else { "Not in this build" };
            self.row(ui, Row::Depth, "Host depth", "3D depth computed on this Mac's GPU", depth, true, |_| {});

            // Other depth models, downloaded by Meteor itself.
            let models = self.shared.models.lock().unwrap().clone();
            for (id, name, bytes) in &models.offers {
                let state = format!("{:.1} GB download", *bytes as f64 / 1e9);
                self.row(ui, Row::Models, name, "Depth model on this Mac's GPU", &state, busy || models.downloading.is_some(), |ui| {
                    if ui.button("Install").clicked() {
                        let id = id.clone();
                        self.spawn(move |shared| shared.depth_request(crate::control::Request::DownloadVulkanVda(id)));
                    }
                });
            }
            if let Some((done, total)) = models.downloading {
                ui.horizontal(|ui| {
                    ui.add(egui::ProgressBar::new(done as f32 / total.max(1) as f32).show_percentage()
                        .text(format!("Downloading a depth model: {} of {} MB", done / 1_000_000, total / 1_000_000))
                        .desired_width(ui.available_width() - 80.0));
                    if ui.small_button("Cancel").clicked() {
                        self.spawn(|shared| shared.depth_request(crate::control::Request::CancelDownload));
                    }
                });
            } else if let Some(error) = &models.error {
                ui.colored_label(egui::Color32::from_rgb(220, 90, 70), format!("Last model download failed: {error}"));
            }

            ui.add_space(6.0);
            ui.horizontal_wrapped(|ui| {
                ui.label("Support:");
                if ui.button("Release information & licenses").clicked() {
                    // Meteor.app/Contents/share/doc, as share/doc beside bin/ on Linux.
                    if let Some(contents) = std::env::current_exe().ok().and_then(|e| e.parent().and_then(std::path::Path::parent).map(PathBuf::from)) {
                        crate::menu::open(&contents.join("share/doc/nightfall-meteor/RELEASE.md").to_string_lossy());
                    }
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

/// `--setup [control socket]`: shows the window. Returns the process's exit code.
pub fn run(socket: Option<PathBuf>) -> i32 {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).try_init();
    let shared = Arc::new(Shared { socket, ..Shared::default() });
    let poll = shared.clone();
    std::thread::spawn(move || loop {
        if poll.working.lock().unwrap().is_none() {
            poll.refresh();
        }
        std::thread::sleep(Duration::from_secs(2));
    });
    // Downloads started from here run in Meteor: follow their progress.
    let models = shared.clone();
    std::thread::spawn(move || loop {
        models.refresh_models();
        std::thread::sleep(Duration::from_millis(1500));
    });
    // The Nightfall mark, white on transparent.
    let rgba = crate::icon::nightfall_alpha(128).into_iter().flat_map(|a| [255, 255, 255, a]).collect();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Nightfall Meteor Setup")
            .with_inner_size([660.0, 540.0])
            .with_min_inner_size([520.0, 400.0])
            .with_active(true)
            .with_icon(egui::IconData { rgba, width: 128, height: 128 }),
        ..Default::default()
    };
    let window = Window { shared: shared.clone() };
    match eframe::run_native("Nightfall Meteor Setup", options, Box::new(move |_| Ok(Box::new(window)))) {
        Ok(()) if shared.restart.load(Ordering::Relaxed) => RESTART_CODE,
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Can't open the Setup window: {error}");
            1
        }
    }
}

/// None: egui's bundled fonts (eframe's default_fonts on macOS) read like the system's.
pub(crate) fn system_font() -> Option<Vec<u8>> {
    None
}

pub(crate) fn fonts_from(font: Vec<u8>) -> egui::FontDefinitions {
    let mut fonts = egui::FontDefinitions::default();
    fonts.font_data.insert("system".to_owned(), Arc::new(egui::FontData::from_owned(font)));
    for family in [egui::FontFamily::Proportional, egui::FontFamily::Monospace] {
        fonts.families.entry(family).or_default().insert(0, "system".to_owned());
    }
    fonts
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_all_does_downloads_before_settings_and_skips_what_is_done() {
        let fresh = Status { loaded: true, ..Default::default() };
        assert_eq!(install_all_rows(&fresh), vec![Row::Microphone, Row::Login, Row::Screen, Row::Accessibility]);
        let done = Status { loaded: true, screen: true, accessibility: true, system_audio: Some(true), microphone: true, login: true, depth_included: true };
        assert!(install_all_rows(&done).is_empty());
    }
}
