//! Meteor's settings file, and finding the local Sunshine's base port.

use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::time::Duration;

use serde::Deserialize;

/// The port the Nightfall client probes to find Meteor in front of a host
/// on the default base port. Keep in sync with src/meteor_client.gd.
pub const DEFAULT_DISCOVERY_PORT: u16 = 47900;
/// Meteor's own ports sit this far below the host's base port: discovery,
/// then depth (+1) and the microphone (+2). The client finds Meteor at the
/// same distance below the base of the host it streams from, so a second
/// host and Meteor on another base (49989, say) don't collide with the
/// first.
pub const DISCOVERY_BELOW_BASE: u16 = 89;
pub const DEFAULT_PORT_OFFSET: u16 = 1000;
pub const DEFAULT_SUNSHINE_PORT: u16 = 47989;

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Where Sunshine is reachable from Meteor. Meteor runs on the Sunshine
    /// PC, so this is normally the loopback address.
    pub sunshine_host: String,
    /// Sunshine's base (HTTP) port. Read from Sunshine's config when unset.
    pub sunshine_port: Option<u16>,
    /// Added to every Sunshine port to get the port Meteor listens on.
    pub port_offset: u16,
    /// The port Nightfall probes. Derived from the host's base port when
    /// unset (see DISCOVERY_BELOW_BASE); depth and the microphone use the
    /// next two.
    pub discovery_port: Option<u16>,
    /// libonnxruntime with the CUDA provider. Found next to the binary in
    /// development builds when unset (see onnx.rs).
    pub onnxruntime_lib: Option<PathBuf>,
    /// libncnn, for single-frame models on Vulkan. Found next to the binary
    /// or on the library path when unset (see ncnn.rs).
    pub ncnn_lib: Option<PathBuf>,
    /// A folder with libnvinfer and libnvonnxparser (TensorRT 10), for VDA.
    /// Found in the VDA download's folder or the development venv when
    /// unset (see tensorrt.rs).
    pub tensorrt_dir: Option<PathBuf>,
    /// Folder of depth models (.ncnn.param or .onnx) for the tray's Model menu.
    pub models_dir: Option<PathBuf>,
    /// Run the depth model with TensorRT fp16 once its engine is built.
    pub tensorrt: bool,
    /// Captured host cursor multiplier, applied only while desktop video flows.
    pub host_cursor_scale: u32,
    /// A Vibepollo build to run as the bundled host instead of the
    /// downloaded one (development).
    pub host_binary: Option<PathBuf>,
    /// Extra environment for the bundled host, e.g. LD_LIBRARY_PATH for a
    /// development build linked against libraries outside the system's.
    pub host_env: std::collections::BTreeMap<String, String>,
    /// Optional managed XR service; disabled until explicitly configured.
    pub xr: XrConfig,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            sunshine_host: "127.0.0.1".into(),
            sunshine_port: None,
            port_offset: DEFAULT_PORT_OFFSET,
            discovery_port: None,
            onnxruntime_lib: None,
            ncnn_lib: None,
            tensorrt_dir: None,
            models_dir: None,
            tensorrt: true,
            host_cursor_scale: 1,
            host_binary: None,
            host_env: Default::default(),
            xr: XrConfig::default(),
        }
    }
}

/// Meteor's own ports for a host on `base`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SidePorts {
    pub discovery: u16,
    pub depth: u16,
    pub mic: u16,
}

