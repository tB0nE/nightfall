//! Windows child supervision for the Meteor-managed GameStream host.

use std::fs::OpenOptions;
use std::os::windows::io::AsRawHandle;
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::Instance;
use crate::ports::Proto;
use windows_sys::Win32::Foundation::{CloseHandle, HANDLE};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
};

struct ChildJob(HANDLE);

impl ChildJob {
    fn attach(child: &mut Child) -> Result<Self, String> {
        // A kill-on-close job stops the host and any helpers if Meteor crashes
        // or exits through TerminateProcess before shutdown can run.
        let job = unsafe { CreateJobObjectW(std::ptr::null(), std::ptr::null()) };
        if job.is_null() {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("can't create host job: {}", std::io::Error::last_os_error()));
        }
        let guard = Self(job);
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let configured = unsafe {
            SetInformationJobObject(
                guard.0, JobObjectExtendedLimitInformation,
                (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        };
        let assigned = configured != 0 && unsafe {
            AssignProcessToJobObject(guard.0, child.as_raw_handle() as HANDLE)
        } != 0;
        if !assigned {
            let error = std::io::Error::last_os_error();
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("can't supervise host process: {error}"));
        }
        Ok(guard)
    }
}

impl Drop for ChildJob {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Stopped,
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

const BACKOFF: [u64; 3] = [1, 5, 30];
const HEALTHY_AFTER: Duration = Duration::from_secs(60);
const POLL: Duration = Duration::from_millis(250);

pub fn backoff(failures: u32) -> Option<Duration> {
    let index = usize::try_from(failures).ok()?.checked_sub(1)?;
    BACKOFF.get(index).map(|&seconds| Duration::from_secs(seconds))
}

impl Supervisor {
    pub fn start(instance: Instance) -> Arc<Self> {
        let supervisor = Arc::new(Self {
            instance,
            phase: Mutex::new(Phase::Stopped),
            wanted: AtomicBool::new(true),
            pid: AtomicU32::new(0),
        });
        let worker = supervisor.clone();
        std::thread::Builder::new().name("host-supervisor".into())
            .spawn(move || worker.run()).expect("spawn the host supervisor");
        supervisor
    }

    pub fn phase(&self) -> Phase {
        self.phase.lock().map_or(Phase::Stopped, |phase| phase.clone())
    }

    fn set(&self, phase: Phase) {
        if let Ok(mut current) = self.phase.lock() && *current != phase {
            log::info!("Bundled host: {phase:?}");
            *current = phase;
        }
    }

    pub fn pid(&self) -> Option<u32> {
        Some(self.pid.load(Ordering::Relaxed)).filter(|&pid| pid != 0)
    }

    pub fn wanted(&self) -> bool {
        self.wanted.load(Ordering::Relaxed)
    }

    pub fn set_wanted(&self, on: bool) {
        self.wanted.store(on, Ordering::Relaxed);
    }

    pub fn shutdown(&self) {
        self.set_wanted(false);
        let deadline = Instant::now() + Duration::from_secs(4);
        while self.pid().is_some() && Instant::now() < deadline {
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
                failures = 0;
                std::thread::sleep(POLL);
                continue;
            }
            if matches!(self.phase(), Phase::Failed(_)) {
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
                (Err(error), _) => self.fail(error),
                (Ok(status), Some(delay)) => {
                    log::warn!("Bundled host exited ({status}); restarting in {}s", delay.as_secs());
                    self.set(Phase::Restarting { failures });
                    let deadline = Instant::now() + delay;
                    while self.wanted() && Instant::now() < deadline {
                        std::thread::sleep(POLL);
                    }
                }
                (Ok(status), None) => self.fail(format!("it keeps exiting ({status}); see its log")),
            }
        }
    }

    fn fail(&self, reason: String) {
        log::error!("Bundled host stopped: {reason}");
        self.set(Phase::Failed(reason));
        self.set_wanted(false);
    }

    fn run_once(&self) -> Result<std::process::ExitStatus, String> {
        let log_path = self.instance.appdata().join("meteor-host.log");
        let log = OpenOptions::new().create(true).append(true).open(&log_path)
            .map_err(|error| format!("{}: {error}", log_path.display()))?;
        let mut command = self.instance.command();
        command.stdin(Stdio::null())
            .stdout(log.try_clone().map_err(|error| error.to_string())?)
            .stderr(log);
        let mut child = command.spawn()
            .map_err(|error| format!("can't start {}: {error}", self.instance.binary.display()))?;
        let _job = ChildJob::attach(&mut child)?;
        self.pid.store(child.id(), Ordering::Relaxed);
        self.set(Phase::Running);
        log::info!("Bundled host started (pid {}, base port {})", child.id(), self.instance.base);
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Err(error) => break Err(error.to_string()),
                Ok(None) if !self.wanted() => break stop(&mut child),
                Ok(None) => std::thread::sleep(POLL),
            }
        };
        self.pid.store(0, Ordering::Relaxed);
        status
    }
}

fn stop(child: &mut Child) -> Result<std::process::ExitStatus, String> {
    child.kill().map_err(|error| error.to_string())?;
    child.wait().map_err(|error| error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restart_backoff_is_bounded() {
        assert_eq!(backoff(0), None);
        assert_eq!(backoff(1), Some(Duration::from_secs(1)));
        assert_eq!(backoff(3), Some(Duration::from_secs(30)));
        assert_eq!(backoff(4), None);
    }

    #[test]
    fn closing_job_stops_child() {
        let mut child = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-Command", "Start-Sleep -Seconds 30"])
            .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null())
            .spawn().unwrap();
        let job = ChildJob::attach(&mut child).unwrap();
        assert!(child.try_wait().unwrap().is_none());
        drop(job);
        let deadline = Instant::now() + Duration::from_secs(4);
        while child.try_wait().unwrap().is_none() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(child.try_wait().unwrap().is_some(), "the host survived its job");
    }
}
