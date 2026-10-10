//! The Linux desktop: autostart and notifications (freedesktop.org specs).

use std::path::{Path, PathBuf};

/// Meteor's entry in `~/.config/autostart`.
fn autostart_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_default();
    base.join("autostart").join("nightfall-meteor.desktop")
}

/// What autostart runs: the AppImage itself (`$APPIMAGE`, set by its
/// runtime), else this binary.
fn launcher() -> Option<PathBuf> {
    std::env::var_os("APPIMAGE").map(PathBuf::from).or_else(|| std::env::current_exe().ok())
}

pub fn autostart_enabled() -> bool {
    autostart_path().is_file()
}

/// Turns autostart on or off.
pub fn set_autostart(on: bool) -> Result<(), String> {
    let path = autostart_path();
    if !on {
        return match std::fs::remove_file(&path) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(format!("{}: {err}", path.display())),
            _ => Ok(()),
        };
    }
    let exe = launcher().ok_or("can't tell where Meteor is")?;
    let entry = format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=Nightfall Meteor\n\
         Comment=Host depth and microphone for Nightfall on Meta Quest\n\
         Exec={}\n\
         Terminal=false\n\
         X-GNOME-Autostart-enabled=true\n\
         X-KDE-autostart-after=panel\n",
        quote_exec(&exe)
    );
    path.parent().map_or(Ok(()), std::fs::create_dir_all).map_err(|e| e.to_string())?;
    std::fs::write(&path, entry).map_err(|e| format!("{}: {e}", path.display()))
}

/// On every start: the first run of the AppImage turns autostart on (running
/// it is taken as the wish to use Meteor), and an entry pointing at an
/// AppImage that has since moved is updated.
pub fn update_autostart() {
    let Some(appimage) = std::env::var_os("APPIMAGE").map(PathBuf::from) else { return };
    let marker = crate::config::config_dir().join("autostart-offered");
    if !marker.exists() {
        let _ = marker.parent().map(std::fs::create_dir_all);
        let _ = std::fs::write(&marker, "Meteor turned autostart on once; it won't again.\n");
        match set_autostart(true) {
            Ok(()) => log::info!("Autostart on ({})", autostart_path().display()),
            Err(err) => log::warn!("Can't turn autostart on: {err}"),
        }
        return;
    }
    if autostart_enabled() && exec_of(&autostart_path()).as_deref() != Some(appimage.as_path()) {
        match set_autostart(true) {
            Ok(()) => log::info!("Autostart now starts {}", appimage.display()),
            Err(err) => log::warn!("Can't update autostart: {err}"),
        }
    }
}

/// The program an entry's Exec line runs.
fn exec_of(entry: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(entry).ok()?;
    let exec = text.lines().find_map(|l| l.strip_prefix("Exec="))?;
    Some(PathBuf::from(unquote_exec(exec)))
}

/// Quotes a path for an Exec line: inside double quotes, `"`, `` ` ``, `$`
/// and `\` are escaped with a backslash.
fn quote_exec(path: &Path) -> String {
    let mut out = String::from("\"");
    for c in path.to_string_lossy().chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

fn unquote_exec(exec: &str) -> String {
    let Some(inner) = exec.strip_prefix('"').and_then(|e| e.strip_suffix('"')) else {
        return exec.split_whitespace().next().unwrap_or_default().to_string();
    };
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        out.push(if c == '\\' { chars.next().unwrap_or('\\') } else { c });
    }
    out
}

/// Shows a desktop notification. Best effort: a desktop without a
/// notification service just logs it.
pub async fn notify(summary: &str, body: &str) {
    let result = async {
        let connection = zbus::Connection::session().await?;
        let hints: std::collections::HashMap<&str, zbus::zvariant::Value> = Default::default();
        connection
            .call_method(
                Some("org.freedesktop.Notifications"),
                "/org/freedesktop/Notifications",
                Some("org.freedesktop.Notifications"),
                "Notify",
                &("Nightfall Meteor", 0u32, "", summary, body, Vec::<&str>::new(), hints, -1i32),
            )
            .await?;
        Ok::<(), zbus::Error>(())
    }
    .await;
    if let Err(err) = result {
        log::info!("Couldn't show a notification ({err}): {summary}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_lines_round_trip() {
        let path = Path::new("/home/me/My Apps/Meteor \"$1\".AppImage");
        let quoted = quote_exec(path);
        assert_eq!(quoted, "\"/home/me/My Apps/Meteor \\\"\\$1\\\".AppImage\"");
        assert_eq!(unquote_exec(&quoted), path.to_string_lossy());
        assert_eq!(unquote_exec("/usr/bin/meteor --no-tray"), "/usr/bin/meteor");
    }
}
