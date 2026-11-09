#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]
//! Nightfall Meteor: a companion app for the Sunshine host PC.
//!
//! The Nightfall client probes Meteor's discovery port before streaming,
//! and when Meteor answers, streams through it instead of straight to
//! Sunshine. For now Meteor only forwards the traffic; the goal is to have
//! it compute depth maps on the host GPU and send them alongside the video.

mod config;
#[cfg(target_os = "linux")]
mod host_cursor;
#[cfg(target_os = "linux")]
mod legacy_host_cursor;
mod crypto;
mod depth;
mod depth_server;
#[cfg(target_os = "linux")]
mod desktop;
#[cfg(windows)]
#[path = "desktop_win_shim.rs"]
mod desktop;
#[cfg(target_os = "macos")]
#[path = "desktop_macos.rs"]
mod desktop;
#[cfg(target_os = "linux")]
mod setup_window;
#[cfg(target_os = "linux")]
mod xr_setup;
#[cfg(windows)]
mod desktop_windows;
mod discovery;
mod download;
mod firewall;
mod gpu_post;
mod gpu_refinement;
mod host;
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
mod shutdown;
mod stream_info;
mod tensorrt;
#[cfg(target_os = "linux")]
mod tray;
#[cfg(windows)]
mod tray_windows;
#[cfg(target_os = "macos")]
mod tray_macos;
mod vda;
mod vda_vulkan;
mod vda_assets;
mod vulkan_processing;
mod video_dump;
mod video_tap;
mod video_decoder;
mod xr_control;
mod xr_encoder;
mod xr_trust;
mod xr_library;
mod xr_bitrate;
mod xr_foveation;
mod xr_launch_intent;
mod xr_data;
#[cfg(target_os = "linux")]
mod xr_events;
mod xr_relay;
#[cfg(target_os = "linux")]
mod xr_session;
#[cfg(windows)]
#[path = "xr_session_windows.rs"]
mod xr_session;
mod xr_wire;
#[cfg(windows)]
mod xr_runtime_windows;
#[cfg(windows)]
mod xr_steam_windows;
#[cfg(windows)]
mod xr_steamvr_windows;
#[cfg(windows)]
mod xr_windows;

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
    #[cfg(target_os = "linux")]
    if args.get(1).is_some_and(|arg| arg == "--setup") {
        std::process::exit(setup_window::run());
    }
    #[cfg(windows)]
    if args.len()>1 {desktop_windows::attach_parent_console_if_needed();}
    #[cfg(windows)]
    if args.get(1).is_some_and(|arg|arg=="--host-pair-pin") {
        if args.len()!=2 {eprintln!("Usage: --host-pair-pin (PIN on standard input)");std::process::exit(1);}
        match host::pin::command() {
            Ok(())=>println!("PIN sent. Finish pairing in Nightfall."),
            Err(error)=>{eprintln!("{error}");std::process::exit(1);},
        }
        return;
    }
    #[cfg(windows)]
    if args.get(1).is_some_and(|arg|arg.starts_with("--xr-windows-")) {
        match xr_windows::command(&args[1..]) {
            Ok(message)=>println!("{message}"),
            Err(error)=>{eprintln!("Windows XR setup: {error}");std::process::exit(1);},
        }
        return;
    }
    #[cfg(windows)]
    if args.get(1).is_some_and(|arg|arg=="--xr-steam-options") {
        if args.len()!=4 || args[2]!="--root" {
            eprintln!("Usage: --xr-steam-options --root <XR config directory>");std::process::exit(1);
        }
        println!("{}",xr_library::launch_options_for(std::path::Path::new(&args[3])));
        return;
    }
    #[cfg(windows)]
    if args.get(1).is_some_and(|arg|arg=="--xr-steam-run") {
        match xr_steam_windows::wrapper(&args[2..]) {
            Ok(code)=>std::process::exit(code),
            Err(error)=>{eprintln!("Meteor Steam launch: {error}");std::process::exit(1);},
        }
    }
    if args.get(1).is_some_and(|arg| arg == "--xr-control-dev") {
        let result = xr_control::command(&args[2..]).await;
        if let Err(error) = result {
            eprintln!("Meteor XR control: {error}");
            std::process::exit(1);
        }
        return;
    }
    if args.get(1).is_some_and(|arg| arg == "--install-xr-runtime") {
        let source = args.get(2).map(std::path::PathBuf::from).or_else(|| {
            std::env::current_exe().ok()?.parent()?.parent().map(|prefix|
                prefix.join("share/nightfall-meteor/xr-bundle"))
        });
        let Some(source) = source else { eprintln!("Cannot locate bundled XR runtime"); std::process::exit(1); };
        let result = std::process::Command::new("/usr/bin/python3")
            .arg(source.join("tools/meteor_xr_install.py")).arg(&source)
            .arg("--destination").arg(config::data_dir().join("xr")).status();
        match result {
            Ok(status) => std::process::exit(status.code().unwrap_or(1)),
            Err(error) => { eprintln!("Cannot install XR runtime: {error}"); std::process::exit(1); }
        }
    }
    #[cfg(target_os = "linux")]
    if args.get(1).is_some_and(|arg| arg == "--enable-xr") {
        let result = async {
            xr_setup::enable_from(&xr_setup::bundle()?, &config::config_path()).await
        }.await;
        match result {
            Ok(()) => { println!("PCVR runtime installed and enabled. Start or restart Meteor, then copy Steam Launch Options from its tray menu."); return; }
            Err(error) => { eprintln!("PCVR setup failed: {error}"); std::process::exit(1); }
        }
    }
    // Development-only managed runtime path. Never initialize the ordinary
    // proxy, depth models, audio devices or tray for this exclusive session.
    if args.get(1).is_some_and(|arg| arg == "--xr-dev") {
        #[cfg(target_os = "linux")]
        {
            let code = match xr_session::run(&args[2..]).await {
                Ok(()) => 0,
                Err(error) => {
                    eprintln!("Meteor XR: {error}");
                    1
                }
            };
            std::process::exit(code);
        }
        #[cfg(not(target_os = "linux"))]
        {
            eprintln!("Managed XR development sessions currently require Linux with NVIDIA or AMD.");
            std::process::exit(2);
        }
    }
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
             \x20 --install-xr-runtime [bundle] install bundled XR files into user data and exit\n\
             \x20 --setup                 open the Setup window: host, PCVR, launch options, VDA\n\
             \x20 --enable-xr            install and enable bundled Linux PCVR, then exit\n\
             \x20 --no-tray               run without a tray icon\n\
             \x20 --xr-service-dev <bind>  opt-in XR alongside proxy (explicit --xr-client-key required)\n\
             \x20 --xr-client-key <hex>    allowlisted headset public key for integrated DEV XR\n\
             \x20 --xr-runtime-root <dir>  optional fixed-demo checkout for integrated DEV XR\n\
             \x20 --xr-dev <checkout> [--smoke]  isolated Linux/USB XR development session\n\
             \x20 --xr-control-dev <bind> <key-file> <client-public-key> [--relay [checkout]]  XR development endpoint\n\
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
             \x20 --jitter-ms <ms>        move each replayed frame up to <ms> early or late\n\
             \x20 --quit-after <seconds>  quit during --replay (tests shutdown)\n\
             \x20 --download-vda          download TensorRT (from NVIDIA, under NVIDIA's licence)\n\
             \x20 --download-host         download/verify the Linux managed host without switching\n\
             \x20 --download-vda-vulkan <518|392> download the optional Vulkan VDA model\n\
             \x20                         and the VDA graphs, then exit"
        );
        return;
    }
    let no_tray = flag("--no-tray");
    let dump_dir = value("--dump-video").map(std::path::PathBuf::from);
    let save_every: u64 = value("--save-every").and_then(|n| n.parse().ok()).unwrap_or(60).max(1);
    let save = value("--save-depth").map(|dir| (std::path::PathBuf::from(dir), save_every));

    let config = config::load();
    #[cfg(target_os = "linux")]
    if flag("--download-host") {
        let Some(release)=host::RELEASE.as_ref() else {
            eprintln!("This build does not yet offer a published Meteor-Vibepollo host");std::process::exit(2);
        };
        match host::Install::run(&download::Download::default(),release) {
            Ok(path)=>{println!("Installed Meteor-Vibepollo at {}. Host selection and running services were not changed.",path.display());return;},
            Err(error)=>{eprintln!("Host download failed: {error}");std::process::exit(1);},
        }
    }
    if let Some(variant)=value("--download-vda-vulkan") {
        let id=match variant.as_str() { "518"=>vda_vulkan::FULL,"392"=>vda_vulkan::FAST,_=>{
            eprintln!("Choose 518 or 392 for --download-vda-vulkan");std::process::exit(2);
        }};
        let directory=config.models_dir.clone().unwrap_or_else(config::default_models_dir);
        let download=download::Download::default();
        match download.run_vulkan(&directory,id) {
            Ok(())=>{println!("Installed {} in {}",depth::model_label(id),directory.display());return;},
            Err(error)=>{eprintln!("Vulkan VDA download failed: {error}");std::process::exit(1);},
        }
    }
    if flag("--download-vda") {
        let models_dir = config.models_dir.clone().unwrap_or_else(config::default_models_dir);
        std::process::exit(download::command(&models_dir));
    }
    // Not for a replay: Sunshine's ports, and the discovery port, which
    // doubles as a single-instance lock. It's taken before the models start
    // loading, so a second launch exits straight away.
    let replay_file = value("--replay");
    let mut host_view = host_view::View::default();
    let startup = if replay_file.is_some() {
        None
    } else {
        // Before choosing ports: a second Meteor would find this one's stack busy, pick the
        // next base and so a discovery port of its own, which then can't serve as the lock.
        #[cfg(target_os = "macos")]
        take_instance_lock().await;
        let bundled_base = host_view.prepare(&config);
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
        let jitter_ms = value("--jitter-ms").and_then(|n| n.parse().ok()).unwrap_or(0.0);
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
        let result = tokio::task::spawn_blocking(move || replay::run(std::path::Path::new(&file), fps, jitter_ms, depth)).await;
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
    if let (Some(depth), Some(host)) = (&depth, host_view.supervisor.as_ref()) {
        depth.set_capture_region_file(host.instance.capture_region_path());
    }
    let depth_port = depth.clone().zip(key.clone()).and_then(|(depth, key)| {
        let streaming = stats.clone();
        depth_server::start(side.depth, depth.clone(), key, Arc::new(move |ip| streaming.is_streaming(ip)))
            .map(|port| (port, depth))
    });
    // Register before exposing tray Quit. The coordinator remains alive while
    // async XR cleanup runs; only then use the existing GPU-safe hard exit.
    let shutdown = SHUTDOWN.get_or_init(shutdown::Shutdown::new);
    #[cfg(target_os = "linux")]
    let cursor = host_cursor::Control::new(config.host_cursor_scale,
        host_view.supervisor.as_ref().map(|host| host.instance.appdata().join("cursor-scale")));
    #[cfg(target_os = "linux")]
    let cursor_task = tokio::spawn(host_cursor::watch(cursor.clone(), stats.clone(), shutdown.subscribe()));
    let dev_xr_address = value("--xr-service-dev");
    #[cfg(target_os = "linux")]
    if dev_xr_address.is_none() { xr_setup::update_installed(&config.xr).await; }
    let mut xr_discovery = None;
    let mut xr_trust = None;
    let mut xr_startup_error = None;
    let xr_address = dev_xr_address.clone().or_else(|| config.xr.enabled.then(|| config.xr.listen.clone()));
    let xr_service = if let Some(address) = xr_address {
        let start = async {
            let address = address.parse::<std::net::SocketAddr>().map_err(std::io::Error::other)?;
            let client = value("--xr-client-key").or_else(|| config.xr.allowed_client.clone());
            if dev_xr_address.is_some() && client.is_none() {
                return Err(std::io::Error::other("DEV XR requires --xr-client-key"));
            }
            let allowed = client.as_deref().map(xr_control::public_key).transpose()?.unwrap_or([0;32]);
            let pairing = if dev_xr_address.is_none() {
                Some(Arc::new(xr_trust::Trust::load(config::config_dir().join(xr_trust::FILE))?))
            } else { None };
            let key = key.clone().ok_or_else(|| std::io::Error::other("XR requires Meteor's host key"))?;
            let runtime_root = value("--xr-runtime-root").map(std::path::PathBuf::from)
                .or_else(|| dev_xr_address.is_none().then(|| config.xr.runtime_root()));
            let runtime_root = xr_control::validate_runtime_root(runtime_root)?;
            #[cfg(windows)]
            let steam_broker=if let Some(root)=runtime_root.as_ref().filter(|root|root.join("windows-games.json").is_file()) {
                Some(xr_steam_windows::start_broker(root)?)
            }else{None};
            #[cfg(windows)]
            let steamvr_broker=if steam_broker.is_some() {Some(xr_steamvr_windows::start(runtime_root.as_deref())?)}else{None};
            #[cfg(not(windows))]
            if dev_xr_address.is_none() && !runtime_root.as_ref().is_some_and(|root| root.join("xr-runtime/manifest.json").is_file()) {
                return Err(std::io::Error::other("Normal XR startup requires an installed managed runtime"));
            }
            #[cfg(not(windows))]
            if dev_xr_address.is_none() {
                let root = runtime_root.as_ref().unwrap();
                let check = tokio::time::timeout(std::time::Duration::from_secs(10),
                    tokio::process::Command::new("/usr/bin/python3")
                        .arg(root.join("tools/meteor_xr_runtime.py")).arg("--check")
                        .kill_on_drop(true).output()).await
                    .map_err(|_| std::io::Error::other("Installed XR runtime check timed out"))??;
                if !check.status.success() {
                    return Err(std::io::Error::other(format!("Installed XR runtime validation failed: {}",
                        String::from_utf8_lossy(&check.stderr).chars().take(1200).collect::<String>())));
                }
            }
            let listener = tokio::net::TcpListener::bind(address).await?;
            let port = listener.local_addr()?.port();
            let relay_ports = if dev_xr_address.is_none() {
                let pair = (config.xr.video_port, config.xr.tracking_port);
                let occupied = firewall::ports(&map, side, true);
                if pair.0 == 0 || pair.1 == 0 || pair.0 == pair.1 || pair.0 == port || pair.1 == port ||
                    occupied.iter().any(|&(other, proto)| proto == ports::Proto::Tcp && [pair.0, pair.1, port].contains(&other)) {
                    return Err(std::io::Error::other("XR control/video/tracking ports must be distinct and must not overlap desktop services"));
                }
                Some(pair)
            } else { None };
            if let Some(root) = runtime_root.as_ref() { xr_library::set_runtime_root(root.clone()); }
            log::info!("Managed XR service alongside proxy at {}; host public key {}", listener.local_addr()?, key.public_hex());
            xr_trust = pairing.clone();
            #[cfg(target_os = "linux")]
            if let Some(trust) = pairing.clone() { desktop::watch_xr_approval(trust); }
            let advertised = if dev_xr_address.is_none() { Some(port) } else { None };
            let service_config=xr_control::ServiceConfig {
                key, allowed, enable_relay: true, runtime_root, pairing, relay_ports,
            };
            let cancel=shutdown.subscribe();
            Ok::<_, std::io::Error>((tokio::spawn(async move {
                #[cfg(windows)]
                let _steam_broker=steam_broker;
                #[cfg(windows)]
                let _steamvr_broker=steamvr_broker;
                xr_control::serve(listener,service_config,cancel).await
            }), advertised))
        }.await;
        match start {
            Ok((task, port)) => { xr_discovery = port; Some(task) },
            Err(error) => {
                log::error!("XR service disabled: {error}; desktop proxy remains available");
                xr_startup_error = Some(error.to_string());
                None
            },
        }
    } else {
        if value("--xr-client-key").is_some() || value("--xr-runtime-root").is_some() {
            log::warn!("XR options ignored without --xr-service-dev");
        }
        None
    };
    if let (Some(key), Some(supervisor)) = (&key, &host_view.supervisor) {
        host_view.pairing = Some(host::pairing::Pairing::new(key.clone(), supervisor.clone(), host_view.state.clone(), xr_trust.clone()));
    }
    let features = discovery::Features {
        key: key.as_ref().map(|k| k.public_hex()),
        mic_port: mic.as_ref().map(|m| m.port),
        depth: depth_port,
        host: host_view.discovery_info(),
        xr_port: xr_discovery,
        pairing: host_view.pairing.clone(),
        #[cfg(windows)]
        vdd_installed: sunshine_vdd_installed(),
        #[cfg(target_os = "linux")]
        vdd_installed: host_view.supervisor.is_some() && host::virtual_monitors_supported(&config),
        // The managed host makes virtual displays itself (CGVirtualDisplay): nothing to install.
        #[cfg(target_os = "macos")]
        vdd_installed: host_view.supervisor.is_some(),
        #[cfg(not(any(windows, target_os = "linux", target_os = "macos")))]
        vdd_installed: false,
    };
    tokio::spawn(discovery::serve(discovery, map.clone(), features));

    let status = Arc::new(Status {
        map,
        sunshine_host: config.sunshine_host.clone(),
        side,
        host_ports: host_view.supervisor.is_some(),
        xr_ports: xr_discovery.map(|port| (port, config.xr.video_port, config.xr.tracking_port)),
        sunshine_up: AtomicBool::new(false),
        firewall: std::sync::Mutex::new(firewall::Status::Checking),
    });
    tokio::spawn(status::watch_sunshine(status.clone()));
    status.check_firewall();

    #[cfg(target_os = "linux")]
    xr_setup::initialize(xr_discovery.is_some(), xr_startup_error);
    #[cfg(windows)]
    xr_windows::initialize(xr_discovery.is_some(),xr_startup_error,xr_trust);

    #[cfg(target_os = "linux")]
    let host_view=Arc::new(host_view);
    #[cfg(target_os = "linux")]
    if !no_tray { host::setup::offer(&config); }
    #[cfg(target_os = "linux")]
    if !no_tray && host_view.state.choice == host::Choice::Bundled && host::input::check() != host::input::Status::Ready {
        let input=host_view.input.clone();
        tokio::spawn(async move {
            if let Err(error)=desktop::input_setup_popup(input).await {
                log::info!("Input setup notification unavailable ({error}); setup remains in the tray");
            }
        });
    }
    #[cfg(target_os = "linux")]
    if !no_tray && !tray::run(tray::MeteorTray { status, stats, depth, mic, xr_trust, host: host_view, cursor }).await {
        desktop::notify(
            "Nightfall Meteor is running",
            "There's no tray to show its controls in. On GNOME, the AppIndicator extension adds one.",
        )
        .await;
    }
    // The host captures and injects input on Meteor.app's behalf: ask for both up front,
    // rather than letting the first stream fail with an encoder error in the headset.
    #[cfg(target_os = "macos")]
    if host_view.supervisor.is_some() {
        desktop::permissions::request_missing();
    }
    #[cfg(target_os = "macos")]
    let menu_bar = (!no_tray).then(|| tray_macos::Tray {
        status: status.clone(), stats: stats.clone(), depth: depth.clone(), mic: mic.clone(),
        host: Arc::new(host_view), runtime: tokio::runtime::Handle::current(),
    });
    #[cfg(not(target_os = "linux"))]
    {
        #[cfg(windows)]
        if !no_tray {
            tray_windows::run(status.clone(), stats.clone(), mic.clone(), depth.clone(), Arc::new(host_view));
        }
        #[cfg(windows)]
        if let Some(d) = &depth {
            let flag = config::data_dir().join("pending-vda-download");
            if std::fs::remove_file(&flag).is_ok() {
                log::info!("Starting VDA download requested during installation");
                d.download_vda();
            }
        }
        let _ = (status, stats, depth, mic);
        if no_tray {
            log::info!("No tray icon requested; press Ctrl+C to stop");
        }
    }

    let finish = async move {
        tokio::select! {
            _ = wait_for_exit_signal() => shutdown.request(),
            _ = shutdown.requested() => {},
        }
        #[cfg(target_os = "linux")]
        if let Err(error) = cursor_task.await { log::warn!("Host cursor cleanup: {error}"); }
        if let Some(task) = xr_service {
            match task.await {
                Ok(Ok(())) => {},
                Ok(Err(error)) => log::error!("XR service shutdown: {error}"),
                Err(error) => log::error!("XR service task failed: {error}"),
            }
        }
        finish_quit();
    };
    // AppKit's menu bar must own the main thread, which tokio::main's main future runs on:
    // shutdown waits on a worker thread instead, and ends the process from there.
    #[cfg(target_os = "macos")]
    if let Some(tray) = menu_bar {
        tokio::spawn(finish);
        tokio::task::block_in_place(move || tray_macos::run(tray));
        return;
    }
    finish.await;
}

