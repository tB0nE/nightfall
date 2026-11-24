//! The Depth model configuration window: model, rate and the depth clean-up
//! settings, applied live to the running Meteor.
//!
//! Its own process (`nightfall-meteor --depth-settings <socket>`), like
//! Setup, talking to Meteor over control.rs.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use eframe::egui;
use serde_json::Value;

use crate::control::{self, Request};

static OPEN: AtomicBool = AtomicBool::new(false);

/// Opens the window unless it's open already. Call from the tokio runtime.
pub fn open() {
    let Some(socket) = control::path().map(PathBuf::from) else {
        tokio::spawn(crate::desktop::notify("Depth settings aren't available", "Meteor's control channel didn't start; see the log."));
        return;
    };
    if OPEN.swap(true, Ordering::Relaxed) {
        return;
    }
    tokio::spawn(async move {
        let status = tokio::task::spawn_blocking(move || {
            let mut command = Command::new(std::env::current_exe()?);
            crate::setup_window::no_console(&mut command);
            command.arg("--depth-settings").arg(socket).stdin(Stdio::null()).status()
        })
        .await;
        OPEN.store(false, Ordering::Relaxed);
        match status {
            Ok(Ok(status)) if status.success() => {}
            Ok(Ok(status)) => log::warn!("Depth settings window exited with {status}"),
            Ok(Err(error)) => log::warn!("Can't open the depth settings window: {error}"),
            Err(error) => log::warn!("Depth settings window task failed: {error}"),
        }
    });
}

#[derive(Default)]
struct Shared {
    snapshot: Mutex<Option<Value>>,
    error: Mutex<Option<String>>,
}

impl Shared {
    fn send(&self, socket: &std::path::Path, request: &Request) {
        match control::send(socket, request) {
            Ok(value) => {
                *self.snapshot.lock().unwrap() = Some(value);
                *self.error.lock().unwrap() = None;
            }
            Err(error) => *self.error.lock().unwrap() = Some(error.to_string()),
        }
    }
}

struct Window {
    socket: PathBuf,
    shared: Arc<Shared>,
    frames: u32,
}

impl Window {
    /// Sends a change without holding up the window.
    fn change(&self, request: Request) {
        let shared = self.shared.clone();
        let socket = self.socket.clone();
        std::thread::spawn(move || shared.send(&socket, &request));
    }
}

/// `--depth-settings <socket>`: shows the window. Returns the exit code.
pub fn run(socket: PathBuf) -> i32 {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).try_init();
    let shared = Arc::new(Shared::default());
    {
        // Keep the readout and the choices current while the window is open.
        let shared = shared.clone();
        let socket = socket.clone();
        std::thread::spawn(move || {
            loop {
                shared.send(&socket, &Request::Depth);
                std::thread::sleep(Duration::from_millis(700));
            }
        });
    }
    #[cfg(not(target_os = "macos"))]
    let rgba = crate::icon::nightfall_rgba(128);
    // macOS: the Nightfall mark, white on transparent, as in Setup.
    #[cfg(target_os = "macos")]
    let rgba = crate::icon::nightfall_alpha(128).into_iter().flat_map(|a| [255, 255, 255, a]).collect();
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Depth model configuration")
            .with_app_id("nightfall-meteor-depth")
            .with_inner_size([560.0, 520.0])
            .with_min_inner_size([480.0, 400.0])
            .with_icon(egui::IconData { rgba, width: 128, height: 128 }),
        ..Default::default()
    };
    // Linux's eframe has no bundled fonts; macOS uses egui's.
    let font = crate::setup_window::system_font();
    if cfg!(target_os = "linux") && font.is_none() {
        eprintln!("Can't open the depth settings window: no system font found");
        return 1;
    }
    let window = Window { socket, shared, frames: 0 };
    let creator = Box::new(move |context: &eframe::CreationContext<'_>| -> Result<Box<dyn eframe::App>, Box<dyn std::error::Error + Send + Sync>> {
        if let Some(font) = font {
            context.egui_ctx.set_fonts(crate::setup_window::fonts_from(font));
        }
        Ok(Box::new(window))
    });
    match eframe::run_native("Depth model configuration", options, creator) {
        Ok(()) => 0,
        Err(error) => {
            eprintln!("Can't open the depth settings window: {error}");
            1
        }
    }
}

