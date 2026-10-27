//! Optional FFmpeg 8 decoding, without subprocess buffering or CUDA.
use crate::{
    nvdec::{NvDecoder, Pixels},
    stream_info::Codec,
};
use serde::{Deserialize, Serialize};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    path::{Path, PathBuf},
    sync::OnceLock,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Backend {
    #[default]
    Auto,
    Nvdec,
    Vaapi,
    Software,
}
impl Backend {
    pub const ALL: [Self; 4] = [Self::Auto, Self::Nvdec, Self::Vaapi, Self::Software];
    pub fn label(self) -> &'static str {
        match self {
            Self::Auto => "Auto",
            Self::Nvdec => "NVDEC (NVIDIA)",
            Self::Vaapi => "VAAPI (Linux)",
            Self::Software => "Software (CPU)",
        }
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub backend: Backend,
    pub vaapi_device: Option<String>,
    pub cpu_processing: bool,
}
impl Settings {
    pub fn candidates(&self, prefer_amd: bool) -> Vec<Backend> {
        match self.backend {
            Backend::Auto if prefer_amd => vec![Backend::Vaapi, Backend::Software],
            Backend::Auto => vec![Backend::Nvdec, Backend::Vaapi, Backend::Software],
            explicit => vec![explicit],
        }
    }
}

/// Persist PCI-based paths rather than renderD numbers, which can reorder.
pub fn vaapi_devices() -> Vec<(String, String)> {
    let mut found = Vec::new();
    #[cfg(target_os = "linux")]
    if let Ok(entries) = std::fs::read_dir("/dev/dri/by-path") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !name.ends_with("-render") {
                continue;
            }
            let render = entry
                .path()
                .canonicalize()
                .ok()
                .and_then(|p| p.file_name().map(|n| n.to_owned()));
            let vendor = render
                .and_then(|r| {
                    std::fs::read_to_string(
                        Path::new("/sys/class/drm").join(r).join("device/vendor"),
                    )
                    .ok()
                })
                .unwrap_or_default();
            let brand = match vendor.trim() {
                "0x1002" => "AMD",
                "0x8086" => "Intel",
                "0x10de" => "NVIDIA",
                _ => "GPU",
            };
            found.push((
                entry.path().to_string_lossy().into_owned(),
                format!(
                    "{brand} {}",
                    name.trim_start_matches("pci-").trim_end_matches("-render")
                ),
            ));
        }
    }
    found.sort_by(|a, b| a.1.cmp(&b.1));
    found
}

#[repr(C)]
#[derive(Default)]
struct RawFrame {
    data: *const u8,
    length: usize,
    id: i64,
    width: u32,
    height: u32,
    matrix: u32,
    full_range: u32,
}
unsafe extern "C" {
    fn meteor_video_api(directory: *const c_char, error: *mut c_char, size: usize) -> *mut c_void;
    fn meteor_video_create(
        api: *mut c_void,
        codec: i32,
        vaapi: bool,
        device: *const c_char,
        error: *mut c_char,
        size: usize,
    ) -> *mut c_void;
    fn meteor_video_send(
        handle: *mut c_void,
        bytes: *const u8,
        len: usize,
        id: i64,
        error: *mut c_char,
        size: usize,
    ) -> i32;
    fn meteor_video_receive(
        handle: *mut c_void,
        pixels: bool,
        frame: *mut RawFrame,
        error: *mut c_char,
        size: usize,
    ) -> i32;
    fn meteor_video_destroy(handle: *mut c_void);
}
struct Runtime(*mut c_void);
// SAFETY: the immutable dispatch table is process-lived; each decoder owns
// its codec context and is used by only its owning video-tap thread.
unsafe impl Send for Runtime {}
unsafe impl Sync for Runtime {}
static RUNTIME: OnceLock<Result<Runtime, String>> = OnceLock::new();
fn message(bytes: &[c_char]) -> String {
    unsafe { CStr::from_ptr(bytes.as_ptr()) }
        .to_string_lossy()
        .into_owned()
}
fn runtime() -> Result<&'static Runtime, String> {
    RUNTIME
        .get_or_init(|| {
            let mut dirs = Vec::<PathBuf>::new();
            if let Some(dir) = std::env::var_os("METEOR_FFMPEG_DIR") {
                dirs.push(dir.into());
            }
            if let Ok(exe) = std::env::current_exe() {
                if let Some(parent) = exe.parent() {
                    dirs.extend([parent.join("../lib"), parent.to_path_buf()]);
                }
            }
            dirs.push(PathBuf::new());
            let mut last = String::new();
            for dir in dirs {
                let name = CString::new(dir.to_string_lossy().as_bytes())
                    .map_err(|_| "Invalid FFmpeg path")?;
                let mut error = [0; 512];
                let ptr =
                    unsafe { meteor_video_api(name.as_ptr(), error.as_mut_ptr(), error.len()) };
                if !ptr.is_null() {
                    return Ok(Runtime(ptr));
                }
                last = message(&error);
            }
            Err(last)
        })
        .as_ref()
        .map_err(Clone::clone)
}

