//! Logs to stderr and to a file, because an autostarted AppImage has no
//! terminal: `~/.local/state/nightfall-meteor/meteor.log`, moved to
//! `meteor.log.1` when it passes 5 MB.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

const MAX_BYTES: u64 = 5_000_000;

pub fn path() -> PathBuf {
    if cfg!(windows) {
        return crate::config::cache_dir().join("meteor.log");
    }
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".local/state")))
        .unwrap_or_default();
    base.join("nightfall-meteor").join("meteor.log")
}

/// Starts logging (RUST_LOG, default info). `rotate` is for the main
/// process; the engine-build child only appends.
pub fn init(rotate: bool) {
    let mut builder = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"));
    if let Some(tee) = Tee::open(path(), rotate) {
        builder.target(env_logger::Target::Pipe(Box::new(tee)));
    }
    builder.init();
}

/// Writes each record to stderr and the log file.
struct Tee {
    path: PathBuf,
    file: File,
    written: u64,
    rotate: bool,
}

impl Tee {
    fn open(path: PathBuf, rotate: bool) -> Option<Tee> {
        std::fs::create_dir_all(path.parent()?).ok()?;
        let size = std::fs::metadata(&path).map_or(0, |m| m.len());
        if rotate && size > MAX_BYTES {
            let _ = std::fs::rename(&path, backup(&path));
        }
        let file = OpenOptions::new().create(true).append(true).open(&path).ok()?;
        let written = file.metadata().map_or(0, |m| m.len());
        Some(Tee { path, file, written, rotate })
    }
}

fn backup(path: &Path) -> PathBuf {
    path.with_extension("log.1")
}

impl Write for Tee {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let _ = std::io::stderr().write_all(buf);
        if self.rotate && self.written > MAX_BYTES {
            let _ = std::fs::rename(&self.path, backup(&self.path));
            if let Ok(file) = OpenOptions::new().create(true).append(true).open(&self.path) {
                self.file = file;
                self.written = 0;
            }
        }
        // A full disk mustn't stop Meteor: the file is best effort.
        if self.file.write_all(buf).is_ok() {
            self.written += buf.len() as u64;
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        let _ = std::io::stderr().flush();
        let _ = self.file.flush();
        Ok(())
    }
}
