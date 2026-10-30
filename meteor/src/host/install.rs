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

/// None until the fork publishes its first Linux build; until then the
/// bundled host needs `host_binary` in meteor.toml.
pub const RELEASE: Option<Release> = None;

pub struct Install;

impl Install {
    pub fn root() -> PathBuf {
        crate::config::data_dir().join("host")
    }

    /// The installed executable of `release`, if it's there.
    pub fn binary(release: &Release) -> Option<PathBuf> {
        let path = Self::root().join(release.version).join(release.binary);
        path.is_file().then_some(path)
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
    let archive = root.join(format!("{}.tar.zst.download", release.version));
    log::info!("Host download: {}", release.url);
    download.resumable(&crate::download::agent(), release.url, 0, release.size, &archive)?;
    let actual = sha256_file(&archive)?;
    if actual != release.sha256 {
        let _ = std::fs::remove_file(&archive);
        return Err(format!("the host download has SHA-256 {actual}, expected {}", release.sha256));
    }
    let target = root.join(release.version);
    let partial = root.join(format!("{}.partial", release.version));
    let _ = std::fs::remove_dir_all(&partial);
    let file = std::fs::File::open(&archive).map_err(|e| fail(&archive, e))?;
    let decoder = zstd::Decoder::new(file).map_err(|e| fail(&archive, e))?;
    tar::Archive::new(decoder).unpack(&partial).map_err(|e| fail(&partial, e))?;
    let _ = std::fs::remove_dir_all(&target);
    std::fs::rename(&partial, &target).map_err(|e| fail(&target, e))?;
    let _ = std::fs::remove_file(&archive);
    prune(&root, release.version);
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
