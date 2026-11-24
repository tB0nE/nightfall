//! A local control channel for Meteor's own windows (the depth model window,
//! and Setup's model downloads). They are separate processes, since a window
//! toolkit owns its process's main thread, so they reach the running Meteor
//! here rather than through files.
//!
//! Only this user can open it, and never from the network: nothing on the LAN
//! can change settings. On Linux and macOS a Unix socket (mode 0600, in the
//! user's runtime folder; on macOS the per-user temporary folder); on Windows
//! a named pipe whose security descriptor names only the user and SYSTEM,
//! which refuses remote clients and which no other process can create first.
//! One JSON request per connection, one JSON answer, each a single line.

use std::io::{self, BufRead, BufReader, Write};
#[cfg(unix)]
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::depth::{Depth, DepthChoice};

static PATH: OnceLock<PathBuf> = OnceLock::new();

/// The socket of the Meteor for this host port.
#[cfg(unix)]
pub fn socket_path(base: u16) -> PathBuf {
    // macOS has no XDG_RUNTIME_DIR. $TMPDIR is per user (0700), and short enough for a
    // socket path (104 bytes there), which Application Support may not be.
    let runtime = if cfg!(target_os = "macos") { "TMPDIR" } else { "XDG_RUNTIME_DIR" };
    let folder = std::env::var_os(runtime).map(PathBuf::from).unwrap_or_else(crate::config::data_dir);
    folder.join(format!("nightfall-meteor-{base}.sock"))
}

/// The pipe of the Meteor for this host port.
#[cfg(windows)]
pub fn socket_path(base: u16) -> PathBuf {
    PathBuf::from(format!(r"\\.\pipe\nightfall-meteor-{base}"))
}

/// The running Meteor's socket, once `serve` has started.
pub fn path() -> Option<&'static Path> {
    PATH.get().map(PathBuf::as_path)
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Request {
    /// The depth settings and what they can be set to.
    Depth,
    DepthChoice(DepthChoice),
    DepthEnabled(bool),
    DepthRate(u32),
    Smoothing(bool),
    Softening(usize),
    EdgeAlignment(bool),
    ContourCleanup(bool),
    /// An index into video_decoder::Backend::ALL.
    DecodeBackend(usize),
    VaapiDevice(Option<String>),
    CpuProcessing(bool),
    /// Downloads, run in Meteor so its menus see their progress.
    DownloadVda,
    DownloadVulkanVda(String),
    RemoveVda,
    CancelDownload,
}

/// Listens for this Meteor's windows. The socket is replaced if a crashed
/// Meteor left one behind.
#[cfg(unix)]
pub async fn serve(base: u16, depth: Option<Arc<Depth>>) {
    let path = socket_path(base);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::remove_file(&path);
    let listener = match tokio::net::UnixListener::bind(&path) {
        Ok(listener) => listener,
        Err(error) => {
            log::warn!("Control socket {}: {error}", path.display());
            return;
        }
    };
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(error) = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)) {
            log::warn!("Control socket permissions: {error}");
            return;
        }
    }
    let _ = PATH.set(path);
    loop {
        let Ok((stream, _)) = listener.accept().await else { continue };
        let depth = depth.clone();
        tokio::task::spawn_blocking(move || {
            let Ok(stream) = stream.into_std() else { return };
            let _ = stream.set_nonblocking(false);
            let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(2)));
            if let Err(error) = answer(stream, depth.as_ref()) {
                log::debug!("Control request failed: {error}");
            }
        });
    }
}

#[cfg(unix)]
fn answer(mut stream: std::os::unix::net::UnixStream, depth: Option<&Arc<Depth>>) -> io::Result<()> {
    let mut line = String::new();
    BufReader::new((&stream).take(MAX_REQUEST)).read_line(&mut line)?;
    stream.write_all(reply(&line, depth).as_bytes())
}

/// The longest request line read.
const MAX_REQUEST: u64 = 64 * 1024;

/// The answer to one request line, as one line.
fn reply(line: &str, depth: Option<&Arc<Depth>>) -> String {
    let value = match serde_json::from_str::<Request>(line) {
        Ok(request) => handle(request, depth),
        Err(error) => json!({"error": format!("Bad request: {error}")}),
    };
    let mut text = value.to_string();
    text.push('\n');
    text
}

