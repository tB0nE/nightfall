//! User-scoped SteamVR driver bootstrap. Only a prepared, authorized XR session
//! publishes settings; registering a driver alone never creates a headset.
use std::{io, sync::Mutex, time::Duration};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::windows::named_pipe::{NamedPipeServer, ServerOptions}};
use windows_sys::Win32::{Foundation::{CloseHandle, LocalFree}, Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER, SECURITY_ATTRIBUTES, Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW}}, System::Threading::{GetCurrentProcess, OpenProcessToken}};

pub(crate) const KEYS: &[&str] = &[
    "METEOR_TRACKING_BRIDGE", "METEOR_TRACKING_PORT", "METEOR_XR_DIRECT_PORT",
    "METEOR_XR_EYE_SIZE", "METEOR_XR_EYE_HEIGHT", "XRT_COMPOSITOR_NULL_FPS",
    "METEOR_XR_CODEC", "METEOR_XR_BITRATE_MBPS", "METEOR_XR_ASYNC_DELIVERY",
    "METEOR_XR_TRACKED_SCENE", "METEOR_WINDOWS_SESSION_MARKER", "METEOR_STEAMVR_READY_FILE",
    "METEOR_STEAMVR_DIRECT", "METEOR_XR_HEADSET_OPTICS", "METEOR_XR_CONTROLLERS",
    "METEOR_XR_TOUCH_INPUTS", "METEOR_XR_HAPTICS",
];
static SETTINGS: Mutex<Option<Vec<u8>>> = Mutex::new(None);
#[cfg(test)]
pub(crate) static TEST_DELAY_MS:std::sync::atomic::AtomicU64=std::sync::atomic::AtomicU64::new(0);
static AVAILABLE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
pub(crate) fn available() -> bool { AVAILABLE.load(std::sync::atomic::Ordering::Acquire) }

fn encode(settings: &[(String, String)]) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for (key, value) in settings {
        if !KEYS.contains(&key.as_str()) || !seen.insert(key) || value.contains('\0') || value.len() > 4096 {
            return Err(io::Error::other("Invalid SteamVR session setting"));
        }
        out.extend_from_slice(&(key.len() as u16).to_le_bytes());
        out.extend_from_slice(&(value.len() as u16).to_le_bytes());
        out.extend_from_slice(key.as_bytes()); out.extend_from_slice(value.as_bytes());
    }
    if out.len() > 16384 { return Err(io::Error::other("SteamVR settings exceed 16 KiB")); }
    Ok(out)
}
pub(crate) struct Published;
impl Published {
    pub(crate) fn new(settings: &[(String, String)]) -> io::Result<Self> {
        let bytes = encode(settings)?;
        let mut slot = SETTINGS.lock().unwrap();
        if slot.is_some() { return Err(io::Error::other("Another SteamVR session is published")); }
        *slot = Some(bytes); Ok(Self)
    }
}
impl Drop for Published { fn drop(&mut self) { *SETTINGS.lock().unwrap() = None; } }