/// Checks whether the SunshineVDD virtual display driver is installed by
/// running the probe executable bundled with Meteor-Vibepollo. Result is
/// cached for the lifetime of this Meteor process.
#[cfg(windows)]
fn sunshine_vdd_installed() -> bool {
    use std::sync::OnceLock;
    static CACHE: OnceLock<bool> = OnceLock::new();
    *CACHE.get_or_init(|| {
        let probe = std::env::current_exe()
            .ok()
            .and_then(|e| e.parent().map(|p| p.join("runtime/host/drivers/sunshine/virtualdisplay_probe.exe")));
        probe.is_some_and(|p| {
            if !p.is_file() { return false; }
            // --check requires admin (ERROR_ACCESS_DENIED without it). Use
            // --diagnose instead: it enumerates control interfaces without
            // opening them, so it works without elevation.
            let out = std::process::Command::new(&p).arg("--diagnose").output();
            let Ok(out) = out else { return false; };
            let stdout = String::from_utf8_lossy(&out.stdout);
            // Line is "control_interface_count=1 enumerate_error=0 ..."
            // so take only the first whitespace-delimited token after '='.
            stdout.lines()
                .find(|l| l.starts_with("control_interface_count="))
                .and_then(|l| l.split('=').nth(1))
                .and_then(|v| v.split_whitespace().next())
                .and_then(|n| n.parse::<u32>().ok())
                .is_some_and(|n| n > 0)
        })
    })
}

