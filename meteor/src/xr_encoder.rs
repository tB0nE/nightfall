//! Capabilities come from the same packaged selector that starts the runtime.
use serde::{Deserialize,Serialize};
use std::{path::Path,time::Duration};

#[derive(Clone,Debug,PartialEq,Serialize,Deserialize)]
pub struct Capabilities {
    pub backend:String,
    pub foveated_encoding:bool,
    pub live_bitrate:bool,
    pub codecs:Vec<String>,
    /// The largest frame (width, height) the encoder takes. Both eyes share one frame side by
    /// side, so the headset offers eyes that fit; None when unknown (no limit is applied).
    #[serde(default,skip_serializing_if="Option::is_none")]
    pub max_frame:Option<[u32;2]>,
    #[serde(default,skip_serializing_if="Option::is_none")]
    pub error:Option<String>,
}
impl Capabilities {
    /// Whether a stereo frame of two eyes this size fits the encoder.
    pub fn fits_eyes(&self,width:u32,height:u32)->bool {
        self.max_frame.is_none_or(|[w,h]|width.saturating_mul(2)<=w && height<=h)
    }
}
#[derive(Default)]
pub struct Monitor {key:String,value:Option<Capabilities>}
impl Monitor {
    #[cfg(windows)]
    pub async fn refresh(&mut self,root:Option<&Path>) -> Option<Capabilities> {
        let root=root?;
        Some(match crate::xr_session::load(root) {
            Ok(_)=>Capabilities {backend:"nvenc".into(),foveated_encoding:false,live_bitrate:false,codecs:vec!["h264".into(),"h265".into()],max_frame:None,error:None},
            Err(error)=>unavailable(&error.to_string()),
        })
    }
    #[cfg(not(windows))]
    pub async fn refresh(&mut self,root:Option<&Path>) -> Option<Capabilities> {
        let root=root?;
        let manifest=root.join("xr-runtime/manifest.json");
        if !manifest.is_file() {return None;}
        let config=crate::config::load().xr;
        let key=format!("{}|{:?}|{:?}",config.encoder_backend,config.render_device,std::fs::metadata(&manifest).ok().and_then(|m|m.modified().ok()));
        if self.key==key {return self.value.clone();}
        self.key=key;
        let mut command=tokio::process::Command::new("/usr/bin/python3");
        command.arg(root.join("tools/meteor_xr_runtime.py")).arg("--capabilities")
            .env("NIGHTFALL_XR_ENCODER_BACKEND",config.encoder_backend)
            .env_remove("NIGHTFALL_XR_RENDER_DEVICE").kill_on_drop(true);
        if let Some(node)=config.render_device {command.env("NIGHTFALL_XR_RENDER_DEVICE",node);}
        let result=tokio::time::timeout(Duration::from_secs(3),command.output()).await;
        self.value=Some(match result {
            Ok(Ok(output)) if output.status.success()=>String::from_utf8_lossy(&output.stdout).lines().last()
                .and_then(|line|serde_json::from_str(line).ok()).unwrap_or_else(||unavailable("Invalid encoder capability response")),
            Ok(Ok(output))=>unavailable(&String::from_utf8_lossy(&output.stderr).lines().last().unwrap_or("Encoder unavailable").chars().take(200).collect::<String>()),
            _=>unavailable("Encoder capability query failed or timed out"),
        });
        self.value.clone()
    }
}
fn unavailable(error:&str)->Capabilities {Capabilities{backend:"unavailable".into(),foveated_encoding:false,live_bitrate:false,codecs:vec![],max_frame:None,error:Some(error.into())}}
