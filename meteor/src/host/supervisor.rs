//! Runs the bundled host as a child process and keeps it running.
//!
//! The child gets its own process group, so stopping it also stops
//! whatever it launched, and PR_SET_PDEATHSIG, so it ends with Meteor even
//! when Meteor exits through `_exit` (see `exit_now`) or crashes. The
//! signal follows the thread that spawned the child, which is why the
//! supervisor runs on its own thread for Meteor's whole life.
//!
//! A crash is retried after 1, 5 and 30 seconds; a host that then still
//! won't stay up is left stopped, with the reason in the tray. While
//! another program holds the base port, the supervisor waits for it.

use std::fs::OpenOptions;
use std::os::unix::process::CommandExt;
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::Instance;
use crate::ports::Proto;

#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Stopped,
    /// Another program holds the base port.
    WaitingForPort,
    Running,
    Restarting { failures: u32 },
    Failed(String),
}

pub struct Supervisor {
    pub instance: Instance,
    phase: Mutex<Phase>,
    wanted: AtomicBool,
    pid: AtomicU32,
}

/// Restarts after these delays, then gives up.
const BACKOFF: [u64; 3] = [1, 5, 30];
/// A run this long resets the failure count.
const HEALTHY_AFTER: Duration = Duration::from_secs(60);
const POLL: Duration = Duration::from_millis(250);

/// The delay before restart number `failures`, or None to give up.
pub fn backoff(failures: u32) -> Option<Duration> {
    let i = usize::try_from(failures).ok()?.checked_sub(1)?;
    BACKOFF.get(i).map(|&s| Duration::from_secs(s))
}

impl Supervisor {
    pub fn start(instance: Instance) -> Arc<Self> {
        let supervisor = Arc::new(Supervisor {
            instance,
            phase: Mutex::new(Phase::Stopped),
            wanted: AtomicBool::new(true),
            pid: AtomicU32::new(0),
        });
        let worker = supervisor.clone();
        std::thread::Builder::new()
            .name("host-supervisor".into())
            .spawn(move || worker.run())
            .expect("spawn the host supervisor");
        supervisor
    }

    pub fn phase(&self) -> Phase {
        self.phase.lock().map_or(Phase::Stopped, |p| p.clone())
    }

    fn set(&self, phase: Phase) {
        if let Ok(mut p) = self.phase.lock()
            && *p != phase
        {
            log::info!("Bundled host: {phase:?}");
            *p = phase;
        }
    }

    /// The running child's pid, so host detection can leave it out.
    pub fn pid(&self) -> Option<u32> {
        Some(self.pid.load(Ordering::Relaxed)).filter(|&p| p != 0)
    }

    pub fn wanted(&self) -> bool {
        self.wanted.load(Ordering::Relaxed)
    }

    /// Start or stop from the tray. Starting again also clears a failure.
    pub fn set_wanted(&self, on: bool) {
        self.wanted.store(on, Ordering::Relaxed);
    }

