//! One bundled host: which binary, which base port, and its own config
//! folder. Vibepollo reads `CONFIGURATION_DIRECTORY` before the XDG
//! folders, so the child gets that and nothing else changes in its
//! environment.

use std::path::PathBuf;
use std::process::Command;

pub struct Instance {
    pub binary: PathBuf,
    pub base: u16,
    /// `CONFIGURATION_DIRECTORY` for the child.
    pub dir: PathBuf,
    /// `host_env` from meteor.toml.
    pub env: Vec<(String, String)>,
}

/// Settings Meteor owns: rewritten on every start.
const MANAGED: [&str; 1] = ["port"];

impl Instance {
    /// Vibepollo's data folder: config, state, credentials and logs.
    pub fn appdata(&self) -> PathBuf {
        #[cfg(windows)]
        {
            // Windows Vibepollo stores state beside its executable. A
            // dedicated installed host directory keeps it separate from
            // Apollo, Sunshine and the user's own Vibepollo installation.
            return self.binary.parent().unwrap_or(&self.dir).join("config");
        }
        #[cfg(not(windows))]
        self.dir.join("vibepollo")
    }

    /// Written by the host while it captures several monitors; read by Meteor's depth.
    pub fn capture_region_path(&self) -> PathBuf {
        self.appdata().join("capture-region")
    }

    pub fn conf_path(&self) -> PathBuf {
        self.appdata().join("sunshine.conf")
    }

    /// Writes sunshine.conf: the port every time, and on the first run a
    /// name and `address_family = both` (USB Link needs IPv6). Anything the
    /// user adds is kept.
    pub fn write_config(&self, name: &str) -> Result<(), String> {
        let path = self.conf_path();
        let fail = |e: std::io::Error| format!("{}: {e}", path.display());
        std::fs::create_dir_all(self.appdata()).map_err(fail)?;
        let existing = std::fs::read_to_string(&path).unwrap_or_default();
        let mut initial = vec![("sunshine_name", name.to_string()), ("address_family", "both".into())];
        #[cfg(windows)]
        {
            initial.push(("system_tray", "false".into()));
            // Meteor captures the user's connected monitors by default. The
            // host's Windows 11 default instead creates a virtual display,
            // which needs driver access a normal desktop process may lack.
            // An explicit user choice remains untouched by render_config.
            initial.push(("virtual_display_mode", "disabled".into()));
            // Preserve the user's desktop resolution. The default "automatic"
            // resizes the display to match the stream, which breaks 1440p+
            // desktops when connecting from a 1080p headset.
            initial.push(("dd_resolution_option", "disabled".into()));
        }
        let text = render_config(&existing, &[("port", self.base.to_string())], &initial);
        if text != existing {
            std::fs::write(&path, text).map_err(fail)?;
        }
        // Describes a capture that ended with the previous process.
        match std::fs::remove_file(self.capture_region_path()) {
            Ok(()) => {},
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {},
            Err(e) => return Err(fail(e)),
        }
        // Runtime-only control. Never inherit a previous process's multiplier.
        std::fs::write(self.appdata().join("cursor-scale"), "1\n").map_err(fail)?;
        match std::fs::remove_file(self.appdata().join("cursor-scale.supported")) {
            Ok(()) => {},
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {},
            Err(e) => return Err(fail(e)),
        }
        Ok(())
    }

    pub fn command(&self) -> Command {
        let mut command = Command::new(&self.binary);
        command.arg(self.conf_path()).env("CONFIGURATION_DIRECTORY", &self.dir).envs(self.env.iter().cloned());
        command.env("METEOR_CURSOR_SCALE_FILE", self.appdata().join("cursor-scale"));
        // The host writes the primary monitor's rectangle in its capture frame here, so depth can
        // cover that monitor alone when several are tiled into one frame.
        command.env("METEOR_CAPTURE_REGION_FILE", self.capture_region_path());
        command.env("METEOR_DEFAULT_PRIMARY_OUTPUT", "1");
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
        }
        // A development build finds its web UI files next to itself.
        if let Some(dir) = self.binary.parent() {
            command.current_dir(dir);
        }
        command
    }

    /// Sets the web UI login (`--creds`), which Meteor uses for pairing.
    pub fn set_creds(&self, user: &str, password: &str) -> Result<(), String> {
        let output = self
            .command()
            .args(["--creds", user, password])
            .output()
            .map_err(|e| format!("{}: {e}", self.binary.display()))?;
        if output.status.success() && self.appdata().join("sunshine_state.json").is_file() {
            Ok(())
        } else {
            Err(format!("setting the host's login failed ({}): {}", output.status, String::from_utf8_lossy(&output.stderr).trim()))
        }
    }
}

/// Sets the virtual display count in sunshine.conf (0 = disabled, 1–4 = enabled).
/// Sets `virtual_display_mode = per_client` and `dd_virtual_display_permanent_count
/// = count` when count > 0. A permanent slot must exist for Vibepollo's
/// `resolve_virtual_device_id` (`allow_any_fallback=false`).
/// `virtual_display_layout = extended_isolated` keeps physical monitors active.
/// When count = 0, sets mode to `disabled` and clears the permanent count.

