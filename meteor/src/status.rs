//! What the tray shows about Sunshine itself.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::ports::PortMap;

pub struct Status {
    pub map: PortMap,
    pub sunshine_host: String,
    pub discovery_port: u16,
    pub sunshine_up: AtomicBool,
    pub firewall: Mutex<crate::firewall::Status>,
}

impl Status {
    /// The ports the Quest needs open.
    pub fn quest_ports(&self) -> Vec<(u16, crate::ports::Proto)> {
        crate::firewall::ports(&self.map, self.discovery_port)
    }

    pub fn firewall(&self) -> crate::firewall::Status {
        self.firewall.lock().map_or(crate::firewall::Status::Checking, |f| f.clone())
    }

    /// Checks the firewall in the background.
    pub fn check_firewall(self: &Arc<Self>) {
        let status = self.clone();
        std::thread::spawn(move || {
            let result = crate::firewall::check(&status.quest_ports());
            match &result {
                crate::firewall::Status::Blocked { zone, ports } => {
                    log::warn!("The firewall (zone {zone}) blocks {} of the ports the Quest needs", ports.len())
                }
                crate::firewall::Status::Ufw => log::info!("ufw is active; Meteor can't read its rules"),
                crate::firewall::Status::Open => log::info!("Firewall: the Quest's ports are open"),
                crate::firewall::Status::Checking => {}
            }
            if let Ok(mut f) = status.firewall.lock() {
                *f = result;
            }
        });
    }

    /// Opens the ports (asking for a password), then checks again.
    pub fn allow_firewall(self: &Arc<Self>) {
        let status = self.clone();
        std::thread::spawn(move || {
            if let Err(err) = crate::firewall::allow(&status.firewall(), &status.quest_ports()) {
                log::warn!("{err}");
            }
            status.check_firewall();
        });
    }
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
