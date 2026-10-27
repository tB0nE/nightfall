//! Local approval of authenticated headset identities. Discovery never grants access.
use std::{collections::BTreeSet, io, path::PathBuf, sync::Mutex, time::{Duration, Instant}};

struct Pending { key: [u8; 32], expires: Instant, notified: bool }
struct State { approved: BTreeSet<[u8; 32]>, pending: Option<Pending> }
pub struct Trust { path: PathBuf, state: Mutex<State> }

pub fn code(key: &[u8; 32]) -> String {
    ring::digest::digest(&ring::digest::SHA256, key).as_ref()[..4]
        .iter().map(|byte| format!("{byte:02X}")).collect()
}

impl Trust {
    pub fn load(path: PathBuf) -> io::Result<Self> {
        let approved = match std::fs::read(&path) {
            Ok(bytes) => {
                if bytes.len() > 16384 { return Err(io::Error::other("XR trust file is too large")); }
                let keys: Vec<String> = serde_json::from_slice(&bytes)?;
                if keys.len() > 8 { return Err(io::Error::other("XR trust list exceeds eight headsets")); }
                keys.iter().map(|key| crate::xr_control::public_key(key)).collect::<io::Result<BTreeSet<_>>>()?
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => BTreeSet::new(),
            Err(error) => return Err(error),
        };
        Ok(Self { path, state: Mutex::new(State { approved, pending: None }) })
    }
    pub fn allows(&self, key: &[u8; 32]) -> bool { self.state.lock().unwrap().approved.contains(key) }
    /// Called only after the encrypted Authenticate proves possession of the key.
    pub fn request(&self, key: [u8; 32]) -> Option<String> {
        let mut state = self.state.lock().unwrap();
        if state.approved.contains(&key) { return None; }
        if state.pending.as_ref().is_some_and(|p| p.expires <= Instant::now()) { state.pending = None; }
        if state.pending.is_none() {
            state.pending = Some(Pending { key, expires: Instant::now() + Duration::from_secs(60), notified: false });
        }
        state.pending.as_ref().filter(|p| p.key == key).map(|_| code(&key))
    }
    pub fn pending(&self) -> Option<([u8; 32], String)> {
        self.state.lock().unwrap().pending.as_ref().filter(|p| p.expires > Instant::now())
            .map(|p| (p.key, code(&p.key)))
    }
    pub fn take_notification(&self) -> Option<([u8; 32], String)> {
        let mut state = self.state.lock().unwrap();
        let pending = state.pending.as_mut()?;
        if pending.notified || pending.expires <= Instant::now() { return None; }
        pending.notified = true;
        Some((pending.key, code(&pending.key)))
    }
    pub fn approve(&self, key: [u8; 32]) -> io::Result<()> {
        let mut state = self.state.lock().unwrap();
        if !state.pending.as_ref().is_some_and(|p| p.key == key && p.expires > Instant::now()) {
            return Err(io::Error::other("Headset approval expired or changed"));
        }
        if state.approved.len() >= 8 { return Err(io::Error::other("Eight headsets are already authorized")); }
        let mut updated = state.approved.clone(); updated.insert(key);
        let keys: Vec<String> = updated.iter().map(|key|key.iter().map(|b|format!("{b:02x}")).collect()).collect();
        let parent = self.path.parent().ok_or_else(||io::Error::other("Invalid XR trust path"))?;
        std::fs::create_dir_all(parent)?;
        let temporary = self.path.with_extension(format!("{}.tmp", std::process::id()));
        let mut created = false;
        let result = (|| {
            use std::io::Write;
            let mut options = std::fs::OpenOptions::new(); options.write(true).create_new(true);
            #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
            let mut file = options.open(&temporary)?; created = true;
            file.write_all(&serde_json::to_vec_pretty(&keys)?)?; file.sync_all()?;
            std::fs::rename(&temporary, &self.path)
        })();
        if result.is_err() && created { let _ = std::fs::remove_file(&temporary); }
        // Do not remove a pre-existing file that this invocation did not create.
        if result.is_ok() { state.approved = updated; state.pending = None; }
        result
    }
    pub fn reject(&self, key: [u8; 32]) {
        let mut state = self.state.lock().unwrap();
        if state.pending.as_ref().is_some_and(|p|p.key == key) { state.pending = None; }
    }
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn approval_is_local_bounded_persistent_and_key_specific() {
        let root=std::env::temp_dir().join(format!("meteor-trust-{}-{}",std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let path=root.join("trust.json"); let trust=Trust::load(path.clone()).unwrap();
        assert!(trust.approve([1;32]).is_err());
        assert_eq!(trust.request([1;32]),Some(code(&[1;32])));
        assert_eq!(trust.take_notification(),Some(([1;32],code(&[1;32]))));
        trust.request([1;32]);
        assert!(trust.take_notification().is_none());
        assert!(!trust.allows(&[1;32])); assert!(trust.request([2;32]).is_none());
        assert!(trust.approve([2;32]).is_err()); trust.approve([1;32]).unwrap();
        assert!(Trust::load(path).unwrap().allows(&[1;32]));
        assert!(!trust.allows(&[2;32])); std::fs::remove_dir_all(root).unwrap();
    }
    #[test] fn stale_pending_cannot_be_approved() {
        let trust=Trust::load(PathBuf::from("/unused/xr-trust-test")).unwrap();
        trust.request([1;32]);
        trust.state.lock().unwrap().pending.as_mut().unwrap().expires=Instant::now()-Duration::from_secs(1);
        assert!(trust.pending().is_none()); assert!(trust.approve([1;32]).is_err());
        assert!(trust.take_notification().is_none());
    }
}
