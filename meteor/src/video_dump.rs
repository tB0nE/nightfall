//! `--dump-video <dir>`: writes the tapped elementary stream to a file, so
//! reassembly can be checked by playing it (`ffplay -f hevc file.hevc`).
//!
//! A file starts at the first IDR frame and a new one is started for each
//! new stream (epoch). Next to it, `<file>.frames.tsv` lists each frame's
//! index, arrival time (Unix microseconds), size and whether it's an IDR, for
//! timing a test pattern (test/analyze_stream_pattern.py).

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::stream_info::Codec;
use crate::video_tap::Frame;

pub struct VideoDump {
    dir: PathBuf,
    file: Option<(u32, BufWriter<File>, BufWriter<File>)>,
    failed: bool,
}

impl VideoDump {
    pub fn new(dir: PathBuf) -> VideoDump {
        VideoDump { dir, file: None, failed: false }
    }

    pub fn write(&mut self, frame: &Frame, codec: Option<Codec>) {
        if self.failed {
            return;
        }
        if self.file.as_ref().is_some_and(|(epoch, _, _)| *epoch != frame.epoch) {
            self.file = None;
        }
        if self.file.is_none() {
            let Some(codec) = codec else { return };
            if !frame.idr {
                return;
            }
            let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
            let path = self.dir.join(format!("meteor-{stamp}-{}.{}", frame.epoch, codec.extension()));
            let frames = PathBuf::from(format!("{}.frames.tsv", path.display()));
            let opened = std::fs::create_dir_all(&self.dir)
                .and_then(|()| Ok((File::create(&path)?, File::create(&frames)?)));
            match opened {
                Ok((file, frames)) => {
                    log::info!("Dumping tapped video to {}", path.display());
                    let mut frames = BufWriter::new(frames);
                    let _ = writeln!(frames, "# index\tarrival_unix_us\tbytes\tidr");
                    self.file = Some((frame.epoch, BufWriter::new(file), frames));
                }
                Err(err) => {
                    log::warn!("Can't create {}: {err}", path.display());
                    self.failed = true;
                    return;
                }
            }
        }
        let arrived = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_micros());
        if let Some((_, file, frames)) = &mut self.file
            && let Err(err) = file
                .write_all(&frame.data)
                .and_then(|()| writeln!(frames, "{}\t{arrived}\t{}\t{}", frame.index, frame.data.len(), u8::from(frame.idr)))
        {
            log::warn!("Video dump stopped: {err}");
            self.file = None;
            self.failed = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(index: u32, idr: bool) -> Frame {
        Frame { epoch: 3, index, rtp_timestamp: 0, idr, after_loss: false, data: vec![0, 0, 1, index as u8] }
    }

    #[test]
    fn lists_each_frame_with_its_arrival() {
        let dir = std::env::temp_dir().join(format!("meteor-dump-{}", std::process::id()));
        let mut dump = VideoDump::new(dir.clone());
        dump.write(&frame(1, false), Some(Codec::Hevc)); // waits for an IDR
        dump.write(&frame(2, true), Some(Codec::Hevc));
        dump.write(&frame(3, false), Some(Codec::Hevc));
        drop(dump);
        let video = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path())
            .find(|p| p.extension().is_some_and(|e| e == "hevc")).unwrap();
        assert_eq!(std::fs::read(&video).unwrap(), [0, 0, 1, 2, 0, 0, 1, 3]);
        let frames = std::fs::read_to_string(format!("{}.frames.tsv", video.display())).unwrap();
        let rows: Vec<Vec<&str>> = frames.lines().skip(1).map(|l| l.split('\t').collect()).collect();
        assert_eq!(rows.len(), 2);
        assert_eq!((rows[0][0], rows[0][2], rows[0][3]), ("2", "4", "1"));
        assert_eq!((rows[1][0], rows[1][3]), ("3", "0"));
        assert!(rows[1][1].parse::<u128>().unwrap() >= rows[0][1].parse::<u128>().unwrap());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