fn user_sid() -> io::Result<String> {
    unsafe {
        let mut token = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 { return Err(io::Error::last_os_error()); }
        let mut size = 0;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut size);
        // TOKEN_USER requires pointer alignment.
        let mut words = vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
        let ok = GetTokenInformation(token, TokenUser, words.as_mut_ptr().cast(), size, &mut size);
        let error = io::Error::last_os_error(); CloseHandle(token);
        if ok == 0 { return Err(error); }
        let user = &*(words.as_ptr().cast::<TOKEN_USER>());
        let mut text = std::ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 { return Err(io::Error::last_os_error()); }
        let mut length = 0; while *text.add(length) != 0 { length += 1; }
        let result = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
        LocalFree(text.cast()); Ok(result)
    }
}
fn create_pipe(name: &str, sid: &str, first: bool) -> io::Result<NamedPipeServer> {
    // Protected DACL: only this user may connect; remote clients are rejected.
    let sddl: Vec<u16> = format!("D:P(A;;GA;;;{sid})\0").encode_utf16().collect();
    unsafe {
        let mut descriptor = std::ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), 1, &mut descriptor, std::ptr::null_mut()) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut attrs = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: descriptor, bInheritHandle: 0 };
        let result = ServerOptions::new().first_pipe_instance(first).reject_remote_clients(true)
            .create_with_security_attributes_raw(name, (&mut attrs as *mut SECURITY_ATTRIBUTES).cast());
        LocalFree(descriptor); result
    }
}
pub(crate) struct Broker(tokio::task::JoinHandle<()>,Option<std::path::PathBuf>);
impl Drop for Broker { fn drop(&mut self) { AVAILABLE.store(false, std::sync::atomic::Ordering::Release); self.0.abort(); if let Some(root)=&self.1 {crate::xr_windows::cancel_steamvr(root);} } }
async fn respond(pipe: &mut NamedPipeServer, bytes: &[u8], root: Option<&std::path::Path>) -> io::Result<()> {
    #[cfg(test)] {
        let delay=TEST_DELAY_MS.swap(0,std::sync::atomic::Ordering::AcqRel);
        if delay>0 {tokio::time::sleep(Duration::from_millis(delay)).await;}
    }
    let mut request = [0; 4]; pipe.read_exact(&mut request).await?;
    if &request != b"MDS1" && &request != b"MDS2" { return Err(io::Error::other("Invalid driver bootstrap request")); }
    if &request == b"MDS2" && bytes.is_empty() {
        if let Some(root)=root {
            if let Err(error)=crate::xr_windows::queue_steamvr(root) {
                log::warn!("SteamVR headset activation rejected: {error}");
                return Err(error);
            }
        }
    }
    pipe.write_u32_le(bytes.len() as u32).await?;
    pipe.write_all(bytes).await?;
    if pipe.read_u8().await? != b'!' { return Err(io::Error::other("Driver bootstrap acknowledgment missing")); }
    Ok(())
}
pub(crate) fn start(root:Option<&std::path::Path>) -> io::Result<Broker> {
    let root=root.map(std::path::Path::canonicalize).transpose()?;
    let worker_root=root.clone();
    let sid = user_sid()?;
    let name = format!(r"\\.\pipe\Nightfall.Meteor.SteamVR.{sid}");
    let first = create_pipe(&name, &sid, true)?;
    AVAILABLE.store(true, std::sync::atomic::Ordering::Release);
    Ok(Broker(tokio::spawn(async move {
        let mut pipe = first;
        loop {
            if pipe.connect().await.is_err() { break; }
            let bytes = SETTINGS.lock().unwrap().clone().unwrap_or_default();
            let result = tokio::time::timeout(Duration::from_secs(1), respond(&mut pipe, &bytes, worker_root.as_deref())).await;
            if let Ok(Err(error)) = result { log::debug!("SteamVR bootstrap: {error}"); }
            // Keep the name owned while replacing the completed I/O instance.
            // A fresh instance avoids carrying readiness state across clients.
            match create_pipe(&name, &sid, false) {
                Ok(next) => pipe = next,
                Err(error) => { log::warn!("SteamVR bootstrap listener: {error}"); break; }
            }
        }
        AVAILABLE.store(false, std::sync::atomic::Ordering::Release);
    }),root))
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn bootstrap_allows_only_bounded_driver_settings() {
        assert!(encode(&[("PATH".into(), "untrusted".into())]).is_err());
        assert!(encode(&[(KEYS[0].into(), "bad\0path".into())]).is_err());
        assert!(encode(&[(KEYS[0].into(), "x".repeat(4097))]).is_err());
        assert!(encode(&[(KEYS[0].into(), "a".into()), (KEYS[0].into(), "b".into())]).is_err());
        let bytes = encode(&[(KEYS[0].into(), "C:\\路径\\tracking.dll".into())]).unwrap();
        assert_eq!(u16::from_le_bytes(bytes[..2].try_into().unwrap()) as usize, KEYS[0].len());
    }
    #[tokio::test] async fn bootstrap_is_idle_without_a_published_session() {
        tokio::time::timeout(Duration::from_secs(5), async {
            let sid = user_sid().unwrap();
            let name = format!(r"\\.\pipe\Nightfall.Meteor.SteamVR.Test.{}", std::process::id());
            let mut server = create_pipe(&name, &sid, true).unwrap();
            assert!(create_pipe(&name, &sid, true).is_err());
            for expected in [Vec::new(), encode(&[("METEOR_XR_EYE_SIZE".into(), "2208".into())]).unwrap()] {
                let mut client = tokio::net::windows::named_pipe::ClientOptions::new().open(&name).unwrap();
                server.connect().await.unwrap();
                let exchange = async {
                    client.write_all(b"MDS1").await.unwrap();
                    let size = client.read_u32_le().await.unwrap();
                    let mut actual = vec![0;size as usize];
                    client.read_exact(&mut actual).await.unwrap();
                    assert_eq!(actual, expected); client.write_all(b"!").await.unwrap();
                };
                let (_, result) = tokio::join!(exchange, respond(&mut server, &expected, None)); result.unwrap();
                let next = create_pipe(&name, &sid, false).unwrap();
                drop(client); server = next;
            }
            let mut client = tokio::net::windows::named_pipe::ClientOptions::new().open(&name).unwrap();
            server.connect().await.unwrap(); client.write_all(b"BAD!").await.unwrap();
            assert!(respond(&mut server, &[], None).await.is_err());
        }).await.expect("pipe protocol must finish within five seconds");
    }
    #[tokio::test]
    #[ignore = "requires the built Windows SteamVR bootstrap test executable"]
    async fn native_bootstrap_reads_the_rust_broker() {
        use std::os::windows::process::CommandExt;
        let sid = user_sid().unwrap();
        let name = format!(r"\\.\pipe\Nightfall.Meteor.SteamVR.NativeTest.{}", std::process::id());
        let mut server = create_pipe(&name, &sid, true).unwrap();
        let exe = std::env::var_os("METEOR_STEAMVR_BOOTSTRAP_TEST").expect("Set METEOR_STEAMVR_BOOTSTRAP_TEST to the release C++ helper");
        let mut child = std::process::Command::new(exe).args(["--pipe", &name])
            .creation_flags(0x08000000).spawn().unwrap();
        let exchange = async {
            server.connect().await.unwrap();
            let bytes = encode(&[("METEOR_XR_EYE_SIZE".into(), "2208".into())]).unwrap();
            respond(&mut server, &bytes, None).await.unwrap();
            loop {
                if let Some(status) = child.try_wait().unwrap() { assert!(status.success()); break; }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        };
        let result = tokio::time::timeout(Duration::from_secs(5), exchange).await;
        if result.is_err() { let _ = child.kill(); let _ = child.wait(); }
        result.unwrap();
    }
}
