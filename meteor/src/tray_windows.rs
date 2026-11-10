//! Windows notification-area controls for Meteor.

use std::mem::size_of;
use std::ptr::null_mut;
use std::sync::{Arc, OnceLock};
use std::sync::atomic::Ordering;

use windows_sys::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::UI::Shell::{Shell_NotifyIconW, NOTIFYICONDATAW, NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_INFO, NIM_ADD, NIM_DELETE, NIM_MODIFY, NIN_BALLOONUSERCLICK};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyMenu, DispatchMessageW, GetCursorPos,
    CreateIcon, DestroyIcon, GetMessageW, PostQuitMessage, RegisterClassW, SetForegroundWindow, TrackPopupMenu,
    TranslateMessage, CS_HREDRAW, CS_VREDRAW, CW_USEDEFAULT, MF_CHECKED, MF_GRAYED, MF_POPUP, MF_SEPARATOR, MF_STRING, MSG, PostMessageW, TPM_BOTTOMALIGN,
    TPM_LEFTALIGN, WM_APP, WM_COMMAND, WM_DESTROY, WM_LBUTTONDBLCLK, WM_RBUTTONUP, WNDCLASSW, WS_EX_TOOLWINDOW,
    WS_OVERLAPPED,
};

const TRAY_MESSAGE: u32 = WM_APP + 1;
const TRAY_BALLOON: u32 = WM_APP + 3;
static TRAY_HWND: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
static PENDING_BALLOON: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

pub fn queue_balloon(message: String) {
    if let Ok(mut guard) = PENDING_BALLOON.lock() { *guard = Some(message); }
    let hwnd = TRAY_HWND.load(Ordering::Relaxed);
    if hwnd != 0 {
        unsafe { PostMessageW(hwnd as *mut std::ffi::c_void, TRAY_BALLOON, 0, 0) };
    }
}

