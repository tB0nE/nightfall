//! The endpoint the Nightfall client probes before connecting:
//! `GET http://<host>:47900/meteor` returns which ports to use. The port
//! sits DISCOVERY_BELOW_BASE below the host's base port (config.rs).

use std::io;
use std::sync::Arc;

use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::depth::Depth;
use crate::ports::{CHANNELS, PortMap};

/// Optional services that discovery advertises next to the port map.
#[derive(Clone, Default)]
pub struct Features {
    /// Meteor's public key, hex (crypto.rs).
    pub key: Option<String>,
    pub mic_port: Option<u16>,
    /// Bound, explicitly authorized managed XR control service.
    pub xr_port: Option<u16>,
    pub depth: Option<(u16, Arc<Depth>)>,
    /// The bundled host, when Meteor runs it (host/view.rs).
    pub host: Option<serde_json::Value>,
    pub pairing: Option<Arc<crate::host::pairing::Pairing>>,
    /// True when the SunshineVDD virtual display driver is installed and the
    /// bundled host supports virtual displays.
    pub vdd_installed: bool,
}

/// Bumped when the client has to change how it talks to Meteor.
pub const PROTOCOL_VERSION: u32 = 1;

pub fn info(map: &PortMap, features: &Features) -> serde_json::Value {
    let mut sunshine = serde_json::Map::new();
    let mut ports = serde_json::Map::new();
    for ch in CHANNELS {
        sunshine.insert(ch.name.into(), map.sunshine(ch).into());
        ports.insert(ch.name.into(), map.meteor(ch).into());
    }
    let mut info = json!({
        "service": "nightfall-meteor",
        "version": env!("CARGO_PKG_VERSION"),
        "protocol": PROTOCOL_VERSION,
        "mode": "proxy",
        "sunshine": sunshine,
        "ports": ports,
    });
    // Optional features; older clients ignore keys they don't know. Both
    // side channels are encrypted for Meteor's key.
    if let Some(key) = &features.key {
        info["key"] = json!(key);
    }
    if let Some(host) = &features.host {
        info["host"] = host.clone();
    }
    if let Some(port) = features.mic_port {
        info["mic"] = json!({
            "port": port,
            "formats": [crate::mic::FORMAT_OPUS_48K_MONO, crate::mic::FORMAT_PCM_S16LE_48K_MONO],
            "encryption": crate::crypto::ENCRYPTION,
        });
    }
    if let Some(port) = features.xr_port {
        // Protocol-1 clients gate on this historical backend token. Retain it
        // for compatibility; expose the real host platform separately.
        info["xr"] = json!({"port": port, "backend": "linux-nvidia", "platform":std::env::consts::OS, "authorization": "allowlist", "protocol": 1});
    }
    if features.vdd_installed {
        // The host creates the extra displays per session, up to this many.
        info["virtual_display"] = json!({"driver_installed": true, "max_count": MAX_VIRTUAL});
    }
    // Only while a model is loaded and host depth is switched on in the tray.
    if let Some((port, depth)) = &features.depth
        && depth.enabled()
        && let Some((model, width, height)) = depth.active_model()
    {
        info["depth"] = json!({
            "port": port,
            "formats": [crate::depth_server::FORMAT_L8],
            "compression": "zstd",
            "encryption": crate::crypto::ENCRYPTION,
            "width": width,
            "height": height,
            "model": model,
            "max_hz": depth.rate(),
        });
    }
    info
}

pub async fn bind(port: u16) -> io::Result<TcpListener> {
    match crate::net::tcp_listener(port).await {
        Ok(listener) => Ok(listener),
        Err(_) => TcpListener::bind(("0.0.0.0", port)).await,
    }
}

pub async fn serve(listener: TcpListener, map: PortMap, features: Features) {
    loop {
        let Ok((stream, peer)) = listener.accept().await else { continue };
        // Built per request: depth comes and goes with the tray toggle and model loads.
        let body = info(&map, &features).to_string();
        let features = features.clone();
        tokio::spawn(async move {
            match tokio::time::timeout(std::time::Duration::from_secs(5),respond(stream, &body, &features)).await {
                Ok(Ok(path)) => log::info!("Discovery probe from {peer} ({path})"),
                Ok(Err(err)) => log::debug!("Discovery probe from {peer} failed: {err}"),
                Err(_) => log::debug!("Discovery probe from {peer} timed out"),
            }
        });
    }
}

