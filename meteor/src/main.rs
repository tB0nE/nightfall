//! Nightfall Meteor: a companion app for the Sunshine host PC.
//!
//! The Nightfall client probes Meteor's discovery port before streaming,
//! and when Meteor answers, streams through it instead of straight to
//! Sunshine. For now Meteor only forwards the traffic; the goal is to have
//! it compute depth maps on the host GPU and send them alongside the video.

mod config;
mod crypto;
mod depth;
mod depth_server;
#[cfg(target_os = "linux")]
mod desktop;
#[cfg(windows)]
mod desktop_windows;
mod discovery;
mod download;
mod firewall;
mod gpu_post;
mod gpu_refinement;
#[cfg(target_os = "linux")]
mod host;
#[cfg(target_os = "linux")]
use host::view as host_view;
mod icon;
mod logfile;
mod mic;
mod net;
mod ncnn;
mod nvdec;
mod onnx;
mod ports;
mod postprocess;
mod proxy;
mod replay;
mod refinement;
mod status;
mod stream_info;
mod tensorrt;
#[cfg(target_os = "linux")]
mod tray;
#[cfg(windows)]
mod tray_windows;
mod vda;
mod video_dump;
mod video_tap;

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, OnceLock};

use crate::depth::Depth;
use crate::mic::Mic;
use crate::ports::PortMap;
use crate::proxy::{Proxy, Stats};
use crate::status::Status;

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    logfile::init(args.get(1).map(String::as_str) != Some("--build-tensorrt"));
    // A TensorRT engine build, run by Meteor in a child process.
    if args.get(1).map(String::as_str) == Some("--build-tensorrt") {
        std::process::exit(tensorrt::build_command(&args[2..], config::load().tensorrt_dir));
    }
    let flag = |name: &str| args.iter().any(|arg| arg == name);
    let value = |name: &str| {
        args.iter().position(|arg| arg == name).map(|i| match args.get(i + 1) {
            Some(value) => value.clone(),
            None => {
                log::error!("{name} needs a value");
                std::process::exit(2);
            }
        })
    };
    if flag("--help") || flag("-h") {
        println!(
            "nightfall-meteor [options]\n\
             \x20 --no-tray               run without a tray icon\n\
             \x20 --no-depth              don't load the depth model (proxy only)\n\
             \x20 --no-mic                don't create the Nightfall Microphone device\n\
             \x20 --cpu-frames            convert decoded frames on the CPU (for comparison)\n\
             \x20 --no-tensorrt           run the model with CUDA only\n\
             \x20 --cpu-post              post-process depth on the CPU (for comparison)\n\
             \x20 --dump-video <dir>      write the tapped video to <dir>\n\
             \x20 --save-depth <dir>      save every Nth frame and depth map as PNGs\n\
             \x20 --save-every <n>        N for --save-depth (default 60)\n\
             \x20 --replay <file>         run a .h264/.hevc file through host depth and exit\n\
             \x20 --fps <n>               frame rate for --replay (default 60)\n\
             \x20 --quit-after <seconds>  quit during --replay (tests shutdown)\n\
             \x20 --download-vda          download TensorRT (from NVIDIA, under NVIDIA's licence)\n\
             \x20                         and the VDA graphs, then exit"
        );
        return;
    }
    let no_tray = flag("--no-tray");
    let dump_dir = value("--dump-video").map(std::path::PathBuf::from);
    let save_every: u64 = value("--save-every").and_then(|n| n.parse().ok()).unwrap_or(60).max(1);
    let save = value("--save-depth").map(|dir| (std::path::PathBuf::from(dir), save_every));

    let config = config::load();
    if flag("--download-vda") {
        let models_dir = config.models_dir.clone().unwrap_or_else(config::default_models_dir);
        std::process::exit(download::command(&models_dir));
    }
    // Not for a replay: Sunshine's ports, and the discovery port, which
    // doubles as a single-instance lock. It's taken before the models start
    // loading, so a second launch exits straight away.
    let replay_file = value("--replay");
    #[cfg(target_os = "linux")]
    let mut host_view = host_view::View::default();
    let startup = if replay_file.is_some() {
        None
    } else {
        #[cfg(target_os = "linux")]
        let bundled_base = host_view.prepare(&config);
        #[cfg(not(target_os = "linux"))]
        let bundled_base: Option<u16> = None;
        let sunshine_base = config
            .sunshine_port
            .or(bundled_base)
            .unwrap_or_else(|| config::detect_sunshine_port(&config.sunshine_host));
        let side = config.side_ports(sunshine_base);
        let map = match PortMap::new(sunshine_base, config.port_offset) {
            Ok(map) => map,
            Err(err) => {
                log::error!("Bad port settings in {}: {err}", config::config_path().display());
                exit_now(2);
            }
        };
        log::info!(
            "Nightfall Meteor {} proxying Sunshine at {}:{} (settings: {})",
            env!("CARGO_PKG_VERSION"),
            config.sunshine_host,
            sunshine_base,
            config::config_path().display()
        );
        // After a restart from the tray, the old process may still hold it
        // for a moment.
        let mut discovery = discovery::bind(side.discovery).await;
        if std::env::var_os(RESTART_ENV).is_some() {
            for _ in 0..50 {
                if discovery.is_ok() {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                discovery = discovery::bind(side.discovery).await;
            }
        }
        let discovery = match discovery {
            Ok(listener) => listener,
            Err(err) => {
                log::error!("Can't listen on discovery port {} ({err}); is Meteor already running?", side.discovery);
                #[cfg(target_os = "linux")]
                desktop::notify(
                    "Nightfall Meteor is already running",
                    &format!("Look for it in the tray. (Port {} is in use.)", side.discovery),
                )
                .await;
                exit_now(1);
            }
        };
        log::info!("discovery TCP :{} (GET /meteor)", side.discovery);
        log::info!("Log: {}", logfile::path().display());
        // Only now: the discovery port is the single-instance lock, so a
        // second launch never starts a second host.
        #[cfg(target_os = "linux")]
        host_view.start();
        Some((map, discovery, side))
    };
    let depth = (!flag("--no-depth")).then(|| {
        let models_dir = config.models_dir.clone().unwrap_or_else(config::default_models_dir);
        let tensorrt = config.tensorrt && !flag("--no-tensorrt");
        tensorrt::configure(config.tensorrt_dir.clone());
        let runtimes = depth::Runtimes { onnxruntime: config.onnxruntime_lib.as_deref(), ncnn: config.ncnn_lib.as_deref() };
        let depth = Depth::start(runtimes, tensorrt, models_dir, save);
        depth.gpu_frames.store(!flag("--cpu-frames"), std::sync::atomic::Ordering::Relaxed);
        depth.gpu_post.store(!flag("--cpu-post"), std::sync::atomic::Ordering::Relaxed);
        depth
    });
    let Some((map, discovery, side)) = startup else {
        let file = replay_file.unwrap_or_default();
        let fps = value("--fps").and_then(|n| n.parse().ok()).unwrap_or(60);
        let Some(depth) = depth else {
            log::error!("--replay needs host depth");
            exit_now(2);
        };
        // Quits through the normal path mid-replay, to test shutdown while
        // the depth threads are busy (see exit_now).
        if let Some(secs) = value("--quit-after").and_then(|s| s.parse::<f64>().ok()) {
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_secs_f64(secs));
                quit();
            });
        }
        // Lets a local test client read the replayed maps.
        match crypto::MeteorKey::load_or_create(&config::data_dir().join("meteor.key")) {
            Ok(key) => {
                let side = config.side_ports(config::DEFAULT_SUNSHINE_PORT);
                depth_server::start(side.depth, depth.clone(), Arc::new(key), Arc::new(|_| false));
            }
            Err(err) => log::warn!("No key, so no depth port: {err}"),
        }
        let result = tokio::task::spawn_blocking(move || replay::run(std::path::Path::new(&file), fps, depth)).await;
        if let Ok(Err(err)) = result {
            log::error!("{err}");
            exit_now(1);
        }
        exit_now(0);
    };
    #[cfg(target_os = "linux")]
    desktop::update_autostart();

    let stats = Arc::new(Stats::default());
    let proxy = Proxy::new(map.clone(), config.sunshine_host.clone(), stats.clone(), dump_dir, depth.clone());
    if let Err(err) = proxy.start().await {
        log::error!("Can't open the proxy ports: {err}");
        exit_now(1);
    }
    // The side channels are encrypted for this key (crypto.rs); without it
    // Meteor still proxies, but offers neither.
    let key = match crypto::MeteorKey::load_or_create(&config::data_dir().join("meteor.key")) {
        Ok(key) => Some(Arc::new(key)),
        Err(err) => {
            log::warn!("No key, so no host depth or microphone: {err}");
            None
        }
    };
    let mic = match &key {
        Some(key) if !flag("--no-mic") => {
            let streaming = stats.clone();
            Mic::start(side.mic, key.clone(), Arc::new(move |ip| streaming.is_streaming(ip))).await
        }
        _ => None,
    };
    if let Some(mic) = &mic {
        let _ = MIC.set(mic.clone());
    }
    let depth_port = depth.clone().zip(key.clone()).and_then(|(depth, key)| {
        let streaming = stats.clone();
        depth_server::start(side.depth, depth.clone(), key, Arc::new(move |ip| streaming.is_streaming(ip)))
            .map(|port| (port, depth))
    });
    let features = discovery::Features {
        key: key.as_ref().map(|k| k.public_hex()),
        mic_port: mic.as_ref().map(|m| m.port),
        depth: depth_port,
        #[cfg(target_os = "linux")]
        host: host_view.discovery_info(),
        #[cfg(not(target_os = "linux"))]
        host: None,
    };
    tokio::spawn(discovery::serve(discovery, map.clone(), features));

    let status = Arc::new(Status {
        map,
        sunshine_host: config.sunshine_host.clone(),
        side,
        #[cfg(target_os = "linux")]
        host_ports: host_view.supervisor.is_some(),
        #[cfg(not(target_os = "linux"))]
        host_ports: false,
        sunshine_up: AtomicBool::new(false),
        firewall: std::sync::Mutex::new(firewall::Status::Checking),
    });
    tokio::spawn(status::watch_sunshine(status.clone()));
    status.check_firewall();

    #[cfg(target_os = "linux")]
    if !no_tray && !tray::run(tray::MeteorTray { status, stats, depth, mic, host: Arc::new(host_view) }).await {
        desktop::notify(
            "Nightfall Meteor is running",
            "There's no tray to show its controls in. On GNOME, the AppIndicator extension adds one.",
        )
        .await;
    }
    #[cfg(not(target_os = "linux"))]
    {
        #[cfg(windows)]
        if !no_tray {
            tray_windows::run(status.clone(), stats.clone(), mic.clone(), depth.clone());
        }
        let _ = (status, stats, depth, mic);
        if no_tray {
            log::info!("No tray icon requested; press Ctrl+C to stop");
        }
    }

    wait_for_exit_signal().await;
    quit();
}

