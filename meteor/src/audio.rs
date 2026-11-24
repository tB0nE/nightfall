//! Where a stream's audio plays: in the headset, on the PC, or both.
//!
//! The choice lives in meteor.toml (`audio_output`) and is announced in the
//! discovery answer and `/meteor/host-status`. Meteor can't apply it itself:
//! the launch request carrying Moonlight's `localAudioPlayMode` is TLS between
//! Nightfall and the host. Nightfall reads the choice, sends the matching
//! flag when it launches, mutes its own playback for "PC", and restarts the
//! stream when a change needs a different flag.

use std::io;
use std::sync::atomic::{AtomicU8, Ordering};

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Output {
    /// The host mutes the PC and streams the sound (Moonlight's default).
    #[default]
    Headset,
    /// The PC keeps playing; the headset stays silent.
    Pc,
    /// Both play.
    Both,
}

impl Output {
    pub const ALL: [Self; 3] = [Self::Headset, Self::Pc, Self::Both];

    pub fn id(self) -> &'static str {
        match self {
            Self::Headset => "headset",
            Self::Pc => "pc",
            Self::Both => "both",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Headset => "Headset",
            Self::Pc => "PC",
            Self::Both => "Headset and PC",
        }
    }

    fn index(self) -> u8 {
        Self::ALL.iter().position(|o| *o == self).unwrap_or(0) as u8
    }
}

static OUTPUT: AtomicU8 = AtomicU8::new(0);

/// Takes the saved choice at startup.
pub fn init(saved: Output) {
    OUTPUT.store(saved.index(), Ordering::Relaxed);
}

pub fn output() -> Output {
    Output::ALL[usize::from(OUTPUT.load(Ordering::Relaxed)).min(Output::ALL.len() - 1)]
}

/// Saves a new choice; the headset picks it up within a few seconds.
pub fn set(output: Output) -> io::Result<()> {
    let path = crate::config::config_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e),
    };
    let updated = with_output(&text, output)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("toml.tmp");
    std::fs::write(&temporary, updated)?;
    std::fs::rename(&temporary, &path)?;
    OUTPUT.store(output.index(), Ordering::Relaxed);
    log::info!("Audio plays on: {}", output.label());
    Ok(())
}

/// The settings file with `audio_output` set, keeping everything else.
fn with_output(text: &str, output: Output) -> io::Result<String> {
    let mut document: toml_edit::DocumentMut = text.parse().map_err(io::Error::other)?;
    document["audio_output"] = toml_edit::value(output.id());
    Ok(document.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_setting_is_written_beside_the_others() {
        let text = "# Meteor\nport_offset = 10\n[xr]\nenabled = true\n";
        let written = with_output(text, Output::Both).unwrap();
        assert!(written.contains("# Meteor") && written.contains("port_offset = 10"));
        let config: crate::config::Config = toml::from_str(&written).unwrap();
        assert_eq!(config.audio_output, Output::Both);
        assert!(config.xr.enabled);
        let again: crate::config::Config = toml::from_str(&with_output(&written, Output::Pc).unwrap()).unwrap();
        assert_eq!(again.audio_output, Output::Pc);
    }

    #[test]
    fn headset_is_the_default() {
        let config: crate::config::Config = toml::from_str("").unwrap();
        assert_eq!(config.audio_output, Output::Headset);
        assert_eq!(Output::default().id(), "headset");
    }
}
