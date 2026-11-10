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
        let files=match crate::xr_session::load(root) {
            Ok(files)=>files,
            Err(error)=>return Some(unavailable(&error.to_string())),
        };
        // The encoder DLL picks NVENC or AMF for the GPU, and knows AMF's largest frame.
        let key=format!("{}|{:?}",files.encoder.display(),std::fs::metadata(&files.encoder).ok().and_then(|m|m.modified().ok()));
        if self.key==key {return self.value.clone();}
        self.key=key;
        let encoder=files.encoder.clone();
        let reported=tokio::task::spawn_blocking(move||windows_dll::capabilities(&encoder)).await.ok().flatten();
        self.value=Some(match reported {
            Some(json)=>parse_reported(&json).unwrap_or_else(||unavailable("Invalid encoder capability response")),
            // A DLL from before AMF support reports nothing: NVENC, as it always was.
            None=>Capabilities {backend:"nvenc".into(),foveated_encoding:false,live_bitrate:false,codecs:vec!["h264".into(),"h265".into()],max_frame:None,error:None},
        });
        self.value.clone()
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
/// The Windows encoder DLL's report: {"backend":"nvenc"|"amf","codecs":[...],"max_frame":[w,h]}.
#[cfg_attr(not(windows),allow(dead_code))]
fn parse_reported(json:&str)->Option<Capabilities> {
    #[derive(Deserialize)]
    struct Reported {backend:String,codecs:Vec<String>,#[serde(default)] max_frame:Option<[u32;2]>}
    let reported:Reported=serde_json::from_str(json).ok()?;
    if !matches!(reported.backend.as_str(),"nvenc"|"amf") || reported.codecs.is_empty() {return None;}
    Some(Capabilities {backend:reported.backend,foveated_encoding:false,live_bitrate:false,codecs:reported.codecs,
        max_frame:reported.max_frame.filter(|[w,h]|*w>0 && *h>0),error:None})
}

#[cfg(windows)]
mod windows_dll {
    use std::{os::windows::ffi::OsStrExt,path::Path};
    use windows_sys::Win32::Foundation::FreeLibrary;
    use windows_sys::Win32::System::LibraryLoader::{GetProcAddress,LoadLibraryExW,LOAD_WITH_ALTERED_SEARCH_PATH};

    type CapabilitiesFn=unsafe extern "C" fn(*mut u8,u32)->u32;

    /// Calls meteor_encoder_capabilities_v1; None when the DLL is missing or predates it.
    pub fn capabilities(dll:&Path)->Option<String> {
        let wide:Vec<u16>=dll.as_os_str().encode_wide().chain(Some(0)).collect();
        // SAFETY: a NUL-terminated path; the module is freed below, after the call returns.
        let module=unsafe {LoadLibraryExW(wide.as_ptr(),std::ptr::null_mut(),LOAD_WITH_ALTERED_SEARCH_PATH)};
        if module.is_null() {return None;}
        // SAFETY: the export's signature is fixed by the encoder DLL's ABI.
        let result=unsafe {GetProcAddress(module,c"meteor_encoder_capabilities_v1".as_ptr().cast())}.map(|f|{
            let function:CapabilitiesFn=unsafe {std::mem::transmute(f)};
            let mut buffer=vec![0u8;512];
            let length=unsafe {function(buffer.as_mut_ptr(),buffer.len() as u32)} as usize;
            (length>0 && length<buffer.len()).then(||String::from_utf8_lossy(&buffer[..length]).into_owned())
        }).flatten();
        // SAFETY: nothing from the module outlives this call.
        unsafe {FreeLibrary(module)};
        result
    }
}

fn unavailable(error:&str)->Capabilities {Capabilities{backend:"unavailable".into(),foveated_encoding:false,live_bitrate:false,codecs:vec![],max_frame:None,error:Some(error.into())}}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_windows_encoder_report() {
        let amf=parse_reported(r#"{"backend":"amf","codecs":["h264","h265"],"max_frame":[4096,4096]}"#).unwrap();
        assert_eq!(amf.backend,"amf");
        assert_eq!(amf.max_frame,Some([4096,4096]));
        assert!(amf.fits_eyes(2048,2048) && !amf.fits_eyes(2064,2208));
        let nvenc=parse_reported(r#"{"backend":"nvenc","codecs":["h264","h265"]}"#).unwrap();
        assert_eq!(nvenc.max_frame,None);
        assert!(nvenc.fits_eyes(4096,4096));
        assert!(parse_reported(r#"{"backend":"amf","codecs":[]}"#).is_none());
        assert!(parse_reported("not json").is_none());
    }
}
