//! What the tray shows about Sunshine itself.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::ports::PortMap;

pub struct Status {
    pub map: PortMap,
    pub sunshine_host: String,
    pub discovery_port: u16,
    pub sunshine_up: AtomicBool,
}

/// Checks every few seconds whether Sunshine is accepting connections.
pub async fn watch_sunshine(status: Arc<Status>) {
    let mut tick = tokio::time::interval(Duration::from_secs(5));
    loop {
        tick.tick().await;
        let host = status.sunshine_host.clone();
        let port = status.map.sunshine_base;
        let up = tokio::task::spawn_blocking(move || crate::config::is_listening(&host, port))
            .await
            .unwrap_or(false);
        if status.sunshine_up.swap(up, Ordering::Relaxed) != up {
            if up {
                log::info!("Sunshine is running on port {port}");
            } else {
                log::warn!("Sunshine is not answering on port {port}");
            }
        }
    }
}
