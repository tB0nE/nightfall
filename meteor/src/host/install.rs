//! Downloads Meteor-Vibepollo for Nightfall from our fork's GitHub release.
//!
//! The release is pinned here (version, URL, size, SHA-256), as the VDA
//! files are in download.rs, so a host update ships with a Meteor update.
//! The archive is a plain .tar.zst, not an AppImage: it unpacks to
//! `~/.local/share/nightfall-meteor/host/<version>/`, and the version
//! before it is kept for going back.

use std::io::Read;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::download::Download;

pub struct Release {
    pub version: &'static str,
    pub url: &'static str,
    pub size: u64,
    pub sha256: &'static str,
    /// The host's executable inside the archive.
    pub binary: &'static str,
}

/// Portable host preview, built from the matching source companion.
pub const RELEASE: Option<Release> = Some(Release {
    version: "0.1.0-preview.2",
    url: "https://github.com/tB0nE/Vibepollo/releases/download/meteor-host-v0.1.0-preview.2/Meteor-Vibepollo-0.1.0-preview.2-linux-x86_64.tar.zst",
    size: 29_404_669,
    sha256: "b1ce96a6f34b3d7b5b6e79bad4a859e3de4aeb844eed39334ba431c59a9226be",
    binary: "bin/meteor-vibepollo",
});

pub struct Install;

impl Install {
    pub fn root() -> PathBuf {
        crate::config::data_dir().join("host")
    }

    /// The installed executable of `release`, if it's there.
    pub fn binary(release: &Release) -> Option<PathBuf> {
        let root=Self::root().join(release.version);
        verify_install(&root,release).ok()?;
        Some(root.join(release.binary))
    }

    /// Downloads and unpacks `release` on this thread, reporting progress
    /// through `download`. Returns the executable.
    pub fn run(download: &Download, release: &Release) -> Result<PathBuf, String> {
        download.run_task(release.size, |d| fetch(d, release))?;
        Self::binary(release).ok_or_else(|| format!("{} is missing from the download", release.binary))
    }
}

fn fetch(download: &Download, release: &Release) -> Result<(), String> {
    let root = Install::root();
    let fail = |p: &Path, e: std::io::Error| format!("{}: {e}", p.display());
    std::fs::create_dir_all(&root).map_err(|e| fail(&root, e))?;
    let lock_path=root.join(format!("{}.install.lock",release.version));
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(&lock_path).map_err(|e|fail(&lock_path,e))?;
    use std::os::fd::AsRawFd;
    // The descriptor owns the lock, including on cancellation or process exit.
    if unsafe {libc::flock(lock.as_raw_fd(),libc::LOCK_EX|libc::LOCK_NB)} != 0 {
        return Err("This host version is already being installed by another Meteor process".into());
    }
    let target=root.join(release.version);
    if target.exists() {
        return verify_install(&target,release).map_err(|error|format!("Existing host installation needs repair: {error}"));
    }
    let archive = root.join(format!("{}.tar.zst.download", release.version));
    log::info!("Host download: {}", release.url);
    download.resumable(&crate::download::agent(), release.url, 0, release.size, &archive)?;
    let actual = sha256_file(&archive)?;
    if actual != release.sha256 {
        let _ = std::fs::remove_file(&archive);
        return Err(format!("the host download has SHA-256 {actual}, expected {}", release.sha256));
    }
    if download.cancel.load(std::sync::atomic::Ordering::Relaxed) {return Err("Host setup cancelled".into());}
    let partial = root.join(format!("{}.partial", release.version));
    let _ = std::fs::remove_dir_all(&partial);
    let file = std::fs::File::open(&archive).map_err(|e| fail(&archive, e))?;
    let decoder = zstd::Decoder::new(file).map_err(|e| fail(&archive, e))?;
    std::fs::create_dir_all(&partial).map_err(|e|fail(&partial,e))?;
    for entry in tar::Archive::new(decoder).entries().map_err(|e|fail(&partial,e))? {
        let mut entry=entry.map_err(|e|fail(&partial,e))?;
        if !entry.header().entry_type().is_file() && !entry.header().entry_type().is_dir() {
            return Err("Unexpected link or special file in host package".into());
        }
        if !entry.unpack_in(&partial).map_err(|e|fail(&partial,e))? {return Err("Host package path escapes its installation".into());}
    }
    verify_install(&partial,release)?;
    std::fs::rename(&partial, &target).map_err(|e| fail(&target, e))?;
    let _ = std::fs::remove_file(&archive);
    prune(&root, release.version);
    Ok(())
}