async fn respond(mut stream: TcpStream, body: &str, _features: &Features) -> io::Result<String> {
    let mut request = Vec::new();
    let mut buf = [0u8; 1024];
    // Only the request line matters; stop at the end of the headers.
    while !request.windows(4).any(|w| w == b"\r\n\r\n") && request.len() < 8192 {
        let n = tokio::time::timeout(std::time::Duration::from_secs(2), stream.read(&mut buf))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "request timed out"))??;
        if n == 0 {
            break;
        }
        request.extend_from_slice(&buf[..n]);
    }
    let header_end = request.windows(4).position(|w|w==b"\r\n\r\n").map(|p|p+4)
        .ok_or_else(||io::Error::other("Incomplete HTTP headers"))?;
    if header_end>8192 { return Err(io::Error::other("HTTP headers too large")); }
    let headers = std::str::from_utf8(&request[..header_end]).map_err(|_|io::Error::other("Invalid HTTP headers"))?;
    let method = headers.split_whitespace().next().unwrap_or("").to_string();
    let path = headers.split_whitespace().nth(1).unwrap_or("").to_string();
    if path == "/meteor/virtual" && method == "POST" {
        let length = virtual_body_length(headers)?;
        while request.len() < header_end + length {
            let n = tokio::time::timeout(std::time::Duration::from_secs(2), stream.read(&mut buf)).await
                .map_err(|_| io::Error::other("Virtual body timed out"))??;
            if n == 0 { return Err(io::Error::other("Truncated virtual body")); }
            request.extend_from_slice(&buf[..n]);
        }
        let body = &request[header_end..header_end + length];
        let (status, value) = handle_virtual(body).await;
        write_json(&mut stream, status, &value.to_string()).await?;
        return Ok(path);
    }
    if path == "/meteor/pair" && method == "POST" {
        let length = pairing_body_length(headers)?;
        let pairing = _features.pairing.as_ref();
        if let Some(pairing) = pairing {
            while request.len()<header_end+length {
                let n=tokio::time::timeout(std::time::Duration::from_secs(2),stream.read(&mut buf)).await
                    .map_err(|_|io::Error::other("Pairing body timed out"))??;
                if n==0 { return Err(io::Error::other("Truncated pairing body")); }
                request.extend_from_slice(&buf[..n]);
            }
            let peer=stream.peer_addr()?.ip();
            let (status,value) = match pairing.accept(&request[header_end..header_end+length],peer) {
                Ok(()) => (202,json!({"status":"pending","expires_in":60})),
                Err(error) => (400,json!({"error":error})),
            };
            write_json(&mut stream,status,&value.to_string()).await?;
            return Ok(path);
        }
    }
    let response = if method == "GET" && (path == "/meteor" || path.starts_with("/meteor?")) {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    } else {
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
    };
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await?;
    Ok(path)
}

fn virtual_body_length(headers: &str) -> io::Result<usize> {
    let mut size = None;
    let mut json = false;
    for line in headers.lines().skip(1) {
        let Some((key, value)) = line.split_once(':') else { continue };
        match key.trim().to_ascii_lowercase().as_str() {
            "content-type" => json = value.trim().eq_ignore_ascii_case("application/json"),
            "content-length" => {
                if size.is_some() { return Err(io::Error::other("Duplicate content length")); }
                size = Some(value.trim().parse::<usize>().map_err(|_| io::Error::other("Invalid content length"))?);
            }
            _ => {}
        }
    }
    match size {
        Some(n) if json && n > 0 && n <= 256 => Ok(n),
        _ => Err(io::Error::other("Virtual requires a bounded JSON body")),
    }
}

/// Virtual monitors the bundled host can create for one session. The client asks
/// for its count with `virtual_displays=N` on every launch.
const MAX_VIRTUAL: u8 = 4;

