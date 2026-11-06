//! Restore cursor settings left by early DEV builds. New scaling never changes them.
use serde::{Deserialize, Serialize};
use std::{io, time::Duration};
use tokio::io::AsyncWriteExt;
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
enum Kind {
    Kde,
    Gnome,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
struct Original {
    kind: Kind,
    /// None means inherit the desktop default; preserve that rather than pinning 24.
    size: Option<u32>,
    effective: u32,
    x_size: Option<String>,
    /// Older versions skipped X11 for terminal-started desktops. Don't remove
    /// resources they never captured when recovering one of those journals.
    #[serde(default)]
    x_resources_captured: bool,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
struct Journal {
    original: Original,
    applied: u32,
    #[serde(default)]
    previous: Option<u32>,
}
trait Desktop {
    async fn read(&self, kind: Kind) -> io::Result<Original>;
    async fn set(&self, original: &Original, enlarged: Option<u32>) -> io::Result<()>;
}
struct SystemDesktop;
async fn command(program: &str, args: &[&str], input: Option<&str>) -> io::Result<String> {
    use std::process::Stdio;
    let mut child = tokio::process::Command::new(program)
        .args(args)
        .kill_on_drop(true)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let result = tokio::time::timeout(Duration::from_secs(4), async {
        if let Some(input) = input {
            child
                .stdin
                .take()
                .unwrap()
                .write_all(input.as_bytes())
                .await?;
        }
        let output = child.wait_with_output().await?;
        if !output.status.success() {
            return Err(io::Error::other(format!(
                "{program}: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
    })
    .await;
    result.map_err(|_| io::Error::new(io::ErrorKind::TimedOut, format!("{program} timed out")))?
}
fn x11() -> bool {
    has_x_display(std::env::var_os("DISPLAY").as_deref())
}
fn has_x_display(display: Option<&std::ffi::OsStr>) -> bool {
    // XDG_SESSION_TYPE can remain "tty" when Plasma is started with startx.
    // Wayland sessions can also expose Xwayland cursors that need reloading.
    display.is_some_and(|display| !display.is_empty())
}
fn x_size(resources: &str) -> Option<String> {
    resources.lines().find_map(|line| {
        line.split_once(':')
            .filter(|(key, _)| key.trim() == "Xcursor.size")
            .map(|(_, value)| value.trim().to_owned())
    })
}
fn resized_resources(resources: &str, size: Option<&str>) -> String {
    let mut lines: Vec<String> = resources
        .lines()
        .filter(|line| {
            !line
                .split_once(':')
                .is_some_and(|(key, _)| key.trim() == "Xcursor.size")
        })
        .map(str::to_owned)
        .collect();
    if let Some(size) = size {
        lines.push(format!("Xcursor.size:\t{size}"));
    }
    lines.push(String::new());
    lines.join("\n")
}
impl Desktop for SystemDesktop {
    async fn read(&self, kind: Kind) -> io::Result<Original> {
        let raw = match kind {
            Kind::Kde => {
                command(
                    "kreadconfig6",
                    &[
                        "--file",
                        "kcminputrc",
                        "--group",
                        "Mouse",
                        "--key",
                        "cursorSize",
                        "--default",
                        "",
                    ],
                    None,
                )
                .await?
            }
            Kind::Gnome => {
                command(
                    "gsettings",
                    &["get", "org.gnome.desktop.interface", "cursor-size"],
                    None,
                )
                .await?
            }
        };
        let size = if raw.is_empty() {
            None
        } else {
            Some(raw.parse::<u32>().map_err(io::Error::other)?)
        };
        let x_resources_captured = x11();
        let x_size = if x_resources_captured {
            x_size(&command("xrdb", &["-query"], None).await?)
        } else {
            None
        };
        // KDE's zero means automatic sizing. Xcursor knows its effective X11 size.
        let effective = size
            .filter(|size| *size > 0)
            .or_else(|| {
                x_size
                    .as_ref()
                    .and_then(|size| size.parse().ok())
                    .filter(|size| *size > 0)
            })
            .unwrap_or(24);
        if effective > 1024 {
            return Err(io::Error::other(
                "Desktop cursor size is outside the supported range",
            ));
        }
        Ok(Original {
            kind,
            size,
            effective,
            x_size,
            x_resources_captured,
        })
    }
    async fn set(&self, original: &Original, enlarged: Option<u32>) -> io::Result<()> {
        let value = enlarged.or(original.size).map(|size| size.to_string());
        match original.kind {
            Kind::Kde => {
                let mut args = vec![
                    "--file",
                    "kcminputrc",
                    "--group",
                    "Mouse",
                    "--key",
                    "cursorSize",
                ];
                if let Some(value) = &value {
                    args.push(value);
                } else {
                    args.push("--delete");
                }
                command("kwriteconfig6", &args, None).await?;
                let bus = tokio::time::timeout(Duration::from_secs(4), zbus::Connection::session())
                    .await
                    .map_err(io::Error::other)?
                    .map_err(io::Error::other)?;
                tokio::time::timeout(
                    Duration::from_secs(4),
                    bus.emit_signal(
                        None::<&str>,
                        "/KGlobalSettings",
                        "org.kde.KGlobalSettings",
                        "notifyChange",
                        &(5i32, 0i32),
                    ),
                )
                .await
                .map_err(io::Error::other)?
                .map_err(io::Error::other)?;
            }
            Kind::Gnome => {
                if let Some(value) = &value {
                    command(
                        "gsettings",
                        &["set", "org.gnome.desktop.interface", "cursor-size", value],
                        None,
                    )
                    .await?;
                } else {
                    command(
                        "gsettings",
                        &["reset", "org.gnome.desktop.interface", "cursor-size"],
                        None,
                    )
                    .await?;
                }
            }
        }
        if x11() {
            if enlarged.is_some() || original.x_resources_captured {
                let resources = command("xrdb", &["-query"], None).await?;
                let new_size = enlarged.map(|size| size.to_string());
                command(
                    "xrdb",
                    &["-load"],
                    Some(&resized_resources(
                        &resources,
                        new_size.as_deref().or(original.x_size.as_deref()),
                    )),
                )
                .await?;
            }
            let theme = match original.kind {
                Kind::Kde => {
                    command(
                        "kreadconfig6",
                        &[
                            "--file",
                            "kcminputrc",
                            "--group",
                            "Mouse",
                            "--key",
                            "cursorTheme",
                            "--default",
                            "default",
                        ],
                        None,
                    )
                    .await?
                }
                Kind::Gnome => command(
                    "gsettings",
                    &["get", "org.gnome.desktop.interface", "cursor-theme"],
                    None,
                )
                .await?
                .trim_matches('\'')
                .to_owned(),
            };
            let size = enlarged.unwrap_or(original.effective);
            tokio::task::spawn_blocking(move || reload_x11(&theme, size))
                .await
                .map_err(io::Error::other)??;
        }
        if self.read(original.kind).await?.size != enlarged.or(original.size) {
            return Err(io::Error::other(
                "Desktop did not accept the requested cursor size",
            ));
        }
        Ok(())
    }
}

/// Reload named cursors already owned by applications, like KDE's theme applicator.
/// Dynamic loading avoids adding X11 dependencies to Wayland-only installations.
fn reload_x11(theme: &str, size: u32) -> io::Result<()> {
    use std::ffi::{CString, c_char, c_int, c_ulong, c_void};
    type Display = *mut c_void;
    unsafe {
        let x11 = libloading::Library::new("libX11.so.6").map_err(io::Error::other)?;
        let cursor = libloading::Library::new("libXcursor.so.1").map_err(io::Error::other)?;
        let fixes = libloading::Library::new("libXfixes.so.3").map_err(io::Error::other)?;
        let open = x11
            .get::<unsafe extern "C" fn(*const c_char) -> Display>(b"XOpenDisplay\0")
            .map_err(io::Error::other)?;
        let close = x11
            .get::<unsafe extern "C" fn(Display) -> c_int>(b"XCloseDisplay\0")
            .map_err(io::Error::other)?;
        let free = x11
            .get::<unsafe extern "C" fn(Display, c_ulong) -> c_int>(b"XFreeCursor\0")
            .map_err(io::Error::other)?;
        let load = cursor
            .get::<unsafe extern "C" fn(Display, *const c_char) -> c_ulong>(
                b"XcursorLibraryLoadCursor\0",
            )
            .map_err(io::Error::other)?;
        let set_theme = cursor
            .get::<unsafe extern "C" fn(Display, *const c_char) -> c_int>(b"XcursorSetTheme\0")
            .map_err(io::Error::other)?;
        let set_size = cursor
            .get::<unsafe extern "C" fn(Display, c_int) -> c_int>(b"XcursorSetDefaultSize\0")
            .map_err(io::Error::other)?;
        let change = fixes
            .get::<unsafe extern "C" fn(Display, c_ulong, *const c_char)>(
                b"XFixesChangeCursorByName\0",
            )
            .map_err(io::Error::other)?;
        let theme = CString::new(theme).map_err(io::Error::other)?;
        let display = open(std::ptr::null());
        if display.is_null() {
            return Err(io::Error::other("Cannot open the X11 display"));
        }
        set_theme(display, theme.as_ptr());
        set_size(display, size as c_int);
        for name in [
            "left_ptr",
            "default",
            "arrow",
            "up_arrow",
            "cross",
            "crosshair",
            "wait",
            "watch",
            "left_ptr_watch",
            "ibeam",
            "xterm",
            "text",
            "size_ver",
            "size_hor",
            "size_bdiag",
            "size_fdiag",
            "size_all",
            "fleur",
            "split_v",
            "split_h",
            "pointing_hand",
            "pointer",
            "hand1",
            "hand2",
            "openhand",
            "closedhand",
            "forbidden",
            "whats_this",
            "copy",
            "move",
            "link",
            "sb_h_double_arrow",
            "sb_v_double_arrow",
            "top_left_corner",
            "top_right_corner",
            "bottom_left_corner",
            "bottom_right_corner",
        ] {
            let name = CString::new(name).unwrap();
            let image = load(display, name.as_ptr());
            if image != 0 {
                change(display, image, name.as_ptr());
                free(display, image);
            }
        }
        close(display);
    }
    Ok(())
}

pub async fn restore() -> io::Result<()> {
    let path = crate::config::config_dir().join("host-cursor-restore.json");
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    let saved: Journal = serde_json::from_slice(&bytes)?;
    let current = SystemDesktop.read(saved.original.kind).await?;
    if current.size == Some(saved.applied)
        || current.size == saved.original.size
        || saved
            .previous
            .is_some_and(|size| current.size == Some(size))
    {
        SystemDesktop.set(&saved.original, None).await?;
    }
    std::fs::remove_file(path)
}