fn text(value: &Value) -> String {
    value.as_str().unwrap_or_default().to_string()
}

fn rate_label(hz: u64) -> String {
    if hz == 0 { "Match stream".into() } else { format!("{hz} Hz") }
}

impl eframe::App for Window {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        ctx.request_repaint_after(Duration::from_millis(300));
        let snapshot = self.shared.snapshot.lock().unwrap().clone();
        let error = self.shared.error.lock().unwrap().clone();
        self.screenshot_for_tests(ctx, snapshot.is_some());
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.add_space(4.0);
            ui.heading("Depth model configuration");
            ui.add_space(4.0);
            let Some(s) = snapshot else {
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(error.unwrap_or_else(|| "Asking Meteor…".into()));
                });
                return;
            };
            if let Some(error) = error {
                ui.colored_label(egui::Color32::from_rgb(235, 110, 100), error);
            }
            ui.small(text(&s["readout"]));
            ui.separator();
            egui::ScrollArea::vertical().show(ui, |ui| self.settings(ui, &s));
            ui.with_layout(egui::Layout::right_to_left(egui::Align::BOTTOM), |ui| {
                if ui.button("Close").clicked() {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            });
        });
    }
}

impl Window {
    /// METEOR_DEPTH_SCREENSHOT=<file.png> saves the window once Meteor has
    /// answered, then closes it, so a test can look at it without a person.
    fn screenshot_for_tests(&mut self, ctx: &egui::Context, loaded: bool) {
        let Some(path) = std::env::var_os("METEOR_DEPTH_SCREENSHOT") else { return };
        ctx.request_repaint_after(Duration::from_millis(100));
        if loaded {
            self.frames += 1;
        }
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

    fn settings(&self, ui: &mut egui::Ui, s: &Value) {
        let mut enabled = s["enabled"].as_bool().unwrap_or(false);
        if ui.checkbox(&mut enabled, "Host depth").changed() {
            self.change(Request::DepthEnabled(enabled));
        }
        ui.add_space(6.0);

        egui::Grid::new("depth_settings").num_columns(2).spacing([16.0, 10.0]).show(ui, |ui| {
            ui.label("Model");
            egui::ComboBox::from_id_salt("model").width(300.0).selected_text(text(&s["selection"])).show_ui(ui, |ui| {
                for group in s["groups"].as_array().into_iter().flatten() {
                    ui.label(egui::RichText::new(text(&group["label"])).strong());
                    for choice in group["choices"].as_array().into_iter().flatten() {
                        let selected = choice["selected"].as_bool().unwrap_or(false);
                        if ui.selectable_label(selected, format!("   {}", text(&choice["label"]))).clicked()
                            && !selected
                            && let Ok(choice) = serde_json::from_value(choice["choice"].clone())
                        {
                            self.change(Request::DepthChoice(choice));
                        }
                    }
                }
            });
            ui.end_row();

            ui.label("Rate");
            let rate = s["rate"].as_u64().unwrap_or(0);
            egui::ComboBox::from_id_salt("rate").selected_text(rate_label(rate)).show_ui(ui, |ui| {
                for hz in s["rates"].as_array().into_iter().flatten().filter_map(Value::as_u64) {
                    if ui.selectable_label(hz == rate, rate_label(hz)).clicked() && hz != rate {
                        self.change(Request::DepthRate(hz as u32));
                    }
                }
            });
            ui.end_row();
        });
        ui.add_space(8.0);

        let mut smoothing = s["smoothing"].as_bool().unwrap_or(false);
        if ui.checkbox(&mut smoothing, "Temporal smoothing (reduces flicker)").changed() {
            self.change(Request::Smoothing(smoothing));
        }
        ui.small("Blends each depth map with the last few. Adds about 40 ms of lag; VDA is steady without it.");
        ui.add_space(6.0);

        // Softening is a blur on VDA's low-resolution depth map; other
        // models don't use it.
        if s["vda"].as_bool().unwrap_or(false) {
            let level = s["softening"].as_u64().unwrap_or(0) as usize;
            let levels: Vec<String> = s["softening_levels"].as_array().into_iter().flatten().map(text).collect();
            ui.horizontal(|ui| {
                ui.label("Edge softening (hides blocky edges)");
                egui::ComboBox::from_id_salt("softening").selected_text(levels.get(level).cloned().unwrap_or_default()).show_ui(ui, |ui| {
                    for (index, name) in levels.iter().enumerate() {
                        if ui.selectable_label(index == level, name).clicked() && index != level {
                            self.change(Request::Softening(index));
                        }
                    }
                });
            });
            ui.small("Blurs VDA's 518 × 294 depth grid so hard edges don't show as steps.");
            ui.add_space(6.0);
        }

        let mut alignment = s["edge_alignment"].as_bool().unwrap_or(false);
        if ui.checkbox(&mut alignment, "Edge alignment (experimental)").changed() {
            self.change(Request::EdgeAlignment(alignment));
        }
        let mut cleanup = s["contour_cleanup"].as_bool().unwrap_or(false);
        if ui.add_enabled(alignment, egui::Checkbox::new(&mut cleanup, "Contour cleanup (requires alignment)")).changed() {
            self.change(Request::ContourCleanup(cleanup));
        }
        ui.add_space(8.0);

        let download = &s["download"];
        if download["running"].as_bool().unwrap_or(false) {
            let done = download["done"].as_u64().unwrap_or(0);
            let total = download["total"].as_u64().unwrap_or(0).max(1);
            ui.horizontal(|ui| {
                ui.add(egui::ProgressBar::new(done as f32 / total as f32).show_percentage().text(format!("Downloading a model: {} of {} MB", done / 1_000_000, total / 1_000_000)));
                if ui.small_button("Cancel").clicked() {
                    self.change(Request::CancelDownload);
                }
            });
        } else if let Some(error) = download["error"].as_str() {
            ui.colored_label(egui::Color32::from_rgb(235, 110, 100), format!("Last download failed: {error}"));
        }
        ui.small("More models are installed from Setup.");
        ui.add_space(4.0);

        egui::CollapsingHeader::new("Advanced: how Meteor decodes the stream for depth").show(ui, |ui| {
            let decoder = &s["decoder"];
            ui.small(format!("Active: {}", text(&decoder["status"])));
            ui.small("Auto suits almost every PC. Changes apply at the next keyframe or stream.");
            let backends: Vec<String> = decoder["backends"].as_array().into_iter().flatten().map(text).collect();
            let backend = decoder["backend"].as_u64().unwrap_or(0) as usize;
            egui::Grid::new("decoder").num_columns(2).spacing([16.0, 8.0]).show(ui, |ui| {
                ui.label("Video decoder");
                egui::ComboBox::from_id_salt("backend").selected_text(backends.get(backend).cloned().unwrap_or_default()).show_ui(ui, |ui| {
                    for (index, name) in backends.iter().enumerate() {
                        if ui.selectable_label(index == backend, name).clicked() && index != backend {
                            self.change(Request::DecodeBackend(index));
                        }
                    }
                });
                ui.end_row();
                let devices: Vec<(String, String)> = decoder["vaapi_devices"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|pair| Some((pair.get(0)?.as_str()?.to_string(), pair.get(1)?.as_str()?.to_string())))
                    .collect();
                if !devices.is_empty() {
                    let current = decoder["vaapi_device"].as_str().map(str::to_string);
                    let shown = current.as_ref().and_then(|path| devices.iter().find(|(p, _)| p == path)).map_or("Auto".into(), |(_, name)| name.clone());
                    ui.label("VA-API GPU");
                    egui::ComboBox::from_id_salt("vaapi").selected_text(shown).show_ui(ui, |ui| {
                        if ui.selectable_label(current.is_none(), "Auto").clicked() && current.is_some() {
                            self.change(Request::VaapiDevice(None));
                        }
                        for (path, name) in &devices {
                            let selected = current.as_deref() == Some(path.as_str());
                            if ui.selectable_label(selected, name).clicked() && !selected {
                                self.change(Request::VaapiDevice(Some(path.clone())));
                            }
                        }
                    });
                    ui.end_row();
                }
            });
            let mut cpu = decoder["cpu_processing"].as_bool().unwrap_or(false);
            if ui.checkbox(&mut cpu, "CPU frame processing (slow reference path, for debugging)").changed() {
                self.change(Request::CpuProcessing(cpu));
            }
        });
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn rates_read_as_people_say_them() {
        assert_eq!(super::rate_label(0), "Match stream");
        assert_eq!(super::rate_label(72), "72 Hz");
    }
}
