//! Native Windows catalog and local launch selection for the managed XR service.
//! Only host-registered profiles select executables; remote requests select IDs.
use std::{io,path::{Path,PathBuf},sync::{Arc,Mutex,OnceLock},time::{Duration,Instant}};
use serde::{Deserialize,Serialize};
use serde_json::{json,Value};
use crate::xr_session::Files;

#[derive(Clone,Copy,Default,Debug,PartialEq,Serialize,Deserialize)]
#[serde(rename_all="lowercase")]
pub enum Backend {#[default] Monado,Steamvr}
#[derive(Clone,Serialize,Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Game {
    pub app_id:String,pub name:String,
    #[serde(default)] pub backend:Backend,
    pub monado:Option<PathBuf>,pub steamvr:Option<PathBuf>,
    #[serde(default)] pub requires_steamvr:bool,
}
impl Game {
    fn profile(&self,backend:Backend)->io::Result<&Path> {
        match backend {Backend::Monado=>self.monado.as_deref(),Backend::Steamvr=>self.steamvr.as_deref()}
            .ok_or_else(||io::Error::other("This game has no registered profile for that backend"))
    }
    fn files(&self)->io::Result<Files> {
        if self.backend==Backend::Steamvr && self.requires_steamvr {return Err(io::Error::other("This game requires SteamVR to be installed"));}
        let files=crate::xr_session::load(self.profile(self.backend)?)?;
        if files.library_only || files.steam_launch || files.steam_app_id.as_deref()!=Some(self.app_id.as_str()) ||
            files.steamvr_driver.is_some()!=(self.backend==Backend::Steamvr) {
            return Err(io::Error::other("Game profile backend/application ID does not match its registration"));
        }
        Ok(files)
    }
}
fn valid_id(id:&str)->bool { !id.is_empty() && id.len()<=10 && id.bytes().all(|b|b.is_ascii_digit()) && id.parse::<u32>().is_ok_and(|n|n>0) }
pub fn games(root:&Path)->io::Result<Vec<Game>> {
    let path=root.join("windows-games.json");
    if !path.exists(){return Ok(Vec::new());}
    if std::fs::metadata(&path)?.len()>2*1024*1024 {return Err(io::Error::other("Windows XR catalog exceeds 2 MiB"));}
    let games:Vec<Game>=serde_json::from_slice(&std::fs::read(path)?)?;
    let mut seen=std::collections::HashSet::new();
    if games.len()>1000 || games.iter().any(|g|!valid_id(&g.app_id) || !seen.insert(&g.app_id) ||
        g.name.is_empty() || g.name.chars().count()>96 || g.name.chars().any(char::is_control) ||
        [g.monado.as_ref(),g.steamvr.as_ref()].into_iter().flatten().any(|p|!p.is_absolute())) {
        return Err(io::Error::other("Invalid or duplicate Windows XR game registration"));
    }
    Ok(games)
}
fn write(path:&Path,bytes:&[u8])->io::Result<()> {
    use std::io::Write;
    let temporary=path.with_extension(format!("{}.tmp",std::process::id()));
    let mut file=std::fs::OpenOptions::new().create_new(true).write(true).open(&temporary)?;
    let result=(||{file.write_all(bytes)?;file.sync_all()?;drop(file);std::fs::rename(&temporary,path)})();
    if result.is_err(){let _=std::fs::remove_file(temporary);}result
}
pub fn select(root:&Path,id:&str,backend:Backend)->io::Result<()> {
    let mut catalog=games(root)?;
    let game=catalog.iter_mut().find(|g|g.app_id==id).ok_or_else(||io::Error::other("Unknown registered VR game"))?;
    game.backend=backend;game.files()?;
    write(&root.join("windows-games.json"),&serde_json::to_vec_pretty(&catalog)?)
}
struct Launch {root:PathBuf,notice:crate::xr_launch_intent::LaunchNotice,files:Files,completion:Option<std::net::TcpStream>,claimed:bool,expires:Instant}
pub(crate) struct Claimed {pub files:Files,pub completion:Option<std::net::TcpStream>}
static LAUNCH:Mutex<Option<Launch>>=Mutex::new(None);
#[cfg(test)]pub(crate) static TEST_LAUNCH_LOCK:Mutex<()>=Mutex::new(());
static ACTIVE:std::sync::atomic::AtomicBool=std::sync::atomic::AtomicBool::new(false);
pub(crate) struct ActiveSession;
impl ActiveSession {
    pub fn acquire()->io::Result<Self> {
        ACTIVE.compare_exchange(false,true,std::sync::atomic::Ordering::AcqRel,std::sync::atomic::Ordering::Acquire)
            .map_err(|_|io::Error::other("Another Windows XR session is active"))?;Ok(Self)
    }
}
impl Drop for ActiveSession {fn drop(&mut self){ACTIVE.store(false,std::sync::atomic::Ordering::Release);}}
fn queue(slot:&mut Option<Launch>,root:PathBuf,id:String,files:Files)->io::Result<String> {
    if ACTIVE.load(std::sync::atomic::Ordering::Acquire){return Err(io::Error::other("Exit the active XR game before launching another"));}
    if slot.as_ref().is_some_and(|p|p.expires>Instant::now()) {return Err(io::Error::other("Another XR launch is pending; finish or wait for it to expire"));}
    let mut bytes=[0u8;16];ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(),&mut bytes).map_err(|_|io::Error::other("Launch randomness unavailable"))?;
    let generation=bytes.iter().map(|b|format!("{b:02x}")).collect::<String>();
    *slot=Some(Launch {root,notice:crate::xr_launch_intent::LaunchNotice {generation:generation.clone(),app_id:id},files,completion:None,claimed:false,expires:Instant::now()+Duration::from_secs(120)});
    Ok(generation)
}
pub fn pending(root:&Path)->Option<crate::xr_launch_intent::LaunchNotice> {
    LAUNCH.lock().unwrap().as_ref().filter(|p|p.root==root && !p.claimed && p.expires>Instant::now()).map(|p|p.notice.clone())
}
pub fn claim(root:&Path,generation:&str)->bool {
    let mut slot=LAUNCH.lock().unwrap();
    if let Some(p)=slot.as_mut().filter(|p|p.root==root && !p.claimed && p.notice.generation==generation && p.expires>Instant::now()) {p.claimed=true;return true;}false
}
pub(crate) fn claimed_launch(root:&Path,generation:&str)->io::Result<Claimed> {
    let mut slot=LAUNCH.lock().unwrap();
    if !slot.as_ref().is_some_and(|p|p.root==root && p.claimed && p.notice.generation==generation && p.expires>Instant::now()) {
        return Err(io::Error::other("Missing, stale or mismatched Windows game launch"));
    }
    // Consume the host-local snapshot exactly once. Changes to a catalog while
    // a headset prepares cannot change which executable that launch will run.
    let launch=slot.take().unwrap();Ok(Claimed {files:launch.files,completion:launch.completion})
}
/// A driver requests only a SteamVR connection. No executable or argv crosses
/// this channel, and it never launches the game Steam has already started.
pub(crate) fn queue_steamvr(root:&Path)->io::Result<()> {
    let mut slot=LAUNCH.lock().unwrap();
    if ACTIVE.load(std::sync::atomic::Ordering::Acquire) || slot.as_ref().is_some_and(|p|p.expires>Instant::now()) {return Ok(());}
    let shared=root.join("steamvr-runtime");
    let profile=if shared.join("xr-windows.json").is_file() {shared} else {
        games(root)?.into_iter().find_map(|game|game.steamvr)
            .ok_or_else(||io::Error::other("Run Meteor PCVR setup before using the installed driver"))?
    };
    let mut files=crate::xr_session::load(&profile)?;
    if files.steamvr_driver.is_none() || files.steamvr_capture!="direct" {
        return Err(io::Error::other("Automatic SteamVR connection requires direct capture"));
    }
    files.external_steamvr=true;
    queue(&mut slot,root.canonicalize()?,"250820".into(),files)?;
    log::info!("SteamVR requested an authenticated headset connection");
    Ok(())
}
pub(crate) fn cancel_steamvr(root:&Path) {
    let mut slot=LAUNCH.lock().unwrap();
    if slot.as_ref().is_some_and(|p|p.root==root && p.files.external_steamvr) {*slot=None;}
}
/// A cancelled preparation must not leave an unconsumed startup notice claimed
/// for two minutes. Consumed launches and other generations are untouched.
pub(crate) struct StartupClaim {root:Option<PathBuf>,generation:Option<String>}
impl StartupClaim {
    pub(crate) fn new(root:Option<&Path>)->Self {Self {root:root.map(Path::to_path_buf),generation:None}}
    pub(crate) fn set(&mut self,generation:&str) {self.generation=Some(generation.into());}
}
impl Drop for StartupClaim {
    fn drop(&mut self) {
        let (Some(root),Some(generation))=(&self.root,&self.generation) else{return;};
        let mut slot=LAUNCH.lock().unwrap();
        if slot.as_ref().is_some_and(|p|p.root==*root && p.files.external_steamvr && p.claimed && p.notice.generation==*generation) {
            *slot=None;
        }
    }
}
pub(crate) fn queue_steam(root:&Path,launch:crate::xr_steam_windows::Launch,socket:std::net::TcpStream)->io::Result<()> {
    socket.set_nonblocking(true)?;
    let result=(|| {
        let game=games(root)?.into_iter().find(|g|g.app_id==launch.app_id).ok_or_else(||io::Error::other("Register this Steam game in Meteor before using its XR wrapper"))?;
        let mut files=game.files()?;
        files.application=launch.command[0].clone().into();
        let mut arguments=launch.command[1..].to_vec();
        // Steam's explicit flags win; retain required profile defaults only
        // when that option was not supplied (e.g. Moss's -dx11/-hmd=SteamVR).
        for default in files.arguments {
            let key=default.split('=').next().unwrap();
            if !arguments.iter().any(|arg|arg.split('=').next().unwrap().eq_ignore_ascii_case(key)){arguments.push(default);}
        }
        if arguments.len()>64{return Err(io::Error::other("Steam command and profile defaults exceed 64 arguments"));}
        files.arguments=arguments;files.working_directory=Some(launch.cwd);
        let completion=socket.try_clone()?;
        let mut slot=LAUNCH.lock().unwrap();
        queue(&mut slot,root.canonicalize()?,launch.app_id,files)?;
        slot.as_mut().unwrap().completion=Some(completion);
        Ok(())
    })();
    match result {
        Ok(())=>Ok(()),
        Err(error)=>{let mut socket=socket;let _=crate::xr_steam_windows::reject(&mut socket,&error.to_string());Err(error)},
    }
}
pub(crate) fn expire_steam(root:&Path) {
    let mut slot=LAUNCH.lock().unwrap();
    if slot.as_ref().is_some_and(|p|p.root==root && (p.expires<=Instant::now() || p.completion.as_ref().is_some_and(crate::xr_steam_windows::disconnected))) {
        if let Some(mut launch)=slot.take(){if let Some(socket)=launch.completion.as_mut(){let _=crate::xr_steam_windows::reject(socket,"Steam XR launch expired or its wrapper disconnected");}}
    }
}
pub(crate) fn cancel_steam(root:&Path) {
    let mut slot=LAUNCH.lock().unwrap();
    if slot.as_ref().is_some_and(|p|p.root==root && p.completion.is_some()) {
        if let Some(mut launch)=slot.take(){if let Some(socket)=launch.completion.as_mut(){let _=crate::xr_steam_windows::reject(socket,"Meteor stopped before XR was prepared");}}
    }
}
pub fn library(root:&Path,action:&str,key:&str,offset:u32)->Value {
    let run=||->io::Result<Value> {
        if offset>1000 || !matches!(action,"list"|"art"|"launch"|"install_steamvr") {return Err(io::Error::other("Invalid library request"));}
        let catalog=games(root)?;
        if action=="list" {
            let apps:Vec<Value>=catalog.iter().skip(offset as usize).take(4).map(|g| {
                let result=g.files();json!({"key":format!("steam:{}",g.app_id),"name":g.name,"source":"Steam","vr":true,"ready":result.is_ok(),"backend":g.backend,"requires_steamvr":g.backend==Backend::Steamvr && g.requires_steamvr,"error":result.err().map(|e|e.to_string())})
            }).collect();
            return Ok(json!({"action":"list","apps":apps,"offset":offset,"total":catalog.len()}));
        }
        if !crate::xr_library::valid_key(key) {return Err(io::Error::other("Invalid game key"));}
        let game=catalog.iter().find(|g|format!("steam:{}",g.app_id)==key).ok_or_else(||io::Error::other("Choose a host-registered VR game"))?;
        if action=="art" {return Ok(json!({"action":"art","key":key,"image":""}));}
        if game.backend==Backend::Steamvr && game.requires_steamvr {
            if action=="install_steamvr" {
                use std::os::windows::process::CommandExt;
                let script=std::env::current_exe()?.parent().unwrap().join("Install-SteamVR.ps1");
                if !script.is_file(){return Err(io::Error::other("Update Meteor to open SteamVR setup"));}
                std::process::Command::new("powershell.exe").args(["-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File"])
                    .arg(script).arg("-Root").arg(root).creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW).spawn()?;
                return Ok(json!({"action":action,"message":"SteamVR installation opened on your PC. Finish setup there, then refresh VR Apps."}));
            }
            return Ok(json!({"action":action,"error":"This game requires SteamVR. Install it through Steam, then try again.","error_code":"steamvr_required","key":key}));
        }
        if action=="install_steamvr" {return Err(io::Error::other("This game does not require SteamVR setup"));}
        queue(&mut LAUNCH.lock().unwrap(),root.canonicalize()?,game.app_id.clone(),game.files()?)?;
        Ok(json!({"action":"launch","key":key,"message":format!("Starting {}",game.name)}))
    };
    run().unwrap_or_else(|e|json!({"action":action,"error":e.to_string()}))
}

