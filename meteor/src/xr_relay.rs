//! DEV lease-owned encrypted socket relays around existing loopback consumers.
//! Prepared control ownership must outlive this object. No app launch is implicit.
use crate::{
    crypto::MeteorKey,
    xr_data::{Channel, HEADER, Kind},
    xr_wire,
};
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use std::{
    io,
    net::IpAddr,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::watch,
    task::JoinHandle,
};

const WAIT: Duration = Duration::from_secs(20);
const IO: Duration = Duration::from_secs(5);
fn invalid(text: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, text)
}
async fn bounded<T>(future: impl std::future::Future<Output = io::Result<T>>) -> io::Result<T> {
    tokio::time::timeout(IO, future)
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "XR relay I/O timeout"))?
}

#[derive(Clone)]
pub struct Credentials {
    pub host: Arc<MeteorKey>,
    pub client: [u8; 32],
    pub server_nonce: [u8; 32],
    pub client_nonce: [u8; 32],
    pub session: [u8; 16],
}
impl Credentials {
    fn channel(&self, kind: Kind, binding: [u8; 32]) -> io::Result<Channel> {
        Channel::new_bound(
            &self.host,
            self.client,
            self.server_nonce,
            self.client_nonce,
            self.session,
            kind,
            Some(binding),
        )
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Ports {
    pub video: u16,
    pub tracking: u16,
    pub framing: u8,
}
pub struct Relay {
    pub ports: Ports,
    pub local_video: u16,
    pub local_tracking: u16,
    failed: Arc<AtomicBool>,
    stop: watch::Sender<bool>,
    tasks: Vec<JoinHandle<()>>,
    attached: Arc<AtomicUsize>,
}
impl Relay {
    pub async fn prepare(bind: IpAddr, credentials: Credentials) -> io::Result<Self> {
        let video = TcpListener::bind((bind, 0)).await?;
        let tracking = TcpListener::bind((bind, 0)).await?;
        let local_video = TcpListener::bind("127.0.0.1:0").await?;
        let local_tracking = TcpListener::bind("127.0.0.1:0").await?;
        let ports = Ports {
            video: video.local_addr()?.port(),
            tracking: tracking.local_addr()?.port(),
            framing: 1,
        };
        let local_video_port = local_video.local_addr()?.port();
        let local_tracking_port = local_tracking.local_addr()?.port();
        let (stop, _) = watch::channel(false);
        let failed = Arc::new(AtomicBool::new(false));
        let attached = Arc::new(AtomicUsize::new(0));
        let mut tasks = Vec::new();
        for (kind, listener, local) in [
            (Kind::AttachVideo, video, local_video),
            (Kind::AttachTracking, tracking, local_tracking),
        ] {
            let credentials = credentials.clone();
            let mut cancel = stop.subscribe();
            let signal = stop.clone();
            let failure = failed.clone();
            let ready = attached.clone();
            tasks.push(tokio::spawn(async move {
                tokio::select! {
                    result=lane(listener,local,credentials,kind,ready)=> {
                        if let Err(error)=result {failure.store(true,Ordering::Release);eprintln!("Meteor XR relay {kind:?} stopped: {error}");signal.send_replace(true);}
                    },
                    _=cancel.changed()=>{},
                }
            }));
        }
        Ok(Self {
            ports,
            local_video: local_video_port,
            local_tracking: local_tracking_port,
            failed,
            stop,
            tasks,
            attached,
        })
    }
    pub fn failed(&self) -> bool {
        self.failed.load(Ordering::Acquire)
    }
    #[cfg(target_os = "linux")]
    pub fn start_runtime(&mut self, root: std::path::PathBuf) {
        let ready = self.attached.clone();
        let mut cancel = self.stop.subscribe();
        let signal = self.stop.clone();
        let failure = self.failed.clone();
        let (video, tracking) = (self.local_video, self.local_tracking);
        // Intentionally not aborted by Relay::drop: cancellation is delivered
        // through watch, allowing bounded graceful app teardown before kill.
        tokio::spawn(async move {
            let deadline = tokio::time::Instant::now() + WAIT;
            while ready.load(Ordering::Acquire) != 2 {
                if *cancel.borrow() {
                    return;
                }
                tokio::select! {_=cancel.changed()=>return,_=tokio::time::sleep(Duration::from_millis(20))=>{}}
                if tokio::time::Instant::now() >= deadline {
                    failure.store(true, Ordering::Release);
                    signal.send_replace(true);
                    return;
                }
            }
            if let Err(error) =
                crate::xr_session::runtime_adapter(root, video, tracking, cancel).await
            {
                eprintln!("Meteor XR runtime adapter stopped: {error}");
                failure.store(true, Ordering::Release);
                signal.send_replace(true);
            }
        });
    }
}
impl Drop for Relay {
    fn drop(&mut self) {
        self.stop.send_replace(true);
        for task in &self.tasks {
            task.abort();
        }
    }
}

async fn accept(listener: TcpListener) -> io::Result<TcpStream> {
    let (stream, _) = tokio::time::timeout(WAIT, listener.accept())
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "XR endpoint attach timeout"))??;
    stream.set_nodelay(true)?;
    Ok(stream)
}
async fn read(stream: &mut TcpStream, cipher: &mut Channel) -> io::Result<Vec<u8>> {
    bounded(async {
        let mut header = [0; HEADER];
        stream.read_exact(&mut header).await?;
        let size = cipher.payload_length(&header)?;
        let mut body = vec![0; size];
        stream.read_exact(&mut body).await?;
        cipher.open(&header, body)
    })
    .await
}
async fn write(stream: &mut TcpStream, cipher: &mut Channel, bytes: &[u8]) -> io::Result<()> {
    bounded(stream.write_all(&cipher.seal(bytes)?)).await
}
async fn lane(
    listener: TcpListener,
    local: TcpListener,
    credentials: Credentials,
    kind: Kind,
    ready: Arc<AtomicUsize>,
) -> io::Result<()> {
    let mut remote = accept(listener).await?;
    let mut challenge = [0; 32];
    SystemRandom::new()
        .fill(&mut challenge)
        .map_err(|_| invalid("randomness unavailable"))?;
    bounded(remote.write_all(&challenge)).await?;
    let proof = read(&mut remote, &mut credentials.channel(kind, challenge)?).await?;
    if proof[8..24] != credentials.session {
        return Err(invalid("XR endpoint session mismatch"));
    }
    ready.fetch_add(1, Ordering::Release);
    // No trusted-local producer is admitted until remote key possession is proved.
    let mut local = accept(local).await?;
    if kind == Kind::AttachVideo {
        video(&mut remote, &mut local, &credentials, challenge).await
    } else {
        tracking(&mut remote, &mut local, &credentials, challenge).await
    }
}
async fn video(
    remote: &mut TcpStream,
    local: &mut TcpStream,
    credentials: &Credentials,
    binding: [u8; 32],
) -> io::Result<()> {
    let mut tx = credentials.channel(Kind::Video, binding)?;
    let mut rx = credentials.channel(Kind::VideoFeedback, binding)?;
    let mut validator = xr_wire::Reader::default();
    loop {
        let mut header = [0; 152];
        bounded(local.read_exact(&mut header)).await?;
        let info = xr_wire::Header::decode(&header)?;
        let mut packet = header.to_vec();
        let mut body = vec![0; info.payload_len];
        bounded(local.read_exact(&mut body)).await?;
        packet.extend(body);
        validator.read(&mut std::io::Cursor::new(&packet))?;
        write(remote, &mut tx, &packet).await?;
        let feedback = read(remote, &mut rx).await?;
        let mut expected = if info.end {
            b"NFXE".to_vec()
        } else {
            b"NFXA".to_vec()
        };
        expected.extend(info.sequence.to_le_bytes());
        if !info.end {
            expected.extend(info.frame_id.to_le_bytes());
        }
        if feedback != expected {
            return Err(invalid("XR decoder acknowledgment mismatch"));
        }
        bounded(local.write_all(&feedback)).await?;
        if info.end {
            return Ok(());
        }
    }
}
async fn tracking(
    remote: &mut TcpStream,
    local: &mut TcpStream,
    credentials: &Credentials,
    binding: [u8; 32],
) -> io::Result<()> {
    let mut tx = credentials.channel(Kind::HostTracking, binding)?;
    let mut rx = credentials.channel(Kind::HeadsetTracking, binding)?;
    loop {
        let mut request = [0; 32];
        bounded(local.read_exact(&mut request)).await?;
        crate::xr_data::validate_payload(Kind::HostTracking, &request, &mut Default::default())?;
        write(remote, &mut tx, &request).await?;
        if request.starts_with(b"NFXQ") {
            return Ok(());
        }
        let response = read(remote, &mut rx).await?;
        let (magic, size) = match &request[..4] {
            b"NFXC" => (b"NFXC".as_slice(), 32),
            b"NFXP" => (b"NFXT".as_slice(), 64),
            b"NFXO" => (b"NFXO".as_slice(), 112),
            b"NFXJ" => (b"NFXJ".as_slice(), 192),
            b"NFXH" => (b"NFXH".as_slice(), 32),
            _ => return Err(invalid("unsupported tracking request")),
        };
        if response.len() != size || !response.starts_with(magic) {
            return Err(invalid("XR tracking response mismatch"));
        }
        bounded(local.write_all(&response)).await?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn credentials() -> Credentials {
        Credentials {
            host: Arc::new(MeteorKey::from_seed([1; 32])),
            client: MeteorKey::from_seed([2; 32]).public,
            server_nonce: [3; 32],
            client_nonce: [4; 32],
            session: [5; 16],
        }
    }
    fn frame(sequence: u64, end: bool) -> Vec<u8> {
        let payload = [0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 1, 0, 0, 1, 0x65, 1];
        let mut h = vec![0; 152];
        h[..4].copy_from_slice(b"NFXR");
        h[4] = 1;
        h[6] = 152;
        h[8..16].copy_from_slice(&9u64.to_le_bytes());
        h[16..24].copy_from_slice(&sequence.to_le_bytes());
        h[48] = 1;
        if end {
            h[50] = 1;
            return h;
        }
        h[24..32].copy_from_slice(&(sequence + 1).to_le_bytes());
        h[32..40].copy_from_slice(&(sequence + 1000).to_le_bytes());
        h[40..44].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        h[44..46].copy_from_slice(&512u16.to_le_bytes());
        h[46..48].copy_from_slice(&256u16.to_le_bytes());
        h[49] = 1;
        for eye in 0..2 {
            for (field, value) in [(6, 1f32), (7, -0.8), (8, 0.8), (9, 0.8), (10, -0.8)] {
                let at = 64 + (eye * 11 + field) * 4;
                h[at..at + 4].copy_from_slice(&value.to_le_bytes());
            }
        }
        h.extend(payload);
        h
    }
    #[tokio::test]
    async fn invalid_proof_cancels_other_lane_and_local_admission() {
        let relay = Relay::prepare("127.0.0.1".parse().unwrap(), credentials())
            .await
            .unwrap();
        let mut attacker = TcpStream::connect(("127.0.0.1", relay.ports.video))
            .await
            .unwrap();
        let mut challenge = [0; 32];
        attacker.read_exact(&mut challenge).await.unwrap();
        attacker.write_all(&[0; HEADER]).await.unwrap();
        tokio::time::timeout(Duration::from_secs(1), async {
            while !relay.failed() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let mut byte = [0];
        assert_eq!(bounded(attacker.read(&mut byte)).await.unwrap(), 0);
    }
    #[tokio::test]
    async fn dropping_lease_closes_waiting_connections() {
        let relay = Relay::prepare("127.0.0.1".parse().unwrap(), credentials())
            .await
            .unwrap();
        let mut client = TcpStream::connect(("127.0.0.1", relay.ports.video))
            .await
            .unwrap();
        let mut challenge = [0; 32];
        client.read_exact(&mut challenge).await.unwrap();
        drop(relay);
        let mut byte = [0];
        assert_eq!(bounded(client.read(&mut byte)).await.unwrap(), 0);
    }
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires native worker fixture NIGHTFALL_XR_RELAY_CPP_CLIENT"]
    async fn native_live_workers() {
        let binary = std::env::var("NIGHTFALL_XR_RELAY_CPP_CLIENT").unwrap();
        let relay = Relay::prepare("127.0.0.1".parse().unwrap(), credentials())
            .await
            .unwrap();
        let (mut video, mut tracking) = (
            TcpStream::connect(("127.0.0.1", relay.local_video))
                .await
                .unwrap(),
            TcpStream::connect(("127.0.0.1", relay.local_tracking))
                .await
                .unwrap(),
        );
        let child = std::process::Command::new(binary)
            .arg(relay.ports.video.to_string())
            .arg(relay.ports.tracking.to_string())
            .spawn()
            .unwrap();
        for sequence in 0..2 {
            bounded(video.write_all(&frame(sequence, false)))
                .await
                .unwrap();
            let mut ack = [0; 20];
            bounded(video.read_exact(&mut ack)).await.unwrap();
            assert_eq!(&ack[..4], b"NFXA");
            assert_eq!(u64::from_le_bytes(ack[4..12].try_into().unwrap()), sequence);
            let mut request = [0; 32];
            request[..4].copy_from_slice(b"NFXP");
            request[4] = 1;
            request[6] = 32;
            bounded(tracking.write_all(&request)).await.unwrap();
            let mut response = [0; 64];
            bounded(tracking.read_exact(&mut response)).await.unwrap();
            assert_eq!(&response[..4], b"NFXT");
            assert_eq!(
                u64::from_le_bytes(response[16..24].try_into().unwrap()),
                sequence
            );
        }
        bounded(video.write_all(&frame(2, true))).await.unwrap();
        let mut end = [0; 12];
        bounded(video.read_exact(&mut end)).await.unwrap();
        assert_eq!(&end[..4], b"NFXE");
        let mut quit = [0; 32];
        quit[..4].copy_from_slice(b"NFXQ");
        quit[4] = 1;
        quit[6] = 32;
        bounded(tracking.write_all(&quit)).await.unwrap();
        let status = tokio::task::spawn_blocking(move || {
            let mut child = child;
            child.wait().unwrap()
        })
        .await
        .unwrap();
        assert!(status.success());
        assert!(!relay.failed());
    }

    #[cfg(target_os = "linux")]
    #[tokio::test(flavor = "multi_thread", worker_threads = 3)]
    #[ignore = "requires GPU runtime, native worker client and synthetic endpoint"]
    async fn managed_gpu_runtime_through_live_relays() {
        use std::io::BufRead;
        struct Process(std::process::Child);
        impl Drop for Process {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let root = std::path::PathBuf::from(std::env::var("NIGHTFALL_XR_RELAY_ROOT").unwrap());
        let client = std::env::var("NIGHTFALL_XR_RELAY_CPP_CLIENT").unwrap();
        let reserve = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = reserve.local_addr().unwrap().port();
        drop(reserve);
        let mut publisher = Process(
            std::process::Command::new(
                root.join(".build-cache/meteor-xr/tracking-runtime-spike/synthetic-publisher"),
            )
            .args([port.to_string(), "moving".into()])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap(),
        );
        let mut line = String::new();
        std::io::BufReader::new(publisher.0.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        assert!(line.contains("READY"));
        let started = std::time::SystemTime::now();
        let mut relay = Relay::prepare("127.0.0.1".parse().unwrap(), credentials())
            .await
            .unwrap();
        relay.start_runtime(root.clone());
        let child = Process(
            std::process::Command::new(client)
                .args([
                    relay.ports.video.to_string(),
                    relay.ports.tracking.to_string(),
                    port.to_string(),
                ])
                .spawn()
                .unwrap(),
        );
        let result = tokio::task::spawn_blocking(move || {
            let mut child = child;
            child.0.wait().unwrap()
        })
        .await
        .unwrap();
        assert!(result.success());
        assert!(publisher.0.wait().unwrap().success());
        let until = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let proof = std::fs::read_dir(root.join(".build-cache/meteor-xr/lan-sessions"))
                .unwrap()
                .filter_map(Result::ok)
                .map(|entry| entry.path().join("engine-outcome.json"))
                .find(|path| {
                    path.metadata()
                        .ok()
                        .and_then(|m| m.modified().ok())
                        .is_some_and(|time| time >= started)
                });
            if let Some(proof) = proof {
                let report: serde_json::Value =
                    serde_json::from_slice(&std::fs::read(&proof).unwrap()).unwrap();
                assert_eq!(report["engine_shutdown_clean"], true);
                assert_eq!(report["encoder_drain_verified"], true);
                break;
            }
            assert!(
                tokio::time::Instant::now() < until,
                "No normal runtime validation proof; see lan-sessions/<attempt>/runtime.log"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(!relay.failed());
    }
}