async fn handle_virtual(body: &[u8]) -> (u16, serde_json::Value) {
    let Ok(text) = std::str::from_utf8(body) else {
        return (400, json!({"error": "Invalid UTF-8"}));
    };
    let Ok(parsed) = serde_json::from_str::<serde_json::Value>(text) else {
        return (400, json!({"error": "Invalid JSON"}));
    };
    let count = match parsed.get("count").and_then(|v| v.as_u64()) {
        Some(n) if n <= MAX_VIRTUAL as u64 => n as u8,
        Some(_) => return (400, json!({"error": format!("count must be 0-{MAX_VIRTUAL}")})),
        None => return (400, json!({"error": "count field required"})),
    };
    let enabled = count > 0;
    let Some(supervisor) = crate::host::view::RUNNING.get() else {
        return (503, json!({"error": "No bundled host running"}));
    };
    // Linux: the launch carries the count (virtual_displays=N) and the host makes that many
    // KDE virtual monitors for the session itself, so the host's config and its clients'
    // permissions stay as they are.
    #[cfg(not(windows))]
    let reply = {
        let _ = supervisor;
        log::info!("Virtual monitors: {count} from the next launch");
        (202, json!({
            "status": if enabled { "enabled" } else { "disabled" },
            "count": count,
            "deferred": false,
            "host_restarting": false,
        }))
    };
    #[cfg(windows)]
    let reply = apply_virtual_on_windows(supervisor, count, enabled).await;
    reply
}

/// Windows: the host's virtual display driver follows its config and each client's settings.
#[cfg(windows)]
async fn apply_virtual_on_windows(supervisor: &std::sync::Arc<crate::host::Supervisor>, count: u8, enabled: bool) -> (u16, serde_json::Value) {
    let conf_path = supervisor.instance.conf_path();
    let appdata = supervisor.instance.appdata();
    if let Err(err) = crate::host::instance::set_virtual_display_mode(&conf_path, &appdata, count) {
        log::error!("Virtual display mode update failed: {err}");
        return (500, json!({"error": err}));
    }
    log::info!("Virtual display: {} (count={count})", if enabled { "enabled" } else { "disabled" });

    // Load credentials from host.toml before entering spawn_blocking.
    let base = supervisor.instance.base;
    let state = crate::host::load_state();
    let supervisor = supervisor.clone();
    let result = tokio::task::spawn_blocking(move || {
        // Best-effort: a host with no paired clients yet still needs the
        // config change, so don't let this decide the outcome.
        if let Err(err) = update_all_clients_virtual(base, &state.user, &state.password, enabled) {
            log::warn!("Per-client virtual display update failed: {err}");
        }
        // None of the virtual display keys are in Vibepollo's
        // restart_required_keys, so PATCH /api/config applies them without a
        // process restart: immediately when idle, deferred to session end
        // while streaming. The config file write above already persisted the
        // same values, so a failed PATCH only costs a restart, not the setting.
        patch_virtual_display_config(base, &state.user, &state.password, count)
    }).await;

    match result {
        Ok(Ok(deferred)) => {
            log::info!("Virtual display applied via config reload (deferred={deferred})");
            return (202, json!({
                "status": if enabled { "enabled" } else { "disabled" },
                "count": count,
                // The client reconnects to pick up the new manifest. When
                // deferred, Vibepollo applies the change as the session ends.
                "deferred": deferred,
                "host_restarting": false,
            }));
        }
        Ok(Err(err)) => log::warn!("Virtual display config reload failed: {err}; restarting host"),
        Err(err) => log::warn!("Virtual display task panicked: {err}; restarting host"),
    }

    // Fallback only: the config file already holds the new count, so a restart
    // is guaranteed to pick it up even when the HTTP path is unavailable.
    tokio::spawn(async move {
        supervisor.set_wanted(false);
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        supervisor.set_wanted(true);
    });
    (202, json!({
        "status": if enabled { "enabled" } else { "disabled" },
        "count": count,
        "deferred": false,
        "host_restarting": true,
    }))
}

