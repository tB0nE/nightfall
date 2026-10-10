//! Microphone passthrough: the headset sends its microphone to Meteor over
//! UDP, and Meteor plays it into a virtual input device on the PC
//! ("Nightfall Microphone"), which any app can record from.
//!
//! Linux: a PipeWire virtual source created with `pactl`, fed through a
//! `pw-cat` child process (see VirtualMic), so no PipeWire development
//! libraries are needed.
//!
//! Packet (UDP, little-endian), one per 10 ms:
//!
//! | bytes | field |
//! |---|---|
//! | 0-3 | magic `NFMC` |
//! | 4 | version: 2 encrypted, 1 plain (loopback only, for tools/send_mic.py) |
//! | 5 | flags: bit 0 = muted on the headset |
//! | 6 | format: 0 = PCM s16le, 48 kHz, mono; 1 = Opus, 48 kHz, mono |
//! | 7 | reserved |
//! | 8-11 | sequence number |
//! | 12-15 | timestamp of the first sample, in samples |
//! | v2: 16-47 | the sender's X25519 public key |
//! | then | the frame: 480 PCM samples (960 bytes), or one Opus packet (v2 only; empty when muted); v2: encrypted, then a 16-byte tag |
//!
//! Encryption (v2, see crypto.rs): the headset makes a key pair for each
//! microphone session and sends its public key in every packet, so there's
//! no handshake to lose. The session key comes from Meteor's key with
//! MIC_KDF_INFO, the nonce is the sequence number, and the header (bytes
//! 0-47) is the additional data.
//!
//! Opus frames are decoded at playout, in sequence order. A lost one is
//! rebuilt from the next packet's forward error correction when that has
//! arrived, else from the decoder's loss concealment.
//!
//! A playout thread moves one frame every 10 ms from a jitter buffer into
//! the device (see Mic::play). The jitter buffer starts once 40 ms
//! are buffered, drops the oldest audio when more than 120 ms build up (so
//! delay never grows), and fills a missing frame with silence.

use std::collections::BTreeMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const DEFAULT_MIC_PORT: u16 = 47902;
pub const FORMAT_PCM_S16LE_48K_MONO: &str = "pcm_s16le_48k_mono";
pub const FORMAT_OPUS_48K_MONO: &str = "opus_48k_mono";
const FORMAT_PCM: u8 = 0;
const FORMAT_OPUS: u8 = 1;
/// Larger than any Opus packet for 10 ms of mono voice.
const MAX_OPUS_BYTES: usize = 1275;
const MAGIC: &[u8; 4] = b"NFMC";
const VERSION_PLAIN: u8 = 1;
const VERSION_ENCRYPTED: u8 = 2;
const HEADER: usize = 16;
const KEY_BYTES: usize = crate::crypto::KEY_BYTES;
const ENCRYPTED_HEADER: usize = HEADER + KEY_BYTES;
const TAG_BYTES: usize = crate::crypto::TAG_BYTES;
const MIC_KDF_INFO: &[u8] = b"nightfall-meteor mic v2";
/// Senders' derived keys kept at once (one per headset session).
const MAX_SENDER_KEYS: usize = 8;
const FRAME_SAMPLES: usize = 480;
const FRAME_BYTES: usize = FRAME_SAMPLES * 2;
/// Playout starts once this many frames are buffered (40 ms).
const TARGET_FRAMES: usize = 4;
/// More than this (120 ms) and the oldest frames are dropped.
const MAX_FRAMES: usize = 12;
/// No packets for this long and the stream counts as stopped.
const IDLE_AFTER: Duration = Duration::from_millis(500);
const FRAME: Duration = Duration::from_millis(10);
/// Silence written ahead of each stream (30 ms); see Mic::play.
const PREROLL_FRAMES: usize = 3;
#[cfg(target_os = "linux")]
const SOURCE_NAME: &str = "nightfall_mic";

#[derive(Default)]
pub struct MicStats {
    pub packets: AtomicU64,
    pub played: AtomicU64,
    pub concealed: AtomicU64,
    pub dropped: AtomicU64,
    pub rejected: AtomicU64,
}

/// A received frame, still encoded if it's Opus.
#[derive(Clone)]
enum Frame {
    Pcm(Vec<u8>),
    Opus(Vec<u8>),
}

#[derive(Default)]
struct Jitter {
    frames: BTreeMap<u32, Frame>,
    /// The next sequence number to play, once playing.
    next: Option<u32>,
    last_packet: Option<Instant>,
    sender: Option<SocketAddr>,
}

pub struct Mic {
    pub port: u16,
    key: Arc<crate::crypto::MeteorKey>,
    /// AES-256-GCM keys by sender public key.
    keys: Mutex<Vec<([u8; KEY_BYTES], ring::aead::LessSafeKey)>>,
    pub stats: MicStats,
    pub muted: AtomicBool,
    jitter: Mutex<Jitter>,
    device: Mutex<Option<VirtualMic>>,
}

