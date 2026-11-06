//! Encrypted PIN handoff. A network request never authorizes a client itself:
//! only a local notification/tray approval submits the PIN to our managed host.
use std::{collections::VecDeque, net::IpAddr, sync::{Arc, Mutex}, time::{Duration, Instant, SystemTime, UNIX_EPOCH}};
use serde::Deserialize;
use super::{State, Supervisor};

pub const INFO: &[u8] = b"nightfall-host-pair-v1";
pub const AAD: &[u8] = b"nightfall-host-pair-v1";
const TTL: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub struct Pending { pub id: String, pub pin: String, pub peer: IpAddr, expires: Instant }
#[derive(Default)]
struct Requests { pending: Option<Pending>, seen: VecDeque<String>, last: Option<Instant> }
impl Requests {
    fn offer(&mut self, id: String, pin: String, peer: IpAddr, now: Instant) -> Result<(),String> {
        if self.seen.contains(&id) { return Err("Pairing request was already received".into()); }
        if self.pending.as_ref().is_some_and(|p|p.expires>now) { return Err("Another pairing is awaiting approval".into()); }
        if self.last.is_some_and(|last|now.saturating_duration_since(last)<Duration::from_secs(5)) {
            return Err("Wait a moment before requesting pairing again".into());
        }
        self.last=Some(now);self.seen.push_back(id.clone());
        while self.seen.len()>64 {self.seen.pop_front();}
        self.pending=Some(Pending {id,pin,peer,expires:now+TTL});
        Ok(())
    }
    fn take_approved(&mut self, id: &str, now: Instant) -> Option<Pending> {
        if !self.pending.as_ref().is_some_and(|p|p.id==id && p.expires>now) { return None; }
        self.pending.take()
    }
}
pub struct Pairing {
    key: Arc<crate::crypto::MeteorKey>, host: Arc<Supervisor>, credentials: State,
    requests: Mutex<Requests>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope { public_key: String, payload: String }
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request { pin: String, created: u64 }

impl Pairing {
    pub fn new(key: Arc<crate::crypto::MeteorKey>, host: Arc<Supervisor>, credentials: State) -> Arc<Self> {
        Arc::new(Self { key, host, credentials, requests: Mutex::new(Requests::default()) })
    }
    pub fn pending(&self) -> Option<Pending> {
        self.requests.lock().unwrap().pending.as_ref().filter(|p|p.expires > Instant::now()).cloned()
    }
    pub fn accept(self: &Arc<Self>, body: &[u8], peer: IpAddr) -> Result<(), String> {
        if !self.host.wanted() || self.host.pid().is_none() { return Err("Managed host is not running".into()); }
        let (id,request)=decrypt_request(&self.key,body)?;
        {
            let mut state = self.requests.lock().unwrap();
            state.offer(id.clone(),request.pin,peer,Instant::now())?;
        }
        log::info!("Managed host pairing from {peer} awaits desktop approval");
        let pairing = self.clone();
        tokio::spawn(async move {
            if let Err(error) = crate::desktop::host_pairing_popup(pairing, id).await {
                log::info!("Pairing notification unavailable ({error}); approval remains in the tray");
            }
        });
        Ok(())
    }
    pub fn reject(&self, id: &str) {
        let mut state = self.requests.lock().unwrap();
        if state.pending.as_ref().is_some_and(|p|p.id==id) { state.pending = None; }
    }
    pub fn approve(self: &Arc<Self>, id: &str) {
        let pending = {
            let mut state = self.requests.lock().unwrap();
            let Some(pending)=state.take_approved(id,Instant::now()) else {return};
            pending
        };
        let pairing = self.clone();
        tokio::spawn(async move {
            let result = tokio::task::spawn_blocking(move ||pairing.submit(&pending.pin)).await;
            match result {
                Ok(Ok(())) => crate::desktop::notify("Pairing approved", "Nightfall will finish pairing and connect automatically.").await,
                Ok(Err(error)) => crate::desktop::notify("Pairing did not finish", &error).await,
                Err(_) => crate::desktop::notify("Pairing did not finish", "Try pairing again, or enter the PIN through the host web interface.").await,
            }
        });
    }
    fn submit(&self, pin: &str) -> Result<(), String> {
        if self.host.pid().is_none() || !self.host.wanted() { return Err("Managed host stopped. Try pairing again.".into()); }
        // The managed host uses a self-signed certificate. This agent can only
        // contact fixed loopback, ignores proxies and cannot follow redirects.
        // It never sends the web password or PIN to an address from a request.
        let agent: ureq::Agent = ureq::Agent::config_builder().proxy(None).max_redirects(0)
            .timeout_global(Some(Duration::from_secs(5)))
            .tls_config(ureq::tls::TlsConfig::builder().disable_verification(true).build()).build().into();
        let auth = basic_auth(&self.credentials.user, &self.credentials.password);
        let body = serde_json::json!({"pin":pin,"name":"Nightfall headset"}).to_string();
        let mut reply = agent.post(format!("https://127.0.0.1:{}/api/pin", self.host.instance.base+1))
            .header("Authorization", auth).header("Content-Type", "application/json").send(body.as_bytes())
            .map_err(|_|"Could not submit the approved PIN to the managed host. Retry or use its web interface.")?;
        let value: serde_json::Value = serde_json::from_str(&reply.body_mut().with_config().limit(4096).read_to_string().map_err(|_|"Invalid host pairing response")?)
            .map_err(|_|"Invalid host pairing response")?;
        if value["status"] == true { Ok(()) } else { Err("The host did not accept this PIN. Start pairing again in Nightfall.".into()) }
    }
}

fn decrypt_request(meteor: &crate::crypto::MeteorKey, body: &[u8]) -> Result<(String,Request),String> {
    if body.len()>4096 { return Err("Pairing request too large".into()); }
    let envelope: Envelope = serde_json::from_slice(body).map_err(|_|"Invalid encrypted pairing request")?;
    let public: [u8;32] = decode_hex(&envelope.public_key,32)?.try_into().map_err(|_|"Pairing key must be 32 bytes")?;
    let key=meteor.session_key(&public,INFO).ok_or("Invalid pairing key")?;
    let mut payload=decode_hex(&envelope.payload,512)?;
    let plain=key.open_in_place(crate::crypto::nonce(0),ring::aead::Aad::from(AAD),&mut payload)
        .map_err(|_|"Pairing request did not authenticate")?;
    let request:Request=serde_json::from_slice(plain).map_err(|_|"Invalid pairing payload")?;
    validate_request(&request)?;
    Ok((envelope.public_key.to_ascii_lowercase(),request))
}

fn validate_request(request: &Request) -> Result<(), String> {
    if request.pin.len()!=4 || !request.pin.bytes().all(|b|b.is_ascii_digit()) { return Err("Invalid pairing PIN".into()); }
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|_|"System clock unavailable")?.as_secs();
    if now.abs_diff(request.created)>30 { return Err("Pairing request expired; check the PC and headset clocks".into()); }
    Ok(())
}
fn decode_hex(value: &str, max: usize) -> Result<Vec<u8>, String> {
    if value.is_empty() || value.len()%2!=0 || value.len()>max*2 || !value.bytes().all(|b|b.is_ascii_hexdigit()) { return Err("Invalid pairing encoding".into()); }
    (0..value.len()).step_by(2).map(|i|u8::from_str_radix(&value[i..i+2],16).map_err(|_|"Invalid pairing encoding".into())).collect()
}
fn basic_auth(user: &str, password: &str) -> String {
    const DIGITS: &[u8;64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let raw = format!("{user}:{password}"); let mut out = String::from("Basic ");
    for chunk in raw.as_bytes().chunks(3) {
        let n = ((chunk[0] as u32)<<16) | ((chunk.get(1).copied().unwrap_or(0) as u32)<<8) | chunk.get(2).copied().unwrap_or(0) as u32;
        out.push(DIGITS[((n>>18)&63) as usize] as char); out.push(DIGITS[((n>>12)&63) as usize] as char);
        out.push(if chunk.len()>1 {DIGITS[((n>>6)&63) as usize] as char} else {'='});
        out.push(if chunk.len()>2 {DIGITS[(n&63) as usize] as char} else {'='});
    }
    out
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn pin_encoding_clock_and_credentials_are_bounded() {
        assert!(validate_request(&Request {pin:"1234".into(),created:0}).is_err());
        let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        assert!(validate_request(&Request {pin:"1234".into(),created:now}).is_ok());
        assert!(validate_request(&Request {pin:"12\n4".into(),created:now}).is_err());
        assert!(decode_hex("é",32).is_err());assert!(decode_hex("0",32).is_err());
        assert!(decode_hex(&"aa".repeat(33),32).is_err());
        assert_eq!(basic_auth("nightfall","secret"),"Basic bmlnaHRmYWxsOnNlY3JldA==");
        assert_eq!(basic_auth("a","b"),"Basic YTpi");
        assert_eq!(basic_auth("ab","c"),"Basic YWI6Yw==");
    }
    #[test] fn pin_handoff_requires_valid_encryption_and_cannot_cross_channels() {
        let meteor=crate::crypto::MeteorKey::from_seed([7;32]);
        let secret=x25519_dalek::StaticSecret::from([9;32]);
        let public=x25519_dalek::PublicKey::from(&secret).to_bytes();
        let shared=secret.diffie_hellman(&x25519_dalek::PublicKey::from(meteor.public));
        let hex=|bytes:&[u8]|bytes.iter().map(|b|format!("{b:02x}")).collect::<String>();
        let now=SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
        let packet=|info:&[u8],aad:&[u8]| {
            let key=crate::crypto::derive(shared.as_bytes(),&public,&meteor.public,info);
            let mut payload=serde_json::json!({"pin":"1234","created":now}).to_string().into_bytes();
            key.seal_in_place_append_tag(crate::crypto::nonce(0),ring::aead::Aad::from(aad),&mut payload).unwrap();
            serde_json::json!({"public_key":hex(&public),"payload":hex(&payload)})
        };
        let valid=packet(INFO,AAD).to_string();
        assert_eq!(decrypt_request(&meteor,valid.as_bytes()).unwrap().1.pin,"1234");
        assert!(decrypt_request(&meteor,packet(b"other-channel",AAD).to_string().as_bytes()).is_err());
        assert!(decrypt_request(&meteor,packet(INFO,b"other-header").to_string().as_bytes()).is_err());
        let mut invalid=packet(INFO,AAD); invalid["public_key"]=serde_json::json!("ab");
        assert!(decrypt_request(&meteor,invalid.to_string().as_bytes()).is_err());
        invalid["public_key"]=serde_json::json!("00".repeat(32));
        assert!(decrypt_request(&meteor,invalid.to_string().as_bytes()).is_err());
    }
    #[test] fn requests_do_not_approve_themselves_and_replay_or_expired_approvals_fail() {
        let now=Instant::now();let peer="127.0.0.1".parse().unwrap();let mut requests=Requests::default();
        requests.offer("first".into(),"1234".into(),peer,now).unwrap();
        assert!(requests.pending.is_some());
        assert!(requests.take_approved("wrong",now).is_none());
        assert!(requests.offer("second".into(),"5678".into(),peer,now).is_err());
        assert!(requests.take_approved("first",now+TTL).is_none());
        assert!(requests.offer("first".into(),"1234".into(),peer,now+TTL).is_err());
        requests.offer("second".into(),"5678".into(),peer,now+TTL).unwrap();
        assert!(requests.take_approved("second",now+TTL).is_some());
        assert!(requests.take_approved("second",now+TTL).is_none());
        assert!(requests.offer("third".into(),"9012".into(),peer,now+TTL).is_err());
    }
}