/// Held for Meteor's whole life (a restart's exec closes it: O_CLOEXEC).
#[cfg(target_os = "macos")]
static INSTANCE_LOCK: OnceLock<std::fs::File> = OnceLock::new();

/// Exits if another Meteor of this user runs. A restarted Meteor waits up to ten seconds for
/// the old one to let go, as it does for the discovery port.
#[cfg(target_os = "macos")]
async fn take_instance_lock() {
    use std::os::fd::AsRawFd;
    let path = config::config_dir().join("meteor.lock");
    let file = std::fs::create_dir_all(config::config_dir())
        .and_then(|()| std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(&path));
    let file = match file {
        Ok(file) => file,
        Err(error) => {
            log::warn!("Can't open {} ({error}); not checking for another Meteor", path.display());
            return;
        }
    };
    let tries = if std::env::var_os(RESTART_ENV).is_some() { 50 } else { 1 };
    for attempt in 0..tries {
        // SAFETY: flock on a descriptor this function owns.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            let _ = INSTANCE_LOCK.set(file);
            return;
        }
        if attempt + 1 < tries {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
    }
    log::error!("Nightfall Meteor is already running ({} is locked)", path.display());
    desktop::notify("Nightfall Meteor is already running", "Look for it in the menu bar.").await;
    exit_now(1);
}