#[cfg(windows)]
pub fn set_virtual_display_mode(conf_path: &std::path::Path, appdata: &std::path::Path, count: u8) -> Result<(), String> {
    let fail = |e: std::io::Error| format!("{}: {e}", conf_path.display());
    std::fs::create_dir_all(appdata).map_err(fail)?;
    let existing = std::fs::read_to_string(conf_path).unwrap_or_default();
    let mode = if count > 0 { "per_client" } else { "disabled" };
    let mut always: Vec<(&str, String)> = vec![
        ("virtual_display_mode", mode.into()),
        ("dd_virtual_display_permanent_count", count.min(1).to_string()),
    ];
    if count > 0 {
        always.push(("virtual_display_layout", "extended_isolated".into()));
    }
    let text = render_config(&existing, &always, &[]);
    if text != existing {
        std::fs::write(conf_path, text).map_err(fail)?;
    }
    Ok(())
}

/// `existing` with `always` keys set to their values, and `initial` keys
/// added when missing. A header explains who wrote it.
pub(crate) fn render_config(existing: &str, always: &[(&str, String)], initial: &[(&str, String)]) -> String {
    let key_of = |line: &str| line.split_once('=').map(|(k, _)| k.trim().to_string());
    let mut lines: Vec<String> = Vec::new();
    if existing.trim().is_empty() {
        lines.push("# Meteor-Vibepollo for Nightfall, run by Nightfall Meteor.".into());
        lines.push(format!("# Meteor sets {} on every start; other settings are yours.", MANAGED.join(", ")));
    }
    let mut seen: Vec<String> = Vec::new();
    for line in existing.lines() {
        match key_of(line).filter(|_| !line.trim_start().starts_with('#')) {
            Some(key) => {
                if let Some((_, value)) = always.iter().find(|(k, _)| *k == key) {
                    lines.push(format!("{key} = {value}"));
                } else {
                    lines.push(line.to_string());
                }
                seen.push(key);
            }
            None => lines.push(line.to_string()),
        }
    }
    for (key, value) in always.iter().chain(initial) {
        if !seen.iter().any(|k| k == key) {
            lines.push(format!("{key} = {value}"));
        }
    }
    let mut text = lines.join("\n");
    text.push('\n');
    text
}

/// "my-pc (Nightfall)": the name the headset lists the host under.
pub fn host_name() -> String {
    #[cfg(windows)]
    let name = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "PC".into());
    // The name in System Settings > General > About, as the headset should show it.
    #[cfg(target_os = "macos")]
    let name = std::process::Command::new("/usr/sbin/scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Mac".into());
    #[cfg(target_os = "linux")]
    let name = std::fs::read_to_string("/etc/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "PC".into());
    format!("{name} (Nightfall)")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_a_new_config() {
        let text = render_config("", &[("port", "49989".into())], &[("sunshine_name", "pc (Nightfall)".into()), ("address_family", "both".into())]);
        assert!(text.starts_with("# Meteor-Vibepollo for Nightfall"));
        assert!(text.contains("\nport = 49989\n"));
        assert!(text.contains("\nsunshine_name = pc (Nightfall)\n"));
        assert!(text.ends_with("address_family = both\n"));
    }

    #[test]
    fn keeps_user_settings_and_updates_the_port() {
        let existing = "# mine\nport = 47989\nsunshine_name = Living room\ncapture = kwin\n";
        let text = render_config(existing, &[("port", "49989".into())], &[("sunshine_name", "pc (Nightfall)".into()), ("address_family", "both".into())]);
        assert_eq!(text, "# mine\nport = 49989\nsunshine_name = Living room\ncapture = kwin\naddress_family = both\n");
        // Nothing changes on the next start.
        assert_eq!(render_config(&text, &[("port", "49989".into())], &[("sunshine_name", "x".into())]), text);
    }

    #[test]
    fn physical_capture_default_preserves_explicit_virtual_display_choice() {
        let defaults=[("virtual_display_mode", "disabled".into())];
        assert!(render_config("port = 47989\n", &[], &defaults)
            .contains("virtual_display_mode = disabled\n"));
        let explicit="virtual_display_mode = per_client\n";
        assert_eq!(render_config(explicit, &[], &defaults),explicit);
    }

    #[cfg(windows)]
    #[test]
    fn set_virtual_display_mode_writes_and_toggles() {
        let dir = std::env::temp_dir().join(format!("meteor_vdd_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let conf = dir.join("sunshine.conf");
        // Enable (count=1): writes per_client + count=1 + extended_isolated.
        set_virtual_display_mode(&conf, &dir, 1).unwrap();
        let text = std::fs::read_to_string(&conf).unwrap();
        assert!(text.contains("virtual_display_mode = per_client\n"), "{text}");
        assert!(text.contains("dd_virtual_display_permanent_count = 1\n"), "{text}");
        assert!(text.contains("virtual_display_layout = extended_isolated\n"), "{text}");
        // Enable (count=2): the permanent count stays 1; extra displays are per session.
        set_virtual_display_mode(&conf, &dir, 2).unwrap();
        let text_c2 = std::fs::read_to_string(&conf).unwrap();
        assert!(text_c2.contains("dd_virtual_display_permanent_count = 1\n"), "{text_c2}");
        // Disable (count=0): overwrites mode and count, leaves layout alone.
        set_virtual_display_mode(&conf, &dir, 0).unwrap();
        let text2 = std::fs::read_to_string(&conf).unwrap();
        assert!(text2.contains("virtual_display_mode = disabled\n"), "{text2}");
        assert!(text2.contains("dd_virtual_display_permanent_count = 0\n"), "{text2}");
        // Idempotent: no write when nothing changes.
        let mtime = std::fs::metadata(&conf).unwrap().modified().unwrap();
        set_virtual_display_mode(&conf, &dir, 0).unwrap();
        assert_eq!(std::fs::metadata(&conf).unwrap().modified().unwrap(), mtime);
        std::fs::remove_dir_all(&dir).ok();
    }
}