impl Mic {
    /// Creates the virtual device and starts listening. None when the
    /// device can't be created (no PipeWire/PulseAudio or Windows virtual cable).
    pub async fn start(port: u16, key: Arc<crate::crypto::MeteorKey>, allowed: Arc<dyn Fn(IpAddr) -> bool + Send + Sync>) -> Option<Arc<Mic>> {
        let device = match VirtualMic::create() {
            Ok(device) => device,
            Err(err) => {
                log::warn!("Microphone passthrough is off: {err}");
                return None;
            }
        };
        let socket = match crate::net::udp_socket(port).await {
            Ok(socket) => socket,
            Err(_) => match tokio::net::UdpSocket::bind(("0.0.0.0", port)).await {
                Ok(socket) => socket,
                Err(err) => {
                log::warn!("Microphone passthrough is off: can't listen on UDP {port}: {err}");
                return None;
                }
            },
        };
        #[cfg(target_os = "linux")]
        log::info!("Microphone: UDP :{port} -> PipeWire source \"Nightfall Microphone\" ({SOURCE_NAME}), encrypted");
        #[cfg(windows)]
        log::info!("Microphone: UDP :{port} -> VB-CABLE Input (record from CABLE Output), encrypted");
        let mic = Arc::new(Mic {
            port,
            key,
            keys: Mutex::default(),
            stats: MicStats::default(),
            muted: AtomicBool::new(false),
            jitter: Mutex::default(),
            device: Mutex::new(Some(device)),
        });
        tokio::spawn(mic.clone().receive(socket, allowed));
        let playout = mic.clone();
        if let Err(err) = std::thread::Builder::new().name("mic-playout".into()).spawn(move || playout.play()) {
            log::warn!("Microphone playout thread failed: {err}");
        }
        Some(mic)
    }

    /// "idle" or "live from <address>".
    pub fn status(&self) -> String {
        let Ok(jitter) = self.jitter.lock() else { return String::new() };
        match (jitter.sender, jitter.last_packet) {
            (Some(sender), Some(last)) if last.elapsed() < IDLE_AFTER => format!("live from {}", sender.ip()),
            _ => "idle".into(),
        }
    }

    #[cfg(target_os = "linux")]
    pub fn set_default_input(&self) {
        match std::process::Command::new("pactl").args(["set-default-source", SOURCE_NAME]).status() {
            Ok(status) if status.success() => log::info!("Nightfall Microphone is now the default input"),
            Ok(status) => log::warn!("pactl set-default-source failed ({status})"),
            Err(err) => log::warn!("Can't run pactl: {err}"),
        }
    }

    /// Removes the virtual device. Called on exit.
    pub fn shutdown(&self) {
        if let Ok(mut device) = self.device.lock() {
            device.take();
        }
    }

    async fn receive(self: Arc<Self>, socket: tokio::net::UdpSocket, allowed: Arc<dyn Fn(IpAddr) -> bool + Send + Sync>) {
        let mut buf = [0u8; 2048];
        loop {
            let Ok((len, from)) = socket.recv_from(&mut buf).await else { continue };
            let ip = from.ip().to_canonical();
            if !(ip.is_loopback() || allowed(ip)) {
                // Only a client that is streaming through Meteor may send.
                if self.stats.rejected.fetch_add(1, Ordering::Relaxed) == 0 {
                    log::warn!("Ignoring microphone packets from {from}: it isn't streaming through Meteor");
                }
                continue;
            }
            let Some((seq, muted_on_headset, format, payload)) = self.open(&mut buf[..len], ip.is_loopback()) else { continue };
            self.stats.packets.fetch_add(1, Ordering::Relaxed);
            let Ok(mut jitter) = self.jitter.lock() else { return };
            if jitter.sender != Some(from) {
                log::info!("Microphone stream from {from}");
                jitter.frames.clear();
                jitter.next = None;
                jitter.sender = Some(from);
            }
            jitter.last_packet = Some(Instant::now());
            // Late, or already played.
            if jitter.next.is_some_and(|next| seq_before(seq, next)) {
                continue;
            }
            let frame = match format {
                _ if muted_on_headset => Frame::Pcm(vec![0u8; FRAME_BYTES]),
                FORMAT_OPUS => Frame::Opus(payload.to_vec()),
                _ => Frame::Pcm(payload.to_vec()),
            };
            jitter.frames.insert(seq, frame);
        }
    }