/// Listens for this Meteor's windows on its named pipe.
#[cfg(windows)]
pub async fn serve(base: u16, depth: Option<Arc<Depth>>) {
    let path = socket_path(base);
    serve_pipe(path, move |line| reply(&line, depth.as_ref())).await;
}

/// Answers each request line on the pipe at `path` with `answer`.
#[cfg(windows)]
async fn serve_pipe(path: PathBuf, answer: impl Fn(String) -> String + Clone + Send + Sync + 'static) {
    use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
    let security = match pipe::Security::for_current_user() {
        Ok(security) => security,
        Err(error) => {
            log::warn!("Control pipe: can't build its security descriptor: {error}");
            return;
        }
    };
    log::info!("Control pipe {} ({})", path.display(), security.sddl);
    // The first instance claims the name, so no other process can have made it first.
    let mut server = match security.create(&path, true) {
        Ok(server) => server,
        Err(error) => {
            log::warn!("Control pipe {}: {error}", path.display());
            return;
        }
    };
    let _ = PATH.set(path.clone());
    loop {
        if server.connect().await.is_err() {
            match security.create(&path, false) {
                Ok(next) => server = next,
                Err(error) => {
                    log::warn!("Control pipe: {error}");
                    return;
                }
            }
            continue;
        }
        let connected = server;
        server = match security.create(&path, false) {
            Ok(next) => next,
            Err(error) => {
                log::warn!("Control pipe: {error}");
                return;
            }
        };
        let answer = answer.clone();
        tokio::spawn(async move {
            let mut connected = tokio::io::BufReader::new(connected);
            let mut line = String::new();
            let mut limited = (&mut connected).take(MAX_REQUEST);
            let read = limited.read_line(&mut line);
            if !matches!(tokio::time::timeout(std::time::Duration::from_secs(2), read).await, Ok(Ok(_))) {
                return;
            }
            let Ok(text) = tokio::task::spawn_blocking(move || answer(line)).await else { return };
            let mut connected = connected.into_inner();
            let _ = connected.write_all(text.as_bytes()).await;
            let _ = connected.flush().await;
            // Dropping closes this end; the window can still read what's buffered.
            // DisconnectNamedPipe would discard it, cutting long answers short.
        });
    }
}

#[cfg(windows)]
mod pipe {
    use std::io;
    use std::path::Path;

    use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
    use windows_sys::Win32::Foundation::{CloseHandle, HANDLE, LocalFree};
    use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
    use windows_sys::Win32::Security::{GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    /// Full access for SYSTEM and this user, nobody else; "P" stops inherited entries.
    pub(super) fn sddl(user_sid: &str) -> String {
        format!("D:P(A;;GA;;;SY)(A;;GA;;;{user_sid})")
    }

    /// This process's user, as "S-1-5-21-…".
    pub(super) fn current_user_sid() -> io::Result<String> {
        unsafe {
            let mut token: HANDLE = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err(io::Error::last_os_error());
            }
            let mut needed = 0u32;
            GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut needed);
            // u64s keep TOKEN_USER's pointer aligned.
            let mut buffer = vec![0u64; (needed as usize).div_ceil(8).max(1)];
            let ok = GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), needed, &mut needed);
            CloseHandle(token);
            if ok == 0 {
                return Err(io::Error::last_os_error());
            }
            let user = &*(buffer.as_ptr() as *const TOKEN_USER);
            let mut text: *mut u16 = std::ptr::null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
                return Err(io::Error::last_os_error());
            }
            let length = (0..).take_while(|&i| *text.add(i) != 0).count();
            let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
            LocalFree(text.cast());
            Ok(sid)
        }
    }

    /// The pipe's security descriptor, kept for every instance made with it.
    pub(super) struct Security {
        descriptor: PSECURITY_DESCRIPTOR,
        pub(super) sddl: String,
    }
    // The descriptor is only read, by CreateNamedPipeW.
    unsafe impl Send for Security {}
    unsafe impl Sync for Security {}

    impl Security {
        pub(super) fn for_current_user() -> io::Result<Self> {
            Self::from_sddl(sddl(&current_user_sid()?))
        }

        pub(super) fn from_sddl(sddl: String) -> io::Result<Self> {
            let wide: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
            let mut descriptor: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
            if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide.as_ptr(), SDDL_REVISION_1, &mut descriptor, std::ptr::null_mut()) } == 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Self { descriptor, sddl })
        }

        /// A pipe instance at `path`, local clients only. `first` fails when the name exists.
        pub(super) fn create(&self, path: &Path, first: bool) -> io::Result<NamedPipeServer> {
            let mut attributes = SECURITY_ATTRIBUTES {
                nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: self.descriptor,
                bInheritHandle: 0,
            };
            let mut options = ServerOptions::new();
            options.first_pipe_instance(first).reject_remote_clients(true);
            // SAFETY: attributes and the descriptor it points to outlive the call.
            unsafe { options.create_with_security_attributes_raw(path, (&raw mut attributes).cast()) }
        }
    }

    impl Drop for Security {
        fn drop(&mut self) {
            unsafe { LocalFree(self.descriptor.cast()) };
        }
    }

    /// Opens the pipe from a window, waiting a moment while Meteor sets up the next instance.
    pub(super) fn connect(path: &Path) -> io::Result<std::fs::File> {
        const ERROR_PIPE_BUSY: i32 = 231;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            match std::fs::OpenOptions::new().read(true).write(true).open(path) {
                Err(error) if error.raw_os_error() == Some(ERROR_PIPE_BUSY) && std::time::Instant::now() < deadline => {
                    std::thread::sleep(std::time::Duration::from_millis(20));
                }
                result => return result,
            }
        }
    }
}

