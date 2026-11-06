//! Local Steam-command handoff. Remote XR control never supplies executable paths.
use serde::{Deserialize, Serialize};
use std::{io::{self, BufRead, Read, Write}, net::{TcpListener, TcpStream}, path::{Path, PathBuf}, time::{Duration, Instant}};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Ticket { port:u16, token:String, expires_at:u64,#[serde(default)] pid:u32,#[serde(default)] birth:u64 }
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Launch {
    token:String,
    pub command:Vec<String>,
    pub cwd:PathBuf,
    pub app_id:String,
}
fn now()->u64 {std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs()}
fn ticket_path(root:&Path)->PathBuf {root.join("windows-steam-launch.json")}
fn process_birth(pid:u32)->io::Result<u64> {
    use windows_sys::Win32::{Foundation::{CloseHandle,FILETIME},System::Threading::{OpenProcess,GetProcessTimes,PROCESS_QUERY_LIMITED_INFORMATION}};
    let process=unsafe {OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,0,pid)};
    if process.is_null(){return Err(io::Error::last_os_error());}
    let [mut creation,mut exit,mut kernel,mut user]:[FILETIME;4]=unsafe {std::mem::zeroed()};
    let result=unsafe {GetProcessTimes(process,&mut creation,&mut exit,&mut kernel,&mut user)};
    let error=io::Error::last_os_error();unsafe {CloseHandle(process);}
    if result==0{return Err(error);}Ok(((creation.dwHighDateTime as u64)<<32)|creation.dwLowDateTime as u64)
}
fn live(ticket:&Ticket)->bool {
    if ticket.expires_at==0 {ticket.pid>0 && process_birth(ticket.pid).is_ok_and(|birth|birth==ticket.birth)}
    else {ticket.expires_at>now() && ticket.expires_at<=now()+125}
}
fn load_ticket(path:&Path)->io::Result<Ticket> {
    let mut bytes=Vec::new();
    std::fs::File::open(path)?.take(4097).read_to_end(&mut bytes)?;
    if bytes.len()>4096 {return Err(io::Error::other("Steam launch ticket exceeds 4 KiB"));}
    serde_json::from_slice(&bytes).map_err(io::Error::other)
}
fn read_json<T:serde::de::DeserializeOwned>(socket:&TcpStream)->io::Result<T> {
    let mut line=Vec::new();
    io::BufReader::new(socket).take(65537).read_until(b'\n',&mut line)?;
    if line.len()>65536 || line.last()!=Some(&b'\n') {return Err(io::Error::other("Invalid Steam handoff size"));}
    serde_json::from_slice(&line).map_err(io::Error::other)
}
fn send_json(socket:&mut TcpStream,value:&impl Serialize)->io::Result<()> {
    let mut bytes=serde_json::to_vec(value)?;bytes.push(b'\n');
    if bytes.len()>65536 {return Err(io::Error::other("Steam handoff exceeds 64 KiB"));}
    socket.write_all(&bytes)
}
impl Launch {
    fn validate(&self,token:&str,expected_app:Option<&str>)->io::Result<()> {
        let comparison=ring::hmac::Key::new(ring::hmac::HMAC_SHA256,b"Meteor local Steam ticket comparison");
        let expected=ring::hmac::sign(&comparison,token.as_bytes());
        if ring::hmac::verify(&comparison,self.token.as_bytes(),expected.as_ref()).is_err()
            || self.command.is_empty() || self.command.len()>64 || self.command.iter().any(|s|s.len()>4096 || s.contains('\0'))
            || !Path::new(&self.command[0]).is_absolute() || !Path::new(&self.command[0]).is_file()
            || !self.cwd.is_absolute() || !self.cwd.is_dir()
            || self.app_id.parse::<u32>().unwrap_or(0)==0 || expected_app.is_some_and(|id|id!=self.app_id) {
            return Err(io::Error::other("Invalid or mismatched local Steam command"));
        }
        Ok(())
    }
}
pub(crate) struct Pending {listener:TcpListener,path:PathBuf,token:String}
impl Pending {
    pub fn create(root:&Path)->io::Result<Self> {
        Self::create_at(root,"windows-steam-launch.json",false)
    }
    fn create_at(root:&Path,name:&str,broker:bool)->io::Result<Self> {
        let listener=TcpListener::bind("127.0.0.1:0")?;listener.set_nonblocking(true)?;
        let mut random=[0u8;32];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(),&mut random).map_err(|_|io::Error::other("Steam handoff randomness unavailable"))?;
        let token=random.iter().map(|x|format!("{x:02x}")).collect::<String>();
        let path=root.join(name);
        // An existing live ticket belongs to another session. Expired tickets
        // can be removed; a new file is always created exclusively.
        if path.exists() {
            let old=load_ticket(&path)?;
            if live(&old) {return Err(io::Error::other("Another Steam handoff service is already running"));}
            std::fs::remove_file(&path)?;
        }
        let ticket=Ticket {port:listener.local_addr()?.port(),token:token.clone(),expires_at:if broker {0}else{now()+120},pid:std::process::id(),birth:process_birth(std::process::id())?};
        let mut file=std::fs::OpenOptions::new().write(true).create_new(true).open(&path)?;
        file.write_all(&serde_json::to_vec(&ticket)?)?;
        Ok(Self {listener,path,token})
    }
    pub fn poll(&self,expected_app:Option<&str>)->io::Result<Option<(Launch,TcpStream)>> {
        let (socket,_)=match self.listener.accept() {
            Ok(value)=>value,Err(e) if e.kind()==io::ErrorKind::WouldBlock=>return Ok(None),Err(e)=>return Err(e),
        };
        socket.set_read_timeout(Some(Duration::from_secs(2)))?;
        socket.set_write_timeout(Some(Duration::from_secs(2)))?;
        let launch:Launch=read_json(&socket)?;launch.validate(&self.token,expected_app)?;
        Ok(Some((launch,socket)))
    }
}
impl Drop for Pending {
    fn drop(&mut self) {
        if load_ticket(&self.path).is_ok_and(|t|t.token==self.token) {
            let _=std::fs::remove_file(&self.path);
        }
    }
}
pub(crate) fn finish(socket:&mut TcpStream,code:i32)->io::Result<()> {
    socket.set_nonblocking(false)?;socket.set_write_timeout(Some(Duration::from_secs(2)))?;
    send_json(socket,&serde_json::json!({"exit_code":code}))
}
pub(crate) fn reject(socket:&mut TcpStream,error:&str)->io::Result<()> {
    socket.set_nonblocking(false)?;socket.set_write_timeout(Some(Duration::from_secs(2)))?;
    send_json(socket,&serde_json::json!({"exit_code":1,"error":error}))
}
pub(crate) fn disconnected(socket:&TcpStream)->bool {
    if socket.set_nonblocking(true).is_err(){return true;}
    match socket.peek(&mut [0u8;1]) {Ok(0)=>true,Err(e) if e.kind()!=io::ErrorKind::WouldBlock=>true,_=>false}
}

