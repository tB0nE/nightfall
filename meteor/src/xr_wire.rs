//! Experimental diagnostic XR framing. Not enabled by Meteor discovery/server.
//! No authentication/encryption: the probe binds loopback only. See protocol doc.
use std::io::{self, Read};

pub const HEADER_LEN: usize = 152;
pub const MAX_PAYLOAD: usize = 8 * 1024 * 1024;
pub const MAX_FRAMES: u64 = 240;

#[derive(Debug)]
pub struct Header {
    pub epoch: u64,
    pub sequence: u64,
    pub frame_id: u64,
    pub display_ns: u64,
    pub payload_len: usize,
    pub width: u16,
    pub height: u16,
    pub flags: u8,
    pub end: bool,
    pub views: [f32; 22],
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

impl Header {
    fn decode(bytes: &[u8; HEADER_LEN]) -> io::Result<Self> {
        let u16_at = |i| u16::from_le_bytes(bytes[i..i + 2].try_into().unwrap());
        let u32_at = |i| u32::from_le_bytes(bytes[i..i + 4].try_into().unwrap());
        let u64_at = |i| u64::from_le_bytes(bytes[i..i + 8].try_into().unwrap());
        if &bytes[..4] != b"NFXR" || u16_at(4) != 1 || u16_at(6) as usize != HEADER_LEN {
            return Err(invalid("XR magic/version/header size"));
        }
        if bytes[48] != 1
            || bytes[49] & !3 != 0
            || bytes[50] > 1
            || bytes[51..64].iter().any(|b| *b != 0)
        {
            return Err(invalid("XR codec/flags/kind/reserved"));
        }
        let mut views = [0.; 22];
        for (i, value) in views.iter_mut().enumerate() {
            *value = f32::from_bits(u32_at(64 + i * 4));
        }
        let header = Self {
            epoch: u64_at(8),
            sequence: u64_at(16),
            frame_id: u64_at(24),
            display_ns: u64_at(32),
            payload_len: u32_at(40) as usize,
            width: u16_at(44),
            height: u16_at(46),
            flags: bytes[49],
            end: bytes[50] == 1,
            views,
        };
        if header.epoch == 0 || header.payload_len > MAX_PAYLOAD {
            return Err(invalid("XR epoch/payload bound"));
        }
        if header.end {
            if header.payload_len != 0
                || header.width != 0
                || header.height != 0
                || header.frame_id != 0
                || header.display_ns != 0
                || header.flags != 0
                || bytes[64..].iter().any(|b| *b != 0)
            {
                return Err(invalid("XR malformed end packet"));
            }
        } else {
            if header.payload_len == 0
                || header.frame_id == 0
                || header.display_ns == 0
                || !(2..=8192).contains(&header.width)
                || !(2..=8192).contains(&header.height)
                || header.width % 2 != 0
                || header.height % 2 != 0
            {
                return Err(invalid("XR frame bounds"));
            }
            for view in header.views.chunks_exact(11) {
                let norm: f32 = view[3..7].iter().map(|v| v * v).sum();
                if view.iter().any(|v| !v.is_finite())
                    || (norm - 1.).abs() > 0.001
                    || view[7] >= view[8]
                    || view[10] >= view[9]
                    || view[7..11]
                        .iter()
                        .any(|v| v.abs() >= std::f32::consts::FRAC_PI_2)
                {
                    return Err(invalid("XR view pose/FOV"));
                }
            }
        }
        Ok(header)
    }
}

pub struct Frame {
    pub header: Header,
    pub payload: Vec<u8>,
}

#[derive(Default)]
pub struct Reader {
    epoch: Option<u64>,
    sequence: u64,
    frame_id: u64,
    display_ns: u64,
    dimensions: Option<(u16, u16)>,
    quest_local: Option<bool>,
    ended: bool,
}

fn nal_types(payload: &[u8]) -> [bool; 32] {
    let mut types = [false; 32];
    for i in 0..payload.len().saturating_sub(3) {
        if payload[i..i + 3] == [0, 0, 1] {
            types[(payload[i + 3] & 31) as usize] = true;
        }
    }
    types
}

impl Reader {
    /// EOF without explicit END is an error. Bounds are checked before allocation.
    pub fn read(&mut self, input: &mut impl Read) -> io::Result<Option<Frame>> {
        if self.ended {
            return Err(invalid("XR packet after end"));
        }
        let mut bytes = [0; HEADER_LEN];
        input.read_exact(&mut bytes)?;
        let header = Header::decode(&bytes)?;
        if header.sequence != self.sequence || self.epoch.is_some_and(|e| e != header.epoch) {
            return Err(invalid("XR sequence/epoch mismatch"));
        }
        if header.end {
            if self.sequence == 0 {
                return Err(invalid("XR empty diagnostic stream"));
            }
            self.ended = true;
            return Ok(None);
        }
        if self.sequence >= MAX_FRAMES
            || self.quest_local.is_some_and(|mode| mode != (header.flags & 2 != 0))
            || header.frame_id <= self.frame_id
            || header.display_ns <= self.display_ns
            || self
                .dimensions
                .is_some_and(|size| size != (header.width, header.height))
        {
            return Err(invalid("XR order/dimensions/frame limit"));
        }
        let mut payload = vec![0; header.payload_len];
        input.read_exact(&mut payload)?;
        if !payload.starts_with(&[0, 0, 1]) && !payload.starts_with(&[0, 0, 0, 1]) {
            return Err(invalid("XR requires Annex-B H.264"));
        }
        let nals = nal_types(&payload);
        if nals[5] != (header.flags & 1 != 0)
            || (self.sequence == 0 && !(nals[5] && nals[7] && nals[8]))
        {
            return Err(invalid("XR IDR/config mismatch"));
        }
        self.epoch = Some(header.epoch);
        self.sequence += 1;
        self.frame_id = header.frame_id;
        self.display_ns = header.display_ns;
        self.dimensions = Some((header.width, header.height));
        self.quest_local = Some(header.flags & 2 != 0);
        Ok(Some(Frame { header, payload }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;
    fn packet() -> Vec<u8> {
        let payload = [0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 1, 0, 0, 1, 0x65, 1];
        let mut b = vec![0; HEADER_LEN];
        b[..4].copy_from_slice(b"NFXR");
        b[4..6].copy_from_slice(&1u16.to_le_bytes());
        b[6..8].copy_from_slice(&(HEADER_LEN as u16).to_le_bytes());
        for offset in [8, 24, 32] {
            b[offset..offset + 8].copy_from_slice(&1u64.to_le_bytes());
        }
        b[40..44].copy_from_slice(&(payload.len() as u32).to_le_bytes());
        b[44..46].copy_from_slice(&512u16.to_le_bytes());
        b[46..48].copy_from_slice(&256u16.to_le_bytes());
        b[48] = 1;
        b[49] = 1;
        for eye in 0..2 {
            for (field, value) in [(6, 1f32), (7, -0.8), (8, 0.8), (9, 0.8), (10, -0.8)] {
                let offset = 64 + (eye * 11 + field) * 4;
                b[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
            }
        }
        b.extend_from_slice(&payload);
        b
    }
    #[test]
    fn valid_frame() {
        assert!(
            Reader::default()
                .read(&mut Cursor::new(packet()))
                .unwrap()
                .is_some()
        );
    }
    #[test]
    fn tracked_scene_origin_mode() {
        let mut reader = Reader::default();
        let mut scene = packet();
        scene[49] = 3;
        assert_eq!(reader.read(&mut Cursor::new(scene)).unwrap().unwrap().header.flags, 3);
        let mut next = packet();
        next[16..24].copy_from_slice(&1u64.to_le_bytes());
        next[24..32].copy_from_slice(&2u64.to_le_bytes());
        next[32..40].copy_from_slice(&2u64.to_le_bytes());
        assert!(reader.read(&mut Cursor::new(next)).is_err());
        let mut unknown = packet(); unknown[49] = 5;
        assert!(Reader::default().read(&mut Cursor::new(unknown)).is_err());
    }
    #[test]
    fn bad_headers() {
        for (index, value) in [
            (0, 0),
            (4, 2),
            (6, 0),
            (48, 2),
            (49, 2),
            (50, 2),
            (51, 1),
            (64 + 6 * 4, 0xff),
        ] {
            let mut b = packet();
            b[index] = value;
            // Quaternion perturbation at one byte can be tiny; use NaN explicitly.
            if index == 88 {
                b[88..92].copy_from_slice(&f32::NAN.to_le_bytes());
            }
            assert!(
                Reader::default().read(&mut Cursor::new(b)).is_err(),
                "index {index}"
            );
        }
    }
    #[test]
    fn bound_before_payload_read() {
        let mut b = packet();
        b[40..44].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(Reader::default().read(&mut Cursor::new(b)).is_err());
    }
    #[test]
    fn truncated() {
        for len in [0, 100, HEADER_LEN, HEADER_LEN + 2] {
            assert!(
                Reader::default()
                    .read(&mut Cursor::new(&packet()[..len]))
                    .is_err()
            );
        }
    }
    #[test]
    fn duplicate_frame() {
        let mut reader = Reader::default();
        reader.read(&mut Cursor::new(packet())).unwrap();
        assert!(reader.read(&mut Cursor::new(packet())).is_err());
    }
    #[test]
    fn stale_frame_and_epoch() {
        for offset in [8, 24, 32] {
            let mut reader = Reader::default();
            reader.read(&mut Cursor::new(packet())).unwrap();
            let mut b = packet();
            b[16..24].copy_from_slice(&1u64.to_le_bytes());
            b[24..32].copy_from_slice(&2u64.to_le_bytes());
            b[32..40].copy_from_slice(&2u64.to_le_bytes());
            if offset == 8 {
                b[8..16].copy_from_slice(&2u64.to_le_bytes());
            } else {
                b[offset..offset + 8].copy_from_slice(&1u64.to_le_bytes());
            }
            assert!(reader.read(&mut Cursor::new(b)).is_err());
        }
    }
    #[test]
    fn fragmented_reads() {
        struct Fragmented(Cursor<Vec<u8>>);
        impl Read for Fragmented {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                let size = out.len().min(3);
                self.0.read(&mut out[..size])
            }
        }
        assert!(
            Reader::default()
                .read(&mut Fragmented(Cursor::new(packet())))
                .unwrap()
                .is_some()
        );
    }
    #[test]
    fn changed_dimensions() {
        let mut reader = Reader::default();
        reader.read(&mut Cursor::new(packet())).unwrap();
        let mut b = packet();
        for offset in [16, 24, 32] {
            b[offset..offset + 8].copy_from_slice(&2u64.to_le_bytes());
        }
        b[16..24].copy_from_slice(&1u64.to_le_bytes());
        b[44..46].copy_from_slice(&256u16.to_le_bytes());
        assert!(reader.read(&mut Cursor::new(b)).is_err());
    }
    #[test]
    fn missing_config() {
        let mut b = packet();
        b[HEADER_LEN + 3] = 0x61;
        assert!(Reader::default().read(&mut Cursor::new(b)).is_err());
    }
    #[test]
    fn explicit_end() {
        let mut reader = Reader::default();
        reader.read(&mut Cursor::new(packet())).unwrap();
        let mut end = packet()[..HEADER_LEN].to_vec();
        end[16..24].copy_from_slice(&1u64.to_le_bytes());
        end[24..48].fill(0);
        end[49] = 0;
        end[50] = 1;
        end[64..].fill(0);
        assert!(reader.read(&mut Cursor::new(&end)).unwrap().is_none());
        assert!(reader.read(&mut Cursor::new(end)).is_err());
    }

    #[test]
    fn unclean_disconnect() {
        let mut reader = Reader::default();
        reader.read(&mut Cursor::new(packet())).unwrap();
        assert!(reader.read(&mut Cursor::new(Vec::<u8>::new())).is_err());
    }
}