static MIC: OnceLock<Arc<Mic>> = OnceLock::new();

/// Set on the process `restart` starts, so it waits for the old one's
/// discovery port.
const RESTART_ENV: &str = "METEOR_RESTARTED";

/// Removes the virtual microphone and stops the bundled host, then exits.
pub fn quit() -> ! {
    log::info!("Shutting down");
    if let Some(mic) = MIC.get() {
        mic.shutdown();
    }
    #[cfg(target_os = "linux")]
    if let Some(host) = host_view::RUNNING.get() {
        host.shutdown();
    }
    exit_now(0);
}

/// Starts Meteor again with the same arguments (after the host choice
/// changes, which moves the ports), then quits this one.
#[cfg(target_os = "linux")]
pub fn restart() -> ! {
    let Some(exe) = desktop::launcher() else {
        log::error!("Can't tell where Meteor is; quit and start it again");
        quit();
    };
    log::info!("Restarting Meteor");
    #[cfg(target_os = "linux")]
    if let Some(host) = host_view::RUNNING.get() {
        host.shutdown();
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(err) = std::process::Command::new(&exe).args(args).env(RESTART_ENV, "1").spawn() {
        log::error!("Can't start {}: {err}", exe.display());
    }
    quit();
}

/// Exits without running the libraries' exit handlers. TensorRT, ONNX
/// Runtime and the CUDA libraries free their global state in those, while
/// the depth threads may still be using it (an engine build, a model
/// load, a frame), which crashed Meteor on exit: SIGSEGV in libnvinfer
/// (reproduced 2026-10-07 by quitting during an ONNX Runtime TensorRT
/// build). The system frees the process's memory and GPU state anyway.
pub fn exit_now(code: i32) -> ! {
    log::logger().flush();
    #[cfg(unix)]
    // SAFETY: _exit ends the process at once; nothing runs after it.
    unsafe {
        libc::_exit(code)
    }
    #[cfg(not(unix))]
    {
        #[cfg(windows)]
        unsafe {
            windows_sys::Win32::System::Threading::TerminateProcess(
                windows_sys::Win32::System::Threading::GetCurrentProcess(), code as u32,
            );
        }
        std::process::exit(code)
    }
}

async fn wait_for_exit_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};
        match signal(SignalKind::terminate()) {
            Ok(mut term) => {
                tokio::select! {
                    _ = tokio::signal::ctrl_c() => {}
                    _ = term.recv() => {}
                }
            }
            Err(_) => drop(tokio::signal::ctrl_c().await),
        }
    }
    #[cfg(not(unix))]
    drop(tokio::signal::ctrl_c().await);
}

