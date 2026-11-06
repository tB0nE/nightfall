//! The Setup window (Linux): the built-in host, PCVR, Steam launch options and
//! VDA in one place, with Install All for a single click.
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
            Command::new(std::env::current_exe()?).arg("--setup").stdin(Stdio::null()).status()
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

/// `--setup`: shows the window. Returns the process's exit code.
pub fn run() -> i32 {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).try_init();
    let shared = Arc::new(Shared::default());
    let runtime = tokio::runtime::Handle::current();
    let refresh = shared.clone();
    std::thread::spawn(move || refresh.refresh(true));
    let icon = crate::icon::nightfall_icon(128);
    let rgba = icon.data.chunks_exact(4).flat_map(|p| [p[1], p[2], p[3], p[0]]).collect();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Nightfall Meteor Setup")
            .with_app_id("nightfall-meteor-setup")
            .with_inner_size([620.0, 440.0])
            .with_min_inner_size([520.0, 360.0])
            .with_icon(egui::IconData { rgba, width: 128, height: 128 }),
        ..Default::default()
    };
    let window = Window { shared: shared.clone(), runtime, frames: 0 };
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

/// A sans-serif font from the system, as the desktop's own apps would pick it.
fn system_font() -> Option<Vec<u8>> {
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

fn fonts_from(font: Vec<u8>) -> egui::FontDefinitions {
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
}

#[derive(Default)]
struct Shared {
    status: Mutex<Status>,
    /// The row being worked on and what it's doing.
    working: Mutex<Option<(Row, String)>>,
    errors: Mutex<Vec<(Row, String)>>,
    restart: AtomicBool,
    host_download: Download,
    vda_download: Download,
}

impl Shared {
    fn refresh(&self, with_steam: bool) {
        let config = crate::config::load();
        let root = config.xr.runtime_root();
        let state = host::load_state();
        let models = config.models_dir.clone().unwrap_or_else(crate::config::default_models_dir);
        let steam = if with_steam {
            steam_tool(&root).map(|tool| steam_command(&tool, "status"))
        } else {
            self.status.lock().unwrap().steam.clone()
        };
        let status = Status {
            loaded: true,
            pcvr_in_build: crate::xr_setup::bundle().is_ok(),
            pcvr_ready: config.xr.enabled && root.join("xr-runtime/manifest.json").is_file() && steam_tool(&root).is_some(),
            host_chosen: state.choice == Choice::Bundled,
            host_available: host::binary(&config).is_some() || host::RELEASE.is_some(),
            other_host: !host::other_hosts(None).is_empty(),
            steam,
            vda: crate::download::plan(&models).ok().map(|plan| VdaStatus { ready: plan.is_empty(), bytes: plan.bytes() }),
        };
        *self.status.lock().unwrap() = status;
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

    fn steam_options(&self, action: &'static str) {
        self.begin(Row::Steam, "Closing Steam and updating its games");
        let root = crate::config::load().xr.runtime_root();
        let result = match steam_tool(&root) {
            Some(tool) => {
                let reply = steam_command(&tool, action);
                reply.error.map_or(Ok(()), Err)
            }
            None => Err("Install PCVR first".to_string()),
        };
        self.finish(Row::Steam, result);
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
                Row::Steam => self.steam_options("add"),
                Row::Vda => self.install_vda(),
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
    let steam_done = status.steam.as_ref().is_some_and(|s| s.error.is_none() && s.total > 0 && s.ready == s.total);
    if status.pcvr_in_build && !steam_done {
        rows.push(Row::Steam);
    }
    if status.vda.as_ref().is_some_and(|vda| !vda.ready) {
        rows.push(Row::Vda);
    }
    rows
}

fn steam_tool(root: &std::path::Path) -> Option<PathBuf> {
    let tool = root.join("tools/meteor_steam_options.py");
    tool.is_file().then_some(tool)
}

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

fn save_png(path: &std::path::Path, image: &egui::ColorImage) -> Result<(), Box<dyn std::error::Error>> {
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

            if status.pcvr_in_build {
                let steam_state = match &status.steam {
                    None => "Needs PCVR".to_string(),
                    Some(steam) if steam.total == 0 => "No VR games found".to_string(),
                    Some(steam) => format!("{} of {} games", steam.ready, steam.total),
                };
                let steam = status.steam.clone().unwrap_or_default();
                self.row(ui, Row::Steam, "Steam launch options", "So VR games start through Meteor", &steam_state, busy, |ui| {
                    if steam.ready > 0 && ui.button("Remove").clicked() {
                        self.spawn(|shared, _| shared.steam_options("remove"));
                    }
                    if ui.add_enabled(status.steam.is_some() && steam.total > 0 && steam.ready < steam.total, egui::Button::new("Add")).clicked() {
                        self.spawn(|shared, _| shared.steam_options("add"));
                    }
                });
            }

            if let Some(vda) = &status.vda {
                let vda_state = if vda.ready { "Installed".to_string() } else { format!("{} download", gigabytes(vda.bytes)) };
                self.row(ui, Row::Vda, "VDA depth (NVIDIA TensorRT)", "Steadier, more detailed 3D. Takes about 3 minutes to prepare, once", &vda_state, busy, |ui| {
                    if !vda.ready && ui.button("Install").clicked() {
                        self.spawn(|shared, _| shared.install_vda());
                    }
                });
            }

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

    #[test]
    fn install_all_covers_a_fresh_pc_with_pcvr_before_steam() {
        assert_eq!(install_all_rows(&fresh()), [Row::Pcvr, Row::Host, Row::Steam, Row::Vda]);
    }

    #[test]
    fn install_all_leaves_another_host_alone() {
        let status = Status { other_host: true, ..fresh() };
        assert!(!install_all_rows(&status).contains(&Row::Host));
    }

    #[test]
    fn install_all_skips_what_this_pc_cant_use_or_already_has() {
        let status = Status {
            pcvr_ready: true,
            host_chosen: true,
            steam: Some(SteamStatus { total: 3, ready: 3, error: None }),
            vda: None,
            ..fresh()
        };
        assert!(install_all_rows(&status).is_empty());
        let status = Status { steam: Some(SteamStatus { total: 3, ready: 1, error: None }), ..status };
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
