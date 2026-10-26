//! Bounded catalog requests on the existing authenticated control connection.
use std::{io,path::Path,process::Stdio};
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
    let root=Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let directory=root.join(".build-cache/meteor-xr");std::fs::create_dir_all(&directory)?;
    std::fs::write(directory.join("open-library"),b"open\n")
}
pub fn take_open(root:&Path)->bool {std::fs::remove_file(root.join(".build-cache/meteor-xr/open-library")).is_ok()}
#[cfg(test)] mod tests {
    #[test] fn library_keys_cannot_select_commands_or_paths(){
        for key in ["steam:546560","steam:438100"] {assert!(super::valid_key(key));}
        for key in ["steam:0","steam:../../etc","lutris:8;id","other:1","steam:4294967296"] {assert!(!super::valid_key(key));}
    }
}