#[cfg(windows)]
/// Applies the virtual display keys through Vibepollo's `PATCH /api/config`,
/// which merges them into the existing config instead of replacing the file.
/// Returns `Ok(true)` when Vibepollo deferred the change to session end.
fn patch_virtual_display_config(base: u16, user: &str, password: &str, count: u8) -> Result<bool, String> {
    let agent = vibepollo_agent();
    let auth = vibepollo_basic_auth(user, password);
    let host_port = base + 1;
    // Values go over as strings: Vibepollo writes non-strings back with
    // serde's JSON form, which its own config parser then has to re-read.
    let mut patch = serde_json::Map::new();
    patch.insert("virtual_display_mode".into(), if count > 0 { "per_client" } else { "disabled" }.into());
    // One permanent slot is all the per-client path needs; the session's extra
    // displays are created at launch from the client's virtual_displays=N.
    patch.insert("dd_virtual_display_permanent_count".into(), count.min(1).to_string().into());
    if count > 0 {
        patch.insert("virtual_display_layout".into(), "extended_isolated".into());
    }
    let body = serde_json::Value::Object(patch).to_string();
    let mut reply = agent
        .patch(format!("https://127.0.0.1:{host_port}/api/config"))
        .header("Authorization", &auth)
        .header("Content-Type", "application/json")
        .send(body.as_bytes())
        .map_err(|e| format!("PATCH /api/config failed: {e}"))?;
    let text = reply.body_mut().with_config().limit(65536).read_to_string()
        .map_err(|e| format!("Failed to read config reply: {e}"))?;
    let parsed: serde_json::Value = serde_json::from_str(&text)
        .map_err(|e| format!("Invalid config reply JSON: {e}"))?;
    if parsed.get("restartRequired").and_then(|v| v.as_bool()).unwrap_or(false) {
        return Err("Vibepollo reported the change needs a restart".into());
    }
    Ok(parsed.get("deferred").and_then(|v| v.as_bool()).unwrap_or(false))
}

#[cfg(windows)]
/// A ureq agent for the managed host: self-signed certificate, fixed loopback
/// only, no proxies and no redirects.
fn vibepollo_agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .timeout_global(Some(std::time::Duration::from_secs(10)))
        .tls_config(ureq::tls::TlsConfig::builder().disable_verification(true).build())
        .build()
        .into()
}

#[cfg(windows)]
/// Calls Vibepollo's `/api/clients/update` for every paired client to set
/// `always_use_virtual_display`. Runs in a blocking thread (ureq is sync).
/// Returns `Ok(())` when at least one client was updated.
fn update_all_clients_virtual(base: u16, user: &str, password: &str, enabled: bool) -> Result<(), String> {
    let agent = vibepollo_agent();
    let auth = vibepollo_basic_auth(user, password);
    let host_port = base + 1;

    // Fetch the list of paired clients.
    let mut reply = agent
        .get(format!("https://127.0.0.1:{host_port}/api/clients/list"))
        .header("Authorization", &auth)
        .call()
        .map_err(|e| format!("Failed to list clients: {e}"))?;
    let list: serde_json::Value = serde_json::from_str(
        &reply.body_mut().with_config().limit(65536).read_to_string()
            .map_err(|e| format!("Failed to read client list: {e}"))?,
    ).map_err(|e| format!("Invalid client list JSON: {e}"))?;

    let empty = vec![];
    let clients = list["named_certs"].as_array().unwrap_or(&empty);
    if clients.is_empty() {
        return Err("No paired clients found".into());
    }

    let mut updated = 0usize;
    for client in clients {
        let Some(uuid) = client["uuid"].as_str() else { continue };
        // Include perm=0xFFFFFFFF (masks to _all) so the existing client
        // permissions are preserved. Without it, perm defaults to _no=0,
        // which revokes the client's "launch" permission and forces re-pairing.
        let body = serde_json::json!({
            "uuid": uuid,
            "always_use_virtual_display": enabled,
            "perm": 0xFFFF_FFFFu32,
        }).to_string();
        match agent
            .post(format!("https://127.0.0.1:{host_port}/api/clients/update"))
            .header("Authorization", &auth)
            .header("Content-Type", "application/json")
            .send(body.as_bytes())
        {
            Ok(_) => updated += 1,
            Err(e) => log::warn!("Failed to update client {uuid}: {e}"),
        }
    }

    if updated == 0 {
        Err(format!("Failed to update any of {} clients", clients.len()))
    } else {
        log::info!("Updated {updated}/{} clients for virtual display (enabled={enabled})", clients.len());
        Ok(())
    }
}

