//! The endpoint the Nightfall client probes before connecting:
//! `GET http://<host>:47900/meteor` returns which ports to use.

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
    pub mic_port: Option<u16>,
    pub depth: Option<(u16, Arc<Depth>)>,
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
    // Optional features; older clients ignore keys they don't know.
    if let Some(port) = features.mic_port {
        info["mic"] = json!({ "port": port, "formats": [crate::mic::FORMAT_PCM_S16LE_48K_MONO] });
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
            "width": width,
            "height": height,
            "model": model,
            "max_hz": depth.rate(),
        });
    }
    info
}

pub async fn bind(port: u16) -> io::Result<TcpListener> {
    match TcpListener::bind(("::", port)).await {
        Ok(listener) => Ok(listener),
        Err(_) => TcpListener::bind(("0.0.0.0", port)).await,
    }
}

pub async fn serve(listener: TcpListener, map: PortMap, features: Features) {
    loop {
        let Ok((stream, peer)) = listener.accept().await else { continue };
        // Built per request: depth comes and goes with the tray toggle and model loads.
        let body = info(&map, &features).to_string();
        tokio::spawn(async move {
            match respond(stream, &body).await {
                Ok(path) => log::info!("Discovery probe from {peer} ({path})"),
                Err(err) => log::debug!("Discovery probe from {peer} failed: {err}"),
            }
        });
    }
}

async fn respond(mut stream: TcpStream, body: &str) -> io::Result<String> {
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
    let request = String::from_utf8_lossy(&request);
    let path = request.split_whitespace().nth(1).unwrap_or("").to_string();
    let response = if path == "/meteor" || path.starts_with("/meteor?") {
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