fn handle(request: Request, depth: Option<&Arc<Depth>>) -> Value {
    let Some(depth) = depth else { return json!({"error": "Host depth is off (--no-depth)"}) };
    match request {
        Request::Depth => return snapshot(depth),
        Request::DepthChoice(choice) => depth.select_choice(&choice),
        Request::DepthEnabled(on) => depth.set_enabled(on),
        Request::DepthRate(hz) => depth.set_rate(hz),
        Request::Smoothing(on) => depth.set_smoothing(on),
        Request::Softening(level) => depth.set_edge_softening(level),
        Request::EdgeAlignment(on) => depth.set_edge_alignment(on),
        Request::ContourCleanup(on) => depth.set_contour_cleanup(on),
        Request::DecodeBackend(index) => match crate::video_decoder::Backend::ALL.get(index) {
            Some(backend) => depth.set_decode_backend(*backend),
            None => return json!({"error": "No such decoder"}),
        },
        Request::VaapiDevice(device) => depth.set_vaapi_device(device),
        Request::CpuProcessing(on) => depth.set_cpu_processing(on),
        Request::DownloadVda => depth.download_vda(),
        Request::DownloadVulkanVda(id) => match depth.vulkan_vda_offers().into_iter().find(|(offer, _)| *offer == id) {
            Some((id, _)) => depth.download_vulkan_vda(id),
            None => return json!({"error": "That model isn't offered here"}),
        },
        Request::RemoveVda => depth.remove_vda_download(),
        Request::CancelDownload => depth.download.cancel.store(true, std::sync::atomic::Ordering::Relaxed),
    }
    snapshot(depth)
}

