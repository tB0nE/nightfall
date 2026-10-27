//! Linux host-local Steam launch intent. No remote argv or executable selection.
use serde::{Deserialize,Serialize};
use std::{fs,io,path::Path,time::{SystemTime,UNIX_EPOCH}};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt,PermissionsExt};

#[derive(Debug,Clone,Serialize,Deserialize,PartialEq)]
pub struct LaunchNotice { pub generation:String, pub app_id:String }

#[derive(Serialize,Deserialize)]
#[serde(deny_unknown_fields)]
struct Intent { generation:String,app_id:String,pid:u32,start_ticks:u64,expires_at:f64,state:String }

#[cfg(target_os="linux")]
fn load(root:&Path) -> io::Result<Option<Intent>> {
    let directory=root.join(".build-cache/meteor-xr/auto-launch");
    let path=directory.join("intent.json");
    let Ok(meta)=fs::symlink_metadata(&path) else { return Ok(None) };
    let parent=fs::symlink_metadata(&directory)?;
    let uid=unsafe {libc::geteuid()};
    if !parent.is_dir() || parent.uid()!=uid || parent.permissions().mode()&0o077!=0
        || !meta.is_file() || meta.uid()!=uid || meta.permissions().mode()&0o077!=0 || meta.len()>4096 { return Ok(None) }
    let value:Intent=serde_json::from_slice(&fs::read(&path)?)?;
    let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64();
    if !value.expires_at.is_finite() || value.expires_at<=now || value.expires_at>now+125.0
        || value.pid<=1 || value.generation.len()!=32 || !value.generation.bytes().all(|c|c.is_ascii_hexdigit())
        || value.app_id.parse::<u32>().unwrap_or(0)==0 { return Ok(None) }
    let Ok(stat)=fs::read_to_string(format!("/proc/{}/stat",value.pid)) else {return Ok(None)};
    let birth=stat.rsplit_once(") ").and_then(|(_,fields)|fields.split_whitespace().nth(19)).and_then(|v|v.parse::<u64>().ok());
    if birth!=Some(value.start_ticks) {return Ok(None)}
    let config_path=root.join(".build-cache/meteor-xr/application.json");
    if fs::metadata(&config_path)?.len()>16384 {return Ok(None)}
    let config:serde_json::Value=serde_json::from_slice(&fs::read(config_path)?)?;
    if config["launch"]!="steam" || (config["steam_app_id"]!=value.app_id && config["steam_app_id"]!="*") {return Ok(None)}
    Ok(Some(value))
}

pub fn pending(root:&Path) -> Option<LaunchNotice> {
    #[cfg(target_os="linux")]
    if let Ok(Some(value))=load(root) {
        if value.state=="pending" {return Some(LaunchNotice {generation:value.generation,app_id:value.app_id})}
    }
    let _=root;
    None
}

/// Resolve a wildcard template only from the live, already claimed local launch.
pub(crate) fn claimed_app_id(root:&Path,generation:&str) -> io::Result<String> {
    #[cfg(target_os="linux")]
    if let Some(value)=load(root)? {
        if value.state=="claimed" && value.generation==generation {return Ok(value.app_id)}
    }
    Err(io::Error::other("missing or stale claimed Steam launch"))
}

pub fn claim(root:&Path,generation:&str) -> bool {
    #[cfg(target_os="linux")]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let Ok(Some(mut value))=load(root) else {return false};
        if value.state!="pending" || value.generation!=generation {return false}
        value.state="claimed".into();
        let directory=root.join(".build-cache/meteor-xr/auto-launch");
        let temporary=directory.join(format!("claim-{generation}.json"));
        let result=(|| -> io::Result<()> {
            let mut file=fs::OpenOptions::new().create_new(true).write(true).mode(0o600).open(&temporary)?;
            file.write_all(&serde_json::to_vec(&value)?)?;
            fs::rename(&temporary,directory.join("intent.json"))?;
            Ok(())
        })();
        if result.is_err() {let _=fs::remove_file(temporary);}
        return result.is_ok();
    }
    #[cfg(not(target_os="linux"))]
    {let _=(root,generation); false}
}

#[cfg(all(test,target_os="linux"))]
mod tests {
    use super::*;
    #[test]
    fn xr_launch_intent_is_private_live_app_bound_and_single_use() {
        let root=std::env::temp_dir().join(format!("meteor-auto-intent-{}-{}",std::process::id(),SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()));
        let directory=root.join(".build-cache/meteor-xr/auto-launch");
        fs::create_dir_all(&directory).unwrap();
        fs::set_permissions(&directory,fs::Permissions::from_mode(0o700)).unwrap();
        let config=directory.parent().unwrap().join("application.json");
        fs::write(&config,br#"{"launch":"steam","steam_app_id":"438100"}"#).unwrap();
        let stat=fs::read_to_string("/proc/self/stat").unwrap();
        let birth=stat.rsplit_once(") ").unwrap().1.split_whitespace().nth(19).unwrap().parse().unwrap();
        let mut value=Intent {generation:"a".repeat(32),app_id:"438100".into(),pid:std::process::id(),start_ticks:birth,expires_at:SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()+120.0,state:"pending".into()};
        let path=directory.join("intent.json");
        fs::write(&path,serde_json::to_vec(&value).unwrap()).unwrap();
        fs::set_permissions(&path,fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(pending(&root).unwrap().app_id,"438100");
        assert!(!claim(&root,&"b".repeat(32)));
        assert!(claim(&root,&value.generation));
        assert!(pending(&root).is_none());
        assert!(!claim(&root,&value.generation));
        value.state="pending".into(); value.start_ticks+=1;
        fs::write(&path,serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(pending(&root).is_none());
        value.start_ticks=birth; value.expires_at=0.0;
        fs::write(&path,serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(pending(&root).is_none());
        value.expires_at=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs_f64()+120.0;
        fs::write(&path,serde_json::to_vec(&value).unwrap()).unwrap();
        fs::set_permissions(&path,fs::Permissions::from_mode(0o644)).unwrap();
        assert!(pending(&root).is_none());
        fs::set_permissions(&path,fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(&config,br#"{"launch":"steam","steam_app_id":"123"}"#).unwrap();
        assert!(pending(&root).is_none());
        fs::write(&config,br#"{"launch":"steam","steam_app_id":"*"}"#).unwrap();
        value.app_id="546560".into();
        fs::write(&path,serde_json::to_vec(&value).unwrap()).unwrap();
        assert_eq!(pending(&root).unwrap().app_id,"546560");
        assert!(claimed_app_id(&root,&value.generation).is_err());
        assert!(claim(&root,&value.generation));
        assert_eq!(claimed_app_id(&root,&value.generation).unwrap(),"546560");
        assert!(claimed_app_id(&root,&"b".repeat(32)).is_err());
        let output=directory.parent().unwrap().join("session");
        fs::create_dir(&output).unwrap();
        assert!(crate::xr_session::session_application(&root,&config,&output,None).is_err());
        let snapshot=crate::xr_session::session_application(&root,&config,&output,Some(&value.generation)).unwrap();
        let frozen:serde_json::Value=serde_json::from_slice(&fs::read(&snapshot).unwrap()).unwrap();
        assert_eq!(frozen["steam_app_id"],"546560");
        assert_eq!(fs::metadata(&snapshot).unwrap().permissions().mode()&0o777,0o600);
        fs::write(&config,br#"{"launch":"steam","steam_app_id":"438100"}"#).unwrap();
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&fs::read(snapshot).unwrap()).unwrap(),frozen);
        fs::remove_dir_all(root).unwrap();
    }
}
