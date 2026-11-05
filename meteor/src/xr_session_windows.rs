//! Explicitly configured Windows DEV runtime adapter; normal packaging is separate.
use std::{io,path::{Path,PathBuf},process::{Command,Stdio},time::{Duration,Instant}};
use serde::{Deserialize,Serialize};
use std::io::Write as _;

#[derive(Clone,Deserialize,Serialize)]
pub(crate) struct Files {
    pub service:PathBuf,
    pub manifest:PathBuf,
    pub encoder:PathBuf,
    pub tracking:PathBuf,
    pub application:PathBuf,
    #[serde(default)] pub working_directory:Option<PathBuf>,
    #[serde(default)] pub openvr_runtime:Option<PathBuf>,
    #[serde(default)] pub openvr_loader:Option<PathBuf>,
    #[serde(default)] pub steamvr_driver:Option<PathBuf>,
    #[serde(default="direct_capture")] pub steamvr_capture:String,
    #[serde(default)] pub steam_launch:bool,
    #[serde(default)] pub steam_app_id:Option<String>,
    #[serde(default)] pub arguments:Vec<String>,
    #[serde(default)] pub library_dirs:Vec<PathBuf>,
    #[serde(default)] pub pixel_probe:bool,
    #[serde(default="delivery_enabled")] pub async_delivery:bool,
}
fn delivery_enabled()->bool {true}
fn direct_capture()->String {"direct".into()}
pub(crate) fn load(root:&Path)->io::Result<Files> {
    let path=root.join("xr-windows.json");
    if std::fs::metadata(&path)?.len()>16384 {return Err(io::Error::other("Windows XR configuration exceeds 16 KiB"));}
    let files:Files=serde_json::from_slice(&std::fs::read(path)?)?;
    if let Some(runtime)=&files.openvr_runtime {
        if !runtime.is_absolute() || !runtime.join("bin/vrclient_x64.dll").is_file() {
            return Err(io::Error::other("Missing absolute Windows xrizer runtime directory"));
        }
    }
    if let Some(driver)=&files.steamvr_driver {
        if !matches!(files.steamvr_capture.as_str(),"direct"|"mirror") {return Err(io::Error::other("Invalid SteamVR capture backend"));}
        if !driver.is_absolute() || !driver.join("driver.vrdrivermanifest").is_file() || !driver.join("bin/win64/driver_meteor.dll").is_file() ||
            files.openvr_loader.is_some() || !files.openvr_runtime.as_ref().is_some_and(|r|r.join("bin/win64/vrstartup.exe").is_file()) {
            return Err(io::Error::other("SteamVR trial requires its installed runtime, Meteor driver, and original Valve loader"));
        }
    }
    if let Some(loader)=&files.openvr_loader {
        if files.openvr_runtime.is_none() || !loader.is_absolute() || !loader.is_file() {
            return Err(io::Error::other("Windows OpenVR loader requires an absolute file and runtime directory"));
        }
    }
    if files.steam_app_id.as_ref().is_some_and(|id|id.parse::<u32>().unwrap_or(0)==0) {
        return Err(io::Error::other("Invalid configured Steam application ID"));
    }
    for file in [&files.service,&files.manifest,&files.encoder,&files.tracking,&files.application] {
        if !file.is_absolute() || !file.is_file() {return Err(io::Error::other(format!("Missing absolute Windows XR file: {}",file.display())));}
    }
    if files.arguments.len()>64 || files.arguments.iter().any(|s|s.len()>4096) ||
        files.working_directory.as_ref().is_some_and(|p|!p.is_absolute() || !p.is_dir()) ||
        files.library_dirs.iter().any(|p|!p.is_absolute() || !p.is_dir()) {
        return Err(io::Error::other("Invalid Windows XR arguments/library directories"));
    }
    Ok(files)
}