    /// Writes one frame every 10 ms on Meteor's clock while a stream is
    /// live. The device reads a whole graph quantum at a time (21 ms at
    /// PipeWire's default 1024 samples) and pads any shortfall with silence,
    /// so each stream starts with PREROLL_FRAMES of silence as a cushion
    /// (measured 2026-10-03: no pre-roll, 115 gaps in 3 s; 30 ms pre-roll,
    /// none, and about 30 ms from write to recorder).
    ///
    /// Known limit: the device's clock and Meteor's drift apart slowly
    /// (typically tens of ppm), which over a long session either grows the
    /// delay or eats the cushion. pw-cat buffers its input internally, so
    /// its fill level can't be observed to correct for it.
    fn play(self: Arc<Self>) {
        let silence = vec![0u8; FRAME_BYTES];
        let mut tick = Instant::now();
        let mut last_log = Instant::now();
        let mut playing = false;
        // One per stream, so its state follows that stream's frames.
        let mut decoder: Option<opus::Decoder> = None;
        loop {
            tick += FRAME;
            match tick.checked_duration_since(Instant::now()) {
                Some(wait) => std::thread::sleep(wait),
                // Fell far behind (suspended?): restart the clock.
                None if tick.elapsed() > Duration::from_millis(100) => tick = Instant::now(),
                None => {}
            }
            if last_log.elapsed() >= Duration::from_secs(1) {
                last_log = Instant::now();
                self.log_levels();
            }
            let (frame, following) = {
                let Ok(mut jitter) = self.jitter.lock() else { return };
                let frame = self.next_frame(&mut jitter);
                // A lost Opus frame can be rebuilt from the next packet.
                let following = match &frame {
                    Some(None) => jitter.next.and_then(|n| jitter.frames.get(&n).cloned()),
                    _ => None,
                };
                (frame, following)
            };
            let Some(frame) = frame else {
                playing = false;
                decoder = None;
                continue;
            };
            let Ok(mut device) = self.device.lock() else { return };
            let Some(device) = device.as_mut() else { continue };
            if !playing {
                playing = true;
                for _ in 0..PREROLL_FRAMES {
                    let _ = device.write(&silence);
                }
            }
            if frame.is_none() {
                self.stats.concealed.fetch_add(1, Ordering::Relaxed);
            }
            let pcm = match frame {
                Some(Frame::Pcm(pcm)) => Some(pcm),
                Some(Frame::Opus(packet)) => decode(&mut decoder, &packet, false),
                None => match following {
                    Some(Frame::Opus(next)) => decode(&mut decoder, &next, true),
                    _ if decoder.is_some() => decode(&mut decoder, &[], false),
                    _ => None,
                },
            };
            let data = if self.muted.load(Ordering::Relaxed) { &silence } else { pcm.as_ref().unwrap_or(&silence) };
            match device.write(data) {
                Ok(true) => {
                    self.stats.played.fetch_add(1, Ordering::Relaxed);
                }
                Ok(false) => {
                    self.stats.dropped.fetch_add(1, Ordering::Relaxed);
                }
                Err(err) => log::warn!("Microphone write failed: {err}"),
            }
        }
    }

    fn log_levels(&self) {
        let buffered = self.jitter.lock().map_or(0, |j| j.frames.len());
        let pipe = self.device.try_lock().ok().and_then(|d| d.as_ref().and_then(VirtualMic::fill));
        if buffered > 0 {
            log::debug!(
                "mic: jitter {} ms, device pipe {} ms, played {}, concealed {}, dropped {}",
                buffered * 10,
                pipe.unwrap_or(0) / 96,
                self.stats.played.load(Ordering::Relaxed),
                self.stats.concealed.load(Ordering::Relaxed),
                self.stats.dropped.load(Ordering::Relaxed)
            );
        }
    }

    /// None: not playing (idle or still buffering). Some(None): play silence
    /// for a missing frame. Some(Some(pcm)): play this frame.
    fn next_frame(&self, jitter: &mut Jitter) -> Option<Option<Frame>> {
        let live = jitter.last_packet.is_some_and(|t| t.elapsed() < IDLE_AFTER);
        if !live {
            if jitter.next.take().is_some() {
                log::info!("Microphone stream stopped");
            }
            jitter.frames.clear();
            return None;
        }
        let next = match jitter.next {
            Some(next) => next,
            None => {
                if jitter.frames.len() < TARGET_FRAMES {
                    return None;
                }
                *jitter.frames.keys().next()?
            }
        };
        // Too much buffered: drop the oldest down to the target.
        let mut next = next;
        if jitter.frames.len() > MAX_FRAMES {
            while jitter.frames.len() > TARGET_FRAMES {
                let Some((oldest, _)) = jitter.frames.pop_first() else { break };
                self.stats.dropped.fetch_add(1, Ordering::Relaxed);
                next = oldest.wrapping_add(1);
            }
        }
        let frame = jitter.frames.remove(&next);
        jitter.next = Some(next.wrapping_add(1));
        Some(frame)
    }
}

