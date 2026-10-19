//! Opt-in development control. Relay/demo launch require explicit local CLI options.
//! Device authorization is an explicit public-key allowlist, not discovery/TOFU alone.
use crate::crypto::MeteorKey;
use ring::{
    aead,
    rand::{SecureRandom, SystemRandom},
};
use serde::{Deserialize, Serialize};
use std::{io, net::SocketAddr, path::Path, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
};

const MAGIC: &[u8; 8] = b"NFXC\x01\0\0\0";
const MAX_FRAME: usize = 4096;
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Request {
    Authenticate {},
    Offer { width: u32, height: u32, hz: u32 },
    Accept { session: String },
    Stop { session: String },
    Status {},
}

#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct Reply {
    pub state: String,
    pub session: Option<String>,
    pub reason: Option<String>,
    // Prepared is NOT streaming. No capability is advertised before implementation.
    pub lan_video_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay: Option<crate::xr_relay::Ports>,
}

struct Session {
    id: String,
    raw_id: [u8; 16],
    accepted: bool,
    expires: tokio::time::Instant,
}
#[derive(Default)]
struct Negotiation {
    session: Option<Session>,
}
impl Negotiation {
    fn reply(&self, reason: Option<&str>) -> Reply {
        Reply {
            state: self
                .session
                .as_ref()
                .map_or("idle", |s| {
                    if s.accepted {
                        "prepared"
                    } else {
                        "awaiting_acceptance"
                    }
                })
                .into(),
            session: self.session.as_ref().map(|s| s.id.clone()),
            reason: reason.map(str::to_owned),
            lan_video_available: false,
            relay: None,
        }
    }
    fn apply(&mut self, request: Request) -> io::Result<Reply> {
        if self
            .session
            .as_ref()
            .is_some_and(|s| tokio::time::Instant::now() >= s.expires)
        {
            self.session = None;
        }
        match request {
            Request::Authenticate {} => return Ok(self.reply(Some("already_authenticated"))),
            Request::Status {} => {}
            Request::Offer { width, height, hz } => {
                if self.session.is_some() {
                    return Ok(self.reply(Some("busy")));
                }
                if !matches!((width, height), (512, 512) | (256, 256)) || !matches!(hz, 20 | 60) {
                    return Ok(self.reply(Some("unsupported_profile")));
                }
                let mut id = [0u8; 16];
                SystemRandom::new()
                    .fill(&mut id)
                    .map_err(|_| invalid("randomness unavailable"))?;
                self.session = Some(Session {
                    id: id.iter().map(|b| format!("{b:02x}")).collect(),
                    raw_id: id,
                    accepted: false,
                    expires: tokio::time::Instant::now() + Duration::from_secs(15),
                });
            }
            Request::Accept { session } => {
                let Some(current) = self.session.as_mut().filter(|s| s.id == session) else {
                    return Ok(self.reply(Some("unknown_session")));
                };
                current.accepted = true;
                // Control-only proof leases expire; no indefinite phantom session.
                current.expires = tokio::time::Instant::now() + IDLE_TIMEOUT;
            }
            Request::Stop { session } => {
                if !self.session.as_ref().is_some_and(|s| s.id == session) {
                    return Ok(self.reply(Some("unknown_session")));
                }
                self.session = None;
            }
        }
        Ok(self.reply(None))
    }
}

struct Cipher {
    key: aead::LessSafeKey,
    sequence: u64,
}
impl Cipher {
    fn seal(&mut self, bytes: &[u8]) -> io::Result<Vec<u8>> {
        if bytes.len() > MAX_FRAME - aead::AES_256_GCM.tag_len() {
            return Err(invalid("control frame too large"));
        }
        let next = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| invalid("sequence exhausted"))?;
        let length = (bytes.len() + aead::AES_256_GCM.tag_len()) as u32;
        let mut data = bytes.to_vec();
        self.key
            .seal_in_place_append_tag(
                crate::crypto::nonce(self.sequence),
                aead::Aad::from(length.to_le_bytes()),
                &mut data,
            )
            .map_err(|_| invalid("control encryption failed"))?;
        self.sequence = next;
        let mut frame = length.to_le_bytes().to_vec();
        frame.extend(data);
        Ok(frame)
    }
    fn open(&mut self, length: u32, mut data: Vec<u8>) -> io::Result<Vec<u8>> {
        if data.len() != length as usize || !(16..=MAX_FRAME).contains(&data.len()) {
            return Err(invalid("invalid control frame size"));
        }
        let next = self
            .sequence
            .checked_add(1)
            .ok_or_else(|| invalid("sequence exhausted"))?;
        let clear = self
            .key
            .open_in_place(
                crate::crypto::nonce(self.sequence),
                aead::Aad::from(length.to_le_bytes()),
                &mut data,
            )
            .map_err(|_| invalid("control authentication failed"))?
            .to_vec();
        self.sequence = next;
        Ok(clear)
    }
}

