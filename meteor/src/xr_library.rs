//! Bounded catalog requests on the existing authenticated control connection.
use std::{io,path::{Path, PathBuf},process::Stdio, sync::OnceLock};
static RUNTIME_ROOT: OnceLock<PathBuf> = OnceLock::new();
pub fn set_runtime_root(root: PathBuf) { let _ = RUNTIME_ROOT.set(root); }
pub fn steam_launch_options() -> io::Result<String> {
    let root = RUNTIME_ROOT.get().ok_or_else(|| io::Error::other("Install and enable Meteor XR first"))?;
    Ok(launch_options_for(root))
}
fn launch_options_for(root: &Path) -> String {
    let wrapper = root.join("tools/meteor_xr.py").to_string_lossy().replace('\'', "'\"'\"'");
    format!("/usr/bin/python3 '{wrapper}' steam-run --app-id auto --wait 120 -- %command%")
}
use serde_json::{Value,json};

pub async fn request(root:&Path,action:&str,key:&str,offset:u32)->Value {
    if !matches!(action,"list"|"art"|"launch") || offset>1000 ||
        (action!="list" && !valid_key(key)) {return json!({"action":action,"error":"Invalid library request"})}
    let python=root.join(".build-cache/model-tester-venv/bin/python");
    let mut command=tokio::process::Command::new(if python.is_file(){python}else{"/usr/bin/python3".into()});
    command.arg(root.join("tools/meteor_vr_library.py")).args([action,"--key",key,"--offset",&offset.to_string()]);
    command.stdin(Stdio::null()).stderr(Stdio::null()).kill_on_drop(true);
    match tokio::time::timeout(std::time::Duration::from_secs(4),command.output()).await {
        Ok(Ok(output)) if output.status.success() && output.stdout.len()<=3000=>
            serde_json::from_slice(&output.stdout).unwrap_or_else(|_|json!({"action":action,"error":"Invalid host library response"})),
        _=>json!({"action":action,"error":"Host library request failed or timed out"}),
    }
}
pub fn valid_key(key:&str)->bool {
    key.split_once(':').is_some_and(|(source,id)|source=="steam" && id.len()<=10 && id.bytes().all(|x|x.is_ascii_digit()) && id.parse::<u32>().is_ok_and(|x|x>0))
}
pub fn request_open()->io::Result<()> {
    let root=RUNTIME_ROOT.get().ok_or_else(||io::Error::other("Managed XR service is not configured"))?;
    let directory=root.join(".build-cache/meteor-xr");std::fs::create_dir_all(&directory)?;
    std::fs::write(directory.join("open-library"),b"open\n")
}
pub fn take_open(root:&Path)->bool {std::fs::remove_file(root.join(".build-cache/meteor-xr/open-library")).is_ok()}
#[cfg(test)] mod tests {
    #[test] fn universal_steam_options_quote_the_installed_wrapper() {
        let options=super::launch_options_for(std::path::Path::new("/home/Ty's Apps/xr"));
        assert_eq!(options,"/usr/bin/python3 '/home/Ty'\"'\"'s Apps/xr/tools/meteor_xr.py' steam-run --app-id auto --wait 120 -- %command%");
    }
    #[test] fn library_keys_cannot_select_commands_or_paths(){
        for key in ["steam:546560","steam:438100"] {assert!(super::valid_key(key));}
        for key in ["steam:0","steam:../../etc","lutris:8;id","other:1","steam:4294967296"] {assert!(!super::valid_key(key));}
    }
}
