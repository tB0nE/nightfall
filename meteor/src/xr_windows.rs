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
}
impl Game {
    fn profile(&self,backend:Backend)->io::Result<&Path> {
        match backend {Backend::Monado=>self.monado.as_deref(),Backend::Steamvr=>self.steamvr.as_deref()}
            .ok_or_else(||io::Error::other("This game has no registered profile for that backend"))
    }
    fn files(&self)->io::Result<Files> {
        let files=crate::xr_session::load(self.profile(self.backend)?)?;
        if files.steam_launch || files.steam_app_id.as_deref()!=Some(self.app_id.as_str()) ||
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
    if std::fs::metadata(&path)?.len()>128*1024 {return Err(io::Error::other("Windows XR catalog exceeds 128 KiB"));}
    let games:Vec<Game>=serde_json::from_slice(&std::fs::read(path)?)?;
    let mut seen=std::collections::HashSet::new();
    if games.len()>100 || games.iter().any(|g|!valid_id(&g.app_id) || !seen.insert(&g.app_id) ||
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
        if offset>1000 || !matches!(action,"list"|"art"|"launch") {return Err(io::Error::other("Invalid library request"));}
        let catalog=games(root)?;
        if action=="list" {
            let apps:Vec<Value>=catalog.iter().skip(offset as usize).take(4).map(|g| {
                let result=g.files();json!({"key":format!("steam:{}",g.app_id),"name":g.name,"source":"Steam","vr":true,"ready":result.is_ok(),"backend":g.backend,"error":result.err().map(|e|e.to_string())})
            }).collect();
            return Ok(json!({"action":"list","apps":apps,"offset":offset,"total":catalog.len()}));
        }
        if !crate::xr_library::valid_key(key) {return Err(io::Error::other("Invalid game key"));}
        let game=catalog.iter().find(|g|format!("steam:{}",g.app_id)==key).ok_or_else(||io::Error::other("Choose a host-registered VR game"))?;
        if action=="art" {return Ok(json!({"action":"art","key":key,"image":""}));}
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
        "--xr-windows-register"=>{
            let profile=Path::new(option("--profile")?).canonicalize()?;
            let files=crate::xr_session::load(&profile)?;
            let id=files.steam_app_id.clone().filter(|id|valid_id(id)).ok_or_else(||io::Error::other("Profile requires steam_app_id"))?;
            let backend=if files.steamvr_driver.is_some(){Backend::Steamvr}else{Backend::Monado};
            if files.steam_launch {return Err(io::Error::other("Catalog profiles launch configured applications directly; steam_launch must be false"));}
            std::fs::create_dir_all(root)?;
            let mut catalog=games(root)?;
            let index=catalog.iter().position(|g|g.app_id==id).unwrap_or_else(||{catalog.push(Game {app_id:id.clone(),name:String::new(),backend,monado:None,steamvr:None});catalog.len()-1});
            let game=&mut catalog[index];game.name=option("--name")?.into();
            if game.name.is_empty() || game.name.chars().count()>96 || game.name.chars().any(char::is_control){return Err(io::Error::other("Invalid game name"));}
            match backend {Backend::Monado=>game.monado=Some(profile),Backend::Steamvr=>game.steamvr=Some(profile)}
            // Prefer Monado whenever available, including when adding it later.
            game.backend=if game.monado.is_some(){Backend::Monado}else{Backend::Steamvr};game.files()?;
            if catalog.len()>100{return Err(io::Error::other("At most 100 games can be registered"));}
            if !root.join("xr-windows.json").exists(){write(&root.join("xr-windows.json"),&serde_json::to_vec_pretty(&files)?)?;}
            write(&root.join("windows-games.json"),&serde_json::to_vec_pretty(&catalog)?)?;
            Ok("Game registered. Choose its backend in Meteor's PCVR menu.".into())
        },
        "--xr-windows-enable"=>{
            crate::xr_session::load(root)?;
            let catalog=games(root)?;if catalog.is_empty(){return Err(io::Error::other("Register a VR game first"));}
            for game in &catalog {game.files()?;}
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
    #[test]fn default_backend_is_monado(){assert_eq!(Backend::default(),Backend::Monado);}
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