fn cipher(
    key: &MeteorKey,
    client: &[u8; 32],
    server_nonce: &[u8; 32],
    client_nonce: &[u8; 32],
    direction: &[u8],
) -> io::Result<Cipher> {
    let mut info = b"nightfall-xr-control-v1/".to_vec();
    info.extend(direction);
    info.extend(server_nonce);
    info.extend(client_nonce);
    Ok(Cipher {
        key: key
            .session_key(client, &info)
            .ok_or_else(|| invalid("invalid peer key"))?,
        sequence: 0,
    })
}

async fn read_frame(stream: &mut TcpStream, cipher: &mut Cipher) -> io::Result<Request> {
    let length = stream.read_u32_le().await?;
    if !(16..=MAX_FRAME as u32).contains(&length) {
        return Err(invalid("invalid control frame size"));
    }
    let mut bytes = vec![0; length as usize];
    stream.read_exact(&mut bytes).await?;
    serde_json::from_slice(&cipher.open(length, bytes)?)
        .map_err(|_| invalid("invalid control request"))
}

async fn respond(stream: &mut TcpStream, cipher: &mut Cipher, reply: &Reply) -> io::Result<()> {
    let bytes = serde_json::to_vec(reply).map_err(|_| invalid("invalid control reply"))?;
    stream.write_all(&cipher.seal(&bytes)?).await
}

async fn connection(
    stream: TcpStream,
    key: Arc<MeteorKey>,
    allowed: [u8; 32],
    session_slot: Arc<Semaphore>,
) -> io::Result<()> {
    connection_mode(stream, key, allowed, session_slot, false, None).await
}
async fn connection_mode(
    mut stream: TcpStream,
    key: Arc<MeteorKey>,
    allowed: [u8; 32],
    session_slot: Arc<Semaphore>,
    enable_relay: bool,
    runtime_root: Option<std::path::PathBuf>,
) -> io::Result<()> {
    let bind = stream.local_addr()?.ip();
    let authenticated = tokio::time::timeout(IO_TIMEOUT, async {
        let mut server_nonce = [0; 32];
        SystemRandom::new()
            .fill(&mut server_nonce)
            .map_err(|_| invalid("randomness unavailable"))?;
        stream.write_all(MAGIC).await?;
        stream.write_all(&key.public).await?;
        stream.write_all(&server_nonce).await?;
        let mut client = [0; 32];
        let mut client_nonce = [0; 32];
        stream.read_exact(&mut client).await?;
        stream.read_exact(&mut client_nonce).await?;
        if client != allowed {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "device not paired",
            ));
        }
        let mut receive = cipher(
            &key,
            &client,
            &server_nonce,
            &client_nonce,
            b"client-to-server",
        )?;
        let send = cipher(
            &key,
            &client,
            &server_nonce,
            &client_nonce,
            b"server-to-client",
        )?;
        if read_frame(&mut stream, &mut receive).await? != (Request::Authenticate {}) {
            return Err(invalid("authentication required first"));
        }
        Ok((receive, send, client, server_nonce, client_nonce))
    })
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "handshake timeout"))??;
    let (mut receive, mut send, client, server_nonce, client_nonce) = authenticated;
    // Reserve exclusive session ownership only after proof of the paired key.
    let Ok(_owner) = session_slot.try_acquire_owned() else {
        let busy = Reply {
            state: "busy".into(),
            session: None,
            reason: Some("another_control_session".into()),
            lan_video_available: false,
            relay: None,
        };
        return tokio::time::timeout(IO_TIMEOUT, respond(&mut stream, &mut send, &busy))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "write timeout"))?;
    };
    let mut negotiation = Negotiation::default();
    let mut relay: Option<crate::xr_relay::Relay> = None;
    tokio::time::timeout(
        IO_TIMEOUT,
        respond(&mut stream, &mut send, &negotiation.reply(None)),
    )
    .await
    .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "write timeout"))??;
    loop {
        if relay.as_ref().is_some_and(|r| r.failed()) {
            return Err(invalid("XR relay disconnected"));
        }
        let deadline = negotiation
            .session
            .as_ref()
            .map(|s| s.expires)
            .unwrap_or_else(|| tokio::time::Instant::now() + IDLE_TIMEOUT);
        let request = tokio::time::timeout_at(deadline, read_frame(&mut stream, &mut receive))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "control idle timeout"))??;
        let mut reply = if enable_relay
            && matches!(&request,Request::Offer{width,height,hz} if (*width,*height,*hz)!=(512,512,20))
        {
            negotiation.reply(Some("relay_profile_requires_512_square_20hz"))
        } else {
            negotiation.apply(request)?
        };
        if reply.state != "prepared" {
            relay = None;
        } else if enable_relay && relay.is_none() {
            let session = negotiation
                .session
                .as_ref()
                .ok_or_else(|| invalid("no accepted lease"))?;
            relay = Some(
                crate::xr_relay::Relay::prepare(
                    bind,
                    crate::xr_relay::Credentials {
                        host: key.clone(),
                        client,
                        server_nonce,
                        client_nonce,
                        session: session.raw_id,
                    },
                )
                .await?,
            );
            #[cfg(target_os = "linux")]
            if let Some(root) = runtime_root.clone() {
                relay.as_mut().unwrap().start_runtime(root);
            }
        }
        reply.relay = relay.as_ref().map(|r| r.ports.clone());
        tokio::time::timeout(IO_TIMEOUT, respond(&mut stream, &mut send, &reply))
            .await
            .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "write timeout"))??;
    }
    // Dropping this connection drops its pending/prepared state and session slot.
}