/// Opens meteor.toml in the default editor, creating it with the defaults
/// written out (commented) the first time.
pub fn open_config_file() {
    let path = config::config_path();
    if !path.exists() {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let template = format!(
            "# Nightfall Meteor settings. Restart Meteor after editing.\n\n\
             # Where Sunshine is reachable from this PC.\n\
             # sunshine_host = \"127.0.0.1\"\n\n\
             # Sunshine's base port (\"port\" in sunshine.conf). Detected when unset.\n\
             # sunshine_port = {}\n\n\
             # Meteor listens on each Sunshine port plus this offset.\n\
             # port_offset = {}\n\n\
             # The port Nightfall probes to find Meteor; depth and the microphone use\n\
             # the next two. The client expects the host's base port minus {} ({} for\n\
             # the default base), so set this only when the client is told too.\n\
             # discovery_port = {}\n\n\
             # ONNX Runtime with the CUDA provider, for host depth.\n\
             # onnxruntime_lib = \"/path/to/libonnxruntime.so\"\n\n\
             # ncnn, for the EdgePad models on Vulkan.\n\
             # ncnn_lib = \"/path/to/libncnn.so.1\"\n\n\
             # A folder with TensorRT 10's libnvinfer and libnvonnxparser, for VDA.\n\
             # tensorrt_dir = \"/path/to/tensorrt/lib\"\n\n\
             # Folder of depth models (.ncnn.param or .onnx) for the tray's Model menu.\n\
             # models_dir = \"{}\"\n\n\
             # Run the depth model with TensorRT fp16 (built once, then cached).\n\
             # tensorrt = true\n\n\
             # A Vibepollo build to run when the tray's host choice is Vibepollo for\n\
             # Nightfall, instead of the downloaded one (development).\n\
             # host_binary = \"/path/to/vibepollo\"\n\n\
             # Extra environment for that host (a table, so keep it last).\n\
             # [host_env]\n\
             # LD_LIBRARY_PATH = \"/path/to/libs\"\n",
            config::DEFAULT_SUNSHINE_PORT,
            config::DEFAULT_PORT_OFFSET,
            config::DISCOVERY_BELOW_BASE,
            config::DEFAULT_DISCOVERY_PORT,
            config::DEFAULT_DISCOVERY_PORT,
            config::default_models_dir().display(),
        );
        if let Err(err) = std::fs::write(&path, template) {
            log::warn!("Can't create {}: {err}", path.display());
            return;
        }
    }
    let opener = if cfg!(windows) { "explorer" } else { "xdg-open" };
    if let Err(err) = std::process::Command::new(opener).arg(&path).spawn() {
        log::warn!("Can't open {}: {err}", path.display());
    }
}
