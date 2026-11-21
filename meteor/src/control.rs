//! A local control channel for Meteor's own windows (the depth model window,
//! and Setup's model downloads). They are separate processes, since a window
//! toolkit owns its process's main thread, so they reach the running Meteor
//! here rather than through files.
//!
//! A Unix socket that only this user can open (mode 0600, in the user's
//! runtime folder; on macOS the per-user temporary folder), never the network: nothing on the LAN can change
//! settings. One JSON request per connection, one JSON answer.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::depth::{Depth, DepthChoice};

static PATH: OnceLock<PathBuf> = OnceLock::new();

/// The socket of the Meteor for this host port.
pub fn socket_path(base: u16) -> PathBuf {
    // macOS has no XDG_RUNTIME_DIR. $TMPDIR is per user (0700), and short enough for a
    // socket path (104 bytes there), which Application Support may not be.
    let runtime = if cfg!(target_os = "macos") { "TMPDIR" } else { "XDG_RUNTIME_DIR" };
    let folder = std::env::var_os(runtime).map(PathBuf::from).unwrap_or_else(crate::config::data_dir);
    folder.join(format!("nightfall-meteor-{base}.sock"))
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

fn answer(mut stream: std::os::unix::net::UnixStream, depth: Option<&Arc<Depth>>) -> io::Result<()> {
    let mut line = String::new();
    BufReader::new((&stream).take(64 * 1024)).read_line(&mut line)?;
    let reply = match serde_json::from_str::<Request>(&line) {
        Ok(request) => handle(request, depth),
        Err(error) => json!({"error": format!("Bad request: {error}")}),
    };
    stream.write_all(reply.to_string().as_bytes())?;
    stream.write_all(b"\n")
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
    let mut stream = std::os::unix::net::UnixStream::connect(path)?;
    stream.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
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
        assert!(socket_path(47989).to_string_lossy().ends_with("nightfall-meteor-47989.sock"));
    }
}