#[derive(Default)]
pub struct State {pub ready:bool,pub error:Option<String>,pub trust:Option<Arc<crate::xr_trust::Trust>>}
static STATE:OnceLock<State>=OnceLock::new();
pub fn initialize(ready:bool,error:Option<String>,trust:Option<Arc<crate::xr_trust::Trust>>) {let _=STATE.set(State {ready,error,trust});}
pub fn state()->&'static State {STATE.get_or_init(State::default)}
pub fn root()->PathBuf {
    let config=crate::config::load();let root=config.xr.runtime_root();
    let imported=root.join("windows");
    if config.xr.runtime_root.is_none() && imported.join("xr-windows.json").is_file(){imported}else{root}
}

pub fn command(args:&[String])->io::Result<String> {
    let option=|name:&str|->io::Result<&str> {args.iter().position(|a|a==name).and_then(|i|args.get(i+1)).map(String::as_str).ok_or_else(||io::Error::other(format!("Missing {name}")))};
    let root=Path::new(option("--root")?);
    if !root.is_absolute(){return Err(io::Error::other("Use an absolute runtime root"));}
    match args[0].as_str() {
        "--xr-windows-host"=>{
            let config=crate::config::load();
            if crate::host::binary(&config).is_none(){return Err(io::Error::other("The bundled Windows host is missing"));}
            let path=crate::config::config_path();
            let original=std::fs::read_to_string(&path).or_else(|e|if e.kind()==io::ErrorKind::NotFound{Ok(String::new())}else{Err(e)})?;
            let mut document:toml_edit::DocumentMut=original.parse().map_err(io::Error::other)?;
            document["host_env"]["METEOR_WINDOWS_MULTIMONITOR"]=toml_edit::value("1");
            std::fs::create_dir_all(path.parent().unwrap())?;
            if path.exists(){let backup=path.with_extension("before-bundled-host.toml");if !backup.exists(){std::fs::copy(&path,backup)?;}}
            write(&path,document.to_string().as_bytes())?;
            let mut state=crate::host::load_state();state.choice=crate::host::Choice::Bundled;
            crate::host::save_state(&state).map_err(io::Error::other)?;
            Ok("Built-in host enabled. Restart Meteor to use it.".into())
        },
        "--xr-windows-require-steamvr"=>{
            let id=option("--app-id")?;let name=option("--name")?;
            if !valid_id(id) || name.is_empty() || name.chars().count()>96 || name.chars().any(char::is_control){return Err(io::Error::other("Invalid game metadata"));}
            let mut catalog=games(root)?;
            if let Some(game)=catalog.iter_mut().find(|g|g.app_id==id) {game.requires_steamvr=true;}
            else {catalog.push(Game {app_id:id.into(),name:name.into(),backend:Backend::Steamvr,monado:None,steamvr:None,requires_steamvr:true});}
            if catalog.len()>1000{return Err(io::Error::other("At most 1000 games can be registered"));}
            std::fs::create_dir_all(root)?;write(&root.join("windows-games.json"),&serde_json::to_vec_pretty(&catalog)?)?;
            Ok("Game will request SteamVR installation when launched.".into())
        },
        "--xr-windows-register"=>{
            let profile=Path::new(option("--profile")?).canonicalize()?;
            let files=crate::xr_session::load(&profile)?;
            let id=files.steam_app_id.clone().filter(|id|valid_id(id)).ok_or_else(||io::Error::other("Profile requires steam_app_id"))?;
            let backend=if files.steamvr_driver.is_some(){Backend::Steamvr}else{Backend::Monado};
            if files.steam_launch {return Err(io::Error::other("Catalog profiles launch configured applications directly; steam_launch must be false"));}
            std::fs::create_dir_all(root)?;
            let mut catalog=games(root)?;
            let index=catalog.iter().position(|g|g.app_id==id).unwrap_or_else(||{catalog.push(Game {app_id:id.clone(),name:String::new(),backend,monado:None,steamvr:None,requires_steamvr:false});catalog.len()-1});
            let game=&mut catalog[index];game.name=option("--name")?.into();
            if game.name.is_empty() || game.name.chars().count()>96 || game.name.chars().any(char::is_control){return Err(io::Error::other("Invalid game name"));}
            match backend {Backend::Monado=>game.monado=Some(profile),Backend::Steamvr=>game.steamvr=Some(profile)}
            if backend==Backend::Steamvr {game.requires_steamvr=false;}
            // Reimport/update must retain the user's saved backend choice.
            if !game.profile(game.backend).is_ok(){game.backend=backend;}
            game.files()?;
            if catalog.len()>1000{return Err(io::Error::other("At most 1000 games can be registered"));}
            if !root.join("xr-windows.json").exists(){write(&root.join("xr-windows.json"),&serde_json::to_vec_pretty(&files)?)?;}
            write(&root.join("windows-games.json"),&serde_json::to_vec_pretty(&catalog)?)?;
            Ok("Game registered. Choose its backend in Meteor's PCVR menu.".into())
        },
        "--xr-windows-enable"=>{
            crate::xr_session::load(root)?;
            let catalog=games(root)?;
            if catalog.is_empty() {
                let files=crate::xr_session::load(&root.join("steamvr-runtime"))?;
                if files.steamvr_driver.is_none(){return Err(io::Error::other("Set up a SteamVR runtime or register a VR game first"));}
            }
            for game in &catalog {if game.backend!=Backend::Steamvr || !game.requires_steamvr {game.files()?;}}
            let path=crate::config::config_path();let original=std::fs::read_to_string(&path).or_else(|e|if e.kind()==io::ErrorKind::NotFound {Ok(String::new())}else{Err(e)})?;
            let _:crate::config::Config=toml::from_str(&original).map_err(io::Error::other)?;
            let mut document:toml_edit::DocumentMut=original.parse().map_err(io::Error::other)?;
            document["xr"]["enabled"]=toml_edit::value(true);document["xr"]["runtime_root"]=toml_edit::value(root.canonicalize()?.to_string_lossy().into_owned());
            std::fs::create_dir_all(path.parent().unwrap())?;
            let backup=path.with_extension("before-windows-xr.toml");if path.exists()&&!backup.exists(){std::fs::copy(&path,backup)?;}
            write(&path,document.to_string().as_bytes())?;
            Ok("PCVR enabled. Restart Meteor, connect Nightfall and approve its code from the PCVR tray menu.".into())
        },
        _=>Err(io::Error::other("Use --xr-windows-register --root <root> --profile <prepared runtime root> --name <game>, or --xr-windows-enable --root <root>")),
    }
}

