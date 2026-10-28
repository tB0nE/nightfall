//! The bundled game streaming host: "Meteor-Vibepollo for Nightfall", our fork of
//! Vibepollo, run by Meteor so a PC needs nothing else installed (Linux).
//!
//! It is a choice in the tray, kept in `host.toml` next to meteor.toml.
//! External hosts (Sunshine, Apollo, Polaris, a Vibepollo the user
//! installed) stay the default and work as before. The bundled one lives in
//! Meteor's own folders, never in `~/.config/vibepollo`, so it can't touch
//! a Vibepollo the user runs themselves.
//!
//! Its base port is 47989 when that's free. When another host or a second
//! Meteor holds it, the next free base in BASES is used, and kept in
//! host.toml so the headset's pairing stays valid across restarts.

mod detect;
mod install;
mod instance;
mod supervisor;
pub mod setup;
pub mod view;

use std::io::Write;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

pub use detect::other_hosts;
pub use install::{Install, RELEASE};
pub use instance::Instance;
pub use supervisor::{Phase, Supervisor};

use crate::ports::{CHANNELS, PortMap, Proto};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Choice {
    /// A host the user installed; Meteor only finds its port.
    #[default]
    External,
    /// Meteor runs Meteor-Vibepollo for Nightfall.
    Bundled,
}

/// `host.toml`. Holds the web UI password, so it's written owner-only.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    pub choice: Choice,
    /// The bundled host's base port, once chosen.
    pub base: Option<u16>,
    /// The bundled host's web UI login, set by Meteor with `--creds`.
    pub user: String,
    pub password: String,
}

/// Base ports to try, in order. Each stack (host, Meteor's proxy at +1000,
/// Meteor's own ports below the base) fits between two of them.
pub const BASES: [u16; 4] = [47989, 49989, 51989, 53989];

pub fn state_path() -> PathBuf {
    crate::config::config_dir().join("host.toml")
}

pub fn load_state() -> State {
    std::fs::read_to_string(state_path()).ok().and_then(|text| toml::from_str(&text).ok()).unwrap_or_default()
}

pub fn save_state(state: &State) -> Result<(), String> {
    let path = state_path();
    let text = toml::to_string(state).map_err(|e| e.to_string())?;
    let fail = |e: std::io::Error| format!("{}: {e}", path.display());
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(fail)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(&path).map_err(fail)?;
    file.write_all(text.as_bytes()).map_err(fail)
}

/// Where the bundled host keeps its config, credentials and logs
/// (`CONFIGURATION_DIRECTORY`; Vibepollo adds `vibepollo/`).
pub fn instance_dir() -> PathBuf {
    crate::config::config_dir().join("host")
}

/// Every port a host on `base` and the Meteor in front of it would use.
pub fn stack_ports(base: u16, offset: u16, side: crate::config::SidePorts) -> Vec<(u16, Proto)> {
    let mut ports = vec![(base + 1, Proto::Tcp), (side.discovery, Proto::Tcp), (side.depth, Proto::Tcp), (side.mic, Proto::Udp)];
    if let Ok(map) = PortMap::new(base, offset) {
        for ch in CHANNELS {
            ports.push((map.sunshine(ch), ch.proto));
            ports.push((map.meteor(ch), ch.proto));
        }
    }
    ports
}

/// The first base whose whole stack is free, preferring the one used last.
pub fn choose_base(preferred: Option<u16>, mut stack_free: impl FnMut(u16) -> bool) -> Option<u16> {
    preferred.into_iter().chain(BASES).find(|&base| stack_free(base))
}

/// Whether nothing is bound to the port yet.
pub fn port_free((port, proto): (u16, Proto)) -> bool {
    match proto {
        Proto::Tcp => std::net::TcpListener::bind(("0.0.0.0", port)).is_ok(),
        Proto::Udp => std::net::UdpSocket::bind(("0.0.0.0", port)).is_ok(),
    }
}

/// The host to run: `host_binary` from meteor.toml, else the installed
/// release.
pub fn binary(config: &crate::config::Config) -> Option<PathBuf> {
    config.host_binary.clone().or_else(|| RELEASE.as_ref().and_then(Install::binary))
}

