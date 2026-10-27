//! Session-bound authenticated envelopes. Not a public listener or LAN stream.
use crate::crypto::MeteorKey;
use ring::aead;
use std::io::{self, Cursor};

pub const HEADER: usize = 24;
pub const MAX_VIDEO: usize = crate::xr_wire::HEADER_LEN + crate::xr_wire::MAX_PAYLOAD;
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(u8)]
pub enum Kind {
    Video = 1,
    HeadsetTracking = 2,
    HostTracking = 3,
    VideoFeedback = 4,
    AttachVideo = 5,
    AttachTracking = 6,
}
impl Kind {
    fn bound(self) -> usize {
        match self {
            Self::Video => MAX_VIDEO,
            Self::HeadsetTracking => 192,
            Self::HostTracking => 32,
            Self::VideoFeedback => 20,
            Self::AttachVideo | Self::AttachTracking => 32,
        }
    }
}
fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

pub struct Channel {
    key: aead::LessSafeKey,
    kind: Kind,
    sequence: u64,
    failed: bool,
    video: crate::xr_wire::Reader,
}
impl Channel {
    // Unbound envelopes are retained only for offline/recorded fixtures. Live
    // relays always use new_bound with a fresh per-connection challenge.
    #[cfg(test)]
    pub fn new(
        host: &MeteorKey,
        client: [u8; 32],
        server_nonce: [u8; 32],
        client_nonce: [u8; 32],
        session: [u8; 16],
        kind: Kind,
    ) -> io::Result<Self> {
        Self::new_bound(
            host,
            client,
            server_nonce,
            client_nonce,
            session,
            kind,
            None,
        )
    }
    pub fn new_bound(
        host: &MeteorKey,
        client: [u8; 32],
        server_nonce: [u8; 32],
        client_nonce: [u8; 32],
        session: [u8; 16],
        kind: Kind,
        binding: Option<[u8; 32]>,
    ) -> io::Result<Self> {
        if session == [0; 16] {
            return Err(invalid("empty XR session"));
        }
        let mut info = b"nightfall-xr-data-v1/".to_vec();
        info.push(kind as u8);
        info.extend(session);
        info.extend(server_nonce);
        info.extend(client_nonce);
        if let Some(binding) = binding {
            info.extend(binding);
        }
        let key = host
            .session_key(&client, &info)
            .ok_or_else(|| invalid("invalid data peer"))?;
        Ok(Self {
            key,
            kind,
            sequence: 0,
            failed: false,
            video: Default::default(),
        })
    }
    pub fn payload_length(&self, header: &[u8; HEADER]) -> io::Result<usize> {
        if self.failed
            || &header[..4] != b"NFXD"
            || header[4] != 1
            || header[5] != self.kind as u8
            || header[6..8] != [0, 0]
            || header[20..] != [0, 0, 0, 0]
            || u64::from_le_bytes(header[8..16].try_into().unwrap()) != self.sequence
            || self.sequence == u64::MAX
        {
            return Err(invalid("XR data magic/version/kind/order"));
        }
        let length = u32::from_le_bytes(header[16..20].try_into().unwrap()) as usize;
        if length < 16 || length > self.kind.bound() + 16 {
            return Err(invalid("XR data allocation bound"));
        }
        Ok(length)
    }
    pub fn seal(&mut self, bytes: &[u8]) -> io::Result<Vec<u8>> {
        if self.failed
            || self.sequence == u64::MAX
            || bytes.len() > self.kind.bound()
            || bytes.is_empty()
        {
            return Err(invalid("XR data send bound/state"));
        }
        let mut header = [0u8; HEADER];
        header[..4].copy_from_slice(b"NFXD");
        header[4] = 1;
        header[5] = self.kind as u8;
        header[8..16].copy_from_slice(&self.sequence.to_le_bytes());
        header[16..20].copy_from_slice(&((bytes.len() + 16) as u32).to_le_bytes());
        let mut body = bytes.to_vec();
        self.key
            .seal_in_place_append_tag(
                crate::crypto::nonce(self.sequence),
                aead::Aad::from(header),
                &mut body,
            )
            .map_err(|_| invalid("XR data encryption failed"))?;
        self.sequence += 1;
        let mut packet = header.to_vec();
        packet.extend(body);
        Ok(packet)
    }
    pub fn open(&mut self, header: &[u8; HEADER], mut body: Vec<u8>) -> io::Result<Vec<u8>> {
        let result = (|| {
            let length = self.payload_length(header)?;
            if body.len() != length {
                return Err(invalid("truncated XR data"));
            }
            let clear = self
                .key
                .open_in_place(
                    crate::crypto::nonce(self.sequence),
                    aead::Aad::from(*header),
                    &mut body,
                )
                .map_err(|_| invalid("XR data authentication failed"))?
                .to_vec();
            validate_payload(self.kind, &clear, &mut self.video)?;
            self.sequence += 1;
            Ok(clear)
        })();
        if result.is_err() {
            self.failed = true;
        }
        result
    }
}