pub struct Ffmpeg {
    handle: *mut c_void,
    target: (usize, usize),
    filter: Option<crate::nvdec::Nv12Footprint>,
    processing_gpu: Option<String>,
    vulkan: Option<crate::vulkan_processing::Processor>,
}
// SAFETY: ownership may move between threads, but operations require &mut self.
unsafe impl Send for Ffmpeg {}
impl Drop for Ffmpeg {
    fn drop(&mut self) {
        unsafe { meteor_video_destroy(self.handle) }
    }
}
impl Ffmpeg {
    pub fn new(
        codec: Codec,
        backend: Backend,
        device: Option<&str>,
        target: (usize, usize),
    ) -> Result<Self, String> {
        if !matches!(backend, Backend::Vaapi | Backend::Software) {
            return Err("Invalid FFmpeg backend".into());
        }
        #[cfg(not(target_os = "linux"))]
        if backend == Backend::Vaapi {
            return Err("VAAPI decoding requires Linux".into());
        }
        let codec = match codec {
            Codec::H264 => 0,
            Codec::Hevc => 1,
            Codec::Av1 => 2,
            _ => return Err("Unsupported depth video codec".into()),
        };
        let name = CString::new(device.unwrap_or("")).map_err(|_| "Invalid VAAPI device")?;
        let mut error = [0; 512];
        let handle = unsafe {
            meteor_video_create(
                runtime()?.0,
                codec,
                backend == Backend::Vaapi,
                name.as_ptr(),
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if handle.is_null() {
            return Err(message(&error));
        }
        Ok(Self {
            handle,
            target,
            filter: None,
            processing_gpu: None,
            vulkan: None,
        })
    }
    pub fn set_processing_gpu(&mut self, gpu: String) {
        self.processing_gpu = Some(gpu);
        self.vulkan = None;
    }
    pub fn gpu_preparation(&self) -> bool {
        self.processing_gpu.is_some()
    }
    fn receive(&mut self, want_pixels: bool, out: &mut Vec<(u32, Pixels)>) -> Result<(), String> {
        loop {
            let mut raw = RawFrame::default();
            let mut error = [0; 512];
            let rc = unsafe {
                meteor_video_receive(
                    self.handle,
                    want_pixels,
                    &mut raw,
                    error.as_mut_ptr(),
                    error.len(),
                )
            };
            if rc == 0 {
                break;
            }
            if rc < 0 {
                return Err(message(&error));
            }
            let id =
                u32::try_from(raw.id).map_err(|_| "Decoded frame has no valid input frame ID")?;
            if !want_pixels {
                continue;
            }
            let (w, h) = (raw.width as usize, raw.height as usize);
            if w < 2
                || h < 2
                || w > 8192
                || h > 8192
                || raw.data.is_null()
                || raw.length != w * h * 3 / 2
            {
                return Err("Invalid decoded NV12 frame".into());
            }
            // Buffer is owned by the shim and valid until the next receive call.
            let source = unsafe { std::slice::from_raw_parts(raw.data, raw.length) };
            if let Some(gpu) = self.processing_gpu.clone() {
                if self
                    .vulkan
                    .as_ref()
                    .is_none_or(|p| p.size != self.target || p.gpu != gpu)
                {
                    match crate::vulkan_processing::Processor::new(Some(&gpu), self.target) {
                        Ok(processor) => self.vulkan = Some(processor),
                        Err(error) => {
                            log::warn!(
                                "Vulkan video preparation unavailable: {error}; using CPU reference"
                            );
                            self.processing_gpu = None;
                            self.vulkan = None;
                        }
                    }
                }
                if let Some(processor) = self.vulkan.as_mut() {
                    match processor.nv12(source, (w, h), raw.matrix as u8, raw.full_range != 0) {
                        Ok(rgb) => {
                            out.push((id, Pixels::Rgb(rgb)));
                            continue;
                        }
                        Err(error) => {
                            log::warn!(
                                "Vulkan video preparation failed: {error}; using CPU reference"
                            );
                            self.processing_gpu = None;
                            self.vulkan = None;
                        }
                    }
                }
            }
            if self
                .filter
                .as_ref()
                .is_none_or(|f| f.dimensions() != ((w, h), self.target))
            {
                self.filter = Some(crate::nvdec::Nv12Footprint::new((w, h), self.target));
            }
            let rgb = self.filter.as_ref().unwrap().convert(
                source,
                raw.matrix as u8,
                raw.full_range != 0,
            );
            out.push((id, Pixels::Rgb(rgb)));
        }
        Ok(())
    }
    pub fn decode(
        &mut self,
        data: Option<&[u8]>,
        id: u32,
        want_pixels: bool,
    ) -> Result<Vec<(u32, Pixels)>, String> {
        let mut out = Vec::new();
        let mut error = [0; 512];
        let (bytes, len) = data.map_or((std::ptr::null(), 0), |d| (d.as_ptr(), d.len()));
        let mut rc = unsafe {
            meteor_video_send(
                self.handle,
                bytes,
                len,
                id as i64,
                error.as_mut_ptr(),
                error.len(),
            )
        };
        if rc == 0 {
            self.receive(want_pixels, &mut out)?;
            rc = unsafe {
                meteor_video_send(
                    self.handle,
                    bytes,
                    len,
                    id as i64,
                    error.as_mut_ptr(),
                    error.len(),
                )
            };
        }
        if rc <= 0 {
            return Err(if rc == 0 {
                "Decoder made no progress after draining".into()
            } else {
                message(&error)
            });
        }
        self.receive(want_pixels, &mut out)?;
        Ok(out)
    }
}

pub enum Decoder {
    Nvdec(NvDecoder),
    Ffmpeg(Ffmpeg),
}
impl Decoder {
    pub fn new(
        codec: Codec,
        backend: Backend,
        device: Option<&str>,
        size: (usize, usize),
        gpu_frames: bool,
    ) -> Result<Self, String> {
        match backend {
            Backend::Nvdec => NvDecoder::new(codec, size.0, size.1, gpu_frames).map(Self::Nvdec),
            Backend::Vaapi | Backend::Software => {
                Ffmpeg::new(codec, backend, device, size).map(Self::Ffmpeg)
            }
            _ => Err("Decoder Auto must be resolved before creation".into()),
        }
    }
    pub fn set_target(&mut self, size: (usize, usize)) {
        match self {
            Self::Nvdec(d) => d.set_target(size.0, size.1),
            Self::Ffmpeg(d) => d.target = size,
        }
    }
    pub fn decode(
        &mut self,
        data: &[u8],
        id: u32,
        want_pixels: bool,
    ) -> Result<Vec<(u32, Pixels)>, String> {
        match self {
            Self::Nvdec(d) => d
                .decode(data, id)
                .map(|p| p.into_iter().map(|p| (id, p)).collect()),
            Self::Ffmpeg(d) => d.decode(Some(data), id, want_pixels),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_decoder_never_silently_falls_back() {
        for backend in [Backend::Nvdec, Backend::Vaapi, Backend::Software] {
            assert_eq!(
                Settings {
                    backend,
                    ..Settings::default()
                }
                .candidates(false),
                vec![backend]
            );
        }
        assert_eq!(
            Settings::default().candidates(true),
            vec![Backend::Vaapi, Backend::Software]
        );
        assert_eq!(Settings::default().candidates(false)[0], Backend::Nvdec);
    }
    #[test]
    fn pipeline_preferences_round_trip_and_old_state_defaults() {
        let value = Settings {
            backend: Backend::Vaapi,
            vaapi_device: Some("/dev/dri/by-path/pci-0000:04:00.0-render".into()),
            cpu_processing: true,
        };
        assert_eq!(
            toml::from_str::<Settings>(&toml::to_string(&value).unwrap()).unwrap(),
            value
        );
        assert_eq!(toml::from_str::<Settings>("").unwrap(), Settings::default());
    }

    /// Fixture: FFmpeg testsrc2 320x180, 20 H.264 frames with AUDs and two
    /// B-frames. Exercises delayed/reordered output and the VAAPI download path.
    #[test]
    #[ignore]
    fn portable_decoder_frame_identity_and_amd_surfaces() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
        for (codec, file) in [
            (Codec::H264, "reordered.h264"),
            (Codec::Hevc, "reordered.hevc"),
        ] {
            let bytes =
                std::fs::read(root.join(".build-cache/meteor-portable-tests").join(file)).unwrap();
            let mut starts = Vec::new();
            let mut i = 0;
            while i + 4 < bytes.len() {
                let prefix = if bytes[i..].starts_with(&[0, 0, 0, 1]) {
                    4
                } else if bytes[i..].starts_with(&[0, 0, 1]) {
                    3
                } else {
                    i += 1;
                    continue;
                };
                if (codec == Codec::H264 && bytes[i + prefix] & 31 == 9)
                    || (codec == Codec::Hevc && (bytes[i + prefix] >> 1) & 63 == 35)
                {
                    starts.push(i);
                }
                i += prefix + 1;
            }
            assert_eq!(starts.len(), 20);
            starts[0] = 0;
            starts.push(bytes.len());
            let device = vaapi_devices()
                .into_iter()
                .find(|(_, label)| label.starts_with("AMD"));
            let mut backends = vec![(Backend::Software, None)];
            if std::env::var_os("METEOR_TEST_VAAPI").is_some() {
                backends.push((
                    Backend::Vaapi,
                    Some(device.expect("AMD render node required").0),
                ));
            }
            let mut reference = std::collections::BTreeMap::new();
            for (backend, device) in backends {
                let mut decoder = Ffmpeg::new(codec, backend, device.as_deref(), (96, 54)).unwrap();
                let mut frames = Vec::new();
                for (id, span) in starts.windows(2).enumerate() {
                    frames.extend(
                        decoder
                            .decode(Some(&bytes[span[0]..span[1]]), id as u32, true)
                            .unwrap(),
                    );
                }
                frames.extend(decoder.decode(None, 0, true).unwrap());
                assert_eq!(frames.len(), 20);
                let order: Vec<_> = frames.iter().map(|(id, _)| *id).collect();
                assert_ne!(
                    order,
                    (0..20).collect::<Vec<_>>(),
                    "Fixture must exercise reordered output"
                );
                for (id, pixels) in frames {
                    let Pixels::Rgb(rgb) = pixels else {
                        panic!("Compatibility path returned a CUDA tensor")
                    };
                    assert_eq!(rgb.len(), 96 * 54 * 3);
                    if backend == Backend::Software {
                        assert!(reference.insert(id, rgb).is_none());
                    } else {
                        let expected = reference.get(&id).unwrap();
                        let difference = rgb
                            .iter()
                            .zip(expected)
                            .map(|(a, b)| (*a as f64 - *b as f64).abs())
                            .sum::<f64>()
                            / rgb.len() as f64;
                        assert!(
                            difference < 1.0,
                            "VAAPI vs software RGB differs for frame {id}: {difference}"
                        );
                    }
                }
                assert_eq!(reference.len(), 20);
                eprintln!(
                    "{codec:?} {}: all 20 frame IDs preserved through B-frame reordering",
                    backend.label()
                );
            }
        }
        #[cfg(target_os = "linux")]
        assert!(
            !std::fs::read_to_string("/proc/self/maps")
                .unwrap()
                .lines()
                .any(|l| l.contains("/libcuda.so")),
            "Compatibility decoder unexpectedly loaded CUDA"
        );
    }
}
