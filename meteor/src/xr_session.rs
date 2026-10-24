//! Development supervisor over the validated USB runtime adapter. Not LAN XR.
use serde_json::{Value, json};
use std::os::fd::AsRawFd;
use std::{
    fs::{self, File},
    io,
    os::unix::{
        fs::{DirBuilderExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant, SystemTime},
};

pub(crate) fn valid_eye_size(size: u32) -> bool {
    (256..=4096).contains(&size) && size % 16 == 0
}

pub(crate) fn session_application(root:&Path, source:&Path, output:&Path, intent:Option<&str>) -> io::Result<PathBuf> {
    if fs::metadata(source)?.len()>16384 {return Err(io::Error::other("XR application configuration exceeds 16 KiB"))}
    let mut spec:Value=serde_json::from_slice(&fs::read(source)?)?;
    if spec["launch"]=="steam" && spec["steam_app_id"]=="*" {
        let generation=intent.ok_or_else(||io::Error::other("Steam application selection requires a local launch intent"))?;
        spec["steam_app_id"]=crate::xr_launch_intent::claimed_app_id(root,generation)?.into();
    }
    // Freeze the selected app for this session. Later launches cannot retarget it.
    let path=output.join("application.json");
    fs::write(&path,serde_json::to_vec(&spec)?)?;
    fs::set_permissions(&path,fs::Permissions::from_mode(0o600))?;
    Ok(path)
}

struct SessionLock(File);
impl SessionLock {
    fn acquire(path: &Path) -> io::Result<Self> {
        let file = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        // Advisory lock lifetime follows this descriptor, including crashes.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::other("another managed XR session is active"));
        }
        Ok(Self(file))
    }
}
impl Drop for SessionLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

struct OwnedProcess(Child);
impl OwnedProcess {
    fn signal(&self, signal: i32) {
        // Only the new child process group, never a named/global process.
        unsafe {
            libc::kill(-(self.0.id() as i32), signal);
        }
    }
}
impl Drop for OwnedProcess {
    fn drop(&mut self) {
        self.signal(libc::SIGTERM);
        std::thread::sleep(Duration::from_millis(150));
        self.signal(libc::SIGKILL);
        let _ = self.0.wait();
    }
}

fn lan_session_directory(cache: &Path) -> io::Result<PathBuf> {
    let sessions = cache.join("lan-sessions");
    fs::create_dir_all(&sessions)?;
    fs::set_permissions(&sessions, fs::Permissions::from_mode(0o700))?;
    let stamp = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_nanos();
    let directory = sessions.join(format!("{stamp}-{}", std::process::id()));
    fs::DirBuilder::new().mode(0o700).create(&directory)?;
    Ok(directory)
}

#[cfg(test)]
pub(crate) async fn runtime_adapter(
    root: PathBuf,
    video: u16,
    tracking: u16,
    hz: u32,
    eye_size: u32,
    long_run: bool,
    cancel: tokio::sync::watch::Receiver<bool>,
) -> io::Result<()> {
    runtime_adapter_with_status(root, video, tracking, hz, eye_size, eye_size, long_run, 0, "h264".into(), false, None, cancel, None, None).await
}

