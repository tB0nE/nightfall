//! Windows per-user autostart. Only the tray toggle changes the Run key.

use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::ERROR_FILE_NOT_FOUND;
use windows_sys::Win32::System::Registry::{
    HKEY, HKEY_CURRENT_USER, KEY_QUERY_VALUE, KEY_SET_VALUE, REG_SZ,
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
};

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const VALUE: &str = "Nightfall Meteor";

fn registry_text(key:HKEY,name:&str)->Option<String> {
    let name=wide(name);let mut kind=0;let mut size=0;
    unsafe {
        if RegQueryValueExW(key,name.as_ptr(),null(),&mut kind,null_mut(),&mut size)!=0 || size>65536 || size%2!=0 {return None;}
        if kind!=REG_SZ && kind!=windows_sys::Win32::System::Registry::REG_EXPAND_SZ{return None;}
        let mut data=vec![0u16;size as usize/2];
        if RegQueryValueExW(key,name.as_ptr(),null(),&mut kind,data.as_mut_ptr().cast(),&mut size)!=0{return None;}
        Some(String::from_utf16_lossy(&data).trim_end_matches('\0').to_string())
    }
}

// Windows 11's per-icon preference is best-effort, not a Shell API guarantee.
// Only initialize an absent preference for this exact executable; never reset
// another icon or overwrite the user's subsequent decision to hide Meteor.
fn promote_in(root:&str,exe:&str)->Result<bool,String> {
    use windows_sys::Win32::System::Registry::{RegEnumKeyExW,KEY_ENUMERATE_SUB_KEYS,REG_DWORD};
    let mut parent:HKEY=null_mut();
    if unsafe {RegOpenKeyExW(HKEY_CURRENT_USER,wide(root).as_ptr(),0,KEY_ENUMERATE_SUB_KEYS,&mut parent)}!=0{return Ok(false);}
    let mut found=false;let mut failure=None;
    for index in 0..4096 {
        let mut name=[0u16;256];let mut size=256;
        if unsafe {RegEnumKeyExW(parent,index,name.as_mut_ptr(),&mut size,null(),null_mut(),null_mut(),null_mut())}!=0{break;}
        let mut key:HKEY=null_mut();
        if unsafe {RegOpenKeyExW(parent,name.as_ptr(),0,KEY_QUERY_VALUE|KEY_SET_VALUE,&mut key)}!=0{continue;}
        if registry_text(key,"ExecutablePath").is_some_and(|path|path.eq_ignore_ascii_case(exe)) {
            found=true;
            let setting=wide("IsPromoted");let mut kind=0;let mut bytes=0;
            let existing=unsafe {RegQueryValueExW(key,setting.as_ptr(),null(),&mut kind,null_mut(),&mut bytes)};
            if existing==ERROR_FILE_NOT_FOUND {
                let value=1u32.to_le_bytes();
                let error=unsafe {RegSetValueExW(key,setting.as_ptr(),0,REG_DWORD,value.as_ptr(),4)};
                if error!=0{failure=Some(format!("cannot initialize tray visibility ({error})"));}
            }
        }
        unsafe {RegCloseKey(key);}
    }
    unsafe {RegCloseKey(parent);}
    if let Some(error)=failure {Err(error)} else {Ok(found)}
}

pub fn request_visible_tray_icon() {
    if std::env::var_os("NIGHTFALL_TEST_SKIP_TRAY_PROMOTION").is_some(){return;}
    std::thread::spawn(|| {
        let Ok(exe)=std::env::current_exe() else{return;};let exe=exe.to_string_lossy();
        let marker=crate::config::config_dir().join("tray-visibility-default");
        if std::fs::read_to_string(&marker).is_ok_and(|saved|saved==exe){return;}
        for _ in 0..30 {
            match promote_in("Control Panel\\NotifyIconSettings",&exe) {
                Ok(true)=>{let _=std::fs::create_dir_all(marker.parent().unwrap());let _=std::fs::write(marker,&*exe);return;},
                Err(error)=>{log::debug!("{error}; use Windows taskbar settings");return;},
                Ok(false)=>std::thread::sleep(std::time::Duration::from_millis(500)),
            }
        }
    });
}

#[cfg(test)]
mod visibility_tests {
    use super::*;
    #[test]
    fn initializes_only_own_missing_visibility_and_preserves_user_choice() {
        use windows_sys::Win32::System::Registry::{RegDeleteTreeW,REG_DWORD};
        let root=format!("Software\\NightfallMeteorTests\\tray-{}-{}",std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos());
        let mut key:HKEY=null_mut();
        assert_eq!(unsafe {RegCreateKeyExW(HKEY_CURRENT_USER,wide(&format!("{root}\\one")).as_ptr(),0,null(),0,KEY_QUERY_VALUE|KEY_SET_VALUE,null(),&mut key,null_mut())},0);
        let path=wide("C:\\Fixture\\meteor.exe");
        assert_eq!(unsafe {RegSetValueExW(key,wide("ExecutablePath").as_ptr(),0,REG_SZ,path.as_ptr().cast(),(path.len()*2) as u32)},0);
        assert!(!promote_in(&root,"C:\\Other\\meteor.exe").unwrap());
        assert!(promote_in(&root,"c:\\fixture\\METEOR.exe").unwrap());
        let mut value=0u32;let mut kind=0;let mut size=4;
        assert_eq!(unsafe {RegQueryValueExW(key,wide("IsPromoted").as_ptr(),null(),&mut kind,(&mut value as *mut u32).cast(),&mut size)},0);
        assert_eq!(value,1);
        let hidden=0u32.to_le_bytes();
        assert_eq!(unsafe {RegSetValueExW(key,wide("IsPromoted").as_ptr(),0,REG_DWORD,hidden.as_ptr(),4)},0);
        assert!(promote_in(&root,"C:\\Fixture\\meteor.exe").unwrap());
        assert_eq!(unsafe {RegQueryValueExW(key,wide("IsPromoted").as_ptr(),null(),&mut kind,(&mut value as *mut u32).cast(),&mut size)},0);
        assert_eq!(value,0);
        unsafe {RegCloseKey(key);RegDeleteTreeW(HKEY_CURRENT_USER,wide(&root).as_ptr());}
    }
}

/// Keep piped CLI output intact, or reuse the caller's existing console.
/// A tray launch never allocates a console of its own.
pub fn attach_parent_console_if_needed() {
    use windows_sys::Win32::System::Console::{AttachConsole,GetStdHandle,ATTACH_PARENT_PROCESS,STD_OUTPUT_HANDLE};
    let output=unsafe {GetStdHandle(STD_OUTPUT_HANDLE)};
    if output.is_null() || output==windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
        unsafe {AttachConsole(ATTACH_PARENT_PROCESS);}
    }
}

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