pub(crate) fn validate_payload(
    kind: Kind,
    bytes: &[u8],
    video: &mut crate::xr_wire::Reader,
) -> io::Result<()> {
    if kind == Kind::Video {
        let mut cursor = Cursor::new(bytes);
        if let Some(frame) = video.read(&mut cursor)? {
            if frame.payload.len() != frame.header.payload_len {
                return Err(invalid("XR inner payload length"));
            }
        }
        if cursor.position() as usize != bytes.len() {
            return Err(invalid("trailing XR video bytes"));
        }
        return Ok(());
    }
    let valid = match kind {
        Kind::Video => unreachable!(),
        Kind::HeadsetTracking => matches!(
            (bytes.get(..4), bytes.len()),
            (Some(b"NFXC" | b"NFXH"), 32)
                | (Some(b"NFXT"), 64)
                | (Some(b"NFXO"), 112)
                | (Some(b"NFXJ"), 192)
        ),
        Kind::HostTracking => {
            bytes.len() == 32
                && matches!(
                    bytes.get(..4),
                    Some(b"NFXC" | b"NFXP" | b"NFXO" | b"NFXJ" | b"NFXH" | b"NFXQ")
                )
        }
        Kind::VideoFeedback => matches!(
            (bytes.get(..4), bytes.len()),
            (Some(b"NFXA"), 20) | (Some(b"NFXE"), 12)
        ),
        Kind::AttachVideo | Kind::AttachTracking => {
            bytes.len() == 32
                && bytes.starts_with(b"NFXB")
                && bytes[4] == if kind == Kind::AttachVideo { 1 } else { 2 }
                && bytes[5..8] == [0; 3]
                && bytes[24..] == [0; 8]
        }
    };
    if !valid {
        return Err(invalid("XR data payload kind/size"));
    }
    if !matches!(
        kind,
        Kind::VideoFeedback | Kind::AttachVideo | Kind::AttachTracking
    ) {
        let version = u16::from_le_bytes(bytes[4..6].try_into().unwrap());
        if version
            != if bytes.starts_with(b"NFXJ") && kind == Kind::HeadsetTracking {
                2
            } else {
                1
            }
            || u16::from_le_bytes(bytes[6..8].try_into().unwrap()) as usize != bytes.len()
        {
            return Err(invalid("XR tracking version/header size"));
        }
    }
    // Existing native pose/controller/optics/clock/haptic semantic validators
    // MUST still run at their consumers. Encryption is not semantic validity.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn channel(kind: Kind, session: u8) -> Channel {
        Channel::new(
            &MeteorKey::from_seed([1; 32]),
            MeteorKey::from_seed([2; 32]).public,
            [3; 32],
            [4; 32],
            [session; 16],
            kind,
        )
        .unwrap()
    }
    fn tracking() -> Vec<u8> {
        let mut b = vec![0; 64];
        b[..4].copy_from_slice(b"NFXT");
        b[4] = 1;
        b[6] = 64;
        b
    }
    fn open(rx: &mut Channel, packet: Vec<u8>) -> io::Result<Vec<u8>> {
        rx.open(
            packet[..HEADER].try_into().unwrap(),
            packet[HEADER..].to_vec(),
        )
    }
    #[test]
    fn tracking_roundtrip_replay_and_poison() {
        let (mut tx, mut rx) = (
            channel(Kind::HeadsetTracking, 1),
            channel(Kind::HeadsetTracking, 1),
        );
        let packet = tx.seal(&tracking()).unwrap();
        assert_eq!(open(&mut rx, packet.clone()).unwrap(), tracking());
        assert!(open(&mut rx, packet).is_err());
        assert!(open(&mut rx, tx.seal(&tracking()).unwrap()).is_err());
    }
    #[test]
    fn session_direction_and_metadata_binding() {
        let mut tx = channel(Kind::HeadsetTracking, 1);
        let packet = tx.seal(&tracking()).unwrap();
        assert!(open(&mut channel(Kind::HeadsetTracking, 2), packet.clone()).is_err());
        assert!(open(&mut channel(Kind::HostTracking, 1), packet.clone()).is_err());
        let mut changed = packet;
        changed[HEADER + 8] ^= 1;
        assert!(open(&mut channel(Kind::HeadsetTracking, 1), changed).is_err());
    }
    #[test]
    fn bound_checked_before_allocation() {
        let mut tx = channel(Kind::HeadsetTracking, 1);
        let packet = tx.seal(&tracking()).unwrap();
        let mut header: [u8; HEADER] = packet[..HEADER].try_into().unwrap();
        header[16..20].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(
            channel(Kind::HeadsetTracking, 1)
                .payload_length(&header)
                .is_err()
        );
        assert!(tx.seal(&vec![0; 193]).is_err());
    }
    #[test]
    fn malformed_authenticated_payload_rejected() {
        let (mut tx, mut rx) = (
            channel(Kind::HeadsetTracking, 1),
            channel(Kind::HeadsetTracking, 1),
        );
        assert!(open(&mut rx, tx.seal(&[0; 64]).unwrap()).is_err());
    }
    #[test]
    fn counter_exhaustion_truncation_and_bad_video() {
        let mut exhausted = channel(Kind::HeadsetTracking, 1);
        exhausted.sequence = u64::MAX;
        assert!(exhausted.seal(&tracking()).is_err());
        let mut tx = channel(Kind::HeadsetTracking, 1);
        let mut packet = tx.seal(&tracking()).unwrap();
        packet.pop();
        assert!(open(&mut channel(Kind::HeadsetTracking, 1), packet).is_err());
        let mut video = channel(Kind::Video, 1);
        assert!(open(&mut channel(Kind::Video, 1), video.seal(&[0; 152]).unwrap()).is_err());
    }
    #[test]
    fn feedback_and_host_requests_roundtrip() {
        for (kind, body) in [
            (Kind::VideoFeedback, [b"NFXA".as_slice(), &[0; 16]].concat()),
            (Kind::HostTracking, {
                let mut b = vec![0; 32];
                b[..4].copy_from_slice(b"NFXP");
                b[4] = 1;
                b[6] = 32;
                b
            }),
        ] {
            let (mut tx, mut rx) = (channel(kind, 1), channel(kind, 1));
            assert_eq!(open(&mut rx, tx.seal(&body).unwrap()).unwrap(), body);
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires C++ client and recorded NVENC fixtures"]
    async fn recorded_video_openssl_transport() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let binary = std::env::var("NIGHTFALL_XR_DATA_CPP_CLIENT").unwrap();
        let fixture = std::path::PathBuf::from(std::env::var("NIGHTFALL_XR_DATA_FIXTURE").unwrap());
        let ledger = std::fs::read_to_string(fixture.join("monado-stereo.jsonl")).unwrap();
        let records: Vec<serde_json::Value> = ledger
            .lines()
            .take(8)
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(records.len(), 8);
        let video = std::fs::read(fixture.join("monado-stereo.h264")).unwrap();
        let mut packets = Vec::new();
        let mut expected: Vec<u8> = Vec::new();
        for (sequence, r) in records.iter().enumerate() {
            let offset = r["offset"].as_u64().unwrap() as usize;
            let length = r["bytes"].as_u64().unwrap() as usize;
            let payload = &video[offset..offset + length];
            expected.extend(payload);
            let idr = (0..payload.len().saturating_sub(3))
                .any(|i| payload[i..i + 3] == [0, 0, 1] && payload[i + 3] & 31 == 5);
            let mut h = vec![0u8; 152];
            h[..4].copy_from_slice(b"NFXR");
            h[4] = 1;
            h[6] = 152;
            for (at, value) in [
                (8, 9),
                (16, sequence as u64),
                (24, r["frame_id"].as_u64().unwrap()),
                (32, r["display_time_ns"].as_u64().unwrap()),
            ] {
                h[at..at + 8].copy_from_slice(&value.to_le_bytes());
            }
            h[40..44].copy_from_slice(&(length as u32).to_le_bytes());
            h[44..46].copy_from_slice(&(r["width"].as_u64().unwrap() as u16).to_le_bytes());
            h[46..48].copy_from_slice(&(r["height"].as_u64().unwrap() as u16).to_le_bytes());
            h[48] = 1;
            h[49] = 2 | u8::from(idr);
            for eye in 0..2 {
                let mut field = 0;
                for key in ["position", "orientation", "fov"] {
                    for v in r["views"][eye][key].as_array().unwrap() {
                        let at = 64 + (eye * 11 + field) * 4;
                        h[at..at + 4].copy_from_slice(&(v.as_f64().unwrap() as f32).to_le_bytes());
                        field += 1;
                    }
                }
            }
            h.extend(payload);
            packets.push(h);
        }
        let mut end = vec![0u8; 152];
        end[..4].copy_from_slice(b"NFXR");
        end[4] = 1;
        end[6] = 152;
        end[8..16].copy_from_slice(&9u64.to_le_bytes());
        end[16..24].copy_from_slice(&8u64.to_le_bytes());
        end[48] = 1;
        end[50] = 1;
        packets.push(end);
        let mut oracle = crate::xr_wire::Reader::default();
        for packet in &packets {
            oracle.read(&mut Cursor::new(packet)).unwrap();
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let (mut tx, mut rx) = (channel(Kind::Video, 5), channel(Kind::HeadsetTracking, 5));
            for (index, packet) in packets.into_iter().enumerate() {
                stream.write_all(&tx.seal(&packet).unwrap()).await.unwrap();
                if index == 8 {
                    break;
                }
                let mut header = [0; HEADER];
                stream.read_exact(&mut header).await.unwrap();
                let length = rx.payload_length(&header).unwrap();
                let mut body = vec![0; length];
                stream.read_exact(&mut body).await.unwrap();
                let tracking = rx.open(&header, body).unwrap();
                assert_eq!(&tracking[..4], b"NFXT");
                assert_eq!(
                    u64::from_le_bytes(tracking[16..24].try_into().unwrap()),
                    index as u64
                );
            }
        });
        let output_file = fixture.join("authenticated-replay.h264");
        let output = std::process::Command::new(binary)
            .arg(port.to_string())
            .arg(&output_file)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        tokio::time::timeout(std::time::Duration::from_secs(5), server)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(std::fs::read(&output_file).unwrap(), expected);
        let probe = std::process::Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-count_frames",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=nb_read_frames",
                "-of",
                "csv=p=0",
            ])
            .arg(output_file)
            .output()
            .unwrap();
        assert!(probe.status.success());
        assert_eq!(String::from_utf8_lossy(&probe.stdout).trim(), "8");
    }
}