    /// Stops the host and waits for it (up to 4 s), for Meteor's quit.
    pub fn shutdown(&self) {
        self.wanted.store(false, Ordering::Relaxed);
        let end = Instant::now() + Duration::from_secs(4);
        while self.pid().is_some() && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    fn run(&self) {
        let mut failures = 0u32;
        loop {
            if !self.wanted() {
                if !matches!(self.phase(), Phase::Failed(_)) {
                    self.set(Phase::Stopped);
                }
                std::thread::sleep(POLL);
                failures = 0;
                continue;
            }
            if matches!(self.phase(), Phase::Failed(_)) {
                // Wanted again after a failure: the tray's Start.
                failures = 0;
            }
            if !super::port_free((self.instance.base, Proto::Tcp)) {
                self.set(Phase::WaitingForPort);
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
            let started = Instant::now();
            let result = self.run_once();
            if !self.wanted() {
                continue;
            }
            if started.elapsed() >= HEALTHY_AFTER {
                failures = 0;
            }
            failures += 1;
            match (result, backoff(failures)) {
                (Err(err), _) => self.fail(err),
                (Ok(status), Some(delay)) => {
                    log::warn!("Bundled host exited ({status}); restarting in {}s", delay.as_secs());
                    self.set(Phase::Restarting { failures });
                    self.sleep_while_wanted(delay);
                }
                (Ok(status), None) => self.fail(format!("it keeps exiting ({status}); see its log")),
            }
        }
    }

    fn fail(&self, reason: String) {
        log::error!("Bundled host stopped: {reason}");
        self.set(Phase::Failed(reason));
        self.wanted.store(false, Ordering::Relaxed);
    }

    fn sleep_while_wanted(&self, delay: Duration) {
        let end = Instant::now() + delay;
        while self.wanted() && Instant::now() < end {
            std::thread::sleep(POLL);
        }
    }

    /// Runs the host until it exits or isn't wanted any more.
    fn run_once(&self) -> Result<std::process::ExitStatus, String> {
        let log_path = self.instance.appdata().join("meteor-host.log");
        let log = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)
            .map_err(|e| format!("{}: {e}", log_path.display()))?;
        let mut command = self.instance.command();
        command
            .stdin(Stdio::null())
            .stdout(log.try_clone().map_err(|e| e.to_string())?)
            .stderr(log)
            .process_group(0);
        // SAFETY: prctl is async-signal-safe and touches only the child.
        unsafe {
            command.pre_exec(|| {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) != 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child: Child = command.spawn().map_err(|e| format!("can't start {}: {e}", self.instance.binary.display()))?;
        self.pid.store(child.id(), Ordering::Relaxed);
        self.set(Phase::Running);
        log::info!("Bundled host started (pid {}, base port {})", child.id(), self.instance.base);
        let status = loop {
            if let Ok(Some(status)) = child.try_wait() {
                break status;
            }
            if !self.wanted() {
                break stop(&mut child, Duration::from_secs(3)).map_err(|e| e.to_string())?;
            }
            std::thread::sleep(POLL);
        };
        self.pid.store(0, Ordering::Relaxed);
        Ok(status)
    }
}

/// SIGTERM to the child's group, then SIGKILL after `grace`.
fn stop(child: &mut Child, grace: Duration) -> std::io::Result<std::process::ExitStatus> {
    let pgid = libc::pid_t::try_from(child.id()).unwrap_or(0);
    // SAFETY: kill(2) on the process group Meteor created for this child.
    unsafe {
        libc::kill(-pgid, libc::SIGTERM);
    }
    let end = Instant::now() + grace;
    while Instant::now() < end {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    log::warn!("Bundled host didn't stop in {}s; killing it", grace.as_secs());
    // SAFETY: as above.
    unsafe {
        libc::kill(-pgid, libc::SIGKILL);
    }
    child.wait()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backs_off_then_gives_up() {
        assert_eq!(backoff(0), None);
        assert_eq!(backoff(1), Some(Duration::from_secs(1)));
        assert_eq!(backoff(3), Some(Duration::from_secs(30)));
        assert_eq!(backoff(4), None);
    }

    /// A fixed port can be some outgoing connection's local port.
    fn free_port() -> u16 {
        std::net::TcpListener::bind(("0.0.0.0", 0)).unwrap().local_addr().unwrap().port()
    }

    #[test]
    fn restarts_a_crashing_child_then_fails() {
        let dir = std::env::temp_dir().join(format!("meteor-host-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("vibepollo")).unwrap();
        // A "host" that exits at once, on a port nothing else uses.
        let instance = Instance { binary: "/bin/false".into(), base: free_port(), dir: dir.clone(), env: Vec::new() };
        let supervisor = Supervisor::start(instance);
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !matches!(supervisor.phase(), Phase::Restarting { failures: 2 }) {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert_eq!(supervisor.phase(), Phase::Restarting { failures: 2 });
        supervisor.set_wanted(false);
        std::thread::sleep(Duration::from_millis(600));
        assert_eq!(supervisor.phase(), Phase::Stopped);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn stops_a_running_child() {
        let dir = std::env::temp_dir().join(format!("meteor-host-run-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("vibepollo")).unwrap();
        // A "host" that ignores its arguments and runs until stopped.
        let script = dir.join("host.sh");
        std::fs::write(&script, "#!/bin/sh\nexec sleep 30\n").unwrap();
        std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
        let instance = Instance { binary: script, base: free_port(), dir: dir.clone(), env: Vec::new() };
        let supervisor = Supervisor::start(instance);
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && supervisor.pid().is_none() {
            std::thread::sleep(Duration::from_millis(50));
        }
        let pid = supervisor.pid().unwrap_or_else(|| panic!("host not started: {:?}", supervisor.phase()));
        supervisor.shutdown();
        assert!(unsafe { libc::kill(pid as libc::pid_t, 0) } != 0, "child still alive");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