pub(crate) async fn runtime_adapter_with_status(
    root: PathBuf,
    video: u16,
    tracking: u16,
    hz: u32,
    eye_size: u32,
    eye_height:u32,
    long_run: bool,
    bitrate_mbps: u32,
    codec: String,
    foveated_encoding:bool,
    launch_intent: Option<String>,
    mut cancel: tokio::sync::watch::Receiver<bool>,
    progress: Option<&crate::xr_relay::RuntimeProgress>,
    bitrate_directory: Option<&crate::xr_bitrate::RuntimeDirectory>,
) -> io::Result<()> {
    if !matches!(hz, 20 | 60 | 72) || !valid_eye_size(eye_size) || !valid_eye_size(eye_height) || (long_run && !matches!(hz,60 | 72))
        || (bitrate_mbps != 0 && !(8..=160).contains(&bitrate_mbps)) || !matches!(codec.as_str(),"h264" | "h265") {
        return Err(io::Error::other("unsupported managed XR profile"));
    }
    let cache = root.join(".build-cache/meteor-xr");
    if let Some(generation)=launch_intent.as_ref() {
        if generation.len()!=32 || !generation.bytes().all(|c|c.is_ascii_hexdigit()) {return Err(io::Error::other("invalid launch intent"))}
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    let _lock = loop {
        if *cancel.borrow() {
            return Ok(());
        }
        match SessionLock::acquire(&cache.join("managed-session.lock")) {
            Ok(lock) => break lock,
            Err(error) if Instant::now() >= deadline => return Err(error),
            Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
        }
    };
    let output = lan_session_directory(&cache)?;
    if let Some(directory)=bitrate_directory { *directory.lock().unwrap()=Some(output.clone()); }
    println!("Meteor XR session diagnostics: {}", output.display());
    let log = File::create(output.join("runtime.log"))?;
    let mut generation = [0u8; 16];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut generation)
        .map_err(|_| io::Error::other("XR runtime generation randomness unavailable"))?;
    let generation: String = generation.iter().map(|byte| format!("{byte:02x}")).collect();
    let mut events = crate::xr_events::Observer::new(generation.clone());
    if let Some(progress) = progress { *progress.lock().unwrap() = events.runtime_status(); }
    let mut command = Command::new("bash");
    command.arg(root.join("tools/build_support/probe_monado_nvenc.sh"));
    for (key, _) in std::env::vars_os() {
        let name = key.to_string_lossy();
        if name.starts_with("NIGHTFALL_XR_") || name.starts_with("METEOR_XR_") {
            command.env_remove(key);
        }
    }
    for (key, value) in [
        ("NIGHTFALL_XR_GODOT_ENGINE", "1"),
        ("NIGHTFALL_XR_UPSTREAM_DEMO", "1"),
        ("METEOR_XR_TRACKED_SCENE", "1"),
        ("NIGHTFALL_XR_CONTROLLERS", "1"),
        ("NIGHTFALL_XR_CONTROLLER_PROFILE", "touch"),
        ("NIGHTFALL_XR_TOUCH_INPUTS", "1"),
        ("NIGHTFALL_XR_HEADSET_OPTICS", "1"),
        ("NIGHTFALL_XR_ASYNC_ENCODE", "1"),
        ("NIGHTFALL_XR_ASYNC_DELIVERY", "1"),
        ("NIGHTFALL_XR_FREE_RUNNING", "1"),
    ] {
        command.env(key, value);
    }
    // Explicit host-local DEV override only. Never take an executable or args
    // from the headset/control protocol. Missing means the validated demo.
    let application = cache.join("application.json");
    if let Some(generation)=launch_intent.as_ref() {command.env("NIGHTFALL_XR_LAUNCH_INTENT",generation);}
    if application.exists() {
        let application=session_application(&root,&application,&output,launch_intent.as_deref())?;
        command.env("NIGHTFALL_XR_APPLICATION_SPEC", application);
    }
    command
        .env("NIGHTFALL_XR_RUNTIME_GENERATION", &generation)
        .env("NIGHTFALL_XR_MONITOR_LEGACY", if std::env::var("NIGHTFALL_XR_MONITOR_LEGACY").as_deref() == Ok("1") { "1" } else { "0" })
        .env("NIGHTFALL_XR_TARGET_HZ", hz.to_string())
        .env("NIGHTFALL_XR_EYE_SIZE", eye_size.to_string())
        .env("NIGHTFALL_XR_EYE_HEIGHT", eye_height.to_string())
        .env("NIGHTFALL_XR_FOVEATED_ENCODING", if foveated_encoding {"1"} else {"0"})
        .env("NIGHTFALL_XR_BITRATE_MBPS", bitrate_mbps.to_string())
        .env("NIGHTFALL_XR_CODEC", &codec)
        .env("NIGHTFALL_XR_PROBE_FRAMES", if long_run { (hz*300).to_string() } else if hz >= 60 { (hz*20).to_string() } else { "200".into() })
        .env("NIGHTFALL_XR_PROBE_OUTPUT", &output)
        .env("NIGHTFALL_XR_DEVICE_PORT", video.to_string())
        .env("NIGHTFALL_XR_TRACKING_PORT", tracking.to_string())
        .env(
            "NIGHTFALL_GODOT_EDITOR",
            cache.join("godot-engine-cleanup/bin/godot.linuxbsd.editor.x86_64"),
        )
        .current_dir(&root)
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log))
        .process_group(0);
    let mut child = OwnedProcess(command.spawn()?);
    let deadline = Instant::now() + Duration::from_secs(if long_run {315} else {45});
    loop {
        if let Some(progress) = progress {
            let mut status = events.runtime_status();
            if status.event_sequence == 0 && fs::read(output.join("application-ready.json")).ok()
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                .is_some_and(|value| value["generation"] == generation && value["state"] == "ready") {
                status.phase = crate::xr_relay::RuntimePhase::ReadyForApplication;
            }
            *progress.lock().unwrap() = status;
        }
        if events.poll(&output.join("service.log"))? != 0 {
            if let Some(progress) = progress { *progress.lock().unwrap() = events.runtime_status(); }
            fs::write(output.join("runtime-session-events.json"), events.snapshot().to_string())?;
        }
        if let Some(status) = child.0.try_wait()? {
            events.finish(&output.join("service.log"))?;
            if let Some(progress) = progress { *progress.lock().unwrap() = events.runtime_status(); }
            fs::write(output.join("runtime-session-events.json"), events.snapshot().to_string())?;
            if status.success() && !events.saw_begin {
                return Err(io::Error::other("No runtime session-begin event; rebuild the managed Monado runtime"));
            }
            return if status.success() {
                Ok(())
            } else {
                Err(io::Error::other(format!(
                    "XR runtime adapter exited {status}; see {}",
                    output.join("runtime.log").display()
                )))
            };
        }
        if *cancel.borrow() || Instant::now() >= deadline {
            let timed_out = !*cancel.borrow();
            if let Some(progress) = progress { progress.lock().unwrap().phase = crate::xr_relay::RuntimePhase::Stopping; }
            let artifacts = &output;
            fs::write(
                artifacts.join("client-disconnected"),
                "LAN session cancelled\n",
            )?;
            fs::write(
                artifacts.join("engine-request-exit"),
                "LAN session cancelled\n",
            )?;
            let mut until = Instant::now() + Duration::from_secs(4);
            let mut validation_grace = false;
            while child.0.try_wait()?.is_none() {
                // Only post-run validation may extend cancellation grace: the
                // adapter writes this marker AFTER its app/service are reaped.
                if !validation_grace && output.join("postrun-validation").exists() {
                    until = Instant::now() + Duration::from_secs(20);
                    validation_grace = true;
                }
                if Instant::now() >= until { break; }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            events.finish(&output.join("service.log"))?;
            fs::write(output.join("runtime-session-events.json"), events.snapshot().to_string())?;
            return if timed_out { Err(io::Error::new(io::ErrorKind::TimedOut, "XR runtime exceeded session deadline")) } else { Ok(()) };
        }
        tokio::select! {_=cancel.changed()=>{},_=tokio::time::sleep(Duration::from_millis(50))=>{}}
    }
}

