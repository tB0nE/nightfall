//! Stream-only cursor scaling in the managed host, never in desktop settings.
use std::{
    io,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU32, Ordering},
    },
    time::Duration,
};

pub struct Control {
    scale: AtomicU32,
    path: Option<PathBuf>,
    status: Mutex<String>,
}
impl Control {
    pub fn new(scale: u32, path: Option<PathBuf>) -> Arc<Self> {
        Arc::new(Self {
            scale: AtomicU32::new(valid_scale(scale)),
            status: Mutex::new(
                if path.is_some() {
                    "Stream only; requires X11 or KDE Wayland capture in Meteor-Vibepollo"
                } else {
                    "Requires the bundled Meteor-Vibepollo host"
                }
                .into(),
            ),
            path,
        })
    }
    pub fn scale(&self) -> u32 {
        self.scale.load(Ordering::Relaxed)
    }
    pub fn available(&self) -> bool {
        self.path.is_some()
    }
    pub fn status(&self) -> String {
        self.status.lock().unwrap().clone()
    }
    fn report(&self, text: String) {
        let mut old = self.status.lock().unwrap();
        if *old != text {
            log::info!("Host cursor: {text}");
            *old = text;
        }
    }
    pub fn select(&self, scale: u32) -> io::Result<()> {
        if !(1..=4).contains(&scale) {
            return Err(io::Error::other("Cursor scale must be 1–4"));
        }
        let path = crate::config::config_path();
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == io::ErrorKind::NotFound => String::new(),
            Err(e) => return Err(e),
        };
        atomic_write(&path, scale_config(&text, scale)?.as_bytes())?;
        self.scale.store(scale, Ordering::Relaxed);
        Ok(())
    }
}
fn valid_scale(scale: u32) -> u32 {
    if (1..=4).contains(&scale) { scale } else { 1 }
}
fn scale_config(text: &str, scale: u32) -> io::Result<String> {
    let mut document: toml_edit::DocumentMut = text.parse().map_err(io::Error::other)?;
    let decor = document
        .get("host_cursor_scale")
        .and_then(toml_edit::Item::as_value)
        .map(|v| v.decor().clone());
    document["host_cursor_scale"] = toml_edit::value(scale as i64);
    if let Some(decor) = decor {
        *document["host_cursor_scale"]
            .as_value_mut()
            .unwrap()
            .decor_mut() = decor;
    }
    Ok(document.to_string())
}
fn atomic_write(path: &Path, data: &[u8]) -> io::Result<()> {
    use std::{io::Write, os::unix::fs::OpenOptionsExt};
    static ID: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    std::fs::create_dir_all(
        path.parent()
            .ok_or_else(|| io::Error::other("No parent directory"))?,
    )?;
    let temp = path.with_extension(format!(
        "cursor-{}-{}.tmp",
        std::process::id(),
        ID.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)?;
    if let Ok(meta) = std::fs::metadata(path) {
        file.set_permissions(meta.permissions())?;
    }
    file.write_all(data)?;
    file.sync_all()?;
    std::fs::rename(temp, path)?;
    std::fs::File::open(path.parent().unwrap())?.sync_all()
}
fn recent_video(last: u64, now: u64) -> bool {
    last != 0 && now.saturating_sub(last) < 2000
}
fn requested_scale(selected: u32, last: u64, now: u64) -> u32 {
    if recent_video(last, now) {
        valid_scale(selected)
    } else {
        1
    }
}

pub async fn watch(
    control: Arc<Control>,
    stats: Arc<crate::proxy::Stats>,
    shutdown: tokio::sync::watch::Receiver<bool>,
) {
    if let Err(error) = crate::legacy_host_cursor::restore().await {
        log::warn!(
            "Could not restore desktop settings from the previous DEV cursor implementation: {error}"
        );
    }
    run(control, stats, shutdown).await;
}
async fn run(
    control: Arc<Control>,
    stats: Arc<crate::proxy::Stats>,
    mut shutdown: tokio::sync::watch::Receiver<bool>,
) {
    let Some(path) = &control.path else { return };
    let mut previous = 0;
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    loop {
        if *shutdown.borrow() {
            break;
        }
        tokio::select! { _ = tick.tick() => {}, _ = shutdown.changed() => break }
        let scale = requested_scale(
            control.scale(),
            stats.last_video_ms.load(Ordering::Relaxed),
            crate::proxy::now_ms(),
        );
        if scale != previous {
            match atomic_write(path, format!("{scale}\n").as_bytes()) {
                Ok(()) => previous = scale,
                Err(error) => {
                    control.report(format!("Cannot update host cursor: {error}"));
                    continue;
                }
            }
        }
        let acknowledged = std::fs::read_to_string(path.with_file_name("cursor-scale.supported"))
            .is_ok_and(|v| matches!(v.trim(), "x11-cursor-scale-v1" | "wayland-cursor-scale-v1"));
        control.report(if scale == 1 {
            "Stream only; desktop cursor unchanged".into()
        } else if acknowledged {
            format!("Active: {scale}× in the stream only")
        } else {
            "Waiting for compatible X11 or KDE Wayland capture in Meteor-Vibepollo".into()
        });
    }
    if let Err(error) = atomic_write(path, b"1\n") {
        log::warn!("Could not reset host cursor scale: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_live_video_uses_selected_scale() {
        assert_eq!(requested_scale(4, 0, 1000), 1);
        assert_eq!(requested_scale(4, 1000, 2999), 4);
        assert_eq!(requested_scale(4, 1000, 3000), 1);
        assert_eq!(requested_scale(3, 2900, 3000), 3);
        assert_eq!(requested_scale(99, 2900, 3000), 1);
        assert_eq!(requested_scale(1, 2900, 3000), 1);
    }
    #[test]
    fn settings_preserve_host_profile_and_comments() {
        let text = "# Host\nhost_cursor_scale = 2 # size\n[ xr ]\nenabled = true\n";
        let updated = scale_config(text, 4).unwrap();
        assert!(updated.contains("# size"));
        assert!(updated.contains("# Host"));
        let config: crate::config::Config = toml::from_str(&updated).unwrap();
        assert_eq!(config.host_cursor_scale, 4);
        assert!(config.xr.enabled);
    }
    #[test]
    fn external_hosts_cannot_offer_unsupported_scaling() {
        assert!(!Control::new(2, None).available());
    }
    #[tokio::test]
    async fn file_control_resets_on_shutdown_without_touching_desktop() {
        let path = std::env::temp_dir()
            .join(format!("meteor-cursor-ipc-{}", std::process::id()))
            .join("cursor-scale");
        let control = Control::new(3, Some(path.clone()));
        let stats = Arc::new(crate::proxy::Stats::default());
        stats
            .last_video_ms
            .store(crate::proxy::now_ms(), Ordering::Relaxed);
        let (tx, rx) = tokio::sync::watch::channel(false);
        let task = tokio::spawn(run(control, stats, rx));
        // No legacy journal should be created by this implementation.
        for _ in 0..100 {
            if std::fs::read_to_string(&path).ok().as_deref() == Some("3\n") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "3\n");
        tx.send(true).unwrap();
        task.await.unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "1\n");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
