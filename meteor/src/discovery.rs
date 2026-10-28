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
    #[cfg(target_os = "linux")]
    pub pairing: Option<Arc<crate::host::pairing::Pairing>>,
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
        info["xr"] = json!({"port": port, "backend": "linux-nvidia", "authorization": "allowlist", "protocol": 1});
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
    #[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
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

#[cfg(target_os = "linux")]
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
    #[cfg(target_os = "linux")]
    #[test] fn pairing_http_rejects_browser_chunked_and_unbounded_requests() {
        let valid="POST /meteor/pair HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n";
        assert_eq!(pairing_body_length(valid).unwrap(),12);
        for extra in ["Origin: http://site.invalid\r\n","Transfer-Encoding: chunked\r\n","Content-Length: 12\r\n"] {
            assert!(pairing_body_length(&valid.replace("\r\n\r\n",&format!("\r\n{extra}\r\n"))).is_err());
        }
        assert!(pairing_body_length(&valid.replace("12","99999")).is_err());
    }
}
