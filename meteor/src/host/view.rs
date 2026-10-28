//! The bundled host as the rest of Meteor sees it: prepared before the
//! ports are chosen, started once Meteor holds its single-instance lock,
//! and read by the tray and discovery.

use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use serde_json::json;

use super::{Choice, Install, Instance, RELEASE, State, Supervisor};
use crate::download::Download;

/// The running host, for quit and restart.
pub static RUNNING: OnceLock<Arc<Supervisor>> = OnceLock::new();

#[derive(Default)]
pub struct View {
    pub state: State,
    /// The host to run, from meteor.toml or the installed release.
    pub binary: Option<PathBuf>,
    /// Why the chosen bundled host couldn't be prepared.
    pub error: Option<String>,
    pub supervisor: Option<Arc<Supervisor>>,
    /// The host download, shown in the tray.
    pub download: Arc<Download>,
    pub input: Arc<super::input::Access>,
    pub pairing: Option<Arc<super::pairing::Pairing>>,
    instance: Option<Instance>,
    installing: std::sync::atomic::AtomicBool,
}

impl View {
    /// Loads host.toml and, when the bundled host is chosen, prepares it.
    /// Returns its base port, which Meteor uses even if the host can't
    /// start, so the tray can say why without Meteor taking another
    /// stack's ports.
    pub fn prepare(&mut self, config: &crate::config::Config) -> Option<u16> {
        self.state = super::load_state();
        self.binary = super::binary(config);
        if self.state.choice != Choice::Bundled {
            return None;
        }
        let base = match super::reserve_base(config, &mut self.state) {
            Ok(base) => base,
            Err(err) => {
                log::error!("Can't start the bundled host: {err}");
                self.error = Some(err);
                return None;
            }
        };
        match super::prepare(config, &mut self.state, base) {
            Ok(instance) => {
                log::info!("Bundled host: {} on base port {base}", instance.binary.display());
                self.instance = Some(instance);
            }
            Err(err) => {
                log::error!("Can't start the bundled host: {err}");
                self.error = Some(err);
            }
        }
        Some(base)
    }

    pub fn start(&mut self) {
        if let Some(instance) = self.instance.take() {
            let supervisor = Supervisor::start(instance);
            let _ = RUNNING.set(supervisor.clone());
            self.supervisor = Some(supervisor);
        }
    }

    /// The `host` entry in Meteor's discovery answer, while Meteor runs the
    /// host.
    pub fn discovery_info(&self) -> Option<serde_json::Value> {
        self.supervisor.as_ref().map(|_| {
            let mut info = json!({
                "kind": "meteor-vibepollo",
                "managed": true,
                "version": RELEASE.as_ref().map_or("development", |r| r.version),
            });
            if self.pairing.is_some() {
                info["pairing"] = json!({"path":"/meteor/pair", "protocol":1, "encryption":crate::crypto::ENCRYPTION});
            }
            info
        })
    }

    /// Saves the choice and restarts Meteor on the new host.
    pub fn switch(&self, choice: Choice) {
        let mut state = self.state.clone();
        state.choice = choice;
        if let Err(err) = super::save_state(&state) {
            log::error!("Can't save the host choice: {err}");
            return;
        }
        crate::restart();
    }

    /// Downloads the release on a thread, then switches to it.
    pub fn download_and_switch(self: &Arc<Self>) {
        let Some(release) = RELEASE.as_ref() else { return };
        if self.installing.compare_exchange(false,true,std::sync::atomic::Ordering::AcqRel,
            std::sync::atomic::Ordering::Acquire).is_err() {return;}
        let view = self.clone();
        let runtime=tokio::runtime::Handle::current();
        std::thread::spawn(move || match Install::run(&view.download, release) {
            Ok(binary) => {
                view.installing.store(false,std::sync::atomic::Ordering::Release);
                log::info!("Installed {}", binary.display());
                view.switch(Choice::Bundled);
            }
            Err(err) => {
                view.installing.store(false,std::sync::atomic::Ordering::Release);
                log::error!("Host download failed: {err}");
                runtime.spawn(async move {crate::desktop::notify("Host setup did not finish",
                    &format!("{err}. You can retry from Meteor's tray menu.")).await;});
            },
        });
    }
}