fn verify_install(root:&Path,release:&Release)->Result<(),String> {
    use std::os::unix::fs::PermissionsExt;
    let manifest:serde_json::Value=serde_json::from_slice(&std::fs::read(root.join("manifest.json")).map_err(|e|e.to_string())?).map_err(|e|e.to_string())?;
    if manifest["version"].as_str()!=Some(release.version) || manifest["binary"].as_str()!=Some(release.binary) {
        return Err("Host package version or executable does not match the requested release".into());
    }
    let files=manifest["files"].as_object().ok_or("Host package has no file manifest")?;
    if !files.contains_key(release.binary) || !files.contains_key("bin/vibepollo") {return Err("Host package omits its executable".into());}
    let canonical=root.canonicalize().map_err(|e|e.to_string())?;
    for (name,digest) in files {
        let relative=Path::new(name);
        if relative.components().any(|p|!matches!(p,std::path::Component::Normal(_))) {return Err("Invalid host package path".into());}
        let file=root.join(relative);
        if file.is_symlink() || !file.canonicalize().map_err(|e|e.to_string())?.starts_with(&canonical) {return Err("Invalid host package file location".into());}
        if sha256_file(&file)?!=digest.as_str().ok_or("Invalid host package checksum")? {return Err(format!("Host package file failed verification: {name}"));}
    }
    for name in [release.binary,"bin/vibepollo"] {
        if std::fs::metadata(root.join(name)).map_err(|e|e.to_string())?.permissions().mode()&0o111==0 {return Err("Host executable is not executable".into());}
    }
    Ok(())
}

/// Removes versions other than `keep` and the newest one before it.
fn prune(root: &Path, keep: &str) {
    let Ok(entries) = std::fs::read_dir(root) else { return };
    let mut others: Vec<(std::time::SystemTime, PathBuf)> = entries
        .flatten()
        .filter(|e| e.file_name() != keep && e.path().is_dir())
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    others.sort();
    others.pop();
    for (_, path) in others {
        log::info!("Removing old host {}", path.display());
        let _ = std::fs::remove_dir_all(path);
    }
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf).map_err(|e| format!("{}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifies_extracted_files_before_activating_a_host() {
        use std::os::unix::fs::PermissionsExt;
        let root=std::env::temp_dir().join(format!("meteor-host-manifest-{}",std::process::id()));
        std::fs::create_dir_all(root.join("bin")).unwrap();
        let release=Release{version:"test",url:"unused",size:0,sha256:"unused",binary:"bin/meteor-vibepollo"};
        let mut files=serde_json::Map::new();
        for name in ["bin/meteor-vibepollo","bin/vibepollo"] {
            let file=root.join(name);std::fs::write(&file,b"original host bytes").unwrap();
            std::fs::set_permissions(&file,std::fs::Permissions::from_mode(0o755)).unwrap();
            files.insert(name.into(),sha256_file(&file).unwrap().into());
        }
        std::fs::write(root.join("manifest.json"),serde_json::to_vec(&serde_json::json!({
            "version":"test","binary":release.binary,"files":files})).unwrap()).unwrap();
        verify_install(&root,&release).unwrap();
        std::fs::write(root.join("bin/vibepollo"),b"incomplete download").unwrap();
        assert!(verify_install(&root,&release).unwrap_err().contains("failed verification"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn hashes_a_file() {
        let path = std::env::temp_dir().join(format!("meteor-hash-{}", std::process::id()));
        std::fs::write(&path, b"abc").unwrap();
        assert_eq!(sha256_file(&path).unwrap(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn keeps_the_current_and_the_previous_version() {
        let root = std::env::temp_dir().join(format!("meteor-prune-{}", std::process::id()));
        for (i, v) in ["0.1", "0.2", "0.3"].iter().enumerate() {
            std::fs::create_dir_all(root.join(v)).unwrap();
            let t = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_000 + i as u64);
            std::fs::File::open(root.join(v)).unwrap().set_modified(t).unwrap();
        }
        prune(&root, "0.3");
        assert!(!root.join("0.1").exists());
        assert!(root.join("0.2").exists() && root.join("0.3").exists());
        std::fs::remove_dir_all(&root).unwrap();
    }
}
