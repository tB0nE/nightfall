//! Rebuilds whole video frames from the packets Meteor forwards.
//!
//! The proxy forwards every video packet first and then hands a copy to the
//! tap. The tap never slows forwarding down: its queue is bounded, and when
//! it is full packets are dropped and the frame is counted as incomplete.
//!
//! Packet layout (moonlight-common-c `Video.h`, Sunshine `stream.cpp`):
//! an RTP header (12 bytes, plus 4 when the extension bit is set), then
//! `NV_VIDEO_PACKET` (16 bytes, little-endian), then the payload. A frame is
//! split into up to four FEC blocks; each block has `data_shards` data
//! packets followed by parity packets. Sunshine to Meteor is loopback, so
//! the tap only keeps data packets and doesn't attempt FEC recovery. The
//! first packet of a frame starts with Sunshine's frame header, which says
//! the frame type and the real length of the last packet.
//!
//! `frame_index` is the same number the client sees as
//! `decodeUnit->frameNumber`, which is how depth maps get matched to frames.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender, TrySendError};
use std::time::{Duration, Instant};

use crate::stream_info::{Codec, StreamInfo};

const RTP_HEADER: usize = 12;
const RTP_EXTENSION_FLAG: u8 = 0x10;
const NV_HEADER: usize = 16;
#[cfg(test)]
const FLAG_SOF: u8 = 0x04;
const FLAG_EOF: u8 = 0x02;
/// Sunshine frame-header type 2 is an IDR frame.
const FRAME_TYPE_IDR: u8 = 2;
/// Packets the tap may fall behind by before it starts dropping them.
const QUEUE_PACKETS: usize = 8192;
const STATS_LOG_INTERVAL: Duration = Duration::from_secs(10);

/// One reassembled frame, ready for a decoder.
#[allow(dead_code)] // index, timestamp and loss feed the depth worker (Phase 1)
pub struct Frame {
    /// Increments whenever the frame numbers restart (a new stream).
    pub epoch: u32,
    pub index: u32,
    pub rtp_timestamp: u32,
    pub idr: bool,
    /// A frame before this one was lost since the last IDR, so a decoder's
    /// output may show corruption until the next IDR.
    pub after_loss: bool,
    /// The elementary-stream data, with Sunshine's frame header removed.
    pub data: Vec<u8>,
}

#[derive(Default)]
pub struct TapStats {
    pub frames: AtomicU64,
    pub incomplete_frames: AtomicU64,
    pub dropped_packets: AtomicU64,
}

/// The proxy side of the tap: cheap to call for every packet.
pub struct VideoTap {
    queue: SyncSender<Vec<u8>>,
    stats: Arc<TapStats>,
}

impl VideoTap {
    /// Starts a reassembly thread that calls `on_frame` for each complete
    /// frame. The thread ends when the tap is dropped.
    pub fn start(
        name: String,
        info: Option<StreamInfo>,
        stats: Arc<TapStats>,
        mut on_frame: impl FnMut(&Frame, Option<Codec>) + Send + 'static,
    ) -> VideoTap {
        let (queue, packets) = mpsc::sync_channel(QUEUE_PACKETS);
        let thread_stats = stats.clone();
        let spawned = std::thread::Builder::new().name("video-tap".into()).spawn(move || {
            run(name, info, packets, thread_stats, &mut on_frame);
        });
        if let Err(err) = spawned {
            log::warn!("Can't start the video tap: {err}");
        }
        VideoTap { queue, stats }
    }

    pub fn push(&self, packet: &[u8]) {
        match self.queue.try_send(packet.to_vec()) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => {
                self.stats.dropped_packets.fetch_add(1, Ordering::Relaxed);
            }
            Err(TrySendError::Disconnected(_)) => {}
        }
    }
}

fn run(
    name: String,
    info: Option<StreamInfo>,
    packets: Receiver<Vec<u8>>,
    stats: Arc<TapStats>,
    on_frame: &mut dyn FnMut(&Frame, Option<Codec>),
) {
    let mut codec = info.as_ref().and_then(|i| i.codec);
    let mut reassembler = Reassembler::default();
    let mut last_log = Instant::now();
    let mut logged = (0u64, 0u64, 0u64);
    while let Ok(packet) = packets.recv() {
        if let Some(frame) = reassembler.push(&packet) {
            stats.frames.fetch_add(1, Ordering::Relaxed);
            // Guess only from IDR frames, which start with parameter sets.
            if codec.is_none() && frame.idr {
                codec = guess_codec(&frame.data);
                if let Some(c) = codec {
                    log::info!("{name}: no ANNOUNCE seen; the bitstream looks like {c:?}");
                }
            }
            on_frame(&frame, codec);
        }
        stats.incomplete_frames.store(reassembler.incomplete, Ordering::Relaxed);
        if last_log.elapsed() >= STATS_LOG_INTERVAL {
            logged = log_stats(&name, &stats, logged);
            last_log = Instant::now();
        }
    }
    log_stats(&name, &stats, logged);
}

