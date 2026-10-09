//! The depth side channel: the Nightfall client connects to this TCP port
//! once its stream is up, and Meteor sends it every depth map made from that
//! client's video, tagged with the frame number the client's decoder sees.
//!
//! The client first sends `NFDK` and its X25519 public key (36 bytes), made
//! for this connection; both sides derive an AES-256-GCM key from it and
//! Meteor's key with DEPTH_KDF_INFO (see crypto.rs). After that the client
//! sends nothing.
//!
//! Each message is a 32-byte little-endian header followed by the map,
//! compressed with zstd, then encrypted with a 16-byte tag. The header is
//! the additional data and the message's index on the connection (from 0)
//! is the nonce:
//!
//! ```text
//!  0  magic "NFDM"          16  width u16            24  payload length u32 (with the tag)
//!  4  version u16 (2)       18  height u16           28  frame-in to map-out, µs u32
//!  6  header length u16     20  format u8 (0 = L8)
//!  8  epoch u32             21  compression u8 (1 = zstd)
//! 12  frame number u32      22  flags u16 (bit 0: made after packet loss)
//! ```
//!
//! When the network can't keep up, maps made while one is being written are
//! skipped; only the newest is sent next.

use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use crate::crypto::{KEY_BYTES, MeteorKey, TAG_BYTES};
use crate::depth::{Depth, DepthMap};

pub const DEFAULT_DEPTH_PORT: u16 = 47901;
pub const FORMAT_L8: &str = "L8";
pub const HEADER_LEN: usize = 32;
const MAGIC: &[u8; 4] = b"NFDM";
const VERSION: u16 = 2;
const HELLO_MAGIC: &[u8; 4] = b"NFDK";
const DEPTH_KDF_INFO: &[u8] = b"nightfall-meteor depth v2";
const COMPRESSION_ZSTD: u8 = 1;
const ZSTD_LEVEL: i32 = 1;
/// A client may connect just before its video flow opens.
const STREAM_WAIT: Duration = Duration::from_secs(5);

pub fn start(port: u16, depth: Arc<Depth>, key: Arc<MeteorKey>, allowed: Arc<dyn Fn(IpAddr) -> bool + Send + Sync>) -> Option<u16> {
    let listener = match crate::net::tcp_listener_std(port).or_else(|_| TcpListener::bind(("0.0.0.0", port))) {
        Ok(listener) => listener,
        Err(err) => {
            log::warn!("Can't listen on depth port {port} ({err}); host depth won't reach clients");
            return None;
        }
    };
    log::info!("depth TCP :{port}");
    let spawned = std::thread::Builder::new().name("depth-server".into()).spawn(move || {
        for stream in listener.incoming().flatten() {
            let depth = depth.clone();
            let key = key.clone();
            let allowed = allowed.clone();
            let _ = std::thread::Builder::new().name("depth-client".into()).spawn(move || {
                let Ok(peer) = stream.peer_addr() else { return };
                if let Err(err) = serve(stream, peer, &depth, &key, &*allowed) {
                    log::info!("Depth client {peer} disconnected ({err})");
                }
            });
        }
    });
    spawned.ok().map(|_| port)
}