#[allow(clippy::too_many_arguments)]
pub(crate) async fn runtime_adapter_with_status(
    root:PathBuf,video:u16,tracking:u16,hz:u32,eye_size:u32,eye_height:u32,
    _long_run:bool,bitrate_mbps:u32,codec:String,foveated:bool,intent:Option<String>,
    cancel:tokio::sync::watch::Receiver<bool>,progress:Option<&crate::xr_relay::RuntimeProgress>,
    _bitrate_directory:Option<&crate::xr_bitrate::RuntimeDirectory>,
) -> io::Result<()> {
    if foveated || !matches!(codec.as_str(),"h264"|"h265") || !matches!(hz,20|60|72) ||
        !crate::xr_control::valid_eye_size(eye_size) || !crate::xr_control::valid_eye_size(eye_height) ||
        (bitrate_mbps!=0 && !(8..=160).contains(&bitrate_mbps)) {
        return Err(io::Error::other("Unsupported Windows DEV XR profile"));
    }
    let active=crate::xr_windows::ActiveSession::acquire()?;
    let (files,completion)=match intent.as_deref() {
        Some(generation)=>{let launch=crate::xr_windows::claimed_launch(&root,generation)?;(launch.files,launch.completion)},
        None=>(load(&root)?,None),
    };
    let progress=progress.cloned();
    tokio::task::spawn_blocking(move || {
        let _active=active;
        use crate::xr_relay::RuntimePhase;
        let cancelled=||*cancel.borrow() || cancel.has_changed().is_err();
        if cancelled() {return Ok(());}
        let mut generation=[0u8;16];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut generation)
            .map_err(|_|io::Error::other("XR runtime generation randomness unavailable"))?;
        if let Some(p)=&progress {
            let mut p=p.lock().unwrap();
            p.generation=Some(generation.iter().map(|b|format!("{b:02x}")).collect());
            p.event_sequence=0;
        }
        let stamp=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(io::Error::other)?.as_nanos();
        let output=crate::config::data_dir().join("xr/windows-sessions").join(format!("{stamp}"));
        std::fs::create_dir_all(&output)?;
        let mut supervisor=std::fs::File::create(output.join("supervisor.log"))?;
        let mut event=|message:&str|->io::Result<()> {
            let utc=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(io::Error::other)?.as_millis();
            writeln!(supervisor,"utc_ms={utc} {message}")
        };
        let marker=output.join("session-active");
        let steamvr_paths=output.join("steamvr-paths.vrpath");
        let steamvr_ready=output.join("steamvr-ready");
        if let Some(driver)=&files.steamvr_driver {
            let config=output.join("steamvr-config");let logs=output.join("steamvr-logs");
            std::fs::create_dir_all(&config)?;std::fs::create_dir_all(&logs)?;
            std::fs::write(&steamvr_paths,serde_json::to_vec(&serde_json::json!({
                "jsonid":"vrpathreg","version":1,"runtime":[files.openvr_runtime],"config":[config],"log":[logs],"external_drivers":[driver],
            }))?)?;
            std::fs::write(config.join("steamvr.vrsettings"),serde_json::to_vec(&serde_json::json!({
                "steamvr":{"forcedDriver":"meteor","requireHmd":true,"activateMultipleDrivers":false,
                    "enableHomeApp":false,"doNotFadeToGrid":true,"showStage":false,"showGridCircles":false,
                    "startDashboardFromAppLaunch":false,"startMonitorFromAppLaunch":false,
                    "startCompositorFromAppLaunch":false,"supersampleManualOverride":true,"supersampleScale":1.0,"motionSmoothing":false,"disableAsync":true},
                "dashboard":{"enableDashboard":false},"driver_meteor":{"enable":true},
                "audio":{"setOsDefaultPlaybackDevice":false,"enablePlaybackDeviceOverride":false,
                    "setOsDefaultRecordingDevice":false,"enableRecordingDeviceOverride":false,"enablePlaybackMirror":false},
                "driver_lighthouse":{"enable":false},"driver_oculus":{"enable":false},"driver_null":{"enable":false},
            }))?)?;
        }
        let log=std::fs::File::create(output.join("runtime.log"))?;
        let mut dirs=files.library_dirs.clone();
        if let Some(runtime)=&files.openvr_runtime {dirs.push(runtime.join("bin"));}
        dirs.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()));
        let path=std::env::join_paths(dirs).map_err(io::Error::other)?;
        let configure=|command:&mut Command|->io::Result<()> {
            command.env("PATH",&path).env("XR_RUNTIME_JSON",&files.manifest)
                .env("SIMULATED_ENABLE","1").env("XRT_COMPOSITOR_NULL","1").env("XRT_NO_STDIN","1")
                .env("SIMULATED_LEFT","touch").env("SIMULATED_RIGHT","touch")
                .env("METEOR_WINDOWS_ENCODER",&files.encoder).env("METEOR_TRACKING_BRIDGE",&files.tracking)
                .env("METEOR_XR_DIRECT_PORT",video.to_string()).env("METEOR_TRACKING_PORT",tracking.to_string())
                .env("METEOR_XR_CONTROLLERS","1").env("METEOR_XR_TOUCH_INPUTS","1").env("METEOR_XR_HAPTICS","1")
                .env("METEOR_XR_HEADSET_OPTICS","1").env("METEOR_XR_EYE_SIZE",eye_size.to_string())
                .env("METEOR_XR_EYE_HEIGHT",eye_height.to_string()).env("XRT_COMPOSITOR_NULL_FPS",hz.to_string())
                .env("METEOR_XR_CODEC",&codec).env("METEOR_PROBE_OUTPUT",&output)
                .env("METEOR_WINDOWS_SESSION_MARKER",&marker)
                .stdin(Stdio::null()).stdout(Stdio::from(log.try_clone()?)).stderr(Stdio::from(log.try_clone()?));
            if bitrate_mbps!=0 {command.env("METEOR_XR_BITRATE_MBPS",bitrate_mbps.to_string());}
            if files.pixel_probe {command.env("METEOR_WINDOWS_PIXEL_PROBE","1").env_remove("METEOR_XR_TRACKED_SCENE");}
            else {command.env_remove("METEOR_WINDOWS_PIXEL_PROBE").env("METEOR_XR_TRACKED_SCENE","1");}
            if files.async_delivery {command.env("METEOR_XR_ASYNC_DELIVERY","1");}
            else {command.env_remove("METEOR_XR_ASYNC_DELIVERY");}
            if files.steamvr_driver.is_some() {
                command.env("VR_OVERRIDE",files.openvr_runtime.as_ref().unwrap()).env("VR_PATHREG_OVERRIDE",&steamvr_paths)
                    .env("METEOR_STEAMVR_ROOT",files.openvr_runtime.as_ref().unwrap())
                    .env("METEOR_STEAMVR_READY_FILE",output.join("steamvr-driver-ready"))
                    .env("METEOR_STEAMVR_VIDEO_READY_FILE",&steamvr_ready).env("METEOR_STEAMVR_TRIAL","1")
                    .env_remove("METEOR_STEAMVR_SYNTHETIC").env_remove("XR_RUNTIME_JSON");
                if files.steamvr_capture=="direct" {command.env("METEOR_STEAMVR_DIRECT","1");}
                else {command.env_remove("METEOR_STEAMVR_DIRECT");}
            }
            if let Some(app_id)=&files.steam_app_id {command.env("SteamAppId",app_id).env("SteamGameId",app_id);}
            Ok(())
        };
        let mut service=Command::new(&files.service); configure(&mut service)?;
        if files.steamvr_driver.is_some() {service.arg("--service");}
        let mut session=crate::xr_runtime_windows::Session::start(&mut service)?;
        event(&format!("runtime_started service_pid={}",session.process_ids().0))?;
        let ready=Instant::now()+Duration::from_secs(if files.steamvr_driver.is_some() {30}else{2});
        while Instant::now()<ready {
            if cancelled() {event("cancelled_before_application_launch")?;return Ok(());}
            session.ensure_runtime_running()?;
            if files.steamvr_driver.is_some() && steamvr_ready.is_file() {break;}
            std::thread::sleep(Duration::from_millis(20));
        }
        if files.steamvr_driver.is_some() && !steamvr_ready.is_file() {return Err(io::Error::other("SteamVR trial driver did not become ready"));}
        if let Some(p)=&progress {p.lock().unwrap().phase=RuntimePhase::ReadyForApplication;}
        let mut steam_socket=completion;
        let mut app=if files.steam_launch {
            let pending=crate::xr_steam_windows::Pending::create(&root)?;
            event("waiting_for_local_steam_command")?;
            let deadline=Instant::now()+Duration::from_secs(120);
            let (launch,socket)=loop {
                if cancelled() {event("cancelled_before_steam_command")?;return Ok(());}
                session.ensure_runtime_running()?;
                if let Some(value)=pending.poll(files.steam_app_id.as_deref())? {break value;}
                if Instant::now()>=deadline {return Err(io::Error::other("Steam command did not arrive within 120 seconds"));}
                std::thread::sleep(Duration::from_millis(20));
            };
            drop(pending);
            event(&format!("local_steam_command app_id={}",launch.app_id))?;
            let mut app=Command::new(&launch.command[0]);app.args(&launch.command[1..]).current_dir(&launch.cwd)
                .env("SteamAppId",&launch.app_id).env("SteamGameId",&launch.app_id);
            steam_socket=Some(socket);app
        } else {
            let mut app=Command::new(&files.application); app.args(&files.arguments);
            if let Some(directory)=files.working_directory.as_deref().or_else(||files.application.parent()) {app.current_dir(directory);}
            app
        };
        configure(&mut app)?;
        // Scope OpenVR discovery to the game. Neither system registration nor
        // the runtime service inherits the selected xrizer directory.
        if let Some(runtime)=&files.openvr_runtime && files.steamvr_driver.is_none() {
            // Unreal's SteamVR plugin interprets VR_OVERRIDE as an SDK root
            // as well as a runtime root: it loads bin/win64/openvr_api.dll.
            // Stage the application's unchanged Valve loader beside our
            // runtime for this session, rather than patching game files.
            let staged;
            let runtime=if let Some(loader)=&files.openvr_loader {
                staged=output.join("openvr-runtime");
                std::fs::create_dir_all(staged.join("bin/win64"))?;
                std::fs::copy(runtime.join("bin/vrclient_x64.dll"),staged.join("bin/vrclient_x64.dll"))?;
                std::fs::copy(loader,staged.join("bin/win64/openvr_api.dll"))?;
                let search=std::iter::once(staged.join("bin/win64")).chain(std::env::split_paths(&path));
                app.env("PATH",std::env::join_paths(search).map_err(io::Error::other)?);
                event(&format!("openvr_loader_staged source={}",loader.display()))?;
                &staged
            } else {runtime};
            let registry=output.join("openvrpaths.vrpath");
            std::fs::write(&registry,serde_json::to_vec(&serde_json::json!({
                "jsonid":"vrpathreg","version":1,"runtime":[runtime],"config":[],"log":[],
            }))?)?;
            app.env("VR_OVERRIDE",runtime).env("VR_PATHREG_OVERRIDE",registry);
        }
        session.launch(&mut app)?;
        event(&format!("application_started pid={:?} path={}",session.process_ids().1,files.application.display()))?;
        let mut saw_frame=false;let mut saw_end=false;
        loop {
            if steam_socket.as_ref().is_some_and(crate::xr_steam_windows::disconnected) {
                event("steam_wrapper_disconnected")?;
                if files.steamvr_driver.is_some(){std::fs::write(marker.with_extension("stop"),b"")?;}
                return Err(io::Error::other("Steam launch wrapper disconnected"));
            }
            if cancelled() {
                event(&format!("cancel_requested child_state={:?}",session.poll()))?;
                if files.steamvr_driver.is_some() {
                    // Stop direct capture before closing vrmonitor. Otherwise
                    // the compositor can keep submitting to a disappearing
                    // receiver while SteamVR is trying to exit.
                    std::fs::write(marker.with_extension("stop"),b"")?;
                    let deadline=Instant::now()+Duration::from_millis(1500);
                    while !marker.with_extension("ended").is_file() && !marker.with_extension("failed").is_file() && Instant::now()<deadline {
                        std::thread::sleep(Duration::from_millis(10));
                    }
                }
                if let Some(socket)=&mut steam_socket {let _=crate::xr_steam_windows::finish(socket,130);}
                return Ok(());
            }
            if marker.is_file() && !saw_frame {event("first_encoded_frame")?;saw_frame=true;}
            if marker.is_file() && let Some(p)=&progress {
                let mut p=p.lock().unwrap();
                if p.active_sessions==0 {p.event_sequence+=1;}
                p.phase=RuntimePhase::SessionActive; p.active_sessions=1;
            }
            let status=match session.poll() {Ok(status)=>status,Err(error)=>{event(&format!("runtime_poll_failed error={error}"))?;return Err(error);}};
            if let Some(status)=status {
                event(&format!("application_exited status={status}"))?;
                if files.steamvr_driver.is_some() {std::fs::write(marker.with_extension("stop"),b"")?;}
                if let Some(socket)=&mut steam_socket {let _=crate::xr_steam_windows::finish(socket,status.code().unwrap_or(1));}
                // Monado processes client session destruction asynchronously.
                // Keep it alive until its encoder drain and END acknowledgement
                // finish, rather than killing it as soon as the app exits.
                if status.success() && marker.is_file() {
                    let drained=marker.with_extension("ended");
                    let deadline=Instant::now()+Duration::from_secs(3);
                    while !drained.is_file() && Instant::now()<deadline {
                        if cancelled() {event("cancelled_after_application_exit_while_draining")?;return Ok(());}
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    if !drained.is_file() {return Err(io::Error::other("Windows XR encoder did not acknowledge session END"));}
                }
                return if status.success() {Ok(())} else {Err(io::Error::other(format!("Windows XR application exited: {status}")))};
            }
            if marker.with_extension("ended").is_file() && !saw_end {event("video_end_acknowledged_application_still_running")?;saw_end=true;}
            std::thread::sleep(Duration::from_millis(20));
        }
    }).await.map_err(io::Error::other)?
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[tokio::test]
    #[ignore = "launches the explicitly configured Windows application with synthetic tracking"]
    async fn configured_application_delivers_frames_before_bounded_stop() {
        let observation_seconds=std::env::var("NIGHTFALL_WINDOWS_XR_OBSERVE_SECONDS").ok().map(|value|value.parse::<u64>().unwrap()).unwrap_or(10);
        assert!((1..=60).contains(&observation_seconds));
        let root=PathBuf::from(std::env::var_os("NIGHTFALL_WINDOWS_XR_ROOT").expect("runtime root")).canonicalize().unwrap();
        let mut steam_broker=None;
        let mut steam_wrapper=None;
        let launch_intent=std::env::var("NIGHTFALL_WINDOWS_XR_CATALOG_APP").ok().map(|app_id| {
            if std::env::var_os("NIGHTFALL_WINDOWS_XR_STEAM_WRAPPER").is_some() {
                steam_broker=Some(crate::xr_steam_windows::start_broker(&root).unwrap());
                let game=crate::xr_windows::games(&root).unwrap().into_iter().find(|g|g.app_id==app_id).unwrap();
                let profile=match game.backend {crate::xr_windows::Backend::Monado=>game.monado.unwrap(),crate::xr_windows::Backend::Steamvr=>game.steamvr.unwrap()};
                let files=load(&profile).unwrap();
                let mut command=vec![files.application.to_string_lossy().into_owned()];command.extend(files.arguments);
                let cwd=files.application.parent().unwrap().to_path_buf();let request_root=root.clone();let id=app_id.clone();
                steam_wrapper=Some(std::thread::spawn(move ||crate::xr_steam_windows::request_launch(&request_root,command,cwd,id)));
                let deadline=Instant::now()+Duration::from_secs(5);
                while crate::xr_windows::pending(&root).is_none(){assert!(Instant::now()<deadline,"Steam wrapper did not queue the catalog launch");std::thread::sleep(Duration::from_millis(10));}
            } else {
                let result=crate::xr_windows::library(&root,"launch",&format!("steam:{app_id}"),0);
                assert!(result.get("error").is_none(),"{result}");
            }
            let notice=crate::xr_windows::pending(&root).expect("native catalog launch notice");
            assert_eq!(notice.app_id,app_id);assert!(crate::xr_windows::claim(&root,&notice.generation));
            notice.generation
        });
        let tracking=std::env::var("NIGHTFALL_WINDOWS_TRACKING_PORT").unwrap().parse().unwrap();
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let video=listener.local_addr().unwrap().port(); listener.set_nonblocking(true).unwrap();
        let (arrived,first_frames)=tokio::sync::oneshot::channel();
        let codec=std::env::var("NIGHTFALL_WINDOWS_XR_TEST_CODEC").unwrap_or_else(|_|"h264".into());
        let capture=root.join(if codec=="h265" {"application-startup.hevc"}else{"application-startup.h264"});
        let metadata_path=root.join("application-frames.jsonl");
        let finished=std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let receiver_finished=finished.clone();
        let mut receiver=tokio::task::spawn_blocking(move ||->io::Result<u64> {
            let deadline=Instant::now()+Duration::from_secs(45);
            let mut socket=loop {
                match listener.accept() {
                    Ok((socket,_))=>break socket,
                    Err(e) if e.kind()==io::ErrorKind::WouldBlock && Instant::now()<deadline && !receiver_finished.load(std::sync::atomic::Ordering::Acquire)=>std::thread::sleep(Duration::from_millis(10)),
                    Err(e)=>return Err(e),
                }
            };
            socket.set_nonblocking(false)?;socket.set_read_timeout(Some(Duration::from_secs(5)))?;
            let mut recording=std::fs::File::create(capture)?;
            let mut metadata=if std::env::var_os("METEOR_STEAMVR_GEOMETRY_PROBE").is_some() {
                Some(std::fs::File::create(metadata_path)?)
            }else{None};
            let mut reader=crate::xr_wire::Reader::default();let mut count=0;let mut arrived=Some(arrived);
            loop {
                match reader.read(&mut socket) {
                    Ok(Some(frame))=>{
                        if let Some(output)=&mut metadata {
                            writeln!(output,"{}",serde_json::json!({"frame_id":frame.header.frame_id,"views":frame.header.views}))?;
                        }
                        recording.write_all(&frame.payload)?;
                        let mut ack=b"NFXA".to_vec();ack.extend(frame.header.sequence.to_le_bytes());ack.extend(frame.header.frame_id.to_le_bytes());
                        if let Err(error)=socket.write_all(&ack) {if count>=3 {return Ok(count);}return Err(error);}
                        count+=1;
                        if count==3 {let _=arrived.take().unwrap().send(());}
                    },
                    Ok(None)=>{
                        let mut ack=b"NFXE".to_vec();ack.extend((count as u64).to_le_bytes());let _=socket.write_all(&ack);return Ok(count);
                    },
                    Err(_) if count>=3=>return Ok(count),
                    Err(error)=>return Err(error),
                }
            }
        });
        let (stop,cancel)=tokio::sync::watch::channel(false);
        let test_dimension=|name:&str|std::env::var(name).map(|v|v.parse::<u32>().expect("Invalid test dimension")).unwrap_or(1024);
        let width=test_dimension("NIGHTFALL_WINDOWS_XR_TEST_WIDTH");
        let height=test_dimension("NIGHTFALL_WINDOWS_XR_TEST_HEIGHT");
        let bitrate=std::env::var("NIGHTFALL_WINDOWS_XR_TEST_BITRATE").map(|v|v.parse::<u32>().expect("Invalid test bitrate")).unwrap_or(32);
        let mut runtime=tokio::spawn(runtime_adapter_with_status(root,video,tracking,72,width,height,true,bitrate,codec,false,launch_intent,cancel,None,None));
        let mut completed=false;
        let mut receiver_result=None;
        let mut outcome=tokio::select! {
            result=first_frames=>result.map_err(|_|"receiver closed before three frames".to_string()),
            result=&mut runtime=>{completed=true;Err(format!("Application runtime exited before three frames: {result:?}"))},
            _=tokio::time::sleep(Duration::from_secs(45))=>Err("application did not deliver three frames within 45s".into()),
        };
        if outcome.is_ok() {
            tokio::select! {
                _=tokio::time::sleep(Duration::from_secs(observation_seconds))=>{},
                result=&mut runtime=>{completed=true;outcome=Err(format!("Application exited during startup observation: {result:?}"));},
                result=&mut receiver=>{outcome=Err(format!("Video receiver ended during startup observation: {result:?}"));receiver_result=Some(result);},
            }
        }
        stop.send_replace(true);
        finished.store(true,std::sync::atomic::Ordering::Release);
        if !completed {runtime.await.unwrap().unwrap();}
        let count=match receiver_result {Some(result)=>result,None=>receiver.await}.unwrap();
        outcome.unwrap();assert!(count.unwrap()>=3);
        if let Some(wrapper)=steam_wrapper {assert_eq!(wrapper.join().unwrap().unwrap(),130);println!("PASS: Steam broker selected catalog backend and returned cancellation status 130");}
        drop(steam_broker);
        println!("PASS: configured Windows application delivered validated frames and remained running for {observation_seconds}s; owned process tree stopped (bounded cancellation, not graceful application exit)");
    }
    #[tokio::test]
    #[ignore = "requires configured Windows Monado build and synthetic tracking publisher"]
    async fn configured_runtime_delivers_frames_and_cleans_up() {
        let root=PathBuf::from(std::env::var_os("NIGHTFALL_WINDOWS_XR_ROOT").expect("runtime root"));
        let tracking=std::env::var("NIGHTFALL_WINDOWS_TRACKING_PORT").unwrap().parse().unwrap();
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let video=listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let receiver=tokio::task::spawn_blocking(move ||->io::Result<u64> {
            let deadline=Instant::now()+Duration::from_secs(15);
            let mut socket=loop {
                match listener.accept() {
                    Ok((socket,_))=>break socket,
                    Err(e) if e.kind()==io::ErrorKind::WouldBlock && Instant::now()<deadline=>std::thread::sleep(Duration::from_millis(10)),
                    Err(e)=>return Err(e),
                }
            };
            socket.set_nonblocking(false)?; socket.set_read_timeout(Some(Duration::from_secs(5)))?;
            let mut reader=crate::xr_wire::Reader::default(); let mut count=0u64;
            while let Some(frame)=reader.read(&mut socket)? {
                let mut ack=b"NFXA".to_vec(); ack.extend(frame.header.sequence.to_le_bytes()); ack.extend(frame.header.frame_id.to_le_bytes());
                socket.write_all(&ack)?; count+=1;
            }
            let mut ack=b"NFXE".to_vec(); ack.extend(count.to_le_bytes()); socket.write_all(&ack)?;
            Ok(count)
        });
        let (_stop,cancel)=tokio::sync::watch::channel(false);
        let progress=std::sync::Arc::new(std::sync::Mutex::new(crate::xr_relay::RuntimeStatus::default()));
        runtime_adapter_with_status(root,video,tracking,20,256,256,false,0,"h264".into(),false,None,cancel,Some(&progress),None).await.unwrap();
        let status=progress.lock().unwrap();
        assert_eq!(status.generation.as_ref().unwrap().len(),32);
        assert!(status.event_sequence>0);
        let count=receiver.await.unwrap().unwrap(); assert!(count>0);
        println!("PASS: native Windows session adapter delivered {count} validated frames and clean END");
    }
}
