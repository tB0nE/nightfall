//! `--dump-video <dir>`: writes the tapped elementary stream to a file, so
//! reassembly can be checked by playing it (`ffplay -f hevc file.hevc`).
//!
//! A file starts at the first IDR frame and a new one is started for each
//! new stream (epoch).

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::stream_info::Codec;
use crate::video_tap::Frame;

pub struct VideoDump {
    dir: PathBuf,
    file: Option<(u32, BufWriter<File>)>,
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
        if self.file.as_ref().is_some_and(|(epoch, _)| *epoch != frame.epoch) {
            self.file = None;
        }
        if self.file.is_none() {
            let Some(codec) = codec else { return };
            if !frame.idr {
                return;
            }
            let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
            let path = self.dir.join(format!("meteor-{stamp}-{}.{}", frame.epoch, codec.extension()));
            let opened = std::fs::create_dir_all(&self.dir).and_then(|()| File::create(&path));
            match opened {
                Ok(file) => {
                    log::info!("Dumping tapped video to {}", path.display());
                    self.file = Some((frame.epoch, BufWriter::new(file)));
                }
                Err(err) => {
                    log::warn!("Can't create {}: {err}", path.display());
                    self.failed = true;
                    return;
                }
            }
        }
        if let Some((_, file)) = &mut self.file
            && let Err(err) = file.write_all(&frame.data)
        {
            log::warn!("Video dump stopped: {err}");
            self.file = None;
            self.failed = true;
        }
    }
}