/// Logs the counts since the previous call; returns the new totals.
fn log_stats(name: &str, stats: &TapStats, previous: (u64, u64, u64)) -> (u64, u64, u64) {
    let now = (
        stats.frames.load(Ordering::Relaxed),
        stats.incomplete_frames.load(Ordering::Relaxed),
        stats.dropped_packets.load(Ordering::Relaxed),
    );
    if now != previous {
        log::info!(
            "{name}: {} frames, {} incomplete, {} packets dropped (totals {} / {} / {})",
            now.0 - previous.0,
            now.1 - previous.1,
            now.2 - previous.2,
            now.0,
            now.1,
            now.2
        );
    }
    now
}

struct Packet<'a> {
    rtp_timestamp: u32,
    frame_index: u32,
    flags: u8,
    block: usize,
    last_block: usize,
    fec_index: usize,
    data_shards: usize,
    payload: &'a [u8],
}

fn parse(packet: &[u8]) -> Option<Packet<'_>> {
    let header_len = RTP_HEADER + if packet.first()? & RTP_EXTENSION_FLAG != 0 { 4 } else { 0 };
    let nv = packet.get(header_len..header_len + NV_HEADER)?;
    let le32 = |b: &[u8]| u32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    let fec_info = le32(&nv[12..16]);
    let multi_fec_blocks = nv[11];
    Some(Packet {
        rtp_timestamp: u32::from_be_bytes([packet[4], packet[5], packet[6], packet[7]]),
        frame_index: le32(&nv[4..8]),
        flags: nv[8],
        block: ((multi_fec_blocks >> 4) & 0x3) as usize,
        last_block: ((multi_fec_blocks >> 6) & 0x3) as usize,
        fec_index: ((fec_info & 0x3F_F000) >> 12) as usize,
        data_shards: (fec_info >> 22) as usize,
        payload: &packet[header_len + NV_HEADER..],
    })
}

struct Block {
    shards: Vec<Option<Vec<u8>>>,
    received: usize,
}

struct PendingFrame {
    index: u32,
    rtp_timestamp: u32,
    blocks: Vec<Option<Block>>,
    eof_seen: bool,
}

impl PendingFrame {
    fn complete(&self) -> bool {
        self.eof_seen
            && self.blocks.iter().all(|b| b.as_ref().is_some_and(|b| b.received == b.shards.len()))
    }
}

#[derive(Default)]
pub struct Reassembler {
    epoch: u32,
    current: Option<PendingFrame>,
    /// The newest frame index seen, finished or not.
    newest: Option<u32>,
    /// The last frame handed out; its trailing parity packets are ignored.
    done: Option<u32>,
    /// A frame was lost and no IDR has arrived since.
    lost_since_idr: bool,
    pub incomplete: u64,
}

