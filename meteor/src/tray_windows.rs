//! Windows notification-area controls for Meteor.

use std::mem::size_of;
use std::ptr::{null, null_mut};
use std::sync::OnceLock;
use std::sync::atomic::Ordering;

use windows_sys::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::UI::WindowsAndMessaging::{CheckMenuRadioItem, HMENU, MF_BYCOMMAND};

use crate::menu::{Action, Entry, Sources};
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
static SOURCES: OnceLock<Sources> = OnceLock::new();
static TOKIO_HANDLE: OnceLock<tokio::runtime::Handle> = OnceLock::new();
/// The open menu's actions; command id N is ACTIONS[N - 1].
static ACTIONS: std::sync::Mutex<Vec<Action>> = std::sync::Mutex::new(Vec::new());

fn wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Runs a menu action on the tokio runtime's blocking pool: actions may wait (a
/// restart, a helper process) and use tokio::spawn, and the menu thread has no runtime.
fn activate(action: Action) {
    let (Some(_), Some(handle)) = (SOURCES.get(), TOKIO_HANDLE.get()) else { return };
    handle.spawn_blocking(move || {
        if let Some(sources) = SOURCES.get() {
            sources.activate(action);
        }
    });
}

/// Draws `entries` into `menu`, numbering each action's command.
unsafe fn draw(menu: HMENU, entries: Vec<Entry>, actions: &mut Vec<Action>) {
    for entry in entries {
        match entry {
            Entry::Label(text) => unsafe {
                AppendMenuW(menu, MF_STRING | MF_GRAYED, 0, wide(&text).as_ptr());
            },
            Entry::Separator => unsafe {
                AppendMenuW(menu, MF_SEPARATOR, 0, null());
            },
            Entry::Item { title, action, enabled, checked } => {
                let flags = MF_STRING | if enabled { 0 } else { MF_GRAYED } | if checked == Some(true) { MF_CHECKED } else { 0 };
                actions.push(action);
                unsafe { AppendMenuW(menu, flags, actions.len(), wide(&title).as_ptr()) };
            }
            Entry::Choice { title, enabled, options, selected, note } => unsafe {
                let submenu = CreatePopupMenu();
                if submenu.is_null() {
                    continue;
                }
                radio(submenu, enabled, options, selected, actions);
                if let Some(note) = note {
                    AppendMenuW(submenu, MF_STRING | MF_GRAYED, 0, wide(&note).as_ptr());
                }
                AppendMenuW(menu, MF_POPUP | if enabled { 0 } else { MF_GRAYED }, submenu as usize, wide(&title).as_ptr());
            },
            Entry::Options { enabled, options, selected } => unsafe { radio(menu, enabled, options, selected, actions) },
            Entry::Submenu { title, entries } => unsafe {
                let submenu = CreatePopupMenu();
                if submenu.is_null() {
                    continue;
                }
                draw(submenu, entries, actions);
                AppendMenuW(menu, MF_POPUP, submenu as usize, wide(&title).as_ptr());
            },
        }
    }
}

/// Mutually exclusive options, the selected one with a radio bullet.
unsafe fn radio(menu: HMENU, enabled: bool, options: Vec<(String, Action)>, selected: usize, actions: &mut Vec<Action>) {
    let first = actions.len() + 1;
    for (title, action) in options {
        actions.push(action);
        unsafe { AppendMenuW(menu, MF_STRING | if enabled { 0 } else { MF_GRAYED }, actions.len(), wide(&title).as_ptr()) };
    }
    let last = actions.len();
    if last >= first {
        unsafe { CheckMenuRadioItem(menu, first as u32, last as u32, (first + selected.min(last - first)) as u32, MF_BYCOMMAND) };
    }
}

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        TRAY_BALLOON => {
            let msg = PENDING_BALLOON.lock().ok().and_then(|mut g| g.take());
            if let Some(msg) = msg { unsafe { show_balloon(hwnd, "Nightfall Meteor", &msg) }; }
            0
        }
        TRAY_MESSAGE if lparam as u32 == WM_RBUTTONUP => {
            let Some(sources) = SOURCES.get() else { return 0 };
            let menu = unsafe { CreatePopupMenu() };
            if menu.is_null() {
                return 0;
            }
            let mut actions = Vec::new();
            unsafe { draw(menu, sources.entries(), &mut actions) };
            *ACTIONS.lock().unwrap() = actions;
            unsafe {
                let mut point = POINT { x: 0, y: 0 };
                GetCursorPos(&mut point);
                SetForegroundWindow(hwnd);
                TrackPopupMenu(menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN, point.x, point.y, 0, hwnd, null_mut());
                // Destroys the submenus too.
                DestroyMenu(menu);
            }
            0
        }
        TRAY_MESSAGE if lparam as u32 == NIN_BALLOONUSERCLICK => {
            // A click on the pairing balloon approves the pending headset.
            if let Some(pending) = SOURCES.get().and_then(|s| s.host.pairing.as_ref()).and_then(|p| p.pending()) {
                activate(Action::PairApprove(pending.id));
            }
            0
        }
        TRAY_MESSAGE if lparam as u32 == WM_LBUTTONDBLCLK => {
            open_path(crate::logfile::path());
            0
        }
        WM_COMMAND => {
            let command = (wparam as usize) & 0xffff;
            let action = command.checked_sub(1).and_then(|index| ACTIONS.lock().unwrap().get(index).cloned());
            if let Some(action) = action {
                activate(action);
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

/// Starts the notification-area icon, drawing the shared menu (menu.rs), on a
/// dedicated Win32 message thread. Call from the tokio runtime.
pub fn run(sources: Sources) {
    let _ = SOURCES.set(sources);
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