impl Config {
    pub fn side_ports(&self, base: u16) -> SidePorts {
        let discovery = self.discovery_port.unwrap_or_else(|| base.saturating_sub(DISCOVERY_BELOW_BASE));
        SidePorts { discovery, depth: discovery.saturating_add(1), mic: discovery.saturating_add(2) }
    }
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct XrConfig {
    pub enabled: bool,
    pub listen: String,
    pub video_port: u16,
    pub tracking_port: u16,
    pub allowed_client: Option<String>,
    pub runtime_root: Option<PathBuf>,
    /// auto prefers NVIDIA when available; vaapi selects AMD HEVC explicitly.
    pub encoder_backend: String,
    /// Optional AMD DRM render node for machines with multiple AMD GPUs.
    pub render_device: Option<PathBuf>,
}

impl Default for XrConfig {
    fn default() -> Self {
        Self { enabled: false, listen: "0.0.0.0:47910".into(), video_port: 47911, tracking_port: 47912, allowed_client: None, runtime_root: None, encoder_backend: "auto".into(), render_device: None }
    }
}

impl XrConfig {
    pub fn runtime_root(&self) -> PathBuf {
        self.runtime_root.clone().unwrap_or_else(|| data_dir().join("xr"))
    }
}

pub fn config_path() -> PathBuf {
    config_dir().join("meteor.toml")
}

pub fn load() -> Config {
    let path = config_path();
    match std::fs::read_to_string(&path) {
        Ok(text) => match toml::from_str(&text) {
            Ok(config) => config,
            Err(err) => {
                log::warn!("Ignoring {}: {err}", path.display());
                Config::default()
            }
        },
        Err(_) => Config::default(),
    }
}

/// Where the tray remembers its choices (model, rate). Kept apart from
/// meteor.toml so routine tray choices never rewrite a file the user edits.
/// Explicit PCVR setup changes only xr.enabled, retaining comments and a backup.
pub fn state_path() -> PathBuf {
    config_dir().join("state.toml")
}

/// TensorRT engines (rebuilt automatically if deleted).
pub fn cache_dir() -> PathBuf {
    if cfg!(windows) {
        return std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default().join("Nightfall Meteor");
    }
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
        .unwrap_or_default();
    base.join("nightfall-meteor")
}

/// Downloaded runtimes and the default models folder.
pub fn data_dir() -> PathBuf {
    if cfg!(windows) {
        return std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default().join("Nightfall Meteor");
    }
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/share")))
        .unwrap_or_default();
    base.join("nightfall-meteor")
}

pub fn default_models_dir() -> PathBuf {
    data_dir().join("models")
}

pub fn config_dir() -> PathBuf {
    if cfg!(windows) {
        let appdata = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default();
        return appdata.join("Nightfall Meteor");
    }
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_default();
    base.join("nightfall-meteor")
}

/// Sunshine and its forks keep the base port in their config file, as
/// `port = 47989`, or leave it out to use the default. Several can be
/// installed side by side, so the first configured port that is actually
/// listening wins.
pub fn detect_sunshine_port(host: &str) -> u16 {
    let mut candidates: Vec<u16> = Vec::new();
    for path in sunshine_config_candidates() {
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        let port = parse_port(&text).unwrap_or(DEFAULT_SUNSHINE_PORT);
        log::debug!("{} sets base port {port}", path.display());
        if !candidates.contains(&port) {
            candidates.push(port);
        }
    }
    if !candidates.contains(&DEFAULT_SUNSHINE_PORT) {
        candidates.push(DEFAULT_SUNSHINE_PORT);
    }
    candidates
        .iter()
        .copied()
        .find(|port| is_listening(host, *port))
        .unwrap_or(candidates[0])
}

pub fn is_listening(host: &str, port: u16) -> bool {
    let addrs: Vec<SocketAddr> = match (host, port).to_socket_addrs() {
        Ok(addrs) => addrs.collect(),
        Err(_) => return false,
    };
    addrs
        .iter()
        .any(|addr| TcpStream::connect_timeout(addr, Duration::from_millis(300)).is_ok())
}

fn parse_port(conf: &str) -> Option<u16> {
    conf.lines().find_map(|line| {
        let (key, value) = line.split_once('=')?;
        if key.trim() != "port" {
            return None;
        }
        value.trim().parse().ok()
    })
}

fn sunshine_config_candidates() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if cfg!(windows) {
        for dir in ["Sunshine", "Apollo", "Vibepollo", "Vibeshine"] {
            paths.push(PathBuf::from(format!(r"C:\Program Files\{dir}\config\sunshine.conf")));
        }
    } else {
        let config = config_dir().parent().map(PathBuf::from).unwrap_or_default();
        for dir in ["vibepollo", "vibeshine", "apollo", "sunshine"] {
            paths.push(config.join(dir).join("sunshine.conf"));
        }
        paths.push(config.join("polaris").join("polaris.conf"));
    }
    paths
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xr_is_opt_in_and_saved_authorization_is_retained() {
        let old: Config = toml::from_str("sunshine_host = '127.0.0.1'").unwrap();
        assert!(!old.xr.enabled);
        assert!(old.xr.allowed_client.is_none());
        let configured: Config = toml::from_str("[xr]\nenabled = true\nlisten = '127.0.0.1:47910'\nallowed_client = 'authorized-key'\nruntime_root = '/opt/meteor-xr'").unwrap();
        assert!(configured.xr.enabled);
        assert_eq!(configured.xr.allowed_client.as_deref(), Some("authorized-key"));
        assert_eq!(configured.xr.runtime_root(), PathBuf::from("/opt/meteor-xr"));
    }

    #[test]
    fn parses_port_line() {
        assert_eq!(parse_port("address_family = both\nport = 57989\n"), Some(57989));
        assert_eq!(parse_port("# port = 1\nupnp = on\n"), None);
    }

    #[test]
    fn side_ports_follow_the_base() {
        let config = Config::default();
        assert_eq!(config.side_ports(47989), SidePorts { discovery: 47900, depth: 47901, mic: 47902 });
        assert_eq!(config.side_ports(49989), SidePorts { discovery: 49900, depth: 49901, mic: 49902 });
        let pinned = Config { discovery_port: Some(40000), ..Config::default() };
        assert_eq!(pinned.side_ports(49989), SidePorts { discovery: 40000, depth: 40001, mic: 40002 });
    }
}