impl Reassembler {
    pub fn push(&mut self, packet: &[u8]) -> Option<Frame> {
        let p = parse(packet)?;
        if p.data_shards == 0 || p.last_block < p.block || self.done == Some(p.frame_index) {
            return None;
        }
        if let Some(newest) = self.newest {
            let behind = newest.wrapping_sub(p.frame_index);
            if behind > 0 && behind < 0x8000_0000 {
                if behind > 1000 || p.frame_index <= 1 {
                    // The frame numbers restarted: a new stream on the same flow.
                    self.restart();
                } else {
                    return None; // late packet for a frame already finished or dropped
                }
            } else if p.frame_index != newest && newest.wrapping_add(1) != p.frame_index {
                // Whole frames went missing.
                self.lost_since_idr = true;
                self.incomplete += u64::from(p.frame_index.wrapping_sub(newest).wrapping_sub(1));
            }
        }
        if self.current.as_ref().is_some_and(|f| f.index != p.frame_index) {
            // A new frame started before the previous one was finished.
            self.current = None;
            self.incomplete += 1;
            self.lost_since_idr = true;
        }
        self.newest = Some(p.frame_index);
        let frame = self.current.get_or_insert_with(|| PendingFrame {
            index: p.frame_index,
            rtp_timestamp: p.rtp_timestamp,
            blocks: (0..=p.last_block).map(|_| None).collect(),
            eof_seen: false,
        });
        if p.last_block + 1 != frame.blocks.len() || p.fec_index >= p.data_shards {
            return None; // inconsistent block count, or a parity packet
        }
        let block = frame.blocks[p.block].get_or_insert_with(|| Block {
            shards: vec![None; p.data_shards],
            received: 0,
        });
        if block.shards.len() != p.data_shards {
            return None;
        }
        let slot = &mut block.shards[p.fec_index];
        if slot.is_none() {
            *slot = Some(p.payload.to_vec());
            block.received += 1;
        }
        if p.flags & FLAG_EOF != 0 && p.block == p.last_block {
            frame.eof_seen = true;
        }
        if !frame.complete() {
            return None;
        }
        let frame = self.current.take()?;
        self.finish(frame)
    }

    fn restart(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
        self.current = None;
        self.newest = None;
        self.done = None;
        self.lost_since_idr = false;
    }

    fn finish(&mut self, frame: PendingFrame) -> Option<Frame> {
        self.done = Some(frame.index);
        let mut shards: Vec<Vec<u8>> = frame
            .blocks
            .into_iter()
            .flatten()
            .flat_map(|b| b.shards.into_iter().flatten())
            .collect();
        let first = shards.first()?;
        // 0x01: the short 8-byte header Sunshine sends; 0x81: GFE's 44-byte one.
        let header_len = match first.first()? {
            0x01 => 8,
            0x81 => 44,
            _ => {
                self.incomplete += 1;
                return None;
            }
        };
        if first.len() < header_len.max(6) {
            self.incomplete += 1;
            return None;
        }
        let idr = first[3] == FRAME_TYPE_IDR;
        // Sunshine pads the last packet; its real length is in the header.
        // H.264/HEVC parsers ignore the zero padding, AV1 needs it removed.
        let last_len = u16::from_le_bytes([first[4], first[5]]) as usize;
        if let Some(last) = shards.last_mut()
            && last_len > 0
            && last_len <= last.len()
        {
            last.truncate(last_len);
        }
        let total: usize = shards.iter().map(Vec::len).sum();
        let mut data = Vec::with_capacity(total - header_len);
        data.extend_from_slice(&shards[0][header_len..]);
        for shard in &shards[1..] {
            data.extend_from_slice(shard);
        }
        if idr {
            self.lost_since_idr = false;
        }
        Some(Frame {
            epoch: self.epoch,
            index: frame.index,
            rtp_timestamp: frame.rtp_timestamp,
            idr,
            after_loss: self.lost_since_idr,
            data,
        })
    }
}