impl Mic {
    /// Checks a packet and returns (sequence, muted, format, frame),
    /// decrypting it in place. Plain (v1) packets count only from loopback.
    fn open<'a>(&self, packet: &'a mut [u8], loopback: bool) -> Option<(u32, bool, u8, &'a [u8])> {
        if packet.len() < HEADER || &packet[..4] != MAGIC {
            return None;
        }
        let seq = u32::from_le_bytes([packet[8], packet[9], packet[10], packet[11]]);
        let muted = packet[5] & 1 != 0;
        let format = packet[6];
        let body = packet.len().saturating_sub(ENCRYPTED_HEADER + TAG_BYTES);
        let size_ok = match format {
            FORMAT_PCM => body == FRAME_BYTES,
            FORMAT_OPUS => body <= MAX_OPUS_BYTES && packet.len() >= ENCRYPTED_HEADER + TAG_BYTES,
            _ => false,
        };
        match packet[4] {
            VERSION_PLAIN if loopback && format == FORMAT_PCM && packet.len() == HEADER + FRAME_BYTES => {
                Some((seq, muted, format, &packet[HEADER..]))
            }
            VERSION_ENCRYPTED if size_ok => {
                let sender: [u8; KEY_BYTES] = packet[HEADER..ENCRYPTED_HEADER].try_into().ok()?;
                let (header, body) = packet.split_at_mut(ENCRYPTED_HEADER);
                let mut keys = self.keys.lock().ok()?;
                let index = match keys.iter().position(|(k, _)| *k == sender) {
                    Some(index) => index,
                    None => {
                        let key = self.key.session_key(&sender, MIC_KDF_INFO)?;
                        if keys.len() >= MAX_SENDER_KEYS {
                            keys.remove(0);
                        }
                        keys.push((sender, key));
                        keys.len() - 1
                    }
                };
                let pcm = keys[index]
                    .1
                    .open_in_place(crate::crypto::nonce(u64::from(seq)), ring::aead::Aad::from(&*header), body)
                    .ok()?;
                Some((seq, muted, format, &*pcm))
            }
            _ => None,
        }
    }
}

/// One 10 ms frame from Opus: `packet` itself, its forward error correction
/// for the frame before it (`fec`), or, with no packet, loss concealment.
fn decode(decoder: &mut Option<opus::Decoder>, packet: &[u8], fec: bool) -> Option<Vec<u8>> {
    if decoder.is_none() {
        *decoder = opus::Decoder::new(48_000, opus::Channels::Mono).ok();
    }
    let mut out = [0i16; FRAME_SAMPLES];
    let samples = decoder.as_mut()?.decode(packet, &mut out, fec).ok()?;
    (samples == FRAME_SAMPLES).then(|| out.iter().flat_map(|s| s.to_le_bytes()).collect())
}

fn seq_before(a: u32, b: u32) -> bool {
    let d = b.wrapping_sub(a);
    d > 0 && d < 0x8000_0000
}

/// The virtual input device. Removed when dropped.
///
/// Preferred (Linux): a null sink with `media.class=Audio/Source/Virtual`,
/// which apps see as a microphone, fed by a `pw-cat` child process that
/// Meteor writes PCM into and links to the device with `pw-link`. Measured
/// at about 8 ms from write to recorder (2026-10-03).
///
/// Fallback: `module-pipe-source`, which needs only `pactl` but whose rate
/// control holds about 260 ms of audio.
struct VirtualMic {
    #[cfg(target_os = "linux")]
    module: String,
    #[cfg(target_os = "linux")]
    feed: Feed,
    #[cfg(windows)]
    feed: std::sync::mpsc::SyncSender<Vec<u8>>,
    #[cfg(windows)]
    queued: Arc<std::sync::atomic::AtomicUsize>,
}

#[cfg(target_os = "linux")]
enum Feed {
    PwCat { child: std::process::Child, stdin: std::process::ChildStdin },
    Pipe(std::fs::File),
}

#[cfg(target_os = "linux")]
const FEED_NODE: &str = "nightfall_mic_feed";
#[cfg(target_os = "linux")]
const DEVICE_PROPS: &str = "device.description=\"Nightfall Microphone\" device.icon_name=audio-input-microphone";

#[cfg(target_os = "linux")]
impl VirtualMic {
    fn create() -> Result<VirtualMic, String> {
        // A device left behind by a crashed Meteor would otherwise appear twice.
        remove_stale_modules();
        match Self::create_linked() {
            Ok(mic) => return Ok(mic),
            Err(err) => log::warn!("Low-latency microphone device unavailable ({err}); using a pipe source (adds ~260 ms)"),
        }
        Self::create_pipe()
    }

