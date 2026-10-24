//! One bounded, coalesced encoder command per authenticated XR session.
use serde::{Deserialize, Serialize};
use std::{fs, io, path::PathBuf, sync::{Arc, Mutex}};
pub(crate) type RuntimeDirectory = Arc<Mutex<Option<PathBuf>>>;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Status {
    pub sequence: u64,
    pub requested_mbps: u32,
    pub applied_bps: Option<u32>,
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
    pub fn queue(&mut self, mbps: u32) -> io::Result<()> {
        if mbps != 0 && !(8..=160).contains(&mbps) {return Err(io::Error::other("unsupported_bitrate"));}
        let directory=self.directory.lock().unwrap().clone().ok_or_else(||io::Error::other("runtime_not_ready"))?;
        let next=self.sequence.checked_add(1).ok_or_else(||io::Error::other("bitrate_counter_exhausted"))?;
        let temporary=directory.join("bitrate-request.tmp");
        fs::write(&temporary,format!("{next} {mbps}\n"))?;
        fs::rename(temporary,directory.join("bitrate-request"))?;
        self.sequence=next; self.requested=mbps;
        Ok(())
    }
    pub fn status(&self) -> Option<Status> {
        if self.sequence==0 {return None;}
        let mut status=Status {sequence:self.sequence,requested_mbps:self.requested,
            applied_bps:None,state:"pending".into(),error:None};
        let directory=self.directory.lock().unwrap().clone()?;
        let path=directory.join("bitrate-ack");
        if !fs::metadata(&path).is_ok_and(|m|m.is_file() && m.len()<=128) {return Some(status);}
        let Ok(text)=fs::read_to_string(path) else {return Some(status);};
        let fields:Vec<_>=text.split_whitespace().collect();
        if fields.len()!=4 {return Some(status);}
        let parsed=(fields[0].parse::<u64>(),fields[1].parse::<u32>(),fields[2].parse::<u32>(),fields[3].parse::<u32>());
        if let (Ok(sequence),Ok(requested),Ok(applied),Ok(code))=parsed {
            if sequence==self.sequence && requested==self.requested && applied>0 {
                status.applied_bps=Some(applied);
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
    fn xr_bitrate_commands_are_bounded_coalesced_and_acknowledged() {
        let directory=std::env::temp_dir().join(format!("meteor-bitrate-{}-{}",std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir(&directory).unwrap();
        let mut control=Control::default();
        assert!(control.queue(80).is_err());
        *control.directory.lock().unwrap()=Some(directory.clone());
        assert!(control.queue(161).is_err());
        control.queue(32).unwrap(); control.queue(80).unwrap();
        assert_eq!(fs::read_to_string(directory.join("bitrate-request")).unwrap(),"2 80\n");
        fs::write(directory.join("bitrate-ack"),"1 32 32000000 0\n").unwrap();
        assert_eq!(control.status().unwrap().state,"pending");
        fs::write(directory.join("bitrate-ack"),"2 80 80000000 0\n").unwrap();
        assert_eq!(control.status().unwrap().applied_bps,Some(80_000_000));
        control.queue(0).unwrap();
        fs::write(directory.join("bitrate-ack"),"3 0 80000000 12\n").unwrap();
        assert_eq!(control.status().unwrap().state,"rejected");
        assert_eq!(control.status().unwrap().applied_bps,Some(80_000_000));
        fs::remove_file(directory.join("bitrate-request")).unwrap();
        fs::remove_file(directory.join("bitrate-ack")).unwrap(); fs::remove_dir(directory).unwrap();
    }
}