pub fn queue_pairing_balloon(pin: &str) {
    queue_balloon(format!("Pair Nightfall headset — PIN: {pin}  Click to approve or right-click for options"));
}
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
const CMD_EDGE_ALIGNMENT: usize = 17;
const CMD_CONTOUR_CLEANUP: usize = 18;
const CMD_HOST_BUNDLED: usize = 20;
const CMD_HOST_EXTERNAL: usize = 21;
const CMD_HOST_TOGGLE: usize = 22;
const CMD_HOST_FOLDER: usize = 23;
const CMD_HOST_WEB: usize = 24;
const CMD_HOST_LOGIN: usize = 25;
const CMD_XR_FOLDER:usize=26;
const CMD_XR_APPROVE:usize=27;
const CMD_XR_REJECT:usize=28;
const CMD_XR_ENABLE:usize=29;
const CMD_XR_LIBRARY:usize=30;
const CMD_HOST_PAIR:usize=31;
const CMD_TASKBAR_SETTINGS:usize=32;
const CMD_PAIR_APPROVE:usize=33;
const CMD_PAIR_REJECT:usize=34;
const CMD_INSTALL_VDD:usize=35;
const CMD_ALLOW_FIREWALL:usize=36;
const CMD_XR_GAME_BASE:usize=2000;
static XR_GAMES:std::sync::Mutex<Vec<String>>=std::sync::Mutex::new(Vec::new());
static XR_PENDING:std::sync::Mutex<Option<[u8;32]>>=std::sync::Mutex::new(None);
const CMD_RATE_BASE: usize = 100;
const CMD_CHOICE_BASE:usize=1000;
static CHOICES:std::sync::Mutex<Vec<crate::depth::DepthChoice>>=std::sync::Mutex::new(Vec::new());
const CMD_SOFTEN_BASE: usize = 300;
const CMD_DECODE_BASE: usize = 500;
const CMD_CPU_PROCESSING: usize = 19;
static TOKIO_HANDLE: OnceLock<tokio::runtime::Handle> = OnceLock::new();
static MIC: OnceLock<Option<Arc<crate::mic::Mic>>> = OnceLock::new();
static DEPTH: OnceLock<Option<Arc<crate::depth::Depth>>> = OnceLock::new();
static STATUS: OnceLock<Arc<crate::status::Status>> = OnceLock::new();
static STATS: OnceLock<Arc<crate::proxy::Stats>> = OnceLock::new();
static HOST: OnceLock<Arc<crate::host::view::View>> = OnceLock::new();

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        TRAY_BALLOON => {
            let msg = PENDING_BALLOON.lock().ok().and_then(|mut g| g.take());
            if let Some(msg) = msg { unsafe { show_balloon(hwnd, "Nightfall Meteor", &msg) }; }
            0
        }
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
                    let title = wide(&format!("Nightfall Meteor {}", env!("METEOR_VERSION")));
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
                    // Blocked silently, the Quest just doesn't find Meteor; say so here.
                    if let crate::firewall::Status::Windows { .. } = status.firewall() {
                        AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, wide("Windows Firewall is blocking the Quest").as_ptr());
                        AppendMenuW(menu, MF_STRING, CMD_ALLOW_FIREWALL, wide("Allow the Quest through the firewall...").as_ptr());
                    }
                    AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                }
                if let Some(host) = HOST.get() {
                    use crate::host::{Choice, Phase};
                    let submenu = CreatePopupMenu();
                    if !submenu.is_null() {
                        let label = match (&host.supervisor, host.state.choice) {
                            (Some(supervisor), _) => match supervisor.phase() {
                                Phase::Running => format!("Meteor-Vibepollo running on {}", supervisor.instance.base),
                                Phase::WaitingForPort => format!("Waiting for host port {}", supervisor.instance.base),
                                Phase::Restarting { failures } => format!("Host restarting ({failures})"),
                                Phase::Stopped => "Meteor-Vibepollo stopped".into(),
                                Phase::Failed(error) => format!("Host failed: {error}"),
                            },
                            (None, Choice::Bundled) => format!("Host unavailable: {}", host.error.as_deref().unwrap_or("unknown error")),
                            (None, Choice::External) => "Using an external host".into(),
                        };
                        AppendMenuW(submenu, MF_STRING | MF_GRAYED, 0, wide(&label).as_ptr());
                        AppendMenuW(submenu, MF_SEPARATOR, 0, std::ptr::null());
                        AppendMenuW(submenu, MF_STRING | if host.state.choice == Choice::External { MF_CHECKED } else { 0 }, CMD_HOST_EXTERNAL, wide("Use my own host").as_ptr());
                        AppendMenuW(submenu, MF_STRING | if host.binary.is_none() { MF_GRAYED } else if host.state.choice == Choice::Bundled { MF_CHECKED } else { 0 }, CMD_HOST_BUNDLED, wide("Use Meteor-Vibepollo").as_ptr());
                        if let Some(supervisor) = &host.supervisor {
                            AppendMenuW(submenu, MF_STRING, CMD_HOST_PAIR, wide("Pair headset...").as_ptr());
                            AppendMenuW(submenu, MF_STRING, CMD_HOST_TOGGLE, wide(if supervisor.wanted() { "Stop host" } else { "Start host" }).as_ptr());
                            AppendMenuW(submenu, MF_STRING, CMD_HOST_WEB, wide("Open host web page").as_ptr());
                            AppendMenuW(submenu, MF_STRING, CMD_HOST_LOGIN, wide("Open host login (host.toml)").as_ptr());
                            AppendMenuW(submenu, MF_STRING, CMD_HOST_FOLDER, wide("Open host folder").as_ptr());
                            let vdd_script = std::env::current_exe().ok()
                                .and_then(|e| e.parent().map(|p| p.join("Install-VirtualDisplay.ps1")));
                            if vdd_script.as_ref().is_some_and(|p| p.is_file()) {
                                AppendMenuW(submenu, MF_STRING, CMD_INSTALL_VDD, wide("Install virtual display driver").as_ptr());
                            }
                        } else if host.binary.is_none() {
                            AppendMenuW(submenu, MF_STRING | MF_GRAYED, 0, wide("Set host_binary in meteor.toml to a Windows host build").as_ptr());
                        }
                        AppendMenuW(menu, MF_POPUP, submenu as usize, wide("Game streaming host").as_ptr());
                        AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                    }
                }
                if let Some(depth) = DEPTH.get().and_then(Option::as_ref) {
                    let available = depth.available();
                    let title = wide(&format!("Host depth: {}", if available { depth.status() } else { "loading".into() }));
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, title.as_ptr());
                    let enabled = wide("Host depth enabled");
                    AppendMenuW(menu, MF_STRING | if depth.enabled() { MF_CHECKED } else { 0 }, CMD_DEPTH_ENABLED, enabled.as_ptr());
                    let pipeline_menu=CreatePopupMenu();
                    if !pipeline_menu.is_null() {
                        let settings=depth.decode_settings();
                        AppendMenuW(pipeline_menu,MF_STRING | MF_GRAYED,0,wide(&format!("Active: {}",depth.decoder_status())).as_ptr());
                        AppendMenuW(pipeline_menu,MF_STRING | MF_GRAYED,0,wide("Decoder changes: next keyframe or stream").as_ptr());
                        for (i,backend) in crate::video_decoder::Backend::ALL.iter().enumerate() {
                            let disabled=if *backend==crate::video_decoder::Backend::Vaapi {MF_GRAYED} else {0};
                            AppendMenuW(pipeline_menu,MF_STRING | disabled | if *backend==settings.backend {MF_CHECKED} else {0},CMD_DECODE_BASE+i,wide(backend.label()).as_ptr());
                        }
                        AppendMenuW(pipeline_menu,MF_STRING | if settings.cpu_processing {MF_CHECKED} else {0},CMD_CPU_PROCESSING,wide("CPU frame processing").as_ptr());
                        AppendMenuW(menu,MF_POPUP,pipeline_menu as usize,wide("Advanced depth pipeline").as_ptr());
                    }
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
                        if let Ok(mut entries)=CHOICES.lock() {
                            entries.clear();
                            for group in depth.choice_groups() {
                                let submenu=CreatePopupMenu();if submenu.is_null() {continue;}
                                for choice in group.choices {
                                    if entries.len()>=500 {break;}
                                    AppendMenuW(submenu,MF_STRING | if depth.choice_selected(&choice) {MF_CHECKED} else {0},CMD_CHOICE_BASE+entries.len(),wide(&crate::depth::model_label(&choice.model)).as_ptr());
                                    entries.push(choice);
                                }
                                AppendMenuW(model_menu,MF_POPUP,submenu as usize,wide(&group.label).as_ptr());
                            }
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
                        let label = wide(&format!("GPU / model: {}",depth.selection_label()));
                        AppendMenuW(menu, MF_POPUP, model_menu as usize, label.as_ptr());
                    }
                    let smoothing = wide("Depth smoothing");
                    AppendMenuW(menu, MF_STRING | if depth.smoothing() { MF_CHECKED } else { 0 }, CMD_DEPTH_SMOOTHING, smoothing.as_ptr());
                    let alignment = wide("Edge alignment (experimental)");
                    AppendMenuW(menu, MF_STRING | if depth.edge_alignment() { MF_CHECKED } else { 0 }, CMD_EDGE_ALIGNMENT, alignment.as_ptr());
                    let cleanup = wide("Contour cleanup (requires alignment)");
                    AppendMenuW(menu, MF_STRING | if depth.contour_cleanup() { MF_CHECKED } else { 0 } | if depth.edge_alignment() { 0 } else { MF_GRAYED }, CMD_CONTOUR_CLEANUP, cleanup.as_ptr());
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
                let xr_menu=CreatePopupMenu();
                if !xr_menu.is_null() {
                    let state=crate::xr_windows::state();
                    let label=wide(if state.ready {"PCVR ready"}else if state.error.is_some(){"PCVR unavailable — check log"}else{"PCVR not configured"});
                    AppendMenuW(xr_menu,MF_STRING|MF_GRAYED,0,label.as_ptr());
                    let label=wide("Open PCVR profiles folder");AppendMenuW(xr_menu,MF_STRING,CMD_XR_FOLDER,label.as_ptr());
                    if !state.ready {
                        let label=wide("Enable PCVR (restarts Meteor)");
                        let available=crate::xr_windows::games(&crate::xr_windows::root()).is_ok_and(|g|!g.is_empty());
                        AppendMenuW(xr_menu,MF_STRING|if available {0}else{MF_GRAYED},CMD_XR_ENABLE,label.as_ptr());
                    }
                    let label=wide("Open VR Apps in Nightfall");AppendMenuW(xr_menu,MF_STRING|if state.ready {0}else{MF_GRAYED},CMD_XR_LIBRARY,label.as_ptr());
                    let pending=state.trust.as_ref().and_then(|t|t.pending());
                    *XR_PENDING.lock().unwrap()=pending.as_ref().map(|(key,_)|*key);
                    if let Some((_,code))=pending {
                        let label=wide(&format!("Approve headset {code} (compare headset code)"));AppendMenuW(xr_menu,MF_STRING,CMD_XR_APPROVE,label.as_ptr());
                        let label=wide("Reject headset");AppendMenuW(xr_menu,MF_STRING,CMD_XR_REJECT,label.as_ptr());
                    }
                    let games=crate::xr_windows::games(&crate::xr_windows::root()).unwrap_or_default();
                    *XR_GAMES.lock().unwrap()=games.iter().map(|g|g.app_id.clone()).collect();
                    for (i,game) in games.iter().enumerate() {
                        let submenu=CreatePopupMenu();if submenu.is_null(){continue;}
                        for (j,backend) in [crate::xr_windows::Backend::Monado,crate::xr_windows::Backend::Steamvr].into_iter().enumerate() {
                            let available=if j==0 {game.monado.is_some()}else{game.steamvr.is_some()};
                            let label=wide(if j==0 {"Monado / xrizer"}else{"SteamVR"});
                            AppendMenuW(submenu,MF_STRING|if game.backend==backend {MF_CHECKED}else{0}|if available {0}else{MF_GRAYED},CMD_XR_GAME_BASE+i*2+j,label.as_ptr());
                        }
                        let label=wide(&game.name);AppendMenuW(xr_menu,MF_POPUP,submenu as usize,label.as_ptr());
                    }
                    let label=wide("PCVR");AppendMenuW(menu,MF_POPUP,xr_menu as usize,label.as_ptr());
                }
                if let Some(pending) = HOST.get().and_then(|v| v.pairing.as_ref()).and_then(|p| p.pending()) {
                    AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, wide(&format!("Pair Nightfall headset — PIN: {}", pending.pin)).as_ptr());
                    AppendMenuW(menu, MF_STRING, CMD_PAIR_APPROVE, wide("Approve pairing").as_ptr());
                    AppendMenuW(menu, MF_STRING, CMD_PAIR_REJECT, wide("Reject pairing").as_ptr());
                    AppendMenuW(menu, MF_SEPARATOR, 0, std::ptr::null());
                }
                let autostart = wide("Start with my computer");
                AppendMenuW(menu, MF_STRING | if crate::desktop_windows::autostart_enabled() { MF_CHECKED } else { 0 }, CMD_AUTOSTART, autostart.as_ptr());
                AppendMenuW(menu, MF_STRING, CMD_TASKBAR_SETTINGS, wide("Taskbar icon settings...").as_ptr());
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
        TRAY_MESSAGE if lparam as u32 == NIN_BALLOONUSERCLICK => {
            // Balloon click on a pairing notification: approve via Tokio runtime.
            // `Pairing::approve` calls `tokio::spawn` internally, which requires a
            // Tokio context — the Win32 message thread has none, so we hand off.
            if let (Some(pairing), Some(handle)) = (
                HOST.get().and_then(|v| v.pairing.as_ref()),
                TOKIO_HANDLE.get(),
            ) {
                if let Some(pending) = pairing.pending() {
                    let pairing = pairing.clone();
                    let id = pending.id.clone();
                    handle.spawn(async move { pairing.approve(&id); });
                }
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
                if command==CMD_CPU_PROCESSING {depth.set_cpu_processing(!depth.decode_settings().cpu_processing);return 0;}
                if (CMD_DECODE_BASE..CMD_DECODE_BASE+crate::video_decoder::Backend::ALL.len()).contains(&command) {
                    depth.set_decode_backend(crate::video_decoder::Backend::ALL[command-CMD_DECODE_BASE]);return 0;
                }
                if (CMD_RATE_BASE..CMD_RATE_BASE + crate::depth::RATES.len()).contains(&command) {
                    depth.set_rate(crate::depth::RATES[command - CMD_RATE_BASE]);
                    return 0;
                }
                if (CMD_CHOICE_BASE..CMD_CHOICE_BASE+500).contains(&command) {
                    let choice=CHOICES.lock().ok().and_then(|items|items.get(command-CMD_CHOICE_BASE).cloned());
                    if let Some(choice)=choice {depth.select_choice(&choice);}
                    return 0;
                }
                if (CMD_SOFTEN_BASE..CMD_SOFTEN_BASE + crate::vda::SOFTENING.len()).contains(&command) {
                    depth.set_edge_softening(command - CMD_SOFTEN_BASE);
                    return 0;
                }
            }
            if (CMD_XR_GAME_BASE..CMD_XR_GAME_BASE+200).contains(&command) {
                let index=(command-CMD_XR_GAME_BASE)/2;
                let id=XR_GAMES.lock().unwrap().get(index).cloned();
                if let Some(id)=id {
                    let backend=if (command-CMD_XR_GAME_BASE)%2==0 {crate::xr_windows::Backend::Monado}else{crate::xr_windows::Backend::Steamvr};
                    if let Err(error)=crate::xr_windows::select(&crate::xr_windows::root(),&id,backend){log::warn!("PCVR backend: {error}");}
                }
                return 0;
            }
            match command {
                CMD_PAIR_APPROVE|CMD_PAIR_REJECT => {
                    if let Some(pairing) = HOST.get().and_then(|v| v.pairing.as_ref()) {
                        if let Some(pending) = pairing.pending() {
                            if command == CMD_PAIR_APPROVE {
                                if let Some(handle) = TOKIO_HANDLE.get() {
                                    let pairing = pairing.clone();
                                    let id = pending.id.clone();
                                    handle.spawn(async move { pairing.approve(&id); });
                                }
                            } else {
                                pairing.reject(&pending.id);
                            }
                        }
                    }
                },
                CMD_XR_FOLDER=>{let root=crate::xr_windows::root();let _=std::fs::create_dir_all(&root);open_path(root);},
                CMD_XR_ENABLE=>{
                    let root=crate::xr_windows::root();
                    match crate::xr_windows::command(&["--xr-windows-enable".into(),"--root".into(),root.to_string_lossy().into_owned()]) {
                        Ok(_)=>crate::restart(),Err(error)=>log::warn!("PCVR setup: {error}"),
                    }
                },
                CMD_XR_LIBRARY=>{if let Err(error)=crate::xr_library::request_open(){log::warn!("PCVR library: {error}");}},
                CMD_XR_APPROVE|CMD_XR_REJECT=>{
                    if let Some(key)=*XR_PENDING.lock().unwrap() {
                        if let Some(trust)=&crate::xr_windows::state().trust {
                            if command==CMD_XR_APPROVE {if let Err(error)=trust.approve(key){log::warn!("XR approval: {error}");}}
                            else {trust.reject(key);}
                        }
                    }
                },
                CMD_ALLOW_FIREWALL => {
                    if let Some(status) = STATUS.get() {
                        status.allow_firewall();
                    }
                }
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
                CMD_EDGE_ALIGNMENT => { if let Some(depth) = depth { depth.set_edge_alignment(!depth.edge_alignment()); } }
                CMD_CONTOUR_CLEANUP => { if let Some(depth) = depth { if depth.edge_alignment() { depth.set_contour_cleanup(!depth.contour_cleanup()); } } }
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
                CMD_HOST_BUNDLED => {
                    if let Some(host) = HOST.get() { host.switch(crate::host::Choice::Bundled); }
                }
                CMD_HOST_EXTERNAL => {
                    if let Some(host) = HOST.get() { host.switch(crate::host::Choice::External); }
                }
                CMD_HOST_TOGGLE => {
                    if let Some(supervisor) = HOST.get().and_then(|host| host.supervisor.as_ref()) {
                        supervisor.set_wanted(!supervisor.wanted());
                    }
                }
                CMD_HOST_FOLDER => {
                    if let Some(supervisor) = HOST.get().and_then(|host| host.supervisor.as_ref()) {
                        open_path(supervisor.instance.appdata());
                    }
                }
                CMD_HOST_WEB => {
                    if let Some(supervisor) = HOST.get().and_then(|host| host.supervisor.as_ref()) {
                        open_url(&format!("https://localhost:{}", supervisor.instance.base + 1));
                    }
                }
                CMD_INSTALL_VDD => {
                    if let Ok(exe) = std::env::current_exe() {
                        let script = exe.parent().unwrap().join("Install-VirtualDisplay.ps1");
                        if script.is_file() {
                            // PowerShell Start-Process with -Verb RunAs triggers the UAC prompt.
                            use std::os::windows::process::CommandExt;
                            let _ = std::process::Command::new("powershell.exe")
                                .args(["-NoProfile", "-Command",
                                    &format!("Start-Process powershell.exe -Verb RunAs -ArgumentList \"-NoProfile -ExecutionPolicy Bypass -File '{}'\"", script.display())])
                                .creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW)
                                .stdin(std::process::Stdio::null())
                                .stdout(std::process::Stdio::null())
                                .stderr(std::process::Stdio::null())
                                .spawn();
                        }
                    }
                }
                CMD_HOST_PAIR => {
                    if let Ok(exe)=std::env::current_exe() {
                        use std::os::windows::process::CommandExt;
                        let script=exe.parent().unwrap().join("Pair-Headset.ps1");
                        if let Err(error)=std::process::Command::new("powershell.exe")
                            .args(["-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File"])
                            .arg(script).creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW)
                            .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn() {
                            log::warn!("Cannot open headset pairing dialog: {error}");
                        }
                    }
                }
                CMD_TASKBAR_SETTINGS => open_url("ms-settings:taskbar"),
                CMD_HOST_LOGIN => {
                    let _ = std::process::Command::new("notepad.exe").arg(crate::host::state_path()).spawn();
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

unsafe fn show_balloon(hwnd: HWND, title: &str, message: &str) {
    let mut data = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: hwnd,
        uID: 1,
        uFlags: NIF_INFO,
        ..std::mem::zeroed()
    };
    let title_w = wide(title);
    let tlen = title_w.len().min(data.szInfoTitle.len());
    data.szInfoTitle[..tlen].copy_from_slice(&title_w[..tlen]);
    let info_w = wide(message);
    let ilen = info_w.len().min(data.szInfo.len());
    data.szInfo[..ilen].copy_from_slice(&info_w[..ilen]);
    data.dwInfoFlags = NIIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &mut data);
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
pub fn run(status: Arc<crate::status::Status>, stats: Arc<crate::proxy::Stats>, mic: Option<Arc<crate::mic::Mic>>, depth: Option<Arc<crate::depth::Depth>>, host: Arc<crate::host::view::View>) {
    let _ = STATUS.set(status);
    let _ = STATS.set(stats);
    let _ = MIC.set(mic);
    let _ = DEPTH.set(depth);
    let _ = HOST.set(host);
    // Capture the Tokio handle so the Win32 message thread can spawn tasks.
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        let _ = TOKIO_HANDLE.set(handle);
    }
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
        TRAY_HWND.store(hwnd as usize, Ordering::Relaxed);
        log::info!("Windows tray icon started");
        crate::desktop_windows::request_visible_tray_icon();
        let mut message = MSG::default();
        while GetMessageW(&mut message, null_mut(), 0, 0) > 0 {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        TRAY_HWND.store(0, Ordering::Relaxed);
        Shell_NotifyIconW(NIM_DELETE, &mut icon);
        if !icon.hIcon.is_null() {
            DestroyIcon(icon.hIcon);
        }
    });
}
