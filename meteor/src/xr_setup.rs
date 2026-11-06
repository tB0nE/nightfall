//! Per-user PCVR installation, from the Setup window; never changes global VR selection.
use std::{io, path::{Path, PathBuf}, sync::{Mutex, OnceLock}, time::Duration};

#[derive(Clone, Default)]
pub struct State { pub ready: bool, pub busy: bool, pub error: Option<String> }
static STATE: OnceLock<Mutex<State>> = OnceLock::new();
pub fn initialize(ready: bool, error: Option<String>) {
    if let Some(message) = error.clone() {
        tokio::spawn(async move { crate::desktop::notify("PCVR unavailable — check Meteor's menu", &message).await; });
    }
    *STATE.get_or_init(Default::default).lock().unwrap() = State { ready, busy: false, error };
}
pub fn state() -> State { STATE.get_or_init(Default::default).lock().unwrap().clone() }
pub fn bundle() -> io::Result<PathBuf> {
    let executable = std::env::current_exe()?;
    let root = executable.parent().and_then(Path::parent)
        .ok_or_else(|| io::Error::other("Cannot locate the Meteor package"))?
        .join("share/nightfall-meteor/xr-bundle");
    if !root.join("tools/meteor_xr_install.py").is_file() {
        return Err(io::Error::other("This Meteor build has no PCVR runtime. Use the XR-enabled Linux AppImage."));
    }
    Ok(root)
}

fn enabled_config(text: &str) -> io::Result<String> { config_with_enabled(text, true) }

fn config_with_enabled(text: &str, enabled: bool) -> io::Result<String> {
    // Validate the complete existing configuration first, rather than silently
    // replacing a malformed file with defaults. Preserve unknown keys/comments.
    let _: crate::config::Config = toml::from_str(text).map_err(io::Error::other)?;
    let mut document: toml_edit::DocumentMut = text.parse().map_err(io::Error::other)?;
    let decor = document.get("xr").and_then(|xr| xr.get("enabled"))
        .and_then(toml_edit::Item::as_value).map(|value| value.decor().clone());
    document["xr"]["enabled"] = toml_edit::value(enabled);
    if let Some(decor) = decor { *document["xr"]["enabled"].as_value_mut().unwrap().decor_mut() = decor; }
    Ok(document.to_string())
}

fn read_config(path: &Path) -> io::Result<String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(error),
    }
}

fn save_enabled(path: &Path, original: &str, replacement: &str) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if read_config(path)? != original { return Err(io::Error::other("Settings changed during setup. Retry PCVR setup.")); }
    std::fs::create_dir_all(path.parent().ok_or_else(|| io::Error::other("Invalid settings path"))?)?;
    if path.is_file() {
        let backup = path.with_extension("before-pcvr-setup.toml");
        if !backup.exists() { std::fs::copy(path, backup)?; }
    }
    let temporary = path.with_extension(format!("pcvr-{}.tmp", std::process::id()));
    let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
    let result = (|| {
        file.write_all(replacement.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&temporary, path)
    })();
    if result.is_err() { let _ = std::fs::remove_file(temporary); }
    result
}

pub async fn enable_from(source: &Path, config_path: &Path) -> io::Result<()> {
    let original = read_config(config_path)?;
    let updated = enabled_config(&original)?;
    let settings: crate::config::Config = toml::from_str(&original).map_err(io::Error::other)?;
    let destination = settings.xr.runtime_root();
    if !destination.is_absolute() { return Err(io::Error::other("The PCVR runtime_root setting must be an absolute path.")); }
    install(source, &destination).await?;
    save_enabled(config_path, &original, &updated)
}

async fn install(source: &Path, destination: &Path) -> io::Result<()> {
    let output = tokio::time::timeout(Duration::from_secs(30),
        tokio::process::Command::new("/usr/bin/python3")
            .arg(source.join("tools/meteor_xr_install.py")).arg(source)
            .arg("--destination").arg(destination)
            .stdin(std::process::Stdio::null()).kill_on_drop(true).output()).await
        .map_err(|_| io::Error::other("PCVR installation timed out. Check disk space and retry."))??;
    if !output.status.success() {
        return Err(io::Error::other(format!("PCVR installation failed: {}",
            String::from_utf8_lossy(&output.stderr).chars().take(1400).collect::<String>())));
    }
    Ok(())
}

/// Whether an installed runtime differs from the package. The manifest lists
/// every file's hash, so the same manifest means the same runtime.
fn outdated(package: &Path, installed: &Path) -> bool {
    let manifest = |root: &Path| std::fs::read(root.join("xr-runtime/manifest.json")).ok();
    matches!((manifest(package), manifest(installed)), (Some(new), Some(old)) if new != old)
}

/// Brings an installed runtime in line with the one in this AppImage, so an
/// upgrade gets its fixes. Runs before the XR service starts. A failure keeps
/// the old runtime working; a runtime the user chose in the settings is theirs.
pub async fn update_installed(settings: &crate::config::XrConfig) {
    if !settings.enabled || settings.runtime_root.is_some() { return; }
    let Ok(package) = bundle() else { return };
    let installed = settings.runtime_root();
    if !outdated(&package, &installed) { return; }
    match install(&package, &installed).await {
        Ok(()) => log::info!("Updated the PCVR runtime from this AppImage"),
        Err(error) => log::warn!("Keeping the installed PCVR runtime: {error}"),
    }
}

