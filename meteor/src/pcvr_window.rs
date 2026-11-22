//! The PCVR games window (Windows): every registered VR game, a filter and a
//! scroll list, and for the chosen game its runtime, what was detected and
//! where it's installed. The tray opens it instead of listing games itself,
//! since a Steam library can hold any number of them.
//!
//! Its own process (`nightfall-meteor --pcvr-games`), like Setup. It reads and
//! writes the catalog through xr_windows (`games`, `select`), which validates
//! every change. Meteor reads the catalog at each launch, so a new runtime
//! applies to the game's next launch without a restart.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use eframe::egui;

use crate::xr_windows::{Backend, Game};

static OPEN: AtomicBool = AtomicBool::new(false);

/// Opens the window unless it's open already. Call from the tokio runtime.
pub fn open() {
    if OPEN.swap(true, Ordering::Relaxed) {
        return;
    }
    tokio::spawn(async move {
        let status = tokio::task::spawn_blocking(|| {
            let mut command = Command::new(std::env::current_exe()?);
            crate::setup_window::no_console(&mut command);
            command.arg("--pcvr-games").stdin(Stdio::null()).status()
        })
        .await;
        OPEN.store(false, Ordering::Relaxed);
        match status {
            Ok(Ok(status)) if status.success() => {}
            Ok(Ok(status)) => log::warn!("PCVR games window exited with {status}"),
            Ok(Err(error)) => log::warn!("Can't open the PCVR games window: {error}"),
            Err(error) => log::warn!("PCVR games window task failed: {error}"),
        }
    });
}

/// The runtime names shown everywhere for a backend.
pub fn runtime_name(backend: Backend) -> &'static str {
    match backend {
        Backend::Steamvr => "SteamVR",
        Backend::Monado => "Monado (OpenXR)",
    }
}

/// What a game's row says it runs on.
pub fn runtime_summary(game: &Game) -> String {
    if game.requires_steamvr && game.steamvr.is_none() {
        return "needs SteamVR".into();
    }
    runtime_name(game.backend).into()
}

/// Games whose name contains the filter (any case), in name order.
pub fn filtered<'a>(games: &'a [Game], filter: &str) -> Vec<&'a Game> {
    let filter = filter.trim().to_lowercase();
    let mut shown: Vec<&Game> = games.iter().filter(|g| filter.is_empty() || g.name.to_lowercase().contains(&filter)).collect();
    shown.sort_by_key(|g| g.name.to_lowercase());
    shown
}

struct Window {
    root: PathBuf,
    games: Vec<Game>,
    loaded: Instant,
    filter: String,
    selected: Option<String>,
    error: Option<String>,
    frames: u32,
}

impl Window {
    fn reload(&mut self) {
        match crate::xr_windows::games(&self.root) {
            Ok(games) => {
                self.games = games;
                if self.selected.as_ref().is_some_and(|id| !self.games.iter().any(|g| &g.app_id == id)) {
                    self.selected = None;
                }
            }
            Err(error) => self.error = Some(format!("Can't read the game list: {error}")),
        }
        self.loaded = Instant::now();
    }

    /// METEOR_PCVR_SCREENSHOT=<png>: save the window after a few frames and
    /// close, for checking its layout without a person at the PC.
    fn screenshot_for_tests(&mut self, ctx: &egui::Context) {
        let Some(path) = std::env::var_os("METEOR_PCVR_SCREENSHOT") else { return };
        ctx.request_repaint_after(Duration::from_millis(100));
        self.frames += 1;
        if self.frames == 5 {
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::UserData::default()));
        }
        let image = ctx.input(|i| i.events.iter().find_map(|event| match event {
            egui::Event::Screenshot { image, .. } => Some(image.clone()),
            _ => None,
        }));
        if let Some(image) = image {
            if let Err(error) = crate::setup_window::save_png(&PathBuf::from(path), &image) {
                eprintln!("Can't save the screenshot: {error}");
            }
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
        }
    }

    fn choose(&mut self, id: &str, backend: Backend) {
        self.error = crate::xr_windows::select(&self.root, id, backend).err().map(|e| e.to_string());
        self.reload();
    }
}

/// `--pcvr-games`: shows the window. Returns the exit code.
pub fn run() -> i32 {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).try_init();
    let rgba = crate::icon::nightfall_rgba(128);
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("PCVR games")
            .with_app_id("nightfall-meteor-pcvr")
            .with_inner_size([760.0, 520.0])
            .with_min_inner_size([560.0, 360.0])
            .with_icon(egui::IconData { rgba, width: 128, height: 128 }),
        ..Default::default()
    };
    let Some(font) = crate::setup_window::system_font() else {
        eprintln!("Can't open the PCVR games window: no system font found");
        return 1;
    };
    let mut window = Window { root: crate::xr_windows::root(), games: Vec::new(), loaded: Instant::now(), filter: String::new(),
        selected: std::env::var("METEOR_PCVR_SELECT").ok(), error: None, frames: 0 };
    window.reload();
    let creator = Box::new(move |context: &eframe::CreationContext<'_>| -> Result<Box<dyn eframe::App>, Box<dyn std::error::Error + Send + Sync>> {
        context.egui_ctx.set_fonts(crate::setup_window::fonts_from(font));
        Ok(Box::new(window))
    });
    match eframe::run_native("PCVR games", options, creator) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Can't open the PCVR games window: {error}");
            1
        }
    }
}

fn open_folder(path: &Path) {
    let _ = Command::new("explorer.exe").arg(path).spawn();
}

