//! Linux socket activation. Only a local IPC connection creates a notice;
//! the existing authenticated XR control channel must claim it before startup.
use std::{fs, io, os::{fd::{AsRawFd, FromRawFd}, unix::{fs::{MetadataExt, PermissionsExt, OpenOptionsExt}, net::UnixListener}}, path::{Path, PathBuf}, sync::{Arc, Mutex, Weak}, time::{Duration, Instant}};
use ring::rand::{SecureRandom, SystemRandom};

struct Notice { generation: String, claimed: bool, expires: Instant }
struct Listener {
    root: PathBuf,
    socket: UnixListener,
    path: PathBuf,
    identity: (u64, u64),
    _lock: fs::File,
    notice: Option<Notice>,
    active: Option<String>,
    registration: Weak<RegistrationLease>,
}
static LISTENER: Mutex<Option<Listener>> = Mutex::new(None);

fn private_directory(path: &Path) -> io::Result<()> {
    match fs::create_dir(path) {
        Ok(()) => fs::set_permissions(path, fs::Permissions::from_mode(0o700))?,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {},
        Err(error) => return Err(error),
    }
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() || meta.uid() != unsafe {libc::geteuid()} || meta.mode() & 0o077 != 0 {
        return Err(io::Error::other("XR activation directory is not private or user-owned"));
    }
    Ok(())
}

impl Listener {
    fn new(root: &Path, directory: &Path) -> io::Result<Self> {
        private_directory(directory)?;
        let lock = fs::OpenOptions::new().read(true).write(true).create(true).truncate(false)
            .mode(0o600).custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).open(directory.join("activation.lock"))?;
        if unsafe {libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB)} != 0 {
            return Err(io::Error::other("Another XR activation listener owns this directory"));
        }
        let path = directory.join("monado_comp_ipc");
        // No unlink here: even a stale-looking socket can belong to another runtime.
        let socket = UnixListener::bind(&path)?;
        socket.set_nonblocking(true)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let meta = fs::symlink_metadata(&path)?;
        Ok(Self { root: root.canonicalize()?, socket, path, identity: (meta.dev(), meta.ino()),
                  _lock: lock, notice: None, active: None, registration: Weak::new() })
    }
    fn drain(&self) {
        // Reject only queued, not-yet-handed-off connections. No established
        // game connection or foreign process is touched.
        for _ in 0..32 {
            if self.socket.accept().is_err() {break;}
        }
    }
    fn pending(&mut self) -> Option<crate::xr_launch_intent::LaunchNotice> {
        if self.active.is_some() {return None;}
        if self.notice.as_ref().is_some_and(|notice|notice.expires <= Instant::now()) {
            self.notice = None;
            self.drain();
            return None;
        }
        if self.notice.is_none() {
            let mut poll = libc::pollfd {fd: self.socket.as_raw_fd(), events: libc::POLLIN, revents: 0};
            if unsafe {libc::poll(&mut poll, 1, 0)} <= 0 || poll.revents & libc::POLLIN == 0 {return None;}
            let mut random = [0u8; 16];
            SystemRandom::new().fill(&mut random).ok()?;
            self.notice = Some(Notice {generation: random.iter().map(|byte|format!("{byte:02x}")).collect(),
                                      claimed: false, expires: Instant::now() + Duration::from_secs(30)});
        }
        self.notice.as_ref().filter(|notice|!notice.claimed).map(|notice|crate::xr_launch_intent::LaunchNotice {
            generation: notice.generation.clone(),
            // Wire-compatible connection-only placeholder, as used by the
            // Windows SteamVR route. This never selects or launches a game.
            app_id: "250820".into(),
        })
    }
    fn claim(&mut self, generation: &str) -> bool {
        if let Some(notice) = self.notice.as_mut().filter(|notice|!notice.claimed && notice.expires > Instant::now() && notice.generation == generation) {
            notice.claimed = true;
            return true;
        }
        false
    }
}
impl Drop for Listener {
    fn drop(&mut self) {
        if fs::symlink_metadata(&self.path).is_ok_and(|meta|(meta.dev(),meta.ino()) == self.identity) {
            let _ = fs::remove_file(&self.path);
        }
    }
}

/// Opt-in DEV listener only. Registration is intentionally a separate lease.
pub(crate) struct Service {root: PathBuf}
pub(crate) fn start(root: &Path, directory: &Path) -> io::Result<Service> {
    let mut slot = LISTENER.lock().unwrap();
    if slot.is_some() {return Err(io::Error::other("XR activation is already enabled"));}
    let listener = Listener::new(root, directory)?;
    let root = listener.root.clone();
    *slot = Some(listener);
    Ok(Service {root})
}
impl Drop for Service {
    fn drop(&mut self) {
        let mut slot = LISTENER.lock().unwrap();
        if slot.as_ref().is_some_and(|listener|listener.root == self.root) {*slot = None;}
    }
}
pub(crate) fn pending(root: &Path) -> Option<crate::xr_launch_intent::LaunchNotice> {
    LISTENER.lock().unwrap().as_mut().filter(|listener|listener.root == root).and_then(Listener::pending)
}
pub(crate) fn claim(root: &Path, generation: &str) -> bool {
    LISTENER.lock().unwrap().as_mut().filter(|listener|listener.root == root).is_some_and(|listener|listener.claim(generation))
}
pub(crate) fn cancel_claim(root: &Path, generation: &str) {
    let mut slot = LISTENER.lock().unwrap();
    if let Some(listener) = slot.as_mut().filter(|listener|listener.root == root) {
        if listener.notice.as_ref().is_some_and(|notice|notice.claimed && notice.generation == generation) {
            listener.notice = None;
            listener.drain();
        }
    }
}