#[cfg(windows)]
fn vibepollo_basic_auth(user: &str, password: &str) -> String {
    const DIGITS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let raw = format!("{user}:{password}");
    let mut out = String::from("Basic ");
    for chunk in raw.as_bytes().chunks(3) {
        let n = ((chunk[0] as u32) << 16)
            | ((chunk.get(1).copied().unwrap_or(0) as u32) << 8)
            | chunk.get(2).copied().unwrap_or(0) as u32;
        out.push(DIGITS[((n >> 18) & 63) as usize] as char);
        out.push(DIGITS[((n >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 { DIGITS[((n >> 6) & 63) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { DIGITS[(n & 63) as usize] as char } else { '=' });
    }
    out
}

fn pairing_body_length(headers: &str) -> io::Result<usize> {
    let mut size=None; let mut json=false;
    for line in headers.lines().skip(1) {
        let Some((key,value))=line.split_once(':') else {continue};
        match key.trim().to_ascii_lowercase().as_str() {
            "origin" | "transfer-encoding" => return Err(io::Error::other("Browser and chunked pairing requests are not accepted")),
            "content-type" => json=value.trim().eq_ignore_ascii_case("application/json"),
            "content-length" => {
                if size.is_some() { return Err(io::Error::other("Duplicate content length")); }
                size=Some(value.trim().parse::<usize>().map_err(|_|io::Error::other("Invalid content length"))?);
            }
            _=>{},
        }
    }
    match size { Some(n) if json && n>0 && n<=4096 => Ok(n), _=>Err(io::Error::other("Pairing requires a bounded JSON body")) }
}

async fn write_json(stream: &mut TcpStream, status: u16, body: &str) -> io::Result<()> {
    let response=format!("HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());
    stream.write_all(response.as_bytes()).await?;
    stream.shutdown().await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn xr_discovery_is_absent_until_service_supplies_a_port() {
        let map = PortMap::new(47989, 1000).unwrap();
        let mut features = Features::default();
        assert!(info(&map, &features).get("xr").is_none());
        features.xr_port = Some(47910);
        assert_eq!(info(&map, &features)["xr"]["port"], 47910);
        assert_eq!(info(&map, &features)["xr"]["authorization"], "allowlist");
    }
    #[test] fn pairing_http_rejects_browser_chunked_and_unbounded_requests() {
        let valid="POST /meteor/pair HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n";
        assert_eq!(pairing_body_length(valid).unwrap(),12);
        for extra in ["Origin: http://site.invalid\r\n","Transfer-Encoding: chunked\r\n","Content-Length: 12\r\n"] {
            assert!(pairing_body_length(&valid.replace("\r\n\r\n",&format!("\r\n{extra}\r\n"))).is_err());
        }
        assert!(pairing_body_length(&valid.replace("12","99999")).is_err());
    }
    #[test] fn virtual_discovery_absent_without_vdd() {
        let map = PortMap::new(47989, 1000).unwrap();
        let features = Features::default();
        assert!(info(&map, &features).get("virtual_display").is_none());
    }
    #[test] fn virtual_discovery_present_with_vdd() {
        let map = PortMap::new(47989, 1000).unwrap();
        let mut features = Features::default();
        features.vdd_installed = true;
        let body = info(&map, &features);
        assert_eq!(body["virtual_display"]["driver_installed"], true);
        assert_eq!(body["virtual_display"]["max_count"], 4);
    }
    #[test] fn virtual_http_rejects_missing_or_oversized_body() {
        let valid = "POST /meteor/virtual HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n";
        assert_eq!(virtual_body_length(valid).unwrap(), 12);
        // Missing content-type.
        assert!(virtual_body_length("POST /meteor/virtual HTTP/1.1\r\nContent-Length: 12\r\n\r\n").is_err());
        // Body too large.
        assert!(virtual_body_length(&valid.replace("12", "257")).is_err());
        // No body.
        assert!(virtual_body_length(&valid.replace("12", "0")).is_err());
    }
    #[tokio::test] async fn virtual_handler_validates_count() {
        let (status, body) = handle_virtual(b"{\"count\":0}").await;
        // No supervisor running in tests — expect 503, not a 400 parse error.
        assert_eq!(status, 503);
        let (status, _) = handle_virtual(b"{\"count\":4}").await;
        assert_eq!(status, 503);
        let (status, _) = handle_virtual(b"{\"count\":5}").await;
        assert_eq!(status, 400);
        let (status, _) = handle_virtual(b"{}").await;
        assert_eq!(status, 400);
        let (status, _) = handle_virtual(b"not json").await;
        assert_eq!(status, 400);
        let _ = body; // suppress unused warning
    }
}
