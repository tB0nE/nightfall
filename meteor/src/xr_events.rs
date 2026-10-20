//! DEV runtime-origin events, not IPC readiness or proof of a presented frame.
use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, fs::File, io::{self, Read, Seek, SeekFrom}, path::Path};

const PREFIX: &[u8] = b"METEOR_XR_EVENT ";
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Event { generation: String, sequence: u64, session: u64, event: State }
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
enum State { Created, Begun, Ended, Destroyed }

pub(crate) struct Observer {
    generation: String,
    sequence: u64,
    sessions: BTreeMap<u64, State>,
    offset: u64,
    pending: Vec<u8>,
    pub(crate) saw_begin: bool,
}
impl Observer {
    pub(crate) fn new(generation: String) -> Self {
        Self { generation, sequence: 0, sessions: BTreeMap::new(), offset: 0, pending: Vec::new(), saw_begin: false }
    }
    fn line(&mut self, line: &[u8]) -> io::Result<()> {
        let Some(payload) = line.strip_prefix(PREFIX) else { return Ok(()); };
        let event: Event = serde_json::from_slice(payload).map_err(io::Error::other)?;
        if event.generation != self.generation || event.sequence != self.sequence + 1 || event.session == 0 {
            return Err(io::Error::other("stale or out-of-order XR runtime event"));
        }
        let previous = self.sessions.get(&event.session).copied();
        let valid = match (previous, event.event) {
            (None, State::Created) => self.sessions.len() < 128,
            (Some(State::Created | State::Ended), State::Begun) => true,
            (Some(State::Begun), State::Ended) => true,
            (Some(State::Created | State::Begun | State::Ended), State::Destroyed) => true,
            _ => false,
        };
        if !valid { return Err(io::Error::other("invalid XR runtime session transition")); }
        self.sequence = event.sequence;
        self.saw_begin |= event.event == State::Begun;
        self.sessions.insert(event.session, event.event);
        log::info!("XR runtime session {} {:?} (event {})", event.session, event.event, event.sequence);
        Ok(())
    }
    /// One bounded read per supervisor tick; fragmented lines remain pending.
    pub(crate) fn poll(&mut self, path: &Path) -> io::Result<usize> {
        let mut file = match File::open(path) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound && self.offset == 0 => return Ok(0),
            Err(error) => return Err(error),
        };
        if file.metadata()?.len() < self.offset { return Err(io::Error::other("runtime event log truncated")); }
        file.seek(SeekFrom::Start(self.offset))?;
        let mut bytes = Vec::new();
        file.take(65536).read_to_end(&mut bytes)?;
        self.offset += bytes.len() as u64;
        for byte in &bytes {
            if *byte == b'\n' {
                let line = std::mem::take(&mut self.pending);
                self.line(&line)?;
            } else {
                if self.pending.len() >= 8192 { return Err(io::Error::other("runtime log line exceeds event bound")); }
                self.pending.push(*byte);
            }
        }
        Ok(bytes.len())
    }
    pub(crate) fn snapshot(&self) -> serde_json::Value {
        serde_json::json!({"generation":self.generation,"sequence":self.sequence,
            "application_session_observed":self.saw_begin,"sessions":self.sessions})
    }
    pub(crate) fn finish(&mut self, path: &Path) -> io::Result<()> {
        while self.poll(path)? != 0 {}
        if self.pending.starts_with(PREFIX) {
            return Err(io::Error::other("truncated runtime event at shutdown"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn line(generation: &str, sequence: u64, event: &str) -> Vec<u8> {
        format!("METEOR_XR_EVENT {{\"generation\":\"{generation}\",\"sequence\":{sequence},\"session\":1,\"event\":\"{event}\"}}").into_bytes()
    }
    #[test]
    fn session_events_are_distinct_from_readiness() {
        let mut observer = Observer::new("current".into());
        observer.line(b"IPC ready").unwrap();
        observer.line(&line("current",1,"created")).unwrap();
        assert!(!observer.saw_begin);
        observer.line(&line("current",2,"begun")).unwrap();
        assert!(observer.saw_begin);
        observer.line(&line("current",3,"ended")).unwrap();
        observer.line(&line("current",4,"begun")).unwrap();
        observer.line(&line("current",5,"destroyed")).unwrap();
        assert!(observer.line(&line("current",6,"begun")).is_err());
    }
    #[test]
    fn stale_replayed_and_out_of_order_events_are_rejected() {
        let mut observer = Observer::new("current".into());
        assert!(observer.line(&line("old",1,"created")).is_err());
        assert!(observer.line(&line("current",2,"created")).is_err());
        assert!(observer.line(&line("current",1,"begun")).is_err());
        observer.line(&line("current",1,"created")).unwrap();
        assert!(observer.line(&line("current",1,"created")).is_err());
    }
    #[test]
    fn malformed_events_cannot_advance_state() {
        let mut observer = Observer::new("current".into());
        for invalid in [b"METEOR_XR_EVENT {".as_slice(), b"METEOR_XR_EVENT {}"] {
            assert!(observer.line(invalid).is_err());
        }
        assert_eq!(observer.sequence, 0);
    }
    #[test]
    fn partial_lines_wait_and_truncation_fails() {
        let path = std::env::temp_dir().join(format!("xr-event-test-{}", std::process::id()));
        let mut observer = Observer::new("current".into());
        let mut bytes = line("current",1,"created");
        std::fs::write(&path,&bytes).unwrap();
        observer.poll(&path).unwrap();
        assert_eq!(observer.sequence,0);
        bytes.push(b'\n');
        std::fs::write(&path,&bytes).unwrap();
        observer.poll(&path).unwrap();
        assert_eq!(observer.sequence,1);
        std::fs::write(&path,b"").unwrap();
        assert!(observer.poll(&path).is_err());
        std::fs::remove_file(path).unwrap();
    }
}
