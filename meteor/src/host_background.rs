//! Connection-scoped, authenticated desktop changes. Never accepts shell text.
use std::time::Duration;
use std::sync::atomic::{AtomicU64, Ordering};
static OPERATIONS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
static NEXT: AtomicU64 = AtomicU64::new(1);

pub struct Lease { active: bool, owner: String }
impl Lease {
    pub fn new() -> Self { Self { active: false, owner: format!("{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)) } }
    pub async fn set(&mut self, color: &str) -> Result<(), String> {
        if !matches!(color, "off" | "green" | "blue" | "magenta") {
            return Err("Unsupported host background colour".into());
        }
        // Mark before spawning: cancellation must also restore partial changes.
        self.active = color != "off" || self.active;
        change(color, Some(&self.owner)).await?;
        self.active = color != "off";
        Ok(())
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if self.active {
            let owner = self.owner.clone();
            tokio::spawn(async move { if let Err(e) = change("off", Some(&owner)).await { log::warn!("Host background restore pending: {e}"); } });
        }
    }
}
pub async fn recover() {
    if let Err(e) = change("off", None).await { log::warn!("Host background recovery: {e}"); }
}
async fn change(color: &str, owner: Option<&str>) -> Result<(), String> {
    let _serial = OPERATIONS.lock().await;
    #[cfg(target_os = "linux")]
    {
        let output = tokio::time::timeout(Duration::from_secs(15),
            tokio::process::Command::new("/usr/bin/python3")
                .args(["-c", include_str!("../scripts/host_background.py"), color, owner.unwrap_or("")])
                .kill_on_drop(true).output()).await
            .map_err(|_| "Host background operation timed out".to_string())?
            .map_err(|e| e.to_string())?;
        if !output.status.success() { return Err(String::from_utf8_lossy(&output.stderr).trim().to_string()); }
        Ok(())
    }
    #[cfg(windows)]
    {
        let mut command = tokio::process::Command::new("powershell.exe");
        command.args(["-NoProfile", "-NonInteractive", "-Command", include_str!("../scripts/host_background_windows.ps1")])
            .env("METEOR_BG_COLOR", color).env("METEOR_BG_OWNER", owner.unwrap_or(""));
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        execute(command).await
    }
    #[cfg(target_os = "macos")]
    {
        let root = crate::config::data_dir().join("host-background");
        std::fs::create_dir_all(&root).map_err(|e|e.to_string())?;
        let image = root.join(format!("{color}.png"));
        if color != "off" { write_solid_png(&image, color)?; }
        let mut command = tokio::process::Command::new("/usr/bin/osascript");
        command.args(["-l", "JavaScript", "-e", include_str!("../scripts/host_background_macos.js"), "--", color, owner.unwrap_or("")])
            .arg(&root).arg(&image);
        execute(command).await
    }
    #[cfg(not(any(target_os = "linux", windows, target_os = "macos")))]
    { let _ = (color, owner); Err("Automatic host background is not supported on this platform".into()) }
}
#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn rejects_shell_input_without_changing_desktop() {
        let mut lease = super::Lease::new();
        assert!(lease.set("green; echo bad").await.is_err());
        assert!(!lease.active);
    }
}

#[cfg(any(windows, target_os = "macos"))]
async fn execute(mut command: tokio::process::Command) -> Result<(), String> {
    let output = tokio::time::timeout(Duration::from_secs(15), command.kill_on_drop(true).output()).await
        .map_err(|_| "Host background operation timed out".to_string())?.map_err(|e|e.to_string())?;
    if output.status.success() { Ok(()) }
    else { Err(String::from_utf8_lossy(&output.stderr).trim().to_string()) }
}
#[cfg(target_os = "macos")]
fn write_solid_png(path: &std::path::Path, color: &str) -> Result<(), String> {
    if path.exists() { return Ok(()); }
    let rgb = match color {"green" => [0,255,0], "blue" => [0,0,255], "magenta" => [255,0,255], _ => return Err("Invalid colour".into())};
    let file = std::fs::File::create(path).map_err(|e|e.to_string())?;
    let mut encoder = png::Encoder::new(file, 1, 1);
    encoder.set_color(png::ColorType::Rgb);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.write_header().and_then(|mut w| w.write_image_data(&rgb)).map_err(|e|e.to_string())
}
