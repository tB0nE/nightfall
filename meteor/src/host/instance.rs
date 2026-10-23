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
        self.dir.join("vibepollo")
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
        let text = render_config(
            &existing,
            &[("port", self.base.to_string())],
            &[("sunshine_name", name.to_string()), ("address_family", "both".into())],
        );
        if text != existing {
            std::fs::write(&path, text).map_err(fail)?;
        }
        Ok(())
    }

    pub fn command(&self) -> Command {
        let mut command = Command::new(&self.binary);
        command.arg(self.conf_path()).env("CONFIGURATION_DIRECTORY", &self.dir).envs(self.env.iter().cloned());
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

/// `existing` with `always` keys set to their values, and `initial` keys
/// added when missing. A header explains who wrote it.
fn render_config(existing: &str, always: &[(&str, String)], initial: &[(&str, String)]) -> String {
    let key_of = |line: &str| line.split_once('=').map(|(k, _)| k.trim().to_string());
    let mut lines: Vec<String> = Vec::new();
    if existing.trim().is_empty() {
        lines.push("# Vibepollo for Nightfall, run by Nightfall Meteor.".into());
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
        assert!(text.starts_with("# Vibepollo for Nightfall"));
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
}
