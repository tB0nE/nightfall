//! Nightfall Meteor: a companion app for the Sunshine host PC.
//!
//! The Nightfall client probes Meteor's discovery port before streaming,
//! and when Meteor answers, streams through it instead of straight to
//! Sunshine. For now Meteor only forwards the traffic; the goal is to have
//! it compute depth maps on the host GPU and send them alongside the video.

mod config;
mod depth;
mod depth_server;
mod discovery;
mod gpu_post;
#[cfg(target_os = "linux")]
mod icon;
mod mic;
mod nvdec;
mod onnx;
mod ports;
mod postprocess;
mod proxy;
mod replay;
mod status;
mod stream_info;
#[cfg(target_os = "linux")]
mod tray;
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
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let args: Vec<String> = std::env::args().collect();
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
             \x20 --fps <n>               frame rate for --replay (default 60)"
        );
        return;
    }
    let no_tray = flag("--no-tray");
    let dump_dir = value("--dump-video").map(std::path::PathBuf::from);
    let save_every: u64 = value("--save-every").and_then(|n| n.parse().ok()).unwrap_or(60).max(1);
    let save = value("--save-depth").map(|dir| (std::path::PathBuf::from(dir), save_every));

    let config = config::load();
    let depth = (!flag("--no-depth")).then(|| {
        let models_dir = config.models_dir.clone().unwrap_or_else(config::default_models_dir);
        let tensorrt = config.tensorrt && !flag("--no-tensorrt");
        let depth = Depth::start(config.onnxruntime_lib.as_deref(), tensorrt, models_dir, save);
        depth.gpu_frames.store(!flag("--cpu-frames"), std::sync::atomic::Ordering::Relaxed);
        depth.gpu_post.store(!flag("--cpu-post"), std::sync::atomic::Ordering::Relaxed);
        depth
    });
    if let Some(file) = value("--replay") {
        let fps = value("--fps").and_then(|n| n.parse().ok()).unwrap_or(60);
        let Some(depth) = depth else {
            log::error!("--replay needs host depth");
            std::process::exit(2);
        };
        // Lets a local test client read the replayed maps.
        depth_server::start(depth_server::DEFAULT_DEPTH_PORT, depth.clone(), Arc::new(|_| false));
        let result = tokio::task::spawn_blocking(move || replay::run(std::path::Path::new(&file), fps, depth)).await;
        if let Ok(Err(err)) = result {
            log::error!("{err}");
            std::process::exit(1);
        }
        return;
    }
    let sunshine_base = config
        .sunshine_port
        .unwrap_or_else(|| config::detect_sunshine_port(&config.sunshine_host));
    let map = match PortMap::new(sunshine_base, config.port_offset) {
        Ok(map) => map,
        Err(err) => {
            log::error!("Bad port settings in {}: {err}", config::config_path().display());
            std::process::exit(2);
        }
    };
    log::info!(
        "Nightfall Meteor {} proxying Sunshine at {}:{} (settings: {})",
        env!("CARGO_PKG_VERSION"),
        config.sunshine_host,
        sunshine_base,
        config::config_path().display()
    );

    // The discovery port doubles as a single-instance lock.
    let discovery = match discovery::bind(config.discovery_port).await {
        Ok(listener) => listener,
        Err(err) => {
            log::error!("Can't listen on discovery port {} ({err}); is Meteor already running?", config.discovery_port);
            std::process::exit(1);
        }
    };
    log::info!("discovery TCP :{} (GET /meteor)", config.discovery_port);

    let stats = Arc::new(Stats::default());
    let proxy = Proxy::new(map.clone(), config.sunshine_host.clone(), stats.clone(), dump_dir, depth.clone());
    if let Err(err) = proxy.start().await {
        log::error!("Can't open the proxy ports: {err}");
        std::process::exit(1);
    }
    let mic = if flag("--no-mic") {
        None
    } else {
        let streaming = stats.clone();
        Mic::start(mic::DEFAULT_MIC_PORT, Arc::new(move |ip| streaming.is_streaming(ip))).await
    };
    if let Some(mic) = &mic {
        let _ = MIC.set(mic.clone());
    }
    let depth_port = depth.clone().and_then(|depth| {
        let streaming = stats.clone();
        depth_server::start(depth_server::DEFAULT_DEPTH_PORT, depth.clone(), Arc::new(move |ip| streaming.is_streaming(ip)))
            .map(|port| (port, depth))
    });
    let features = discovery::Features { mic_port: mic.as_ref().map(|m| m.port), depth: depth_port };
    tokio::spawn(discovery::serve(discovery, map.clone(), features));

    let status = Arc::new(Status {
        map,
        sunshine_host: config.sunshine_host.clone(),
        discovery_port: config.discovery_port,
        sunshine_up: AtomicBool::new(false),
    });
    tokio::spawn(status::watch_sunshine(status.clone()));

    #[cfg(target_os = "linux")]
    if !no_tray {
        tray::run(tray::MeteorTray { status, stats, depth, mic }).await;
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (no_tray, status, stats, depth, mic);
        log::info!("No tray icon on this platform yet; press Ctrl+C to stop");
    }

    wait_for_exit_signal().await;
    quit();
}

static MIC: OnceLock<Arc<Mic>> = OnceLock::new();

/// Removes the virtual microphone, then exits.
pub fn quit() -> ! {
    log::info!("Shutting down");
    if let Some(mic) = MIC.get() {
        mic.shutdown();
    }
    std::process::exit(0);
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
             # The port Nightfall probes to find Meteor. The client expects {}.\n\
             # discovery_port = {}\n\n\
             # ONNX Runtime with the CUDA provider, for host depth.\n\
             # onnxruntime_lib = \"/path/to/libonnxruntime.so\"\n\n\
             # Folder of depth models (.onnx) for the tray's Model menu.\n\
             # models_dir = \"{}\"\n\n\
             # Run the depth model with TensorRT fp16 (built once, then cached).\n\
             # tensorrt = true\n",
            config::DEFAULT_SUNSHINE_PORT,
            config::DEFAULT_PORT_OFFSET,
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
