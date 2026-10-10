//! Windows per-user autostart. Only the tray toggle changes the Run key.

use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SZ,
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
};

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const VALUE: &str = "Nightfall Meteor";

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(std::iter::once(0)).collect()
}

fn command() -> Result<String, String> {
    let exe = std::env::current_exe().map_err(|e| format!("can't find Meteor's executable: {e}"))?;
    Ok(format!("\"{}\"", exe.display()))
}

pub fn autostart_enabled() -> bool {
    let mut key: HKEY = null_mut();
    let path = wide(RUN_KEY);
    let name = wide(VALUE);
    // SAFETY: NUL-terminated names and valid out-pointers. The opened key is closed below.
    unsafe {
        if RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, KEY_QUERY_VALUE, &mut key) != 0 {
            return false;
        }
        let mut kind = 0;
        let mut bytes = 0u32;
        let first = RegQueryValueExW(key, name.as_ptr(), null(), &mut kind, null_mut(), &mut bytes);
        let mut data = vec![0u8; bytes as usize];
        let second = if first == 0 && kind == REG_SZ && bytes > 0 {
            RegQueryValueExW(key, name.as_ptr(), null(), &mut kind, data.as_mut_ptr(), &mut bytes)
        } else {
            first
        };
        RegCloseKey(key);
        if second != 0 || kind != REG_SZ || bytes % 2 != 0 {
            return false;
        }
        let value: Vec<u16> = data[..bytes as usize].chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .take_while(|&unit| unit != 0)
            .collect();
        command().is_ok_and(|expected| String::from_utf16_lossy(&value).eq_ignore_ascii_case(&expected))
    }
}

pub fn set_autostart(on: bool) -> Result<(), String> {
    let value = if on { Some(wide(&command()?)) } else { None };
    let mut key: HKEY = null_mut();
    let path = wide(RUN_KEY);
    let name = wide(VALUE);
    // SAFETY: NUL-terminated names and valid out-pointers. The opened key is closed below.
    unsafe {
        let result = if on {
            RegCreateKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, null(), 0, KEY_SET_VALUE, null(), &mut key, null_mut())
        } else {
            RegOpenKeyExW(HKEY_CURRENT_USER, path.as_ptr(), 0, KEY_SET_VALUE, &mut key)
        };
        if !on && result == ERROR_FILE_NOT_FOUND {
            return Ok(());
        }
        if result != 0 {
            return Err(format!("can't open the Windows Run key ({result})"));
        }
        let result = if on {
            let value = value.as_ref().expect("on needs a command");
            RegSetValueExW(key, name.as_ptr(), 0, REG_SZ, value.as_ptr().cast(), (value.len() * 2) as u32)
        } else {
            RegDeleteValueW(key, name.as_ptr())
        };
        RegCloseKey(key);
        if result == 0 || !on && result == ERROR_FILE_NOT_FOUND {
            Ok(())
        } else {
            Err(format!("can't change the Windows Run key ({result})"))
        }
    }
}
