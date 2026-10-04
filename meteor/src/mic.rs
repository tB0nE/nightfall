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
//! | 4 | version (1) |
//! | 5 | flags: bit 0 = muted on the headset |
//! | 6 | format: 0 = PCM s16le, 48 kHz, mono |
//! | 7 | reserved |
//! | 8-11 | sequence number |
//! | 12-15 | timestamp of the first sample, in samples |
//! | 16.. | 480 samples (960 bytes) |
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
const MAGIC: &[u8; 4] = b"NFMC";
const VERSION: u8 = 1;
const HEADER: usize = 16;
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
const SOURCE_NAME: &str = "nightfall_mic";

#[derive(Default)]
pub struct MicStats {
    pub packets: AtomicU64,
    pub played: AtomicU64,
    pub concealed: AtomicU64,
    pub dropped: AtomicU64,
    pub rejected: AtomicU64,
}

#[derive(Default)]
struct Jitter {
    frames: BTreeMap<u32, Vec<u8>>,
    /// The next sequence number to play, once playing.
    next: Option<u32>,
    last_packet: Option<Instant>,
    sender: Option<SocketAddr>,
}

pub struct Mic {
    pub port: u16,
    pub stats: MicStats,
    pub muted: AtomicBool,
    jitter: Mutex<Jitter>,
    device: Mutex<Option<VirtualMic>>,
}

impl Mic {
    /// Creates the virtual device and starts listening. None when the
    /// device can't be created (no PipeWire/PulseAudio, or not Linux).
    pub async fn start(port: u16, allowed: Arc<dyn Fn(IpAddr) -> bool + Send + Sync>) -> Option<Arc<Mic>> {
        let device = match VirtualMic::create() {
            Ok(device) => device,
            Err(err) => {
                log::warn!("Microphone passthrough is off: {err}");
                return None;
            }
        };
        let socket = match tokio::net::UdpSocket::bind(("::", port)).await {
            Ok(socket) => socket,
            Err(_) => match tokio::net::UdpSocket::bind(("0.0.0.0", port)).await {
                Ok(socket) => socket,
                Err(err) => {
                    log::warn!("Microphone passthrough is off: can't listen on UDP {port}: {err}");
                    return None;
                }
            },
        };
        log::info!("Microphone: UDP :{port} -> PipeWire source \"Nightfall Microphone\" ({SOURCE_NAME})");
        let mic = Arc::new(Mic {
            port,
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
            let Some((seq, muted_on_headset, pcm)) = parse(&buf[..len]) else { continue };
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
            let frame = if muted_on_headset { vec![0u8; FRAME_BYTES] } else { pcm.to_vec() };
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
            let frame = {
                let Ok(mut jitter) = self.jitter.lock() else { return };
                self.next_frame(&mut jitter)
            };
            let Some(frame) = frame else {
                playing = false;
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
            let data = if self.muted.load(Ordering::Relaxed) { &silence } else { frame.as_ref().unwrap_or(&silence) };
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
    fn next_frame(&self, jitter: &mut Jitter) -> Option<Option<Vec<u8>>> {
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

fn parse(packet: &[u8]) -> Option<(u32, bool, &[u8])> {
    if packet.len() != HEADER + FRAME_BYTES || &packet[..4] != MAGIC || packet[4] != VERSION || packet[6] != 0 {
        return None;
    }
    let seq = u32::from_le_bytes([packet[8], packet[9], packet[10], packet[11]]);
    Some((seq, packet[5] & 1 != 0, &packet[HEADER..]))
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

#[cfg(not(target_os = "linux"))]
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
        p.extend_from_slice(&[VERSION, flags, 0, 0]);
        p.extend_from_slice(&seq.to_le_bytes());
        p.extend_from_slice(&(seq * 480).to_le_bytes());
        p.extend(std::iter::repeat_n(seq as u8, FRAME_BYTES));
        p
    }

    fn mic() -> Mic {
        Mic {
            port: 0,
            stats: MicStats::default(),
            muted: AtomicBool::new(false),
            jitter: Mutex::default(),
            device: Mutex::new(None),
        }
    }

    #[test]
    fn parses_packets() {
        let muted_packet = packet(7, 1);
        let (seq, muted, pcm) = parse(&muted_packet).unwrap();
        assert_eq!((seq, muted, pcm.len()), (7, true, FRAME_BYTES));
        assert!(parse(&packet(7, 0)[..100]).is_none());
        let mut wrong = packet(7, 0);
        wrong[0] = b'X';
        assert!(parse(&wrong).is_none());
    }

    #[test]
    fn jitter_buffer_waits_conceals_and_caps_delay() {
        let m = mic();
        let mut j = Jitter { last_packet: Some(Instant::now()), ..Default::default() };
        let add = |j: &mut Jitter, seq: u32| {
            j.frames.insert(seq, vec![seq as u8; FRAME_BYTES]);
        };
        // Waits until 40 ms are buffered.
        for seq in 10..13 {
            add(&mut j, seq);
        }
        assert!(m.next_frame(&mut j).is_none());
        add(&mut j, 14); // 13 is missing
        assert_eq!(m.next_frame(&mut j).unwrap().unwrap()[0], 10);
        assert_eq!(m.next_frame(&mut j).unwrap().unwrap()[0], 11);
        assert_eq!(m.next_frame(&mut j).unwrap().unwrap()[0], 12);
        assert!(m.next_frame(&mut j).unwrap().is_none()); // 13 concealed
        assert_eq!(m.next_frame(&mut j).unwrap().unwrap()[0], 14);
        // A burst of 20 frames is cut back to the target.
        for seq in 15..35 {
            add(&mut j, seq);
        }
        let played = m.next_frame(&mut j).unwrap().unwrap()[0];
        assert_eq!(played, 35 - TARGET_FRAMES as u8);
        assert_eq!(j.frames.len(), TARGET_FRAMES - 1);
        // Silence for long enough and it goes idle.
        j.last_packet = Some(Instant::now() - IDLE_AFTER * 2);
        assert!(m.next_frame(&mut j).is_none());
        assert!(j.next.is_none());
    }
}