/// Everything the depth window shows.
fn snapshot(depth: &Depth) -> Value {
    use crate::video_decoder::{Backend, vaapi_devices};
    let groups: Vec<Value> = depth
        .choice_groups()
        .into_iter()
        .map(|group| {
            let choices: Vec<Value> = group
                .choices
                .into_iter()
                .map(|choice| {
                    json!({"label": crate::depth::model_label(&choice.model), "selected": depth.choice_selected(&choice),
                        "vda": crate::depth::is_vda(&choice.model), "choice": choice})
                })
                .collect();
            json!({"label": group.label, "choices": choices})
        })
        .collect();
    let settings = depth.decode_settings();
    let download = &depth.download;
    let (running, error) = match download.state() {
        crate::download::State::Running => (true, None),
        crate::download::State::Failed(error) => (false, Some(error)),
        _ => (false, None),
    };
    let load = |a: &std::sync::atomic::AtomicU64| a.load(std::sync::atomic::Ordering::Relaxed);
    json!({
        "available": depth.available(),
        "status": depth.status(),
        "enabled": depth.enabled(),
        "selection": depth.selection_label(),
        "vda": depth.model().is_some_and(|m| crate::depth::is_vda(&m)),
        "groups": groups,
        "rate": depth.rate(),
        "rates": crate::depth::RATES,
        "smoothing": depth.smoothing(),
        "softening": depth.edge_softening(),
        "softening_levels": crate::vda::SOFTENING.iter().map(|(name, _)| *name).collect::<Vec<_>>(),
        "edge_alignment": depth.edge_alignment(),
        "contour_cleanup": depth.contour_cleanup(),
        "decoder": {
            "status": depth.decoder_status(),
            "backend": Backend::ALL.iter().position(|b| *b == settings.backend).unwrap_or(0),
            "backends": Backend::ALL.iter().map(|b| b.label()).collect::<Vec<_>>(),
            "vaapi_device": settings.vaapi_device,
            "vaapi_devices": vaapi_devices(),
            "cpu_processing": settings.cpu_processing,
        },
        "readout": readout(depth),
        "download": {"running": running, "done": load(&download.done), "total": load(&download.total), "error": error},
        "vda_offer": depth.vda_offer(),
        "vda_installed": crate::download::installed(),
        "vulkan_offers": depth.vulkan_vda_offers().into_iter()
            .map(|(id, bytes)| json!({"id": id, "label": crate::depth::model_label(id), "bytes": bytes})).collect::<Vec<_>>(),
    })
}

fn readout(depth: &Depth) -> String {
    use std::sync::atomic::Ordering;
    let s = &depth.stats;
    let ms = |us: &std::sync::atomic::AtomicU32| f64::from(us.load(Ordering::Relaxed)) / 1000.0;
    let rate_x10 = s.rate_x10.load(Ordering::Relaxed);
    if !depth.enabled() {
        "Host depth is off".into()
    } else if rate_x10 == 0 {
        format!("Idle - {}", depth.status())
    } else {
        format!(
            "{:.1} fps - decode {:.1} ms, model {:.1} ms, frame to map {:.1} ms",
            f64::from(rate_x10) / 10.0,
            ms(&s.decode_us),
            ms(&s.infer_us),
            ms(&s.total_us)
        )
    }
}