fn serve(mut stream: TcpStream, peer: SocketAddr, depth: &Depth, key: &MeteorKey, allowed: &dyn Fn(IpAddr) -> bool) -> io::Result<()> {
    let ip = peer.ip().to_canonical();
    let waited = Instant::now();
    while !(ip.is_loopback() || allowed(ip)) {
        if waited.elapsed() > STREAM_WAIT {
            log::info!("Depth connection from {peer} refused: not a streaming client");
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    stream.set_read_timeout(Some(STREAM_WAIT))?;
    let mut hello = [0u8; 4 + KEY_BYTES];
    stream.read_exact(&mut hello)?;
    let theirs: [u8; KEY_BYTES] = hello[4..].try_into().expect("the hello holds one key");
    let session = match (&hello[..4] == HELLO_MAGIC).then(|| key.session_key(&theirs, DEPTH_KDF_INFO)).flatten() {
        Some(session) => session,
        None => {
            log::info!("Depth connection from {peer} refused: no valid key");
            return Ok(());
        }
    };
    stream.set_read_timeout(None)?;
    stream.set_nodelay(true)?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    depth.subscribers.fetch_add(1, Ordering::Relaxed);
    let _guard = Subscribed(depth);
    log::info!("Depth client {peer} connected");

    let mut last_seq = depth.latest.lock().ok().and_then(|m| m.as_ref().map(|m| m.seq)).unwrap_or(0);
    let mut compressor = zstd::bulk::Compressor::new(ZSTD_LEVEL)?;
    let mut message = Vec::new();
    let mut sent = 0u64;
    let mut last_sent: Option<(Instant, Instant, u64)> = None;
    loop {
        let map = {
            let Ok(latest) = depth.latest.lock() else { return Ok(()) };
            let (latest, _) = depth
                .map_ready
                .wait_timeout_while(latest, Duration::from_secs(1), |m| m.as_ref().is_none_or(|m| m.seq <= last_seq))
                .unwrap_or_else(|e| e.into_inner());
            latest.clone().filter(|m| m.seq > last_seq)
        };
        let Some(map) = map else {
            // Nothing to send; notice a client that has gone away.
            if closed(&stream)? {
                return Err(io::Error::new(io::ErrorKind::ConnectionAborted, format!("closed after {sent} maps")));
            }
            continue;
        };
        last_seq = map.seq;
        // Only this client's own video (or anyone's, for a local test client).
        if !(ip.is_loopback() || map.client == Some(ip)) {
            continue;
        }
        let encode_start = Instant::now();
        encode(&map, &mut compressor, &session, sent, &mut message)?;
        let write_start = Instant::now();
        stream.write_all(&message)?;
        let sent_at = Instant::now();
        if let Some((previous_sent, previous_done, previous_seq)) = last_sent {
            let send_gap = sent_at.duration_since(previous_sent);
            let map_gap = map.done.saturating_duration_since(previous_done);
            if send_gap >= Duration::from_millis(100) || map_gap >= Duration::from_millis(100) {
                log::info!(
                    "Depth delivery gap to {peer}: send {:.0} ms, maps {:.0} ms, {} maps advanced, encode {:.1} ms, write {:.1} ms, map age {:.1} ms, frame {}",
                    send_gap.as_secs_f64() * 1000.0,
                    map_gap.as_secs_f64() * 1000.0,
                    map.seq.saturating_sub(previous_seq),
                    (write_start - encode_start).as_secs_f64() * 1000.0,
                    (sent_at - write_start).as_secs_f64() * 1000.0,
                    sent_at.duration_since(map.done).as_secs_f64() * 1000.0,
                    map.frame_index,
                );
            }
        }
        last_sent = Some((sent_at, map.done, map.seq));
        sent += 1;
    }
}

struct Subscribed<'a>(&'a Depth);

impl Drop for Subscribed<'_> {
    fn drop(&mut self) {
        self.0.subscribers.fetch_sub(1, Ordering::Relaxed);
    }
}

/// True once the client has closed its end (it never sends anything).
fn closed(stream: &TcpStream) -> io::Result<bool> {
    stream.set_nonblocking(true)?;
    let mut buf = [0u8; 64];
    let result = match stream.peek(&mut buf) {
        Ok(0) => Ok(true),
        Ok(_) => Ok(false),
        Err(err) if err.kind() == io::ErrorKind::WouldBlock => Ok(false),
        Err(err) => Err(err),
    };
    stream.set_nonblocking(false)?;
    result
}