static MIC: OnceLock<Arc<Mic>> = OnceLock::new();
static SHUTDOWN: OnceLock<shutdown::Shutdown> = OnceLock::new();
static RESTART: AtomicBool = AtomicBool::new(false);

/// Set on the process `restart` starts, so it waits for the old one's
/// discovery port.
const RESTART_ENV: &str = "METEOR_RESTARTED";

pub fn restart() {
    RESTART.store(true, std::sync::atomic::Ordering::Relaxed);
    quit();
}

/// Nonblocking tray/thread callback; async main drains services before exiting.
/// Replay has no service coordinator and retains its existing immediate exit.
pub fn quit() {
    if let Some(shutdown) = SHUTDOWN.get() {
        shutdown.request();
    } else {
        finish_quit();
    }
}

fn finish_quit() -> ! {
    log::info!("Shutting down");
    if let Some(mic) = MIC.get() {
        mic.shutdown();
    }
    if let Some(host) = host_view::RUNNING.get() {
        host.shutdown();
    }
    // Vibepollo's display helper breaks out of the job object intentionally so
    // it can restore display topology after the host exits. Kill it here so it
    // doesn't linger after Meteor itself shuts down.
    #[cfg(windows)]
    kill_processes_by_name("sunshine_display_helper.exe");
    #[cfg(windows)]
    if RESTART.load(std::sync::atomic::Ordering::Relaxed) {
        match std::env::current_exe().and_then(|exe| {
            let mut command = std::process::Command::new(exe);
            command.args(std::env::args_os().skip(1)).env(RESTART_ENV, "1").spawn()
        }) {
            Ok(child) => log::info!("Restarted Meteor as process {}", child.id()),
            Err(error) => log::error!("Cannot restart Meteor: {error}"),
        }
    }
    #[cfg(target_os = "macos")]
    if RESTART.load(std::sync::atomic::Ordering::Relaxed) {
        use std::os::unix::process::CommandExt;
        match std::env::current_exe() {
            Ok(exe) => log::error!("Cannot restart Meteor: {}", std::process::Command::new(exe)
                .args(std::env::args_os().skip(1)).env(RESTART_ENV, "1").exec()),
            Err(error) => log::error!("Cannot restart Meteor: {error}"),
        }
        exit_now(1);
    }
    #[cfg(target_os = "linux")]
    if RESTART.load(std::sync::atomic::Ordering::Relaxed) {
        use std::os::unix::process::CommandExt;
        match xr_setup::restart_command() {
            Ok(mut command) => log::error!("Cannot restart Meteor: {}", command.exec()),
            Err(error) => log::error!("Cannot restart Meteor: {error}"),
        }
        exit_now(1);
    }
    exit_now(0);
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

#[cfg(windows)]
fn kill_processes_by_name(name: &str) {
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW,
        PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Threading::{OpenProcess, TerminateProcess, PROCESS_TERMINATE};
    use windows_sys::Win32::Foundation::CloseHandle;
    let name_lower = name.to_ascii_lowercase();
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
    if snapshot == windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE {
        return;
    }
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
    let mut ok = unsafe { Process32FirstW(snapshot, &mut entry) } != 0;
    while ok {
        let exe = String::from_utf16_lossy(entry.szExeFile.iter().take_while(|&&c| c != 0).copied().collect::<Vec<_>>().as_slice());
        if exe.to_ascii_lowercase() == name_lower {
            let handle = unsafe { OpenProcess(PROCESS_TERMINATE, 0, entry.th32ProcessID) };
            if !handle.is_null() {
                unsafe { TerminateProcess(handle, 1) };
                unsafe { CloseHandle(handle) };
                log::info!("Killed lingering {name} (pid {})", entry.th32ProcessID);
            }
        }
        ok = unsafe { Process32NextW(snapshot, &mut entry) } != 0;
    }
    unsafe { CloseHandle(snapshot) };
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
    let opener = if cfg!(windows) { "explorer" } else if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    if let Err(err) = std::process::Command::new(opener).arg(&path).spawn() {
        log::warn!("Can't open {}: {err}", path.display());
    }
}