    fn create_linked() -> Result<VirtualMic, String> {
        use std::process::{Command, Stdio};
        let module = pactl_load(&[
            "module-null-sink",
            &format!("sink_name={SOURCE_NAME}"),
            "media.class=Audio/Source/Virtual",
            "channel_map=mono",
            "rate=48000",
            &format!("sink_properties='{DEVICE_PROPS}'"),
        ])?;
        let mut child = match Command::new("pw-cat")
            .args(["--playback", "--raw", "--format", "s16", "--rate", "48000", "--channels", "1", "--latency", "10ms"])
            .args([
                "-P",
                &format!(
                    "{{ node.name = {FEED_NODE} node.description = \"Nightfall Microphone feed\" \
                     node.autoconnect = false node.dont-fallback = true }}"
                ),
                "-",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => child,
            Err(err) => {
                unload(&module);
                return Err(format!("can't run pw-cat: {err}"));
            }
        };
        let stdin = child.stdin.take().expect("piped stdin");
        set_nonblocking(&stdin);
        let mic = VirtualMic { module, feed: Feed::PwCat { child, stdin } };
        // The feed node appears asynchronously; link it once it exists.
        let link = || {
            Command::new("pw-link")
                .args([format!("{FEED_NODE}:output_MONO"), format!("{SOURCE_NAME}:input_MONO")])
                .stderr(Stdio::null())
                .status()
                .is_ok_and(|s| s.success())
        };
        for _ in 0..40 {
            if link() {
                return Ok(mic);
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        Err("couldn't link pw-cat to the device (pw-link)".into()) // mic drops: unloads and kills
    }

    fn create_pipe() -> Result<VirtualMic, String> {
        use std::os::unix::fs::OpenOptionsExt;
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").ok_or("XDG_RUNTIME_DIR isn't set")?;
        let path = std::path::Path::new(&runtime).join("nightfall-mic");
        let module = pactl_load(&[
            "module-pipe-source",
            &format!("source_name={SOURCE_NAME}"),
            &format!("file={}", path.display()),
            "format=s16le",
            "rate=48000",
            "channels=1",
            &format!("source_properties='{DEVICE_PROPS}'"),
        ])?;
        // The source keeps the read end open; non-blocking so a stalled
        // PipeWire can never block the playout thread.
        let fifo = std::fs::OpenOptions::new()
            .write(true)
            .custom_flags(O_NONBLOCK)
            .open(&path)
            .map_err(|err| {
                unload(&module);
                format!("can't open {}: {err}", path.display())
            })?;
        Ok(VirtualMic { module, feed: Feed::Pipe(fifo) })
    }

    fn fill(&self) -> Option<usize> {
        match &self.feed {
            Feed::PwCat { stdin, .. } => pipe_fill(stdin),
            Feed::Pipe(fifo) => pipe_fill(fifo),
        }
    }

    /// Ok(false) when the pipe is full.
    fn write(&mut self, pcm: &[u8]) -> std::io::Result<bool> {
        use std::io::Write;
        let result = match &mut self.feed {
            Feed::PwCat { stdin, .. } => stdin.write(pcm),
            Feed::Pipe(fifo) => fifo.write(pcm),
        };
        match result {
            Ok(n) if n == pcm.len() => Ok(true),
            Ok(_) => Ok(false),
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => Ok(false),
            Err(err) => Err(err),
        }
    }
}

#[cfg(target_os = "linux")]
impl Drop for VirtualMic {
    fn drop(&mut self) {
        if let Feed::PwCat { child, .. } = &mut self.feed {
            let _ = child.kill();
            let _ = child.wait();
        }
        unload(&self.module);
        log::info!("Removed the Nightfall Microphone device");
    }
}

#[cfg(target_os = "linux")]
const O_NONBLOCK: i32 = 0o4000;

#[cfg(target_os = "linux")]
unsafe extern "C" {
    fn ioctl(fd: i32, request: u64, ...) -> i32;
    fn fcntl(fd: i32, cmd: i32, ...) -> i32;
}

#[cfg(target_os = "linux")]
fn set_nonblocking(file: &impl std::os::fd::AsRawFd) {
    const F_GETFL: i32 = 3;
    const F_SETFL: i32 = 4;
    let fd = file.as_raw_fd();
    // SAFETY: plain fcntl flag calls on a descriptor we own.
    unsafe {
        let flags = fcntl(fd, F_GETFL);
        if flags >= 0 {
            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }
    }
}

/// Bytes waiting in a pipe (FIONREAD works on a pipe's write end on Linux).
#[cfg(target_os = "linux")]
fn pipe_fill(file: &impl std::os::fd::AsRawFd) -> Option<usize> {
    const FIONREAD: u64 = 0x541B;
    let mut bytes: i32 = 0;
    // SAFETY: FIONREAD writes one int through the pointer.
    let rc = unsafe { ioctl(file.as_raw_fd(), FIONREAD, &mut bytes as *mut i32) };
    (rc == 0).then_some(bytes as usize)
}

#[cfg(target_os = "linux")]
fn pactl_load(args: &[&str]) -> Result<String, String> {
    let output = std::process::Command::new("pactl")
        .arg("load-module")
        .args(args)
        .output()
        .map_err(|err| format!("can't run pactl ({err}); is PipeWire or PulseAudio installed?"))?;
    if !output.status.success() {
        return Err(format!("pactl load-module {} failed: {}", args[0], String::from_utf8_lossy(&output.stderr).trim()));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(target_os = "linux")]
fn unload(module: &str) {
    let _ = std::process::Command::new("pactl").args(["unload-module", module]).status();
}

#[cfg(target_os = "linux")]
fn remove_stale_modules() {
    let Ok(output) = std::process::Command::new("pactl").args(["list", "modules", "short"]).output() else { return };
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let ours = line.contains(&format!("source_name={SOURCE_NAME} ")) || line.contains(&format!("sink_name={SOURCE_NAME} "));
        if ours && let Some(id) = line.split_whitespace().next() {
            log::info!("Removing a Nightfall Microphone left from an earlier run");
            unload(id);
        }
    }
}

#[cfg(windows)]
impl VirtualMic {
    fn create() -> Result<VirtualMic, String> {
        let (feed, recv) = std::sync::mpsc::sync_channel(8);
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        let queued = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let report = queued.clone();
        std::thread::Builder::new().name("mic-wasapi".into())
            .spawn(move || windows_audio(recv, ready_tx, report))
            .map_err(|e| format!("can't start Windows audio thread: {e}"))?;
        ready_rx.recv().map_err(|_| "Windows audio thread exited during startup".to_string())??;
        Ok(VirtualMic { feed, queued })
    }

    fn write(&mut self, pcm: &[u8]) -> std::io::Result<bool> {
        use std::sync::mpsc::TrySendError;
        match self.feed.try_send(pcm.to_vec()) {
            Ok(()) => Ok(true),
            Err(TrySendError::Full(_)) => Ok(false),
            Err(TrySendError::Disconnected(_)) => Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "Windows audio thread stopped")),
        }
    }

    fn fill(&self) -> Option<usize> {
        Some(self.queued.load(Ordering::Relaxed))
    }
}

#[cfg(windows)]
fn windows_audio(
    recv: std::sync::mpsc::Receiver<Vec<u8>>,
    ready: std::sync::mpsc::SyncSender<Result<(), String>>,
    queued: Arc<std::sync::atomic::AtomicUsize>,
) {
    use wasapi::{DeviceEnumerator, Direction, StreamMode, WaveFormat, SampleType};
    let result = (|| -> Result<_, String> {
        wasapi::initialize_mta().ok().map_err(|e| format!("can't initialize COM for audio: {e:?}"))?;
        let devices = DeviceEnumerator::new().map_err(|e| e.to_string())?
            .get_device_collection(&Direction::Render).map_err(|e| e.to_string())?;
        let device = (&devices).into_iter().filter_map(Result::ok)
            .find(|d| d.get_friendlyname().ok().is_some_and(|name| {
                let name = name.to_ascii_lowercase();
                name.contains("cable input") || name.contains("cable-a input") || name.contains("cable-b input")
            }))
            .ok_or("VB-CABLE render device not found. Install VB-CABLE, then restart Meteor; select CABLE Output as the recording device in your app")?;
        log::info!("Windows microphone output: {}", device.get_friendlyname().unwrap_or_default());
        let mut client = device.get_iaudioclient().map_err(|e| e.to_string())?;
        let format = WaveFormat::new(16, 16, &SampleType::Int, 48_000, 1, None);
        client.initialize_client(&format, &Direction::Render, &StreamMode::PollingShared {
            autoconvert: true,
            buffer_duration_hns: 500_000,
        }).map_err(|e| format!("can't open VB-CABLE audio stream: {e}"))?;
        let render = client.get_audiorenderclient().map_err(|e| e.to_string())?;
        client.start_stream().map_err(|e| e.to_string())?;
        Ok((client, render))
    })();
    let (client, render) = match result {
        Ok(pair) => { let _ = ready.send(Ok(())); pair }
        Err(err) => { let _ = ready.send(Err(err)); return; }
    };
    while let Ok(pcm) = recv.recv() {
        let frames = pcm.len() / 2;
        match client.get_available_space_in_frames() {
            Ok(space) if space as usize >= frames => {
                if let Err(err) = render.write_to_device(frames, &pcm, None) {
                    log::warn!("VB-CABLE audio write failed: {err}");
                    break;
                }
            }
            Ok(_) => log::debug!("VB-CABLE audio buffer full; dropping one microphone frame"),
            Err(err) => { log::warn!("VB-CABLE audio buffer failed: {err}"); break; }
        }
        if let Ok(frames) = client.get_current_padding() {
            queued.store(frames as usize * 2, Ordering::Relaxed);
        }
    }
    let _ = client.stop_stream();
}

#[cfg(not(any(target_os = "linux", windows)))]
impl VirtualMic {
    fn create() -> Result<VirtualMic, String> {
        Err("needs a virtual audio driver on this platform (not supported yet)".into())
    }