#[cfg(test)]mod tests {
    use super::*;
    #[test]fn catalog_rejects_remote_paths_and_unknown_games(){
        let root=std::env::temp_dir().join(format!("meteor-catalog-{}",std::process::id()));let _=std::fs::remove_dir_all(&root);std::fs::create_dir_all(&root).unwrap();
        assert!(library(&root,"launch","steam:438100",0).get("error").is_some());
        std::fs::write(root.join("windows-games.json"),br#"[{"app_id":"438100","name":"VRChat","monado":"relative","steamvr":null}]"#).unwrap();
        assert!(games(&root).is_err());std::fs::remove_dir_all(root).unwrap();
    }
    #[test]fn steamvr_activation_is_idempotent_and_never_selects_a_game_command(){
        let _serial=TEST_LAUNCH_LOCK.lock().unwrap();
        let root=std::env::temp_dir().join(format!("meteor-steamvr-activate-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);std::fs::create_dir_all(&root).unwrap();let root=root.canonicalize().unwrap();
        let runtime=root.join("steamvr");let driver=root.join("driver");let profile=root.join("profile");
        for path in [runtime.join("bin/vrclient_x64.dll"),runtime.join("bin/win64/vrstartup.exe"),driver.join("driver.vrdrivermanifest"),driver.join("bin/win64/driver_meteor.dll")] {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();std::fs::write(path,b"fixture").unwrap();
        }
        let exe=std::env::current_exe().unwrap();std::fs::create_dir_all(&profile).unwrap();
        let value=json!({"service":exe,"manifest":exe,"encoder":exe,"tracking":exe,"application":exe,"steam_app_id":"438100","steamvr_driver":driver,"openvr_runtime":runtime,"external_steamvr":true});
        std::fs::write(profile.join("xr-windows.json"),serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(!crate::xr_session::load(&profile).unwrap().external_steamvr);
        std::fs::write(root.join("windows-games.json"),serde_json::to_vec(&json!([{"app_id":"438100","name":"VRChat","steamvr":profile,"monado":null,"backend":"steamvr"}])).unwrap()).unwrap();
        *LAUNCH.lock().unwrap()=None;
        queue_steamvr(&root).unwrap();let first=pending(&root).unwrap();assert_eq!(first.app_id,"250820");
        queue_steamvr(&root).unwrap();assert_eq!(pending(&root).unwrap(),first);
        assert!(claim(&root,&first.generation));let claimed=claimed_launch(&root,&first.generation).unwrap();
        assert!(claimed.files.external_steamvr);assert!(claimed.completion.is_none());
        queue_steamvr(&root).unwrap();
        let cancelled=pending(&root).unwrap();assert!(claim(&root,&cancelled.generation));
        {
            let mut guard=StartupClaim::new(Some(&root));guard.set(&cancelled.generation);
        }
        assert!(pending(&root).is_none());
        queue_steamvr(&root).unwrap();assert_ne!(pending(&root).unwrap().generation,cancelled.generation);
        cancel_steamvr(&root);assert!(pending(&root).is_none());
        // No title-specific registration is needed for an ordinary Steam launch.
        std::fs::remove_file(root.join("windows-games.json")).unwrap();
        let shared=root.join("steamvr-runtime");std::fs::create_dir_all(&shared).unwrap();
        std::fs::write(shared.join("xr-windows.json"),serde_json::to_vec(&value).unwrap()).unwrap();
        queue_steamvr(&root).unwrap();assert_eq!(pending(&root).unwrap().app_id,"250820");
        cancel_steamvr(&root);
        // Generic game profiles accept only this app's VR URL and Steam client.
        let steam=root.join("steam.exe");std::fs::write(&steam,b"fixture").unwrap();
        let mut generic=value.clone();generic["application"]=json!(steam);
        generic["steam_app_id"]=json!("987654");generic["steamvr_launch_via_steam"]=json!(true);
        generic["arguments"]=json!(["steam://launch/987654/VR"]);
        std::fs::write(shared.join("xr-windows.json"),serde_json::to_vec(&generic).unwrap()).unwrap();
        assert!(crate::xr_session::load(&shared).unwrap().steamvr_launch_via_steam);
        generic["arguments"]=json!(["steam://launch/1/VR"]);
        std::fs::write(shared.join("xr-windows.json"),serde_json::to_vec(&generic).unwrap()).unwrap();
        assert!(crate::xr_session::load(&shared).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]fn default_backend_is_monado(){assert_eq!(Backend::default(),Backend::Monado);}
    #[test]fn missing_steamvr_is_a_per_game_requirement_not_a_launch(){
        let root=std::env::temp_dir().join(format!("meteor-missing-steamvr-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);std::fs::create_dir_all(&root).unwrap();let root=root.canonicalize().unwrap();
        command(&["--xr-windows-require-steamvr".into(),"--root".into(),root.to_string_lossy().into_owned(),"--app-id".into(),"438100".into(),"--name".into(),"VRChat".into()]).unwrap();
        let listed=library(&root,"list","",0);assert_eq!(listed["apps"][0]["requires_steamvr"],true);assert_eq!(listed["apps"][0]["ready"],false);
        let launched=library(&root,"launch","steam:438100",0);assert_eq!(launched["error_code"],"steamvr_required");
        assert!(pending(&root).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]fn setup_reimport_retains_selected_backend(){
        let root=std::env::temp_dir().join(format!("meteor-reimport-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);std::fs::create_dir_all(&root).unwrap();
        let root=root.canonicalize().unwrap();
        let runtime=root.join("steamvr");let driver=root.join("driver");
        for path in [runtime.join("bin/vrclient_x64.dll"),runtime.join("bin/win64/vrstartup.exe"),driver.join("driver.vrdrivermanifest"),driver.join("bin/win64/driver_meteor.dll")] {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();std::fs::write(path,b"fixture").unwrap();
        }
        let exe=std::env::current_exe().unwrap();
        let mut files:Files=serde_json::from_value(json!({"service":exe,"manifest":exe,"encoder":exe,"tracking":exe,"application":exe,"steam_app_id":"846470"})).unwrap();
        for backend in [Backend::Monado,Backend::Steamvr] {
            let profile=root.join(if backend==Backend::Monado{"monado"}else{"steamvr-profile"});std::fs::create_dir_all(&profile).unwrap();
            if backend==Backend::Steamvr {files.steamvr_driver=Some(driver.clone());files.openvr_runtime=Some(runtime.clone());}
            std::fs::write(profile.join("xr-windows.json"),serde_json::to_vec(&files).unwrap()).unwrap();
            command(&["--xr-windows-register".into(),"--root".into(),root.to_string_lossy().into_owned(),"--profile".into(),profile.to_string_lossy().into_owned(),"--name".into(),"Fixture".into()]).unwrap();
        }
        select(&root,"846470",Backend::Steamvr).unwrap();
        command(&["--xr-windows-register".into(),"--root".into(),root.to_string_lossy().into_owned(),"--profile".into(),root.join("monado").to_string_lossy().into_owned(),"--name".into(),"Fixture".into()]).unwrap();
        assert_eq!(games(&root).unwrap()[0].backend,Backend::Steamvr);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]fn launch_is_bound_to_root_snapshot_generation_and_one_claim(){
        let _serial=TEST_LAUNCH_LOCK.lock().unwrap();
        let path=std::env::current_exe().unwrap();
        let files:Files=serde_json::from_value(json!({"service":path,"manifest":path,"encoder":path,"tracking":path,"application":path,"steam_app_id":"438100","arguments":["literal & %PATH%"]})).unwrap();
        let root=std::env::temp_dir().canonicalize().unwrap();
        let mut slot=LAUNCH.lock().unwrap();*slot=None;
        let generation=queue(&mut slot,root.clone(),"438100".into(),files.clone()).unwrap();
        assert!(queue(&mut slot,root.clone(),"438100".into(),files).is_err());drop(slot);
        assert!(pending(&root).is_some());assert!(pending(&root.join("other")).is_none());
        assert!(!claim(&root,"wrong"));assert!(!claim(&root.join("other"),&generation));
        assert!(claimed_launch(&root,&generation).is_err());assert!(claim(&root,&generation));
        assert!(pending(&root).is_none());assert!(!claim(&root,&generation));
        assert!(claimed_launch(&root,"wrong").is_err());
        let selected=claimed_launch(&root,&generation).unwrap().files;assert_eq!(selected.arguments,vec!["literal & %PATH%"]);
        assert!(claimed_launch(&root,&generation).is_err());
        let mut slot=LAUNCH.lock().unwrap();queue(&mut slot,root.clone(),"438100".into(),selected).unwrap();
        slot.as_mut().unwrap().expires=Instant::now()-Duration::from_secs(1);drop(slot);
        assert!(pending(&root).is_none());*LAUNCH.lock().unwrap()=None;
    }
}