fn public_key(hex: &str) -> io::Result<[u8; 32]> {
    if hex.len() != 64 || !hex.is_ascii() {
        return Err(invalid("client public key must be 64 hex characters"));
    }
    let mut key = [0; 32];
    for (i, value) in key.iter_mut().enumerate() {
        *value = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16)
            .map_err(|_| invalid("invalid public key"))?;
    }
    if key == [0; 32] {
        return Err(invalid("invalid public key"));
    }
    Ok(key)
}

pub async fn command(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    if args.len() != 3 && !((args.len() == 4 || args.len() == 5) && args[3] == "--relay") {
        return Err("usage: --xr-control-dev <bind-address:port> <server-key-file> <allowed-client-public-hex> [--relay [checkout]]".into());
    }
    let address: SocketAddr = args[0].parse()?;
    let enable_relay = args.len() >= 4;
    let runtime_root = if args.len() == 5 {
        Some(std::path::PathBuf::from(&args[4]).canonicalize()?)
    } else {
        None
    };
    if let Some(root) = runtime_root.as_ref() {
        if !cfg!(target_os = "linux") {
            return Err("Runtime launch currently requires Linux/NVIDIA".into());
        }
        for file in [
            "tools/build_support/probe_monado_nvenc.sh",
            ".build-cache/meteor-xr/godot-engine-cleanup/bin/godot.linuxbsd.editor.x86_64",
        ] {
            if !root.join(file).is_file() {
                return Err(format!("Missing XR prerequisite: {file}").into());
            }
        }
    }
    let key = Arc::new(MeteorKey::load_or_create(Path::new(&args[1]))?);
    let allowed = public_key(&args[2])?;
    let listener = TcpListener::bind(address).await?;
    println!(
        "Meteor XR control-only DEV listening on {}; pinned host key {}",
        listener.local_addr()?,
        key.public_hex()
    );
    if !enable_relay {
        println!(
            "Control-only mode: no applications will be launched. Explicit client acceptance is required to prepare a session."
        );
    }
    if enable_relay {
        println!(
            "DEV encrypted relays enabled; runtime launch: {}. Not a production LAN capability.",
            runtime_root.is_some()
        );
    }
    let connections = Arc::new(Semaphore::new(4));
    let session_slot = Arc::new(Semaphore::new(1));
    let mut tasks = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            result=listener.accept() => {
                let (stream,_peer)=result?;
                let Ok(permit)=connections.clone().try_acquire_owned() else {continue};
                let key=key.clone();let slot=session_slot.clone();let root=runtime_root.clone();
                tasks.spawn(async move {let _permit=permit;let result=if enable_relay {connection_mode(stream,key,allowed,slot,true,root).await} else {connection(stream,key,allowed,slot).await};if let Err(error)=result {eprintln!("Meteor XR control session ended: {error}");}});
            },
            _=tokio::signal::ctrl_c()=>break,
            _=tasks.join_next(), if !tasks.is_empty()=>{},
        }
    }
    tasks.abort_all();
    while tasks.join_next().await.is_some() {}
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn pair(direction: &[u8], nonce: u8) -> (Cipher, Cipher) {
        let server = MeteorKey::from_seed([1; 32]);
        let client = MeteorKey::from_seed([2; 32]);
        (
            cipher(&server, &client.public, &[nonce; 32], &[4; 32], direction).unwrap(),
            cipher(&server, &client.public, &[nonce; 32], &[4; 32], direction).unwrap(),
        )
    }
    fn decode(cipher: &mut Cipher, frame: Vec<u8>) -> io::Result<Vec<u8>> {
        cipher.open(
            u32::from_le_bytes(frame[..4].try_into().unwrap()),
            frame[4..].to_vec(),
        )
    }
    #[test]
    fn replay_is_rejected() {
        let (mut tx, mut rx) = pair(b"client-to-server", 3);
        let frame = tx.seal(b"hello").unwrap();
        assert_eq!(decode(&mut rx, frame.clone()).unwrap(), b"hello");
        assert!(decode(&mut rx, frame).is_err());
    }
    #[test]
    fn cross_session_and_reflection_rejected() {
        let (mut tx, _) = pair(b"client-to-server", 3);
        let (_, mut other) = pair(b"client-to-server", 9);
        let (_, mut reverse) = pair(b"server-to-client", 3);
        let frame = tx.seal(b"hello").unwrap();
        assert!(decode(&mut other, frame.clone()).is_err());
        assert!(decode(&mut reverse, frame).is_err());
    }
    #[test]
    fn tamper_and_oversize_rejected() {
        let (mut tx, mut rx) = pair(b"client-to-server", 3);
        let mut frame = tx.seal(b"hello").unwrap();
        frame[5] ^= 1;
        assert!(decode(&mut rx, frame).is_err());
        assert!(tx.seal(&vec![0; MAX_FRAME]).is_err());
    }
    #[test]
    fn explicit_matching_acceptance_required() {
        let mut state = Negotiation::default();
        assert_eq!(
            state
                .apply(Request::Offer {
                    width: 999,
                    height: 512,
                    hz: 20
                })
                .unwrap()
                .state,
            "idle"
        );
        let offer = state
            .apply(Request::Offer {
                width: 512,
                height: 512,
                hz: 20,
            })
            .unwrap();
        assert_eq!(offer.state, "awaiting_acceptance");
        assert_eq!(
            state
                .apply(Request::Accept {
                    session: "wrong".into()
                })
                .unwrap()
                .state,
            "awaiting_acceptance"
        );
        let accepted = state
            .apply(Request::Accept {
                session: offer.session.clone().unwrap(),
            })
            .unwrap();
        assert_eq!(accepted.state, "prepared");
        assert!(!accepted.lan_video_available);
        assert_eq!(
            state
                .apply(Request::Stop {
                    session: offer.session.unwrap()
                })
                .unwrap()
                .state,
            "idle"
        );
    }
    #[test]
    fn strict_request_schema_and_keys() {
        assert!(serde_json::from_str::<Request>(r#"{"type":"status","command":"rm"}"#).is_err());
        assert!(serde_json::from_str::<Request>(r#"{"type":"launch","path":"game"}"#).is_err());
        assert!(public_key(&"0".repeat(64)).is_err());
        assert!(public_key("invalid").is_err());
    }

    #[test]
    fn expired_offer_cannot_be_accepted() {
        let mut negotiation = Negotiation::default();
        let offer = negotiation
            .apply(Request::Offer {
                width: 512,
                height: 512,
                hz: 20,
            })
            .unwrap();
        negotiation.session.as_mut().unwrap().expires =
            tokio::time::Instant::now() - Duration::from_secs(1);
        let reply = negotiation
            .apply(Request::Accept {
                session: offer.session.unwrap(),
            })
            .unwrap();
        assert_eq!(reply.state, "idle");
        assert_eq!(reply.reason.as_deref(), Some("unknown_session"));
    }

    async fn client_handshake(
        stream: &mut TcpStream,
        pin: [u8; 32],
        seed: [u8; 32],
    ) -> (Cipher, Cipher) {
        let mut hello = [0u8; 72];
        stream.read_exact(&mut hello).await.unwrap();
        assert_eq!(&hello[..8], MAGIC);
        assert_eq!(&hello[8..40], &pin);
        let server_nonce: [u8; 32] = hello[40..].try_into().unwrap();
        let client_nonce = [7u8; 32];
        let secret = x25519_dalek::StaticSecret::from(seed);
        let public = x25519_dalek::PublicKey::from(&secret).to_bytes();
        stream.write_all(&public).await.unwrap();
        stream.write_all(&client_nonce).await.unwrap();
        let shared = secret.diffie_hellman(&x25519_dalek::PublicKey::from(pin));
        let make = |direction: &[u8]| {
            let mut info = b"nightfall-xr-control-v1/".to_vec();
            info.extend(direction);
            info.extend(server_nonce);
            info.extend(client_nonce);
            Cipher {
                key: crate::crypto::derive(shared.as_bytes(), &public, &pin, &info),
                sequence: 0,
            }
        };
        let mut tx = make(b"client-to-server");
        let rx = make(b"server-to-client");
        stream
            .write_all(&tx.seal(br#"{"type":"authenticate"}"#).unwrap())
            .await
            .unwrap();
        (tx, rx)
    }

    async fn reply(stream: &mut TcpStream, rx: &mut Cipher) -> Reply {
        let length = stream.read_u32_le().await.unwrap();
        assert!(length <= MAX_FRAME as u32);
        let mut data = vec![0; length as usize];
        stream.read_exact(&mut data).await.unwrap();
        serde_json::from_slice(&rx.open(length, data).unwrap()).unwrap()
    }

    #[tokio::test]
    async fn encrypted_socket_negotiation_and_disconnect_release() {
        let key = Arc::new(MeteorKey::from_seed([1; 32]));
        let pin = key.public;
        let allowed = MeteorKey::from_seed([2; 32]).public;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let slot = Arc::new(Semaphore::new(1));
        let owned = slot.clone();
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            connection(stream, key, allowed, owned).await
        });
        let mut stream = TcpStream::connect(address).await.unwrap();
        let (mut tx, mut rx) = client_handshake(&mut stream, pin, [2; 32]).await;
        assert_eq!(reply(&mut stream, &mut rx).await.state, "idle");
        stream
            .write_all(
                &tx.seal(br#"{"type":"offer","width":512,"height":512,"hz":20}"#)
                    .unwrap(),
            )
            .await
            .unwrap();
        let offer = reply(&mut stream, &mut rx).await;
        assert_eq!(offer.state, "awaiting_acceptance");
        let accept = serde_json::to_vec(&Request::Accept {
            session: offer.session.unwrap(),
        })
        .unwrap();
        stream.write_all(&tx.seal(&accept).unwrap()).await.unwrap();
        let accepted = reply(&mut stream, &mut rx).await;
        assert_eq!(accepted.state, "prepared");
        assert!(!accepted.lan_video_available);
        assert_eq!(slot.available_permits(), 0);
        drop(stream);
        assert!(
            tokio::time::timeout(Duration::from_secs(2), task)
                .await
                .unwrap()
                .unwrap()
                .is_err()
        );
        assert_eq!(slot.available_permits(), 1);
    }

    #[tokio::test]
    async fn unauthorized_key_never_reserves_session() {
        let key = Arc::new(MeteorKey::from_seed([1; 32]));
        let allowed = MeteorKey::from_seed([2; 32]).public;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let slot = Arc::new(Semaphore::new(1));
        let owned = slot.clone();
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            connection(stream, key, allowed, owned).await
        });
        let mut stream = TcpStream::connect(address).await.unwrap();
        let mut hello = [0; 72];
        stream.read_exact(&mut hello).await.unwrap();
        stream
            .write_all(&MeteorKey::from_seed([9; 32]).public)
            .await
            .unwrap();
        stream.write_all(&[0; 32]).await.unwrap();
        let error = task.await.unwrap().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(slot.available_permits(), 1);
    }

    #[tokio::test]
    async fn claiming_allowlisted_public_key_without_secret_is_rejected() {
        let key = Arc::new(MeteorKey::from_seed([1; 32]));
        let allowed = MeteorKey::from_seed([2; 32]).public;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let slot = Arc::new(Semaphore::new(1));
        let owned = slot.clone();
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            connection(stream, key, allowed, owned).await
        });
        let mut stream = TcpStream::connect(address).await.unwrap();
        let mut hello = [0; 72];
        stream.read_exact(&mut hello).await.unwrap();
        stream.write_all(&allowed).await.unwrap();
        stream.write_all(&[0; 32]).await.unwrap();
        stream.write_u32_le(16).await.unwrap();
        stream.write_all(&[0; 16]).await.unwrap();
        assert!(
            task.await
                .unwrap()
                .unwrap_err()
                .to_string()
                .contains("authentication failed")
        );
        assert_eq!(slot.available_permits(), 1);
    }

    #[tokio::test]
    async fn second_authenticated_connection_is_busy() {
        let key = Arc::new(MeteorKey::from_seed([1; 32]));
        let pin = key.public;
        let allowed = MeteorKey::from_seed([2; 32]).public;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let slot = Arc::new(Semaphore::new(1));
        let owner = slot.clone();
        let host = key.clone();
        let first_task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let first = tokio::spawn(connection(stream, host, allowed, owner));
            let (stream, _) = listener.accept().await.unwrap();
            let second = connection(stream, key, allowed, slot).await;
            (first, second)
        });
        let mut first = TcpStream::connect(address).await.unwrap();
        let (_, mut first_rx) = client_handshake(&mut first, pin, [2; 32]).await;
        assert_eq!(reply(&mut first, &mut first_rx).await.state, "idle");
        let mut second = TcpStream::connect(address).await.unwrap();
        let (_, mut second_rx) = client_handshake(&mut second, pin, [2; 32]).await;
        let busy = reply(&mut second, &mut second_rx).await;
        assert_eq!(busy.state, "busy");
        assert!(busy.session.is_none());
        drop(second);
        drop(first);
        let (first, second) = first_task.await.unwrap();
        assert!(second.is_ok());
        assert!(first.await.unwrap().is_err());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires compiled C++ test client in NIGHTFALL_XR_CONTROL_CPP_CLIENT"]
    async fn openssl_client_interoperability() {
        let binary = std::env::var("NIGHTFALL_XR_CONTROL_CPP_CLIENT").unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let key = Arc::new(MeteorKey::from_seed([1; 32]));
        let allowed = MeteorKey::from_seed([2; 32]).public;
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            connection(stream, key, allowed, Arc::new(Semaphore::new(1))).await
        });
        let output = std::process::Command::new(binary)
            .arg(port.to_string())
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(String::from_utf8_lossy(&output.stdout).contains("PASS OpenSSL"));
        assert!(task.await.unwrap().is_err()); // EOF after explicit stop releases connection.
    }

    #[tokio::test]
    async fn relays_exist_only_after_accept_and_stop_closes_them() {
        let key = Arc::new(MeteorKey::from_seed([1; 32]));
        let pin = key.public;
        let allowed = MeteorKey::from_seed([2; 32]).public;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            connection_mode(
                stream,
                key,
                allowed,
                Arc::new(Semaphore::new(1)),
                true,
                None,
            )
            .await
        });
        let mut stream = TcpStream::connect(address).await.unwrap();
        let (mut tx, mut rx) = client_handshake(&mut stream, pin, [2; 32]).await;
        assert!(reply(&mut stream, &mut rx).await.relay.is_none());
        stream
            .write_all(
                &tx.seal(br#"{"type":"offer","width":256,"height":256,"hz":60}"#)
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(reply(&mut stream, &mut rx).await.state, "idle");
        stream
            .write_all(
                &tx.seal(br#"{"type":"offer","width":512,"height":512,"hz":20}"#)
                    .unwrap(),
            )
            .await
            .unwrap();
        let offer = reply(&mut stream, &mut rx).await;
        assert!(offer.relay.is_none());
        let session = offer.session.unwrap();
        stream
            .write_all(
                &tx.seal(
                    &serde_json::to_vec(&Request::Accept {
                        session: session.clone(),
                    })
                    .unwrap(),
                )
                .unwrap(),
            )
            .await
            .unwrap();
        let accepted = reply(&mut stream, &mut rx).await;
        let ports = accepted.relay.unwrap();
        assert!(!accepted.lan_video_available);
        let mut attached = TcpStream::connect(("127.0.0.1", ports.video))
            .await
            .unwrap();
        let mut challenge = [0; 32];
        attached.read_exact(&mut challenge).await.unwrap();
        stream
            .write_all(
                &tx.seal(&serde_json::to_vec(&Request::Stop { session }).unwrap())
                    .unwrap(),
            )
            .await
            .unwrap();
        let stopped = reply(&mut stream, &mut rx).await;
        assert_eq!(stopped.state, "idle");
        assert!(stopped.relay.is_none());
        let mut byte = [0];
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), attached.read(&mut byte))
                .await
                .unwrap()
                .unwrap(),
            0
        );
        drop(stream);
        assert!(task.await.unwrap().is_err());
    }
}