fn fresh_json(path: &Path, start: SystemTime) -> Option<Value> {
    if path.metadata().ok()?.modified().ok()? < start {
        return None;
    }
    serde_json::from_slice(&fs::read(path).ok()?).ok()
}

fn state(directory: &Path, name: &str, detail: &str) -> io::Result<()> {
    println!("Meteor XR [{name}]: {detail}");
    let temporary = directory.join("status.tmp");
    fs::write(
        &temporary,
        json!({"state":name,"detail":detail,"transport":"usb-dev",
        "production_ready":false})
        .to_string(),
    )?;
    fs::rename(temporary, directory.join("status.json"))
}

pub async fn run(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.is_empty() || args.len() > 2 || (args.len() == 2 && args[1] != "--smoke") {
        return Err("usage: nightfall-meteor --xr-dev <checkout> [--smoke]".into());
    }
    let smoke = args.len() == 2;
    let root = PathBuf::from(&args[0]).canonicalize()?;
    let cache = root.join(".build-cache/meteor-xr");
    let engine = cache.join("godot-engine-cleanup/bin/godot.linuxbsd.editor.x86_64");
    for path in [
        root.join("tools/build_support/probe_headset_xr_tracking_runtime.sh"),
        root.join("test/run_monado_tracking_spike.py"),
        engine.clone(),
        cache.join("monado-linux-spike/capture-build/src/xrt/targets/service/monado-service"),
        cache.join("godot-demo-projects/xr/openxr_origin_centric_movement/project.godot"),
    ] {
        if !path.is_file() {
            return Err(format!(
                "missing prerequisite: {}; see XR engine setup instructions",
                path.display()
            )
            .into());
        }
    }
    let _lock = SessionLock::acquire(&cache.join("managed-session.lock"))?;
    let output = cache.join("managed-session");
    fs::create_dir_all(&output)?;
    fs::set_permissions(&output, fs::Permissions::from_mode(0o700))?;
    let log = File::create(output.join("session.log"))?;
    let mut command = if smoke {
        let mut cmd = Command::new(root.join(".build-cache/model-tester-venv/bin/python"));
        cmd.arg(root.join("test/run_monado_tracking_spike.py"))
            .arg(&root);
        cmd
    } else {
        let mut cmd = Command::new("bash");
        cmd.arg(root.join("tools/build_support/probe_headset_xr_tracking_runtime.sh"));
        cmd
    };
    for (key, _) in std::env::vars_os() {
        let name = key.to_string_lossy();
        if name.starts_with("NIGHTFALL_XR_") || name.starts_with("METEOR_XR_") {
            command.env_remove(key);
        }
    }
    for (key, value) in [
        ("NIGHTFALL_XR_GODOT_ENGINE", "1"),
        ("NIGHTFALL_XR_UPSTREAM_DEMO", "1"),
        ("NIGHTFALL_XR_CONTROLLERS", "1"),
        ("NIGHTFALL_XR_CONTROLLER_PROFILE", "touch"),
        ("NIGHTFALL_XR_TOUCH_INPUTS", "1"),
        ("NIGHTFALL_XR_HEADSET_OPTICS", "1"),
        ("NIGHTFALL_XR_EYE_SIZE", "512"),
        ("NIGHTFALL_XR_TARGET_HZ", "20"),
        (
            "NIGHTFALL_XR_PROBE_FRAMES",
            if smoke { "120" } else { "200" },
        ),
        ("NIGHTFALL_XR_ASYNC_ENCODE", "1"),
        ("NIGHTFALL_XR_ASYNC_DELIVERY", "1"),
        ("NIGHTFALL_XR_FREE_RUNNING", "1"),
    ] {
        command.env(key, value);
    }
    command
        .env("NIGHTFALL_GODOT_EDITOR", engine)
        .current_dir(&root)
        .stdout(Stdio::from(log.try_clone()?))
        .stderr(Stdio::from(log))
        .process_group(0);
    state(
        &output,
        "starting",
        "isolated runtime adapter; no global XR changes",
    )?;
    let started = SystemTime::now();
    let mut child = OwnedProcess(command.spawn()?);
    let deadline = Instant::now() + Duration::from_secs(100);
    let artifacts = cache.join("monado-nvenc-spike");
    state(
        &output,
        "waiting",
        if smoke {
            "running synthetic host checks"
        } else {
            "tap DEV: Meteor decoded stereo on Nightfall"
        },
    )?;
    let mut streaming = false;
    let stop = async {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        tokio::select! {
            result=tokio::signal::ctrl_c() => result,
            _=terminate.recv() => Ok::<(),io::Error>(()),
        }
    };
    tokio::pin!(stop);
    loop {
        if let Some(exit) = child.0.try_wait()? {
            let interrupted = fresh_json(&artifacts.join("lifecycle-outcome.json"), started)
                .is_some_and(|v| v["outcome"] == "interrupted");
            if exit.success() && interrupted {
                state(
                    &output,
                    "interrupted",
                    "headset exited/disconnected; not a full completion pass",
                )?;
                return Ok(());
            }
            let proof = fresh_json(&artifacts.join("engine-outcome.json"), started);
            if exit.success()
                && proof.is_some_and(|v| {
                    v["engine_shutdown_clean"] == true
                        && v["encoder_drain_verified"] == true
                        && v["application_revision"].is_string()
                })
            {
                state(
                    &output,
                    "completed",
                    "application, decode, ownership and shutdown validated",
                )?;
                return Ok(());
            }
            state(
                &output,
                "failed",
                "adapter failed or validation incomplete; see session.log",
            )?;
            return Err(format!("session failed ({exit}); logs: {}", output.display()).into());
        }
        if !streaming
            && artifacts
                .join("monado-stereo.jsonl")
                .metadata()
                .ok()
                .is_some_and(|m| {
                    m.len() > 0 && m.modified().ok().is_some_and(|time| time >= started)
                })
        {
            streaming = true;
            state(
                &output,
                "streaming",
                "application frames are being encoded; headset display still needs confirmation",
            )?;
        }
        tokio::select! {
            result=&mut stop => {
                result?;
                state(&output,"stopping","requesting application shutdown")?;
                fs::write(artifacts.join("client-disconnected"),"managed session stop\n")?;
                fs::write(artifacts.join("engine-request-exit"),"managed session stop\n")?;
                let until=Instant::now()+Duration::from_secs(4);
                while child.0.try_wait()?.is_none() && Instant::now()<until {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                state(&output,"cancelled","operator stopped session; not a completed validation pass")?;
                return Ok(());
            }
            _=tokio::time::sleep(Duration::from_millis(100)) => {}
        }
        if Instant::now() >= deadline {
            state(
                &output,
                "failed",
                "session exceeded bounded development timeout",
            )?;
            return Err("XR session timed out; owned child group will be stopped".into());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn runtime_task_drain_reaps_owned_child_before_return() {
        let child = Command::new("sleep").arg("30").process_group(0).spawn().unwrap();
        let pid = child.id() as i32;
        let owned = OwnedProcess(child);
        let tasks = crate::xr_relay::RuntimeTasks::default();
        let (stop, mut cancel) = tokio::sync::watch::channel(false);
        tasks.track(tokio::spawn(async move {
            let _owned = owned;
            let _ = cancel.changed().await;
        }));
        stop.send_replace(true);
        tasks.drain().await.unwrap();
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    }
    #[tokio::test]
    async fn long_runtime_rejects_unsupported_rate_before_launch() {
        let (_send,receive)=tokio::sync::watch::channel(false);
        assert!(runtime_adapter(PathBuf::from("/unused"),1,2,20,1024,true,receive).await.is_err());
    }
    #[test]
    fn lan_retries_keep_separate_private_artifacts() {
        let cache = std::env::temp_dir().join(format!("meteor-lan-logs-{}", std::process::id()));
        let first = lan_session_directory(&cache).unwrap();
        fs::write(first.join("runtime.log"), "first failure").unwrap();
        let second = lan_session_directory(&cache).unwrap();
        assert_ne!(first, second);
        assert_eq!(
            fs::read_to_string(first.join("runtime.log")).unwrap(),
            "first failure"
        );
        assert_eq!(
            first.metadata().unwrap().permissions().mode() & 0o777,
            0o700
        );
        fs::remove_dir_all(cache).unwrap();
    }
    #[test]
    fn stale_or_invalid_proof_is_not_completion() {
        let path = std::env::temp_dir().join(format!("meteor-proof-{}", std::process::id()));
        fs::write(&path, "{}").unwrap();
        assert!(fresh_json(&path, SystemTime::now() + Duration::from_secs(1)).is_none());
        fs::write(&path, "broken").unwrap();
        assert!(fresh_json(&path, SystemTime::UNIX_EPOCH).is_none());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn session_lock_is_exclusive_and_released() {
        let path = std::env::temp_dir().join(format!("meteor-lock-{}", std::process::id()));
        let first = SessionLock::acquire(&path).unwrap();
        assert!(SessionLock::acquire(&path).is_err());
        drop(first);
        drop(SessionLock::acquire(&path).unwrap());
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn owned_process_cleanup_reaps_child() {
        let child = Command::new("sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();
        let pid = child.id() as i32;
        drop(OwnedProcess(child));
        assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    }
}