pub(crate) struct Activation {pub listener: UnixListener, root: PathBuf, generation: String, _registration: Option<Arc<RegistrationLease>>}
pub(crate) fn take(root: &Path, generation: &str) -> io::Result<Option<Activation>> {
    let mut slot = LISTENER.lock().unwrap();
    let Some(listener) = slot.as_mut().filter(|listener|listener.root == root) else {return Ok(None)};
    let Some(notice) = listener.notice.as_ref().filter(|notice|notice.generation == generation) else {return Ok(None)};
    if !notice.claimed || notice.expires <= Instant::now() {
        return Err(io::Error::other("XR socket activation was not claimed or expired"));
    }
    // Give the runtime a duplicate while retaining the listening
    // endpoint in the broker. No parent accept/proxy loses ancillary data.
    let fd = unsafe {libc::fcntl(listener.socket.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 3)};
    if fd < 0 {return Err(io::Error::last_os_error());}
    let duplicate = unsafe {UnixListener::from_raw_fd(fd)};
    // O_NONBLOCK is shared by dup: keep it unchanged. Monado uses epoll and
    // accepts when readable, matching its existing activated-listener path.
    listener.active = Some(generation.into());
    listener.notice = None;
    Ok(Some(Activation {listener: duplicate, root: root.into(), generation: generation.into(), _registration: listener.registration.upgrade()}))
}
impl Drop for Activation {
    fn drop(&mut self) {
        let mut slot = LISTENER.lock().unwrap();
        if let Some(listener) = slot.as_mut().filter(|listener|listener.root == self.root && listener.active.as_deref() == Some(&self.generation)) {
            listener.active = None;
            listener.drain();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;
    #[test]
    fn registration_helper_lifetime_follows_last_owner_and_rejects_bad_reply() {
        let marker=std::env::temp_dir().join(format!("nf-registration-owner-{}",std::process::id()));
        let _=fs::remove_file(&marker);
        let script="import json,sys; from pathlib import Path; print(json.dumps(dict(ready=True,ipc_socket='nightfall-meteor/monado_comp_ipc')),flush=True); sys.stdin.buffer.read(); Path(sys.argv[1]).write_text('restored')";
        let lease=Arc::new(RegistrationLease::command(std::process::Command::new("/usr/bin/python3").arg("-c").arg(script).arg(&marker)).unwrap());
        let runtime=lease.clone();
        drop(lease);
        assert!(!marker.exists());
        drop(runtime);
        assert_eq!(fs::read_to_string(&marker).unwrap(),"restored");
        fs::remove_file(&marker).unwrap();
        assert!(RegistrationLease::command(std::process::Command::new("/usr/bin/python3").arg("-c").arg("print('{}',flush=True); input()")).is_err());
    }

    #[test]
    fn authenticated_notice_route_consumes_listener_and_cancelled_claim_recovers() {
        use std::io::{Read, Write};
        let root = std::env::temp_dir().join(format!("nf-activation-control-{}",std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let service = start(&root, &root.join("runtime")).unwrap();
        assert!(crate::xr_launch_intent::pending(&root).is_none());
        let mut client = UnixStream::connect(root.join("runtime/monado_comp_ipc")).unwrap();
        let notice = crate::xr_launch_intent::pending(&root).unwrap();
        assert!(take(&root,&notice.generation).is_err());
        assert!(!crate::xr_launch_intent::claim(&root,&"e".repeat(32)));
        assert!(crate::xr_launch_intent::claim(&root,&notice.generation));
        let active = take(&root,&notice.generation).unwrap().unwrap();
        assert!(take(&root,&notice.generation).unwrap().is_none());
        assert!(crate::xr_launch_intent::pending(&root).is_none());
        let (mut peer,_) = active.listener.accept().unwrap();
        client.write_all(b"original IPC").unwrap();
        let mut data = [0u8;12];
        peer.read_exact(&mut data).unwrap();
        assert_eq!(&data,b"original IPC");
        drop(peer); drop(client); drop(active);
        let _client = UnixStream::connect(root.join("runtime/monado_comp_ipc")).unwrap();
        let notice = crate::xr_launch_intent::pending(&root).unwrap();
        {
            let mut claim = StartupClaim::new(Some(&root));
            assert!(crate::xr_launch_intent::claim(&root,&notice.generation));
            claim.set(&notice.generation);
        }
        assert!(take(&root,&notice.generation).unwrap().is_none());
        assert!(crate::xr_launch_intent::pending(&root).is_none());
        drop(service);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn socket_notice_requires_claim_is_single_use_and_reconnects() {
        let root = std::env::temp_dir().join(format!("nf-activation-rust-{}",std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let directory = root.join("runtime");
        let mut listener = Listener::new(&root, &directory).unwrap();
        assert!(listener.pending().is_none());
        let client = UnixStream::connect(&listener.path).unwrap();
        let notice = listener.pending().unwrap();
        assert_eq!(listener.pending().unwrap(), notice);
        assert!(!listener.claim(&"f".repeat(32)));
        assert!(listener.claim(&notice.generation));
        assert!(!listener.claim(&notice.generation));
        assert!(listener.pending().is_none());
        listener.notice.as_mut().unwrap().expires = Instant::now();
        assert!(listener.pending().is_none());
        drop(client);
        let _second = UnixStream::connect(&listener.path).unwrap();
        assert_ne!(listener.pending().unwrap().generation, notice.generation);
        assert!(Listener::new(&root, &directory).is_err());
        let path = listener.path.clone();
        drop(listener);
        assert!(!path.exists());
        fs::remove_dir_all(root).unwrap();
    }
}

/// A control connection that disappears during preparation must release its
/// unconsumed request. Once take() succeeds, the runtime owns that generation.
pub(crate) struct StartupClaim {root: Option<PathBuf>, generation: Option<String>}
impl StartupClaim {
    pub(crate) fn new(root: Option<&Path>) -> Self {Self {root:root.map(Path::to_path_buf), generation:None}}
    pub(crate) fn set(&mut self, generation: &str) {self.generation=Some(generation.into());}
}
impl Drop for StartupClaim {
    fn drop(&mut self) {
        if let (Some(root),Some(generation))=(&self.root,&self.generation) {cancel_claim(root,generation);}
    }
}


/// A pipe-owned helper holds filesystem registration while a trusted headset
/// watcher or active runtime needs it. EOF restores configuration on Meteor exit.
pub(crate) struct RegistrationLease {
    child: std::process::Child,
    input: Option<std::process::ChildStdin>,
}
impl RegistrationLease {
    fn launch(root: &Path) -> io::Result<Self> {
        Self::command(std::process::Command::new("/usr/bin/python3")
            .arg(root.join("tools/meteor_xr_register.py")).arg("--root").arg(root))
    }
    fn command(command: &mut std::process::Command) -> io::Result<Self> {
        use std::io::Read;
        use std::process::Stdio;
        let mut child = command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn()?;
        let input = child.stdin.take();
        let mut output = child.stdout.take().ok_or_else(||io::Error::other("Missing XR registration acknowledgement pipe"))?;
        let lease = Self {child, input};
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut bytes = Vec::new();
        loop {
            if Instant::now() >= deadline {return Err(io::Error::other("XR runtime registration timed out"));}
            let mut poll = libc::pollfd {fd: output.as_raw_fd(), events: libc::POLLIN, revents: 0};
            if unsafe {libc::poll(&mut poll, 1, 50)} < 0 {return Err(io::Error::last_os_error());}
            if poll.revents & (libc::POLLIN | libc::POLLHUP) == 0 {continue;}
            let mut byte = [0u8;1];
            if output.read(&mut byte)? == 0 {return Err(io::Error::other("XR registration helper exited before readiness; see Meteor log"));}
            if byte[0] == b'\n' {break;}
            bytes.push(byte[0]);
            if bytes.len() > 4096 {return Err(io::Error::other("XR registration reply exceeds bound"));}
        }
        let reply: serde_json::Value = serde_json::from_slice(&bytes)?;
        if reply["ready"] != true || reply["ipc_socket"] != "nightfall-meteor/monado_comp_ipc" {
            return Err(io::Error::other("XR runtime registration was not acknowledged"));
        }
        Ok(lease)
    }
}
impl Drop for RegistrationLease {
    fn drop(&mut self) {
        self.input.take(); // EOF asks the helper to restore only its own entries.
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if !matches!(self.child.try_wait(),Ok(None)) {break;}
            if Instant::now() >= deadline {
                log::warn!("XR registration cleanup timed out; journals will recover on next connection");
                let _ = self.child.kill();
                let _ = self.child.wait();
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

pub(crate) fn register_authenticated(root: &Path) -> io::Result<Option<Arc<RegistrationLease>>> {
    let mut slot = LISTENER.lock().unwrap();
    let Some(listener) = slot.as_mut().filter(|listener|listener.root == root) else {return Ok(None)};
    if let Some(lease) = listener.registration.upgrade() {return Ok(Some(lease));}
    let lease = Arc::new(RegistrationLease::launch(root)?);
    listener.registration = Arc::downgrade(&lease);
    log::info!("Authenticated headset enabled temporary OpenXR/xrizer registration");
    Ok(Some(lease))
}