    fn write(&mut self, _pcm: &[u8]) -> std::io::Result<bool> {
        Ok(false)
    }

    fn fill(&self) -> Option<usize> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(seq: u32, flags: u8) -> Vec<u8> {
        let mut p = MAGIC.to_vec();
        p.extend_from_slice(&[VERSION_PLAIN, flags, 0, 0]);
        p.extend_from_slice(&seq.to_le_bytes());
        p.extend_from_slice(&(seq * 480).to_le_bytes());
        p.extend(std::iter::repeat_n(seq as u8, FRAME_BYTES));
        p
    }

    fn mic() -> Mic {
        Mic {
            port: 0,
            key: Arc::new(crate::crypto::MeteorKey::from_seed([7u8; KEY_BYTES])),
            keys: Mutex::default(),
            stats: MicStats::default(),
            muted: AtomicBool::new(false),
            jitter: Mutex::default(),
            device: Mutex::new(None),
        }
    }

    #[test]
    fn plain_packets_only_from_loopback() {
        let m = mic();
        let mut muted_packet = packet(7, 1);
        let (seq, muted, format, pcm) = m.open(&mut muted_packet, true).unwrap();
        assert_eq!((seq, muted, format, pcm.len()), (7, true, FORMAT_PCM, FRAME_BYTES));
        assert!(m.open(&mut packet(7, 0), false).is_none());
        assert!(m.open(&mut packet(7, 0)[..100], true).is_none());
        let mut wrong = packet(7, 0);
        wrong[0] = b'X';
        assert!(m.open(&mut wrong, true).is_none());
    }