/// Sends one request to the Meteor listening at `path` (from a window).
pub fn send(path: &Path, request: &Request) -> io::Result<Value> {
    #[cfg(unix)]
    let mut stream = {
        let stream = std::os::unix::net::UnixStream::connect(path)?;
        stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
        stream
    };
    #[cfg(windows)]
    let mut stream = pipe::connect(path)?;
    let mut text = serde_json::to_string(request).map_err(io::Error::other)?;
    text.push('\n');
    stream.write_all(text.as_bytes())?;
    let mut reply = String::new();
    BufReader::new(stream).read_line(&mut reply)?;
    let value: Value = serde_json::from_str(&reply).map_err(io::Error::other)?;
    match value.get("error").and_then(Value::as_str) {
        Some(error) => Err(io::Error::other(error.to_string())),
        None => Ok(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests_are_one_json_line() {
        let request = Request::DepthChoice(DepthChoice { model: "vda_s_518x294".into(), gpu: Some("RTX 3090".into()), cpu: false });
        let text = serde_json::to_string(&request).unwrap();
        assert!(!text.contains('\n'));
        assert_eq!(serde_json::from_str::<Request>(&text).unwrap(), request);
        assert_eq!(serde_json::to_string(&Request::Depth).unwrap(), "\"depth\"");
        assert_eq!(serde_json::from_str::<Request>("{\"depth_rate\":30}").unwrap(), Request::DepthRate(30));
    }

    #[test]
    fn without_depth_every_request_is_refused() {
        assert!(handle(Request::Depth, None)["error"].is_string());
        assert!(handle(Request::DepthRate(30), None)["error"].is_string());
    }

    #[test]
    fn each_meteor_has_its_own_socket() {
        assert_ne!(socket_path(47989), socket_path(48989));
        #[cfg(unix)]
        assert!(socket_path(47989).to_string_lossy().ends_with("nightfall-meteor-47989.sock"));
        #[cfg(windows)]
        assert_eq!(socket_path(47989).to_string_lossy(), r"\\.\pipe\nightfall-meteor-47989");
    }

    #[test]
    fn a_reply_is_one_line() {
        let reply = reply("not json", None);
        assert!(reply.ends_with('\n') && reply.matches('\n').count() == 1);
        assert!(reply.contains("Bad request"));
    }

    /// The pipe's DACL as Windows reads it back: SYSTEM and this user, nothing else.
    #[cfg(windows)]
    #[test]
    fn the_pipe_admits_only_this_user_and_system() {
        use windows_sys::Win32::Foundation::LocalFree;
        use windows_sys::Win32::Security::Authorization::{ConvertSecurityDescriptorToStringSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1, SE_KERNEL_OBJECT};
        use windows_sys::Win32::Security::DACL_SECURITY_INFORMATION;
        let sid = pipe::current_user_sid().unwrap();
        assert!(sid.starts_with("S-1-5-"), "{sid}");
        assert_eq!(pipe::sddl(&sid), format!("D:P(A;;GA;;;SY)(A;;GA;;;{sid})"));
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let _guard = runtime.enter();
        let path = PathBuf::from(format!(r"\\.\pipe\nightfall-meteor-test-dacl-{}", std::process::id()));
        let security = pipe::Security::for_current_user().unwrap();
        let server = security.create(&path, true).unwrap();
        let text = unsafe {
            use std::os::windows::io::AsRawHandle;
            let mut descriptor = std::ptr::null_mut();
            let error = GetSecurityInfo(server.as_raw_handle(), SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, std::ptr::null_mut(),
                std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), &mut descriptor);
            assert_eq!(error, 0);
            let mut text: *mut u16 = std::ptr::null_mut();
            assert_ne!(ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor, SDDL_REVISION_1, DACL_SECURITY_INFORMATION, &mut text, std::ptr::null_mut()), 0);
            let length = (0..).take_while(|&i| *text.add(i) != 0).count();
            let value = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
            LocalFree(text.cast());
            LocalFree(descriptor);
            value
        };
        assert!(text.starts_with("D:P"), "{text}");
        assert_eq!(text.matches("(A;").count(), 2, "{text}");
        assert!(text.contains(";;;SY)") && text.contains(&format!(";;;{sid})")), "{text}");
        for everyone in ["WD", "BU", "AU", "AN", "NU"] {
            assert!(!text.contains(&format!(";;;{everyone})")), "{text}");
        }
        // Another process can't claim the name first, nor a second "first" instance.
        assert!(security.create(&path, true).is_err());
        drop(server);
    }

    /// A long answer (the depth snapshot is several KB) arrives whole.
    #[cfg(windows)]
    #[test]
    fn a_long_answer_arrives_whole() {
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
        let path = PathBuf::from(format!(r"\\.\pipe\nightfall-meteor-test-long-{}", std::process::id()));
        let long = format!("{{\"text\":\"{}\"}}\n", "x".repeat(200_000));
        runtime.block_on(async {
            let expected = long.clone();
            tokio::spawn(serve_pipe(path.clone(), move |_| long.clone()));
            for _ in 0..3 {
                let path = path.clone();
                let mut answer = None;
                for _ in 0..100 {
                    let path = path.clone();
                    match tokio::task::spawn_blocking(move || send(&path, &Request::Depth)).await.unwrap() {
                        Ok(value) => { answer = Some(value); break; }
                        Err(_) => tokio::time::sleep(std::time::Duration::from_millis(10)).await,
                    }
                }
                let value = answer.expect("the pipe answers");
                assert_eq!(value["text"].as_str().unwrap().len(), 200_000);
                assert_eq!(format!("{value}\n").len(), expected.len());
            }
        });
    }

    /// A window's request reaches the pipe and gets its answer.
    #[cfg(windows)]
    #[test]
    fn a_request_goes_through_the_pipe() {
        let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
        let base = 40000 + (std::process::id() % 20000) as u16;
        runtime.block_on(async {
            tokio::spawn(serve(base, None));
            let path = socket_path(base);
            for _ in 0..100 {
                if PATH.get().is_some() { break; }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
            for _ in 0..2 {
                let path = path.clone();
                let answer = tokio::task::spawn_blocking(move || send(&path, &Request::Depth)).await.unwrap();
                assert!(answer.unwrap_err().to_string().contains("Host depth is off"));
            }
        });
    }
}
