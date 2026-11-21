//! Windows shim for `crate::desktop`: the cross-platform API surface that
//! `pairing.rs` and other shared modules call. Linux uses the real `desktop.rs`
//! (zbus / freedesktop.org); Windows routes through the tray balloon.

pub async fn notify(summary: &str, body: &str) {
    crate::tray_windows::queue_balloon(format!("{summary}: {body}"));
}

pub async fn host_pairing_popup(pairing: std::sync::Arc<crate::host::pairing::Pairing>, request: String) -> Result<(), String> {
    crate::desktop_windows::host_pairing_popup(pairing, request).await;
    Ok(())
}

pub use crate::desktop_windows::{autostart_enabled, set_autostart};

/// Opens a web page, or a Windows settings page (ms-settings:…), in the default handler.
pub fn open_web_url(url: String) {
    if let Err(error) = std::process::Command::new("explorer.exe").arg(&url).spawn() {
        log::warn!("Cannot open {url}: {error}");
    }
}

/// Copies text to the Windows clipboard with clip.exe. The text is never run.
pub async fn copy_text(text: &str) -> std::io::Result<()> {
    use tokio::io::AsyncWriteExt;
    let mut child = tokio::process::Command::new("clip.exe")
        .creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(text.as_bytes()).await?;
    }
    let status = child.wait().await?;
    if status.success() { Ok(()) } else { Err(std::io::Error::other(format!("clip.exe exited with {status}"))) }
}