    /// Encrypts like the headset (meteor_mic.cpp).
    fn encrypted(m: &Mic, client: &x25519_dalek::StaticSecret, seq: u32, pcm: &[u8]) -> Vec<u8> {
        encrypted_frame(m, client, seq, FORMAT_PCM, pcm)
    }

    fn encrypted_frame(m: &Mic, client: &x25519_dalek::StaticSecret, seq: u32, format: u8, pcm: &[u8]) -> Vec<u8> {
        let client_public = x25519_dalek::PublicKey::from(client).to_bytes();
        let mut p = MAGIC.to_vec();
        p.extend_from_slice(&[VERSION_ENCRYPTED, 0, format, 0]);
        p.extend_from_slice(&seq.to_le_bytes());
        p.extend_from_slice(&(seq * 480).to_le_bytes());
        p.extend_from_slice(&client_public);
        // The headset's side of the agreement.
        let shared = client.diffie_hellman(&x25519_dalek::PublicKey::from(m.key.public));
        let key = crate::crypto::derive(shared.as_bytes(), &client_public, &m.key.public, MIC_KDF_INFO);
        let mut body = pcm.to_vec();
        key.seal_in_place_append_tag(crate::crypto::nonce(u64::from(seq)), ring::aead::Aad::from(&p[..]), &mut body)
            .unwrap();
        p.extend_from_slice(&body);
        p
    }

    #[test]
    fn decrypts_headset_packets() {
        let m = mic();
        let client = x25519_dalek::StaticSecret::from([9u8; KEY_BYTES]);
        let pcm: Vec<u8> = (0..FRAME_BYTES).map(|i| i as u8).collect();
        let mut p = encrypted(&m, &client, 42, &pcm);
        assert_eq!(p.len(), ENCRYPTED_HEADER + FRAME_BYTES + TAG_BYTES);
        let (seq, muted, format, out) = m.open(&mut p, false).unwrap();
        assert_eq!((seq, muted, format, out), (42, false, FORMAT_PCM, &pcm[..]));
        // Tampered audio, header or sequence number fails.
        for at in [60, 9, 5] {
            let mut bad = encrypted(&m, &client, 42, &pcm);
            bad[at] ^= 1;
            assert!(m.open(&mut bad, false).is_none(), "byte {at}");
        }
        // Another session's key derives its own.
        let other = x25519_dalek::StaticSecret::from([11u8; KEY_BYTES]);
        assert!(m.open(&mut encrypted(&m, &other, 1, &pcm), false).is_some());
        assert_eq!(m.keys.lock().unwrap().len(), 2);
    }