/// Turns PCVR off in the settings. The installed files stay, for turning it back on.
pub fn disable(config_path: &Path) -> io::Result<()> {
    let original = read_config(config_path)?;
    save_enabled(config_path, &original, &config_with_enabled(&original, false)?)
}

pub fn restart_command() -> io::Result<std::process::Command> {
    let executable = std::env::var_os("APPIMAGE").map(PathBuf::from).unwrap_or(std::env::current_exe()?);
    if !executable.is_file() { return Err(io::Error::other("Meteor executable has moved. Reopen its AppImage.")); }
    let mut command = std::process::Command::new(executable);
    command.args(std::env::args_os().skip(1));
    for name in ["APPDIR", "APPIMAGE", "ARGV0", "OWD"] { command.env_remove(name); }
    // The new process waits for this one's discovery port to close.
    command.env(crate::RESTART_ENV, "1");
    Ok(command)
}

fn encoder_config(text: &str, backend: &str) -> io::Result<String> {
    if !matches!(backend,"auto"|"nvenc"|"vaapi") {return Err(io::Error::other("Unknown PCVR encoder"));}
    let _: crate::config::Config=toml::from_str(text).map_err(io::Error::other)?;
    let mut document:toml_edit::DocumentMut=text.parse().map_err(io::Error::other)?;
    if !document.contains_key("xr") {document["xr"]=toml_edit::Item::Table(toml_edit::Table::new());}
    document["xr"]["encoder_backend"]=toml_edit::value(backend);
    if backend!="vaapi" {if let Some(table)=document["xr"].as_table_mut() {table.remove("render_device");}}
    Ok(document.to_string())
}

pub fn select_encoder(backend: &str) -> io::Result<()> {
    let path=crate::config::config_path();let original=read_config(&path)?;
    save_enabled(&path,&original,&encoder_config(&original,backend)?)
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn encoder_selection_preserves_settings_and_removes_stale_device_override() {
        let input="# User settings\n[xr]\nenabled=true\nrender_device='/dev/dri/renderD128'\n";
        let amd=encoder_config(input,"vaapi").unwrap();assert!(amd.contains("render_device"));
        let auto=encoder_config(&amd,"auto").unwrap();assert!(!auto.contains("render_device"));
        assert!(auto.contains("# User settings"));assert!(auto.contains("enabled=true"));
        let parsed:crate::config::Config=toml::from_str(&auto).unwrap();assert_eq!(parsed.xr.encoder_backend,"auto");
        assert!(encoder_config(input,"cpu").is_err());
    }
    #[test] fn only_a_different_installed_runtime_is_outdated() {
        let root=std::env::temp_dir().join(format!("nf-outdated-{}",std::process::id()));
        let write=|name:&str,text:&str|{
            let path=root.join(name).join("xr-runtime");
            std::fs::create_dir_all(&path).unwrap();
            std::fs::write(path.join("manifest.json"),text).unwrap();
        };
        write("package","new"); write("same","new"); write("old","old");
        std::fs::create_dir_all(root.join("none")).unwrap();
        assert!(outdated(&root.join("package"),&root.join("old")));
        assert!(!outdated(&root.join("package"),&root.join("same")));
        assert!(!outdated(&root.join("package"),&root.join("none")),"nothing installed: Setup installs it");
        assert!(!outdated(&root.join("none"),&root.join("old")),"nothing to update from");
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test] fn config_edit_preserves_comments_custom_runtime_and_other_settings() {
        let text="# My settings\nsunshine_host = '10.0.0.13'\n[xr]\nenabled = false # keep this\nruntime_root = '/custom/xr'\nvideo_port = 48001\n";
        let updated=enabled_config(text).unwrap();
        assert!(updated.contains("enabled = true # keep this"));
        assert!(updated.contains("# My settings"));
        let settings:crate::config::Config=toml::from_str(&updated).unwrap();
        assert!(settings.xr.enabled);
        assert_eq!(settings.xr.runtime_root(),PathBuf::from("/custom/xr"));
        assert_eq!(settings.sunshine_host,"10.0.0.13");
        assert_eq!(settings.xr.video_port,48001);
        assert!(enabled_config("[xr\nenabled").is_err());
        assert!(enabled_config("[xr]\nenabled='yes'").is_err());
        assert!(toml::from_str::<crate::config::Config>(&enabled_config("").unwrap()).unwrap().xr.enabled);
    }
    #[test] fn saving_is_backed_up_and_does_not_overwrite_concurrent_edits() {
        let root=std::env::temp_dir().join(format!("nf-setup-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir(&root).unwrap();
        let path=root.join("meteor.toml");
        std::fs::write(&path,"# original\n").unwrap();
        assert!(save_enabled(&path,"", "bad").is_err());
        let updated=enabled_config("# original\n").unwrap();
        save_enabled(&path,"# original\n",&updated).unwrap();
        assert_eq!(std::fs::read_to_string(path.with_extension("before-pcvr-setup.toml")).unwrap(),"# original\n");
        assert_eq!(std::fs::read_to_string(&path).unwrap(),updated);
        std::fs::remove_dir_all(root).unwrap();
    }
}