/// For when no ANNOUNCE was seen (encrypted RTSP, or Meteor started mid-stream).
fn guess_codec(data: &[u8]) -> Option<Codec> {
    let nal = if data.starts_with(&[0, 0, 0, 1]) {
        data.get(4)?
    } else if data.starts_with(&[0, 0, 1]) {
        data.get(3)?
    } else {
        // An AV1 temporal unit starts with an OBU header: forbidden bit 0,
        // type 2 (temporal delimiter) or 1 (sequence header).
        let obu_type = (data.first()? >> 3) & 0xF;
        return (data[0] & 0x80 == 0 && (obu_type == 1 || obu_type == 2)).then_some(Codec::Av1);
    };
    // H.264: 7 SPS, 8 PPS, 9 AUD, 1/5 slices, 6 SEI.
    // HEVC: 32 VPS, 33 SPS, 34 PPS, 35 AUD, 39 SEI (type = byte >> 1).
    match (nal & 0x1F, (nal >> 1) & 0x3F) {
        (_, 32..=35 | 39) if nal & 0x81 == 0 => Some(Codec::Hevc),
        (1 | 5..=9, _) => Some(Codec::H264),
        _ => None,
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// Builds one Sunshine-style video packet.
    pub fn packet(frame: u32, block: u8, last_block: u8, fec_index: u32, data_shards: u32, flags: u8, payload: &[u8]) -> Vec<u8> {
        let mut p = vec![0x90, 0, 0, 0, 0, 0, 0x30, 0x39, 0, 0, 0, 0, 0, 0, 0, 0];
        p.extend_from_slice(&0u32.to_le_bytes()); // streamPacketIndex
        p.extend_from_slice(&frame.to_le_bytes());
        p.extend_from_slice(&[flags | 0x01, 0, 0x10, (last_block << 6) | (block << 4)]);
        let fec_info = (data_shards << 22) | (fec_index << 12) | (20 << 4);
        p.extend_from_slice(&fec_info.to_le_bytes());
        p.extend_from_slice(payload);
        p
    }

    fn header(frame_type: u8, last_len: u16) -> Vec<u8> {
        let l = last_len.to_le_bytes();
        vec![0x01, 0, 0, frame_type, l[0], l[1], 0, 0]
    }

    #[test]
    fn rebuilds_a_frame_across_blocks_and_skips_parity() {
        let mut r = Reassembler::default();
        let mut first = header(FRAME_TYPE_IDR, 3);
        first.extend_from_slice(&[0, 0, 0, 1, 0x40]);
        assert!(r.push(&packet(5, 0, 1, 0, 2, FLAG_SOF, &first)).is_none());
        assert!(r.push(&packet(5, 0, 1, 2, 2, 0, b"PARITY")).is_none());
        assert!(r.push(&packet(5, 0, 1, 1, 2, 0, b"AB")).is_none());
        // Block 1 arrives out of order; the EOF packet is padded.
        assert!(r.push(&packet(5, 1, 1, 1, 2, FLAG_EOF, b"EF\0\0\0")).is_none());
        let frame = r.push(&packet(5, 1, 1, 0, 2, 0, b"CD")).unwrap();
        assert_eq!(frame.index, 5);
        assert!(frame.idr && !frame.after_loss);
        assert_eq!(frame.rtp_timestamp, 0x3039);
        // last_len=3 keeps "EF\0"; the header is gone.
        assert_eq!(frame.data, b"\0\0\0\x01\x40ABCDEF\0");
        assert_eq!(guess_codec(&frame.data), Some(Codec::Hevc));
        // Parity trailing a finished frame must not start a new one.
        assert!(r.push(&packet(5, 1, 1, 2, 2, 0, b"PARITY")).is_none());
        let mut next = header(1, 0);
        next.extend_from_slice(&[0, 0, 0, 1, 0x02]);
        assert!(r.push(&packet(6, 0, 0, 0, 1, FLAG_SOF | FLAG_EOF, &next)).is_some());
        assert_eq!(r.incomplete, 0);
    }

    #[test]
    fn counts_incomplete_and_lost_frames() {
        let mut r = Reassembler::default();
        let single = |frame, frame_type| {
            let mut p = header(frame_type, 0);
            p.extend_from_slice(&[0, 0, 0, 1, 0x65]);
            packet(frame, 0, 0, 0, 1, FLAG_SOF | FLAG_EOF, &p)
        };
        assert!(r.push(&single(1, FRAME_TYPE_IDR)).unwrap().idr);
        // Frame 2 only half arrives.
        assert!(r.push(&packet(2, 0, 0, 0, 2, FLAG_SOF, &header(1, 0))).is_none());
        let f3 = r.push(&single(3, 1)).unwrap();
        assert!(f3.after_loss);
        assert_eq!(r.incomplete, 1);
        // Frames 4 and 5 never arrive.
        let f6 = r.push(&single(6, 1)).unwrap();
        assert!(f6.after_loss);
        assert_eq!(r.incomplete, 3);
        // A late packet for frame 2 is ignored.
        assert!(r.push(&packet(2, 0, 0, 1, 2, FLAG_EOF, b"x")).is_none());
        assert!(!r.push(&single(7, FRAME_TYPE_IDR)).unwrap().after_loss);
        // A new stream restarts the numbering and the epoch.
        let restarted = r.push(&single(0, FRAME_TYPE_IDR)).unwrap();
        assert_eq!((restarted.epoch, restarted.index), (1, 0));
    }

    #[test]
    fn guesses_codecs() {
        assert_eq!(guess_codec(&[0, 0, 0, 1, 0x67]), Some(Codec::H264));
        assert_eq!(guess_codec(&[0, 0, 0, 1, 0x40, 0x01]), Some(Codec::Hevc));
        assert_eq!(guess_codec(&[0x12, 0x00]), Some(Codec::Av1));
        assert_eq!(guess_codec(&[0xFF]), None);
    }
}
