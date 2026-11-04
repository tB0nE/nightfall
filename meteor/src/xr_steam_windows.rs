//! Local Steam-command handoff. Remote XR control never supplies executable paths.
use serde::{Deserialize, Serialize};
use std::{io::{self, BufRead, Read, Write}, net::{TcpListener, TcpStream}, path::{Path, PathBuf}, time::{Duration, Instant}};

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Ticket { port:u16, token:String, expires_at:u64 }
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
        let listener=TcpListener::bind("127.0.0.1:0")?;listener.set_nonblocking(true)?;
        let mut random=[0u8;32];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(),&mut random).map_err(|_|io::Error::other("Steam handoff randomness unavailable"))?;
        let token=random.iter().map(|x|format!("{x:02x}")).collect::<String>();
        let path=ticket_path(root);
        // An existing live ticket belongs to another session. Expired tickets
        // can be removed; a new file is always created exclusively.
        if path.exists() {
            let old=load_ticket(&path)?;
            if old.expires_at>now() {return Err(io::Error::other("Another Steam launch is waiting"));}
            std::fs::remove_file(&path)?;
        }
        let ticket=Ticket {port:listener.local_addr()?.port(),token:token.clone(),expires_at:now()+120};
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
pub(crate) fn finish(socket:&mut TcpStream,code:i32)->io::Result<()> {send_json(socket,&serde_json::json!({"exit_code":code}))}

pub(crate) fn wrapper(args:&[String])->io::Result<i32> {
    if args.len()<4 || args[0]!="--root" || args[2]!="--" {return Err(io::Error::other("Usage: --xr-steam-run --root <XR config directory> -- %command%"));}
    let root=Path::new(&args[1]);
    let deadline=Instant::now()+Duration::from_secs(120);
    eprintln!("Meteor: waiting for an XR session; connect XR in Nightfall.");
    let ticket=loop {
        if let Ok(ticket)=load_ticket(&ticket_path(root)) {
            if ticket.expires_at>now() && ticket.expires_at<=now()+125 && ticket.port!=0 && ticket.token.len()==64 {break ticket;}
        }
        if Instant::now()>=deadline {return Err(io::Error::other("No waiting Meteor XR session within 120 seconds"));}
        std::thread::sleep(Duration::from_millis(100));
    };
    let launch=Launch {token:ticket.token,command:args[3..].to_vec(),cwd:std::env::current_dir()?,app_id:std::env::var("SteamAppId").or_else(|_|std::env::var("SteamGameId")).unwrap_or_default()};
    launch.validate(&launch.token,None)?;
    let mut socket=TcpStream::connect_timeout(&format!("127.0.0.1:{}",ticket.port).parse().unwrap(),Duration::from_secs(2))?;
    socket.set_write_timeout(Some(Duration::from_secs(2)))?;
    send_json(&mut socket,&launch)?;
    // EOF means Meteor cancelled or failed; do not silently launch outside XR.
    let reply:serde_json::Value=read_json(&socket)?;
    reply["exit_code"].as_i64().and_then(|n|i32::try_from(n).ok()).ok_or_else(||io::Error::other("Invalid Meteor application result"))
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
}