impl eframe::App for Window {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Setup or the headset can change the catalog while the window is open.
        if self.loaded.elapsed() > Duration::from_secs(2) {
            self.reload();
        }
        ctx.request_repaint_after(Duration::from_secs(1));
        self.screenshot_for_tests(ctx);

        egui::TopBottomPanel::top("pcvr-top").show(ctx, |ui| {
            ui.add_space(6.0);
            ui.heading("PCVR games");
            ui.label("Choose which runtime each game uses. A change applies to the game's next launch.");
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                ui.add(egui::TextEdit::singleline(&mut self.filter).hint_text("Filter games").desired_width(260.0));
                if !self.filter.is_empty() && ui.button("Clear").clicked() {
                    self.filter.clear();
                }
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.button("Open profiles folder").clicked() {
                        let _ = std::fs::create_dir_all(&self.root);
                        open_folder(&self.root);
                    }
                });
            });
            if let Some(error) = &self.error {
                ui.colored_label(egui::Color32::from_rgb(235, 110, 100), error);
            }
            ui.add_space(4.0);
        });

        let shown: Vec<Game> = filtered(&self.games, &self.filter).into_iter().cloned().collect();
        egui::SidePanel::left("pcvr-list").resizable(true).default_width(320.0).min_width(220.0).show(ctx, |ui| {
            ui.add_space(4.0);
            ui.label(format!("{} of {} games", shown.len(), self.games.len()));
            ui.separator();
            egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                if self.games.is_empty() {
                    ui.label("No VR games registered yet. Run Setup with Steam installed to find them.");
                }
                for game in &shown {
                    let selected = self.selected.as_deref() == Some(game.app_id.as_str());
                    let text = format!("{}\n{} · {}", game.name, runtime_summary(game), game.reason());
                    if ui.selectable_label(selected, text).clicked() {
                        self.selected = Some(game.app_id.clone());
                    }
                }
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            let Some(game) = self.selected.as_ref().and_then(|id| self.games.iter().find(|g| &g.app_id == id)).cloned() else {
                ui.add_space(8.0);
                ui.label("Choose a game on the left.");
                return;
            };
            ui.add_space(4.0);
            ui.heading(&game.name);
            ui.label(format!("Steam app {}", game.app_id));
            ui.add_space(8.0);

            ui.strong("Runtime");
            if game.requires_steamvr && game.steamvr.is_none() {
                ui.label("Needs SteamVR. Install it from Steam, then run Meteor's Setup again.");
            } else {
                for backend in [Backend::Steamvr, Backend::Monado] {
                    let available = match backend {
                        Backend::Steamvr => game.steamvr.is_some(),
                        Backend::Monado => game.monado.is_some(),
                    };
                    let response = ui.add_enabled(available, egui::RadioButton::new(game.backend == backend, runtime_name(backend)));
                    if response.clicked() && game.backend != backend {
                        self.choose(&game.app_id, backend);
                    }
                }
                if game.monado.is_none() {
                    ui.weak(if game.may_use_monado() {
                        "Native OpenXR: Monado can be offered for this game once it has a Monado profile."
                    } else {
                        "Monado isn't offered: it's only for native OpenXR games without anti-cheat."
                    });
                }
            }
            ui.add_space(8.0);

            ui.strong("Detected");
            ui.label(game.reason());
            if let Some(found) = &game.detected {
                let mut apis = Vec::new();
                if found.openvr {
                    apis.push("OpenVR");
                }
                if found.openxr {
                    apis.push("OpenXR");
                }
                ui.weak(format!("Ships: {}", if apis.is_empty() { "no VR loader found".into() } else { apis.join(", ") }));
                if found.partial {
                    ui.weak("The install folder is very large; only part of it was scanned.");
                }
            }
            ui.add_space(8.0);

            ui.strong("Installed in");
            match &game.install_dir {
                Some(dir) => {
                    ui.label(dir.display().to_string().trim_start_matches(r"\\?\").to_string());
                    if ui.button("Open install folder").clicked() {
                        open_folder(dir);
                    }
                }
                None => {
                    ui.weak("Not known yet. Run Meteor's Setup again to scan it.");
                }
            }
            ui.add_space(8.0);
            if ui.button("Open this game's profiles").clicked() {
                let folder = self.root.join("profiles").join(&game.app_id);
                open_folder(if folder.is_dir() { &folder } else { &self.root });
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn game(id: &str, name: &str) -> Game {
        Game { app_id: id.into(), name: name.into(), steamvr: Some(PathBuf::from("p")), ..Default::default() }
    }

    #[test]
    fn the_filter_ignores_case_and_the_list_is_in_name_order() {
        let games = [game("1", "Moss VR"), game("2", "Half-Life: Alyx"), game("3", "moss: Book II")];
        let names = |filter| filtered(&games, filter).into_iter().map(|g| g.name.clone()).collect::<Vec<_>>();
        assert_eq!(names(""), ["Half-Life: Alyx", "Moss VR", "moss: Book II"]);
        assert_eq!(names("  MOSS "), ["Moss VR", "moss: Book II"]);
        assert!(names("zzz").is_empty());
    }

    #[test]
    fn a_game_without_steamvr_says_so() {
        let mut missing = game("1", "VRChat");
        missing.steamvr = None;
        missing.requires_steamvr = true;
        assert_eq!(runtime_summary(&missing), "needs SteamVR");
        let mut monado = game("2", "Moss VR");
        monado.backend = Backend::Monado;
        assert_eq!(runtime_summary(&monado), "Monado (OpenXR)");
    }
}
