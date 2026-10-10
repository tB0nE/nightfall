//! What Meteor learns about a stream from the client's RTSP ANNOUNCE.
//!
//! The ANNOUNCE body is an SDP-like list of `a=key:value` lines that tells
//! Sunshine the codec, resolution, frame rate, and which channels are
//! encrypted. Meteor reads it on the way through (it is never modified) so
//! the video tap knows what it is looking at.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    H264,
    Hevc,
    Av1,
    PyroWave,
}

impl Codec {
    /// File extension for a dumped elementary stream.
    pub fn extension(self) -> &'static str {
        match self {
            Codec::H264 => "h264",
            Codec::Hevc => "hevc",
            Codec::Av1 => "obu",
            Codec::PyroWave => "pyrowave",
        }
    }
}

/// moonlight-common-c's SS_ENC_VIDEO bit in `x-ss-general.encryptionEnabled`.
const SS_ENC_VIDEO: u32 = 0x02;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StreamInfo {
    pub codec: Option<Codec>,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub packet_size: u32,
    pub video_encrypted: bool,
}

impl StreamInfo {
    /// Parses an ANNOUNCE body. Returns None when it has none of the keys
    /// we care about (not an ANNOUNCE, or an unexpected format).
    pub fn from_announce(body: &str) -> Option<StreamInfo> {
        let mut info = StreamInfo::default();
        let mut seen = false;
        for line in body.lines() {
            let Some(attr) = line.trim().strip_prefix("a=") else { continue };
            let Some((key, value)) = attr.split_once(':') else { continue };
            let value = value.trim();
            let number = || value.parse::<u32>().ok();
            match key {
                "x-nv-vqos[0].bitStreamFormat" => {
                    info.codec = match value {
                        "0" => Some(Codec::H264),
                        "1" => Some(Codec::Hevc),
                        "2" => Some(Codec::Av1),
                        "3" => Some(Codec::PyroWave),
                        _ => None,
                    };
                }
                "x-nv-video[0].clientViewportWd" => info.width = number().unwrap_or(0),
                "x-nv-video[0].clientViewportHt" => info.height = number().unwrap_or(0),
                "x-nv-video[0].maxFPS" => info.fps = number().unwrap_or(0),
                "x-nv-video[0].packetSize" => info.packet_size = number().unwrap_or(0),
                "x-ss-general.encryptionEnabled" => {
                    info.video_encrypted = number().unwrap_or(0) & SS_ENC_VIDEO != 0;
                }
                _ => continue,
            }
            seen = true;
        }
        seen.then_some(info)
    }
}

/// Watches the client-to-Sunshine RTSP bytes for an ANNOUNCE request. It only
/// reads; the bytes are forwarded unchanged by the caller.
#[derive(Default)]
pub struct AnnounceSniffer {
    pending: Vec<u8>,
    /// Gave up: not plain-text RTSP (encrypted), or something unexpected.
    done: bool,
}

const MAX_REQUEST: usize = 256 * 1024;

impl AnnounceSniffer {
    pub fn feed(&mut self, bytes: &[u8]) -> Option<StreamInfo> {
        if self.done {
            return None;
        }
        self.pending.extend_from_slice(bytes);
        loop {
            // Encrypted RTSP starts with a binary header, not a method name.
            if !self.pending.first().is_none_or(u8::is_ascii_uppercase) || self.pending.len() > MAX_REQUEST {
                self.done = true;
                self.pending = Vec::new();
                return None;
            }
            let header_end = self.pending.windows(4).position(|w| w == b"\r\n\r\n")? + 4;
            let header = String::from_utf8_lossy(&self.pending[..header_end]).into_owned();
            let body_len = header
                .lines()
                .find_map(|line| {
                    let (key, value) = line.split_once(':')?;
                    key.trim().eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().ok())?
                })
                .unwrap_or(0);
            if self.pending.len() < header_end + body_len {
                return None;
            }
            let body: Vec<u8> = self.pending.drain(..header_end + body_len).skip(header_end).collect();
            if header.starts_with("ANNOUNCE ") {
                self.done = true;
                self.pending = Vec::new();
                return StreamInfo::from_announce(&String::from_utf8_lossy(&body));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_announce_split_across_reads() {
        let body = "v=0\r\na=x-nv-vqos[0].bitStreamFormat:0 \r\n";
        let request = format!(
            "OPTIONS rtsp://h:48010 RTSP/1.0\r\nCSeq: 1\r\n\r\n\
             ANNOUNCE streamid=control/13/0 RTSP/1.0\r\nCSeq: 6\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        let mut sniffer = AnnounceSniffer::default();
        let (a, b) = request.as_bytes().split_at(request.len() - 10);
        assert!(sniffer.feed(a).is_none());
        assert_eq!(sniffer.feed(b).unwrap().codec, Some(Codec::H264));

        let mut encrypted = AnnounceSniffer::default();
        assert!(encrypted.feed(&[0x80, 0, 0, 1]).is_none());
        assert!(encrypted.done);
    }

    #[test]
    fn parses_announce() {
        let body = "v=0\r\no=android 0 14 IN IPv4 127.0.0.1\r\ns=NVIDIA Streaming Client\r\n\
                    a=x-ss-general.encryptionEnabled:1 \r\n\
                    a=x-nv-video[0].clientViewportWd:2560 \r\n\
                    a=x-nv-video[0].clientViewportHt:1440 \r\n\
                    a=x-nv-video[0].maxFPS:90 \r\n\
                    a=x-nv-video[0].packetSize:1392 \r\n\
                    a=x-nv-vqos[0].bitStreamFormat:1 \r\n";
        let info = StreamInfo::from_announce(body).unwrap();
        assert_eq!(info.codec, Some(Codec::Hevc));
        assert_eq!((info.width, info.height, info.fps, info.packet_size), (2560, 1440, 90, 1392));
        // Bit 0x01 is control-stream encryption, not video.
        assert!(!info.video_encrypted);

        let encrypted = StreamInfo::from_announce("a=x-ss-general.encryptionEnabled:3\r\n").unwrap();
        assert!(encrypted.video_encrypted);
        assert!(StreamInfo::from_announce("v=0\r\ns=x\r\n").is_none());
    }
}