pub(crate) struct Broker {stop:std::sync::Arc<std::sync::atomic::AtomicBool>,worker:Option<std::thread::JoinHandle<()>>}
impl Drop for Broker {
    fn drop(&mut self){self.stop.store(true,std::sync::atomic::Ordering::Release);if let Some(worker)=self.worker.take(){let _=worker.join();}}
}
pub(crate) fn start_broker(root:&Path)->io::Result<Broker> {
    let root=root.canonicalize()?;
    if crate::xr_windows::games(&root)?.is_empty(){return Err(io::Error::other("No registered Steam XR games"));}
    let listener=Pending::create_at(&root,"windows-steam-broker.json",true)?;
    let stop=std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));let quit=stop.clone();
    let worker=std::thread::spawn(move || {
        while !quit.load(std::sync::atomic::Ordering::Acquire) {
            crate::xr_windows::expire_steam(&root);
            match listener.poll(None) {
                Ok(Some((launch,socket)))=>{let id=launch.app_id.clone();match crate::xr_windows::queue_steam(&root,launch,socket){
                    Ok(())=>log::info!("Steam requested native XR catalog app {id}"),Err(e)=>log::warn!("Steam catalog launch rejected: {e}"),
                }},
                Ok(None)=>{},Err(e)=>log::warn!("Local Steam handoff rejected: {e}"),
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        crate::xr_windows::cancel_steam(&root);
    });
    Ok(Broker {stop,worker:Some(worker)})
}

pub(crate) fn wrapper(args:&[String])->io::Result<i32> {
    if args.len()<4 || args[0]!="--root" || args[2]!="--" {return Err(io::Error::other("Usage: --xr-steam-run --root <XR config directory> -- %command%"));}
    let root=Path::new(&args[1]);
    let app_id=std::env::var("SteamAppId").or_else(|_|std::env::var("SteamGameId")).unwrap_or_default();
    request_launch(root,args[3..].to_vec(),std::env::current_dir()?,app_id)
}
pub(crate) fn request_launch(root:&Path,command:Vec<String>,cwd:PathBuf,app_id:String)->io::Result<i32> {
    // Validate the original Steam command before waiting for a service.
    let mut launch=Launch {token:String::new(),command,cwd,app_id};launch.validate("",None)?;
    if desktop_mode(&launch.command) {
        let status=std::process::Command::new(&launch.command[0]).args(&launch.command[1..]).current_dir(&launch.cwd).status()?;
        return Ok(status.code().unwrap_or(1));
    }
    let catalog=root.join("windows-games.json").is_file();
    let path=if catalog {root.join("windows-steam-broker.json")}else{ticket_path(root)};
    let deadline=Instant::now()+Duration::from_secs(120);
    eprintln!("Meteor: waiting for an XR session; connect XR in Nightfall.");
    let ticket=loop {
        if let Ok(ticket)=load_ticket(&path) {
            if live(&ticket) && ticket.port!=0 && ticket.token.len()==64 && ticket.token.bytes().all(|b|b.is_ascii_hexdigit()) {break ticket;}
        }
        if Instant::now()>=deadline {return Err(io::Error::other("No waiting Meteor XR session within 120 seconds"));}
        std::thread::sleep(Duration::from_millis(100));
    };
    launch.token=ticket.token;
    launch.validate(&launch.token,None)?;
    let mut socket=TcpStream::connect_timeout(&format!("127.0.0.1:{}",ticket.port).parse().unwrap(),Duration::from_secs(2))?;
    socket.set_write_timeout(Some(Duration::from_secs(2)))?;
    send_json(&mut socket,&launch)?;
    // EOF means Meteor cancelled or failed; do not silently launch outside XR.
    let reply:serde_json::Value=read_json(&socket)?;
    if let Some(error)=reply["error"].as_str(){return Err(io::Error::other(error.to_owned()));}
    reply["exit_code"].as_i64().and_then(|n|i32::try_from(n).ok()).ok_or_else(||io::Error::other("Invalid Meteor application result"))
}
fn desktop_mode(command:&[String])->bool {
    command.iter().skip(1).any(|arg|arg.eq_ignore_ascii_case("--no-vr") || arg.eq_ignore_ascii_case("-nohmd"))
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn steam_command_is_local_app_bound_and_preserves_literal_arguments() {
        let command=vec![std::env::current_exe().unwrap().to_string_lossy().into_owned(),"space quoted \"argument\" & %PATH%".into()];
        let mut launch=Launch {token:"secret".into(),command,cwd:std::env::current_dir().unwrap(),app_id:"438100".into()};
        assert!(launch.validate("secret",Some("438100")).is_ok());
        assert!(launch.validate("wrong",None).is_err());
        assert!(launch.validate("secret",Some("123")).is_err());
        let json=serde_json::to_vec(&launch).unwrap();let decoded:Launch=serde_json::from_slice(&json).unwrap();
        assert_eq!(decoded.command,launch.command);
        launch.command[0]="relative.exe".into();assert!(launch.validate("secret",None).is_err());
    }
    #[test]fn desktop_mode_requires_an_explicit_argument(){
        assert!(desktop_mode(&["game.exe".into(),"--no-vr".into()]));
        assert!(desktop_mode(&["game.exe".into(),"-NoHmd".into()]));
        assert!(!desktop_mode(&["C:/--no-vr/game.exe".into(),"text --no-vr".into()]));
    }
    #[test]fn broker_ticket_tracks_process_birth_not_just_pid(){
        let ticket=Ticket {port:1,token:"x".repeat(64),expires_at:0,pid:std::process::id(),birth:process_birth(std::process::id()).unwrap()};
        assert!(live(&ticket));let old=Ticket {birth:ticket.birth+1,..ticket};assert!(!live(&old));
    }
    #[test]fn broker_handoff_preserves_command_and_cwd_and_returns_exit_code(){
        let _serial=crate::xr_windows::TEST_LAUNCH_LOCK.lock().unwrap();
        let root=std::env::temp_dir().join(format!("meteor-steam-broker-{}",std::process::id()));
        let _=std::fs::remove_dir_all(&root);std::fs::create_dir_all(root.join("profile")).unwrap();let root=root.canonicalize().unwrap();
        let exe=std::env::current_exe().unwrap();
        std::fs::write(root.join("profile/xr-windows.json"),serde_json::to_vec(&serde_json::json!({"service":exe,"manifest":exe,"encoder":exe,"tracking":exe,"application":exe,"steam_app_id":"438100","arguments":["-hmd=SteamVR","-dx11"]})).unwrap()).unwrap();
        std::fs::write(root.join("windows-games.json"),serde_json::to_vec(&serde_json::json!([{"app_id":"438100","name":"VRChat","monado":root.join("profile"),"steamvr":null}])).unwrap()).unwrap();
        let broker=start_broker(&root).unwrap();
        let working=root.join("profile");let input=vec![exe.to_string_lossy().into_owned(),"literal \"quoted\" & %PATH%".into(),"-hmd=Other".into()];
        let request_root=root.clone();let request_cwd=working.clone();let request_args=input.clone();
        let client=std::thread::spawn(move ||request_launch(&request_root,request_args,request_cwd,"438100".into()));
        let deadline=Instant::now()+Duration::from_secs(5);
        let notice=loop {if let Some(notice)=crate::xr_windows::pending(&root){break notice;}assert!(Instant::now()<deadline);std::thread::sleep(Duration::from_millis(10));};
        assert!(crate::xr_windows::claim(&root,&notice.generation));
        let mut selected=crate::xr_windows::claimed_launch(&root,&notice.generation).unwrap();
        assert_eq!(selected.files.application,exe);assert_eq!(selected.files.working_directory,Some(working));
        assert_eq!(selected.files.arguments,vec![input[1].clone(),"-hmd=Other".into(),"-dx11".into()]);
        finish(selected.completion.as_mut().unwrap(),17).unwrap();assert_eq!(client.join().unwrap().unwrap(),17);
        // Unknown app IDs are rejected without producing a headset launch.
        assert!(request_launch(&root,input,root.clone(),"123".into()).is_err());assert!(crate::xr_windows::pending(&root).is_none());
        drop(broker);assert!(!root.join("windows-steam-broker.json").exists());std::fs::remove_dir_all(root).unwrap();
    }
}
