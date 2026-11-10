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