/// Picks the bundled host's base port: the one used last when its whole
/// stack is free, else the first free one. Saves it in host.toml, so
/// Meteor keeps that base (and the headset's pairing) even while the host
/// itself can't start.
pub fn reserve_base(config: &crate::config::Config, state: &mut State) -> Result<u16, String> {
    let base = choose_base(state.base, |base| {
        stack_ports(base, config.port_offset, config.side_ports(base)).into_iter().all(port_free)
    })
    .ok_or("no free base port for the host (tried 47989, 49989, 51989, 53989)")?;
    if state.base != Some(base) {
        state.base = Some(base);
        save_state(state)?;
    }
    Ok(base)
}

/// Gets the bundled host ready to start on `base`: writes its config and,
/// the first time, its login. Saves host.toml.
pub fn prepare(config: &crate::config::Config, state: &mut State, base: u16) -> Result<Instance, String> {
    let binary = binary(config).ok_or("Meteor-Vibepollo for Nightfall isn't installed")?;
    let env = config.host_env.iter().map(|(k, v)| (k.clone(), v.clone())).collect();
    let instance = Instance { binary, base, dir: instance_dir(), env };
    instance.write_config(&instance::host_name())?;
    if state.password.is_empty() || !instance.appdata().join("sunshine_state.json").is_file() {
        let user = "nightfall".to_string();
        let password = new_password();
        instance.set_creds(&user, &password)?;
        state.user = user;
        state.password = password;
        save_state(state)?;
    }
    write_kwin_permission(&instance.binary);
    Ok(instance)
}

/// KDE lets a program capture the screen without asking when a desktop
/// entry for its exact path lists KWin's screencast interface. Written to
/// the user's own applications folder; no root needed.
fn write_kwin_permission(binary: &std::path::Path) {
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default();
    if !desktop.split(':').any(|d| d.eq_ignore_ascii_case("KDE")) {
        return;
    }
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .unwrap_or_default();
    let path = base.join("applications").join("nightfall-meteor-host-kwin.desktop");
    let entry = format!(
        "[Desktop Entry]\nType=Application\nName=Meteor-Vibepollo for Nightfall (screen capture)\n\
         Comment=Lets Nightfall Meteor's host capture the screen\nExec={}\n\
         X-KDE-Wayland-Interfaces=zkde_screencast_unstable_v1\nNoDisplay=true\n",
        binary.canonicalize().unwrap_or_else(|_| binary.to_path_buf()).display()
    );
    if std::fs::read_to_string(&path).ok().as_deref() == Some(entry.as_str()) {
        return;
    }
    let written = path.parent().map_or(Ok(()), std::fs::create_dir_all).and_then(|()| std::fs::write(&path, entry));
    match written {
        Ok(()) => log::info!("KDE screen capture allowed for the host ({})", path.display()),
        Err(err) => log::warn!("Can't write {}: {err}", path.display()),
    }
}

/// A random password for the web UI, which only Meteor uses.
pub fn new_password() -> String {
    let mut bytes = [0u8; 18];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).expect("system random");
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;

    #[test]
    fn stacks_on_neighbouring_bases_dont_overlap() {
        let config = Config::default();
        let ports = |base| stack_ports(base, 1000, config.side_ports(base));
        for pair in BASES.windows(2) {
            let a = ports(pair[0]);
            let b = ports(pair[1]);
            assert!(a.iter().all(|p| !b.contains(p)), "{} and {} overlap", pair[0], pair[1]);
        }
    }

    #[test]
    fn default_stack_has_the_known_ports() {
        let ports = stack_ports(47989, 1000, Config::default().side_ports(47989));
        for p in [(47984, Proto::Tcp), (47989, Proto::Tcp), (47990, Proto::Tcp), (48010, Proto::Tcp), (47998, Proto::Udp), (48989, Proto::Tcp), (47900, Proto::Tcp), (47902, Proto::Udp)] {
            assert!(ports.contains(&p), "{p:?} missing");
        }
    }

    #[test]
    fn chooses_the_remembered_base_then_the_first_free() {
        assert_eq!(choose_base(Some(51989), |_| true), Some(51989));
        assert_eq!(choose_base(Some(51989), |b| b != 51989 && b != 47989), Some(49989));
        assert_eq!(choose_base(None, |_| false), None);
    }

    #[test]
    fn state_round_trips() {
        let state = State { choice: Choice::Bundled, base: Some(49989), user: "nightfall".into(), password: "x".into() };
        let back: State = toml::from_str(&toml::to_string(&state).unwrap()).unwrap();
        assert_eq!(back.choice, Choice::Bundled);
        assert_eq!(back.base, Some(49989));
        let empty: State = toml::from_str("").unwrap();
        assert_eq!(empty.choice, Choice::External);
    }
}
