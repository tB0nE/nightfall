//! Windows notification-area controls for Meteor.

use std::mem::size_of;
use std::ptr::null_mut;
use std::sync::{Arc, OnceLock};
use std::sync::atomic::Ordering;

use windows_sys::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Shell::{Shell_NotifyIconW, NOTIFYICONDATAW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DispatchMessageW, GetCursorPos,
    CreateIcon, DestroyIcon, GetMessageW, PostQuitMessage, RegisterClassW, SetForegroundWindow, TrackPopupMenu,
    TranslateMessage, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, MF_CHECKED, MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MSG, TPM_BOTTOMALIGN,
    TPM_LEFTALIGN, WM_APP, WM_COMMAND, WM_DESTROY, WM_LBUTTONDBLCLK, WM_RBUTTONUP, WNDCLASSW, WS_EX_TOOLWINDOW,
    WS_OVERLAPPED,
};

const TRAY_MESSAGE: u32 = WM_APP + 1;
const CMD_OPEN_LOG: usize = 1;
const CMD_OPEN_SETTINGS: usize = 2;
const CMD_QUIT: usize = 3;
const CMD_OPEN_MODELS: usize = 4;
const CMD_MUTE_MIC: usize = 5;
const CMD_SOUND: usize = 6;
const CMD_INSTALL_CABLE: usize = 7;
const CMD_DEPTH_ENABLED: usize = 8;
const CMD_DEPTH_SMOOTHING: usize = 9;
const CMD_VDA_DOWNLOAD: usize = 10;
const CMD_VDA_CANCEL: usize = 11;
const CMD_VDA_REMOVE: usize = 12;
const CMD_VDA_LICENCE: usize = 13;
const CMD_AUTOSTART: usize = 14;
const CMD_RATE_BASE: usize = 100;
const CMD_MODEL_BASE: usize = 200;
const CMD_SOFTEN_BASE: usize = 300;
static MIC: OnceLock<Option<Arc<crate::mic::Mic>>> = OnceLock::new();
static DEPTH: OnceLock<Option<Arc<crate::depth::Depth>>> = OnceLock::new();
static STATUS: OnceLock<Arc<crate::status::Status>> = OnceLock::new();
static STATS: OnceLock<Arc<crate::proxy::Stats>> = OnceLock::new();

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        TRAY_MESSAGE if lparam as u32 == WM_RBUTTONUP => {
            let menu = unsafe { CreatePopupMenu() };
            if menu.is_null() {
                return 0;
            }
            let log = wide("Open log");
            let settings = wide("Open settings");
            let models = wide("Open models folder");
            let quit = wide("Quit");
            unsafe {
                if let (Some(status), Some(stats)) = (STATUS.get(), STATS.get()) {
                    let title = wide(&format!("Nightfall Meteor {}", env!("CARGO_PKG_VERSION")));
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, title.as_ptr());
                    let udp = stats.udp_flows.load(Ordering::Relaxed);
                    let tcp = stats.tcp_connections.load(Ordering::Relaxed);
                    let summary = wide(&if udp > 0 {
                        format!("Streaming ({udp} UDP flows, {tcp} TCP)")
                    } else if tcp > 0 {
                        format!("Client connected ({tcp} TCP)")
                    } else {
                        "Waiting for a client".to_string()
                    });
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, summary.as_ptr());
                    let sunshine = wide(&format!("Sunshine {}:{} - {}", status.sunshine_host, status.map.sunshine_base,
                        if status.sunshine_up.load(Ordering::Relaxed) { "running" } else { "not answering" }));
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, sunshine.as_ptr());
                    AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                }
                if let Some(depth) = DEPTH.get().and_then(Option::as_ref) {
                    let available = depth.available();
                    let title = wide(&format!("Host depth: {}", if available { depth.status() } else { "loading".into() }));
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, title.as_ptr());
                    let enabled = wide("Host depth enabled");
                    AppendMenuW(menu, MF_STRING | if depth.enabled() { MF_CHECKED } else { 0 }, CMD_DEPTH_ENABLED, enabled.as_ptr());
                    let rate_menu = CreatePopupMenu();
                    if !rate_menu.is_null() {
                        for (i, &hz) in crate::depth::RATES.iter().enumerate() {
                            let label = wide(&if hz == 0 { "Match stream".to_string() } else { format!("{hz} Hz") });
                            AppendMenuW(rate_menu, MF_STRING | if depth.rate() == hz { MF_CHECKED } else { 0 }, CMD_RATE_BASE + i, label.as_ptr());
                        }
                        let label = wide("Depth rate");
                        AppendMenuW(menu, MF_POPUP, rate_menu as usize, label.as_ptr());
                    }
                    let model_menu = CreatePopupMenu();
                    if !model_menu.is_null() {
                        let models = depth.list_models();
                        for (i, model) in models.iter().enumerate() {
                            let label = wide(&crate::depth::model_label(model));
                            AppendMenuW(model_menu, MF_STRING | if depth.model().as_deref() == Some(model) { MF_CHECKED } else { 0 }, CMD_MODEL_BASE + i, label.as_ptr());
                        }
                        match depth.download.state() {
                            crate::download::State::Running => {
                                let done = depth.download.done.load(Ordering::Relaxed) / 1_000_000;
                                let total = depth.download.total.load(Ordering::Relaxed) / 1_000_000;
                                let progress = wide(&format!("Downloading VDA: {done} of {total} MB"));
                                let cancel = wide("Cancel download");
                                AppendMenuW(model_menu, MF_SEPARATOR, 0, std::ptr::null());
                                AppendMenuW(model_menu, MF_STRING | MF_GRAYED, 0, progress.as_ptr());
                                AppendMenuW(model_menu, MF_STRING, CMD_VDA_CANCEL, cancel.as_ptr());
                            }
                            state => {
                                if let Some(bytes) = depth.vda_offer() {
                                    let offer = wide(&format!("Download Video Depth Anything ({} MB)", bytes.div_ceil(1_000_000)));
                                    let download_menu = CreatePopupMenu();
                                    if !download_menu.is_null() {
                                        let description = wide("TensorRT is downloaded from NVIDIA under its licence");
                                        let licence = wide("Read NVIDIA's TensorRT licence");
                                        let accept = wide("Accept and download");
                                        AppendMenuW(download_menu, MF_STRING | MF_GRAYED, 0, description.as_ptr());
                                        if let crate::download::State::Failed(err) = state {
                                            let failed = wide(&format!("Last download failed: {err}"));
                                            AppendMenuW(download_menu, MF_STRING | MF_GRAYED, 0, failed.as_ptr());
                                        }
                                        AppendMenuW(download_menu, MF_STRING, CMD_VDA_LICENCE, licence.as_ptr());
                                        AppendMenuW(download_menu, MF_STRING, CMD_VDA_DOWNLOAD, accept.as_ptr());
                                        AppendMenuW(model_menu, MF_SEPARATOR, 0, std::ptr::null());
                                        AppendMenuW(model_menu, MF_POPUP, download_menu as usize, offer.as_ptr());
                                    }
                                } else if crate::download::installed() {
                                    let remove = wide("Remove the VDA download");
                                    AppendMenuW(model_menu, MF_SEPARATOR, 0, std::ptr::null());
                                    AppendMenuW(model_menu, MF_STRING, CMD_VDA_REMOVE, remove.as_ptr());
                                }
                            }
                        }
                        let label = wide("Depth model");
                        AppendMenuW(menu, MF_POPUP, model_menu as usize, label.as_ptr());
                    }
                    let smoothing = wide("Depth smoothing");
                    AppendMenuW(menu, MF_STRING | if depth.smoothing() { MF_CHECKED } else { 0 }, CMD_DEPTH_SMOOTHING, smoothing.as_ptr());
                    let softening_menu = CreatePopupMenu();
                    if !softening_menu.is_null() {
                        for (i, (label, _)) in crate::vda::SOFTENING.iter().enumerate() {
                            let label = wide(label);
                            AppendMenuW(softening_menu, MF_STRING | if depth.edge_softening() == i { MF_CHECKED } else { 0 }, CMD_SOFTEN_BASE + i, label.as_ptr());
                        }
                        let label = wide("Edge softening (VDA)");
                        AppendMenuW(menu, MF_POPUP, softening_menu as usize, label.as_ptr());
                    }
                    let s = &depth.stats;
                    let readout = wide(&format!("Depth {:.1} fps | decode {:.1} ms | model {:.1} ms | total {:.1} ms",
                        s.rate_x10.load(Ordering::Relaxed) as f32 / 10.0,
                        s.decode_us.load(Ordering::Relaxed) as f32 / 1000.0,
                        s.infer_us.load(Ordering::Relaxed) as f32 / 1000.0,
                        s.total_us.load(Ordering::Relaxed) as f32 / 1000.0));
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, readout.as_ptr());
                    AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                }
                if let Some(mic) = MIC.get().and_then(Option::as_ref) {
                    let label = wide(&format!("Microphone: {} (CABLE Output)", mic.status()));
                    let mute = wide("Mute microphone");
                    let sound = wide("Choose CABLE Output in Sound settings");
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, label.as_ptr());
                    AppendMenuW(menu, MF_STRING | if mic.muted.load(Ordering::Relaxed) { MF_CHECKED } else { 0 }, CMD_MUTE_MIC, mute.as_ptr());
                    AppendMenuW(menu, MF_STRING, CMD_SOUND, sound.as_ptr());
                } else {
                    let install = wide("Microphone: install VB-CABLE");
                    AppendMenuW(menu, MF_STRING, CMD_INSTALL_CABLE, install.as_ptr());
                }
                let autostart = wide("Start with my computer");
                AppendMenuW(menu, MF_STRING | if crate::desktop_windows::autostart_enabled() { MF_CHECKED } else { 0 }, CMD_AUTOSTART, autostart.as_ptr());
                AppendMenuW(menu, MF_STRING, CMD_OPEN_LOG, log.as_ptr());
                AppendMenuW(menu, MF_STRING, CMD_OPEN_SETTINGS, settings.as_ptr());
                AppendMenuW(menu, MF_STRING, CMD_OPEN_MODELS, models.as_ptr());
                AppendMenuW(menu, MF_STRING, CMD_QUIT, quit.as_ptr());
                let mut point = POINT { x: 0, y: 0 };
                GetCursorPos(&mut point);
                SetForegroundWindow(hwnd);
                TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN, point.x, point.y, 0, hwnd, null_mut());
                DestroyMenu(menu);
            }
            0
        }
        TRAY_MESSAGE if lparam as u32 == WM_LBUTTONDBLCLK => {
            open_path(crate::logfile::path());
            0
        }
        WM_COMMAND => {
            let command = (wparam as usize) & 0xffff;
            let depth = DEPTH.get().and_then(Option::as_ref);
            if let Some(depth) = depth {
                if (CMD_RATE_BASE..CMD_RATE_BASE + crate::depth::RATES.len()).contains(&command) {
                    depth.set_rate(crate::depth::RATES[command - CMD_RATE_BASE]);
                    return 0;
                }
                if (CMD_MODEL_BASE..CMD_SOFTEN_BASE).contains(&command) {
                    if let Some(model) = depth.list_models().get(command - CMD_MODEL_BASE) {
                        depth.select_model(model);
                    }
                    return 0;
                }
                if (CMD_SOFTEN_BASE..CMD_SOFTEN_BASE + crate::vda::SOFTENING.len()).contains(&command) {
                    depth.set_edge_softening(command - CMD_SOFTEN_BASE);
                    return 0;
                }
            }
            match command {
                CMD_OPEN_LOG => open_path(crate::logfile::path()),
                CMD_OPEN_SETTINGS => crate::open_config_file(),
                CMD_OPEN_MODELS => open_path(crate::config::default_models_dir()),
                CMD_MUTE_MIC => {
                    if let Some(mic) = MIC.get().and_then(Option::as_ref) {
                        mic.muted.fetch_xor(true, Ordering::Relaxed);
                    }
                }
                CMD_DEPTH_ENABLED => { if let Some(depth) = depth { depth.set_enabled(!depth.enabled()); } }
                CMD_DEPTH_SMOOTHING => { if let Some(depth) = depth { depth.set_smoothing(!depth.smoothing()); } }
                CMD_VDA_DOWNLOAD => { if let Some(depth) = depth { depth.download_vda(); } }
                CMD_VDA_CANCEL => { if let Some(depth) = depth { depth.download.cancel.store(true, Ordering::Relaxed); } }
                CMD_VDA_REMOVE => { if let Some(depth) = depth { depth.remove_vda_download(); } }
                CMD_VDA_LICENCE => open_url(crate::download::LICENCE_URL),
                CMD_AUTOSTART => {
                    let on = !crate::desktop_windows::autostart_enabled();
                    match crate::desktop_windows::set_autostart(on) {
                        Ok(()) => log::info!("Autostart {}", if on { "on" } else { "off" }),
                        Err(err) => log::warn!("Can't change autostart: {err}"),
                    }
                }
                CMD_SOUND => { let _ = std::process::Command::new("control.exe").arg("mmsys.cpl").spawn(); }
                CMD_INSTALL_CABLE => { let _ = std::process::Command::new("explorer.exe").arg("https://vb-audio.com/Cable/index.htm").spawn(); }
                CMD_QUIT => crate::quit(),
                _ => {}
            }
            0
        }
        WM_DESTROY => {
            unsafe { PostQuitMessage(0) };
            0
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn open_path(path: std::path::PathBuf) {
    let _ = std::process::Command::new("explorer.exe").arg(path).spawn();
}

fn open_url(url: &str) {
    let _ = std::process::Command::new("explorer.exe").arg(url).spawn();
}

/// Makes a Windows monochrome icon from the same Nightfall mark used by the
/// Linux tray renderer.
fn meteor_icon() -> windows_sys::Win32::UI::WindowsAndMessaging::HICON {
    // In a monochrome Win32 icon, AND=1 is transparent and AND=0 is opaque.
    let mut and_mask = [0xffu8; 32 * 4];
    let mut xor_mask = [0u8; 32 * 4];
    let alpha = crate::icon::nightfall_alpha(32);
    for y in 0..32usize {
        for x in 0..32usize {
            if alpha[y * 32 + x] > 96 {
                and_mask[y * 4 + x / 8] &= !(0x80 >> (x % 8));
                xor_mask[y * 4 + x / 8] |= 0x80 >> (x % 8);
            }
        }
    }
    // SAFETY: both mask arrays are valid for a 32x32 one-bit icon.
    unsafe { CreateIcon(null_mut(), 32, 32, 1, 1, and_mask.as_ptr(), xor_mask.as_ptr()) }
}

/// Starts the notification-area icon on a dedicated Win32 message thread.
pub fn run(status: Arc<crate::status::Status>, stats: Arc<crate::proxy::Stats>, mic: Option<Arc<crate::mic::Mic>>, depth: Option<Arc<crate::depth::Depth>>) {
    let _ = STATUS.set(status);
    let _ = STATS.set(stats);
    let _ = MIC.set(mic);
    let _ = DEPTH.set(depth);
    std::thread::spawn(|| unsafe {
        let instance: HINSTANCE = GetModuleHandleW(std::ptr::null());
        let class_name = wide("NightfallMeteorTray");
        let class = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(window_proc),
            hInstance: instance,
            lpszClassName: class_name.as_ptr(),
            ..std::mem::zeroed()
        };
        if RegisterClassW(&class) == 0 {
            log::warn!("Windows tray registration failed");
            return;
        }
        let hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW,
            class_name.as_ptr(),
            class_name.as_ptr(),
            WS_OVERLAPPED,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            0,
            0,
            null_mut(),
            null_mut(),
            instance,
            null_mut(),
        );
        if hwnd.is_null() {
            log::warn!("Windows tray window creation failed");
            return;
        }
        let mut tip = [0u16; 128];
        let text = wide("Nightfall Meteor");
        let tip_len = text.len().min(tip.len());
        tip[..tip_len].copy_from_slice(&text[..tip_len]);
        let mut icon = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_MESSAGE | NIF_ICON | NIF_TIP,
            uCallbackMessage: TRAY_MESSAGE,
            hIcon: meteor_icon(),
            szTip: tip,
            ..std::mem::zeroed()
        };
        if Shell_NotifyIconW(NIM_ADD, &mut icon) == 0 {
            log::warn!("Windows tray icon creation failed");
            return;
        }
        log::info!("Windows tray icon started");
        let mut message = MSG::default();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        Shell_NotifyIconW(NIM_DELETE, &mut icon);
        if !icon.hIcon.is_null() {
            DestroyIcon(icon.hIcon);
        }
    });
}
