//! One bounded, coalesced encoder command per authenticated XR session.
use serde::{Deserialize, Serialize};
use std::{fs, io, path::PathBuf, sync::{Arc, Mutex}};
pub(crate) type RuntimeDirectory = Arc<Mutex<Option<PathBuf>>>;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Status {
    pub sequence: u64,
    pub requested_enabled: u32,
    pub applied_enabled: Option<u32>,
    pub state: String,
    pub error: Option<String>,
}
#[derive(Default)]
pub(crate) struct Control {
    pub directory: RuntimeDirectory,
    sequence: u64,
    requested: u32,
}
impl Control {
    pub fn queue(&mut self, enabled: u32) -> io::Result<()> {
        if enabled > 1 {return Err(io::Error::other("unsupported_foveation"));}
        let directory=self.directory.lock().unwrap().clone().ok_or_else(||io::Error::other("runtime_not_ready"))?;
        let next=self.sequence.checked_add(1).ok_or_else(||io::Error::other("foveation_counter_exhausted"))?;
        let temporary=directory.join("foveation-request.tmp");
        fs::write(&temporary,format!("{next} {enabled}\n"))?;
        fs::rename(temporary,directory.join("foveation-request"))?;
        self.sequence=next; self.requested=enabled;
        Ok(())
    }
    pub fn status(&self) -> Option<Status> {
        if self.sequence==0 {return None;}
        let mut status=Status {sequence:self.sequence,requested_enabled:self.requested,
            applied_enabled:None,state:"pending".into(),error:None};
        let directory=self.directory.lock().unwrap().clone()?;
        let path=directory.join("foveation-ack");
        if !fs::metadata(&path).is_ok_and(|m|m.is_file() && m.len()<=128) {return Some(status);}
        let Ok(text)=fs::read_to_string(path) else {return Some(status);};
        let fields:Vec<_>=text.split_whitespace().collect();
        if fields.len()!=4 {return Some(status);}
        let parsed=(fields[0].parse::<u64>(),fields[1].parse::<u32>(),fields[2].parse::<u32>(),fields[3].parse::<u32>());
        if let (Ok(sequence),Ok(requested),Ok(applied),Ok(code))=parsed {
            if sequence==self.sequence && requested==self.requested && applied<=1 {
                status.applied_enabled=Some(applied);
                status.state=if code==0 {"applied"} else {"rejected"}.into();
                if code!=0 {status.error=Some(format!("NVENC reconfiguration error {code}"));}
            }
        }
        Some(status)
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn xr_foveation_latest_choice_and_off_ack_are_validated() {
        let root=std::env::temp_dir().join(format!("meteor-foveation-{}",std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let mut control=Control::default();
        assert!(control.queue(1).is_err());
        *control.directory.lock().unwrap()=Some(root.clone());
        assert!(control.queue(2).is_err());
        control.queue(1).unwrap(); control.queue(0).unwrap();
        assert_eq!(fs::read_to_string(root.join("foveation-request")).unwrap(),"2 0\n");
        fs::write(root.join("foveation-ack"),"1 1 1 0\n").unwrap();
        assert_eq!(control.status().unwrap().state,"pending");
        fs::write(root.join("foveation-ack"),"2 0 0 0\n").unwrap();
        let status=control.status().unwrap();
        assert_eq!(status.state,"applied"); assert_eq!(status.applied_enabled,Some(0));
        fs::remove_dir_all(root).unwrap();
    }
}