    /// A fixed vector for checking the headset's implementation against.
    #[test]
    fn known_session_key() {
        let m = mic();
        let client = x25519_dalek::StaticSecret::from([9u8; KEY_BYTES]);
        let p = encrypted(&m, &client, 1, &[0u8; FRAME_BYTES]);
        let hex: String = p[ENCRYPTED_HEADER..ENCRYPTED_HEADER + 8].iter().map(|b| format!("{b:02x}")).collect();
        let tag: String = p[p.len() - TAG_BYTES..].iter().map(|b| format!("{b:02x}")).collect();
        let public = m.key.public_hex();
        eprintln!("meteor public {public}\nfirst 8 ciphertext bytes {hex}\ntag {tag}");
    }

    fn first(frame: Frame) -> u8 {
        match frame {
            Frame::Pcm(pcm) => pcm[0],
            Frame::Opus(_) => panic!("expected PCM"),
        }
    }

    /// Encodes like the headset (meteor_mic.cpp): 10 ms frames at 48 kHz.
    #[test]
    fn opus_frames_decode_and_conceal() {
        let m = mic();
        let client = x25519_dalek::StaticSecret::from([9u8; KEY_BYTES]);
        let mut encoder = opus::Encoder::new(48_000, opus::Channels::Mono, opus::Application::Voip).unwrap();
        encoder.set_inband_fec(true).unwrap();
        encoder.set_packet_loss_perc(10).unwrap();
        let tone = |seq: u32| -> Vec<i16> {
            (0..FRAME_SAMPLES).map(|n| (8000.0 * (2.0 * std::f64::consts::PI * 440.0 * f64::from(seq * 480 + n as u32) / 48000.0).sin()) as i16).collect()
        };
        let mut decoder = None;
        let mut energy = Vec::new();
        let mut packets = Vec::new();
        for seq in 0..20 {
            let packet = encoder.encode_vec(&tone(seq), MAX_OPUS_BYTES).unwrap();
            let mut wire = encrypted_frame(&m, &client, seq, FORMAT_OPUS, &packet);
            let (got_seq, _, format, payload) = m.open(&mut wire, false).unwrap();
            assert_eq!((got_seq, format, payload), (seq, FORMAT_OPUS, &packet[..]));
            packets.push(packet);
        }
        for (seq, packet) in packets.iter().enumerate() {
            // Frame 12 is lost: rebuilt from 13's forward error correction.
            let pcm = if seq == 12 { decode(&mut decoder, &packets[13], true) } else { decode(&mut decoder, packet, false) }.unwrap();
            let samples: Vec<i16> = pcm.chunks(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
            energy.push((samples.iter().map(|&s| f64::from(s).powi(2)).sum::<f64>() / samples.len() as f64).sqrt());
        }
        // After the encoder's first frames, the tone comes through (8000 peak is about 5657 RMS), lost frame included.
        assert!(energy[5..].iter().all(|&e| e > 3000.0), "{energy:?}");
        // Loss concealment with no packet still gives a full frame.
        assert_eq!(decode(&mut decoder, &[], false).unwrap().len(), FRAME_BYTES);
        // A too-large Opus body is refused.
        let mut huge = encrypted_frame(&m, &client, 30, FORMAT_OPUS, &vec![0u8; MAX_OPUS_BYTES + 1]);
        assert!(m.open(&mut huge, false).is_none());
    }

    #[test]
    fn jitter_buffer_waits_conceals_and_caps_delay() {
        let m = mic();
        let mut j = Jitter { last_packet: Some(Instant::now()), ..Default::default() };
        let add = |j: &mut Jitter, seq: u32| {
            j.frames.insert(seq, Frame::Pcm(vec![seq as u8; FRAME_BYTES]));
        };
        // Waits until 40 ms are buffered.
        for seq in 10..13 {
            add(&mut j, seq);
        }
        assert!(m.next_frame(&mut j).is_none());
        add(&mut j, 14); // 13 is missing
        assert_eq!(first(m.next_frame(&mut j).unwrap().unwrap()), 10);
        assert_eq!(first(m.next_frame(&mut j).unwrap().unwrap()), 11);
        assert_eq!(first(m.next_frame(&mut j).unwrap().unwrap()), 12);
        assert!(m.next_frame(&mut j).unwrap().is_none()); // 13 concealed
        assert_eq!(first(m.next_frame(&mut j).unwrap().unwrap()), 14);
        // A burst of 20 frames is cut back to the target.
        for seq in 15..35 {
            add(&mut j, seq);
        }
        let played = first(m.next_frame(&mut j).unwrap().unwrap());
        assert_eq!(played, 35 - TARGET_FRAMES as u8);
        assert_eq!(j.frames.len(), TARGET_FRAMES - 1);
        // Silence for long enough and it goes idle.
        j.last_packet = Some(Instant::now() - IDLE_AFTER * 2);
        assert!(m.next_frame(&mut j).is_none());
        assert!(j.next.is_none());
    }
}