/// One message: header, then the compressed map sealed with message number
/// `index` as the nonce.
fn encode(map: &DepthMap, compressor: &mut zstd::bulk::Compressor, key: &ring::aead::LessSafeKey, index: u64, out: &mut Vec<u8>) -> io::Result<()> {
    let mut payload = compressor.compress(&map.data)?;
    let latency = u32::try_from(map.done.saturating_duration_since(map.frame_queued).as_micros()).unwrap_or(u32::MAX);
    out.clear();
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&VERSION.to_le_bytes());
    out.extend_from_slice(&(HEADER_LEN as u16).to_le_bytes());
    out.extend_from_slice(&map.epoch.to_le_bytes());
    out.extend_from_slice(&map.frame_index.to_le_bytes());
    out.extend_from_slice(&(map.width as u16).to_le_bytes());
    out.extend_from_slice(&(map.height as u16).to_le_bytes());
    out.push(0); // L8
    out.push(COMPRESSION_ZSTD);
    out.extend_from_slice(&u16::from(map.after_loss).to_le_bytes());
    out.extend_from_slice(&((payload.len() + TAG_BYTES) as u32).to_le_bytes());
    out.extend_from_slice(&latency.to_le_bytes());
    debug_assert_eq!(out.len(), HEADER_LEN);
    key.seal_in_place_append_tag(crate::crypto::nonce(index), ring::aead::Aad::from(&out[..]), &mut payload)
        .map_err(|_| io::Error::other("encrypting a depth map failed"))?;
    out.extend_from_slice(&payload);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(data: Vec<u8>) -> DepthMap {
        let now = Instant::now();
        DepthMap {
            stream: 1,
            client: None,
            seq: 1,
            epoch: 2,
            frame_index: 48213,
            after_loss: true,
            width: 4,
            height: 2,
            data,
            frame_queued: now,
            decoded: now,
            infer_start: now,
            infer_end: now,
            done: now + Duration::from_micros(1800),
        }
    }

    /// The headset's session key for Meteor key seed 7 and headset seed 9.
    fn keys() -> (MeteorKey, ring::aead::LessSafeKey, ring::aead::LessSafeKey) {
        let meteor = MeteorKey::from_seed([7; KEY_BYTES]);
        let headset = x25519_dalek::StaticSecret::from([9; KEY_BYTES]);
        let headset_public = x25519_dalek::PublicKey::from(&headset).to_bytes();
        let shared = headset.diffie_hellman(&x25519_dalek::PublicKey::from(meteor.public));
        let theirs = crate::crypto::derive(shared.as_bytes(), &headset_public, &meteor.public, DEPTH_KDF_INFO);
        let ours = meteor.session_key(&headset_public, DEPTH_KDF_INFO).unwrap();
        (meteor, ours, theirs)
    }

    #[test]
    fn encodes_header_and_encrypted_zstd_payload() {
        let (_, ours, theirs) = keys();
        let data: Vec<u8> = (0..8).collect();
        let mut out = Vec::new();
        encode(&map(data.clone()), &mut zstd::bulk::Compressor::new(ZSTD_LEVEL).unwrap(), &ours, 5, &mut out).unwrap();
        assert_eq!(&out[0..4], b"NFDM");
        assert_eq!(u16::from_le_bytes([out[4], out[5]]), 2);
        assert_eq!(u16::from_le_bytes([out[6], out[7]]) as usize, HEADER_LEN);
        assert_eq!(u32::from_le_bytes(out[8..12].try_into().unwrap()), 2);
        assert_eq!(u32::from_le_bytes(out[12..16].try_into().unwrap()), 48213);
        assert_eq!(u16::from_le_bytes([out[16], out[17]]), 4);
        assert_eq!(u16::from_le_bytes([out[18], out[19]]), 2);
        assert_eq!((out[20], out[21]), (0, 1));
        assert_eq!(u16::from_le_bytes([out[22], out[23]]), 1);
        let len = u32::from_le_bytes(out[24..28].try_into().unwrap()) as usize;
        assert_eq!(u32::from_le_bytes(out[28..32].try_into().unwrap()), 1800);
        assert_eq!(out.len(), HEADER_LEN + len);
        let (header, body) = out.split_at_mut(HEADER_LEN);
        let plain = theirs.open_in_place(crate::crypto::nonce(5), ring::aead::Aad::from(&*header), body).unwrap();
        assert_eq!(zstd::bulk::decompress(plain, 8).unwrap(), data);
        // The wrong message number fails.
        let mut again = Vec::new();
        encode(&map(data), &mut zstd::bulk::Compressor::new(ZSTD_LEVEL).unwrap(), &ours, 5, &mut again).unwrap();
        let (header, body) = again.split_at_mut(HEADER_LEN);
        assert!(theirs.open_in_place(crate::crypto::nonce(6), ring::aead::Aad::from(&*header), body).is_err());
    }

    /// A fixed vector for the headset's decryption (nightfall-stream's
    /// MeteorCipher): the payload of message 0 for the map below.
    #[test]
    fn known_depth_message() {
        let (_, ours, _) = keys();
        let mut out = Vec::new();
        encode(&map((0..8).collect()), &mut zstd::bulk::Compressor::new(ZSTD_LEVEL).unwrap(), &ours, 0, &mut out).unwrap();
        let hex: String = out.iter().map(|b| format!("{b:02x}")).collect();
        eprintln!("depth message 0: {hex}");
    }
}
