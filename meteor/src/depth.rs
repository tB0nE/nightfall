//! Host depth: decodes the tapped video, runs the depth model on the GPU and
//! post-processes the result into 8-bit maps tagged with their frame number.
//!
//! ```text
//! video tap ─► DepthFeed: NVDEC ─────────► Depth engine thread
//!   (frames)    (per flow; RGB at          model + post-process
//!                model size, ~1 ms)
//!                                                         └─► latest map
//! ```
//!
//! The engine keeps only the newest decoded frame, so when inference is busy
//! or the rate cap applies, frames are skipped rather than queued. Every
//! frame is still decoded, because later frames depend on earlier ones.

use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::gpu_post::GpuPost;
use crate::nvdec::{NvDecoder, Pixels};

/// Where a model run left its output.
enum Output {
    Host(Vec<f32>),
    /// Device address of the model's output buffer.
    Device(u64),
}
use crate::onnx::{Backend, DepthModel};
use crate::postprocess::PostProcessor;
use crate::stream_info::Codec;
use crate::video_tap::Frame;

/// Rates offered in the tray. 0 means every frame the stream delivers.
pub const RATES: [u32; 6] = [0, 30, 60, 72, 90, 120];

/// The tray's choices, remembered across restarts in state.toml.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
struct SavedState {
    enabled: bool,
    model: Option<String>,
    rate: u32,
}

impl Default for SavedState {
    fn default() -> Self {
        SavedState { enabled: true, model: None, rate: 0 }
    }
}

/// One finished depth map.
pub struct DepthMap {
    pub stream: u64,
    /// The streaming client whose video this came from.
    pub client: Option<IpAddr>,
    /// Counts maps; the depth server sends each one once.
    pub seq: u64,
    pub epoch: u32,
    pub frame_index: u32,
    pub after_loss: bool,
    pub width: usize,
    pub height: usize,
    pub data: Vec<u8>,
    pub frame_queued: Instant,
    pub decoded: Instant,
    pub infer_start: Instant,
    pub infer_end: Instant,
    pub done: Instant,
}

#[derive(Default)]
pub struct DepthStats {
    pub maps: AtomicU64,
    pub skipped: AtomicU64,
    /// Maps per second, times 10.
    pub rate_x10: AtomicU32,
    pub decode_us: AtomicU32,
    pub infer_us: AtomicU32,
    /// Frame handed to the decoder until its map was ready.
    pub total_us: AtomicU32,
}

pub struct Depth {
    pub models_dir: PathBuf,
    pub stats: DepthStats,
    /// Keep decoded frames on the GPU (default); `--cpu-frames` turns it off.
    pub gpu_frames: AtomicBool,
    /// Post-process on the GPU when frames are on the GPU (default);
    /// `--cpu-post` turns it off.
    pub gpu_post: AtomicBool,
    tensorrt: bool,
    /// A TensorRT engine is being built.
    pub tensorrt_pending: Arc<AtomicBool>,
    available: AtomicBool,
    state: Mutex<SavedState>,
    status: Mutex<String>,
    /// Name and input size of the model in use.
    active: Mutex<Option<(String, usize, usize)>>,
    pending_model: Mutex<Option<PathBuf>>,
    input: Mutex<Option<Decoded>>,
    wake: Condvar,
    pub latest: Mutex<Option<Arc<DepthMap>>>,
    /// Signalled with `latest` whenever a new map is ready.
    pub map_ready: Condvar,
    /// Clients connected to the depth port. The model only runs while there
    /// is one (or while saving snapshots); decoding never stops, because
    /// the decoder can only restart on a keyframe.
    pub subscribers: AtomicU32,
    save: Option<(PathBuf, u64)>,
}

impl Depth {
    /// Loads ONNX Runtime and the selected model in the background. Depth
    /// stays unavailable (and Meteor a plain proxy) if either fails.
    pub fn start(
        onnxruntime_lib: Option<&Path>,
        tensorrt: bool,
        models_dir: PathBuf,
        save: Option<(PathBuf, u64)>,
    ) -> Arc<Depth> {
        let state: SavedState = std::fs::read_to_string(crate::config::state_path())
            .ok()
            .and_then(|text| toml::from_str(&text).ok())
            .unwrap_or_default();
        let depth = Arc::new(Depth {
            models_dir,
            stats: DepthStats::default(),
            gpu_frames: AtomicBool::new(true),
            gpu_post: AtomicBool::new(true),
            tensorrt,
            tensorrt_pending: Arc::default(),
            available: AtomicBool::new(false),
            state: Mutex::new(state),
            status: Mutex::new("starting".into()),
            active: Mutex::new(None),
            pending_model: Mutex::new(None),
            input: Mutex::new(None),
            wake: Condvar::new(),
            latest: Mutex::new(None),
            map_ready: Condvar::new(),
            subscribers: AtomicU32::new(0),
            save,
        });
        match crate::onnx::init(onnxruntime_lib) {
            Ok(source) => log::info!("ONNX Runtime: {source}"),
            Err(err) => {
                log::warn!("Host depth is off: {err}");
                depth.set_status(format!("off: {err}"));
                return depth;
            }
        }
        let models = depth.list_models();
        let wanted = depth.state.lock().ok().and_then(|s| s.model.clone());
        let chosen = wanted.filter(|m| models.contains(m)).or_else(|| preferred_model(&models));
        let Some(chosen) = chosen else {
            let msg = format!("off: no .onnx models in {}", depth.models_dir.display());
            log::warn!("Host depth is {msg}");
            depth.set_status(msg);
            return depth;
        };
        depth.available.store(true, Ordering::Relaxed);
        depth.select_model(&chosen);
        let engine = depth.clone();
        let spawned = std::thread::Builder::new().name("depth".into()).spawn(move || engine.run());
        if let Err(err) = spawned {
            depth.available.store(false, Ordering::Relaxed);
            depth.set_status(format!("off: {err}"));
        }
        depth
    }

    pub fn available(&self) -> bool {
        self.available.load(Ordering::Relaxed)
    }

    pub fn enabled(&self) -> bool {
        self.available() && self.state.lock().is_ok_and(|s| s.enabled)
    }

    pub fn set_enabled(&self, enabled: bool) {
        self.update_state(|s| s.enabled = enabled);
        log::info!("Host depth {}", if enabled { "on" } else { "off" });
    }

    pub fn rate(&self) -> u32 {
        self.state.lock().map_or(0, |s| s.rate)
    }

    pub fn set_rate(&self, hz: u32) {
        self.update_state(|s| s.rate = hz);
        log::info!("Depth rate: {}", if hz == 0 { "match stream".into() } else { format!("{hz} Hz") });
    }

    pub fn status(&self) -> String {
        self.status.lock().map_or_else(|_| String::new(), |s| s.clone())
    }

    /// File name of the model in use (or being loaded).
    pub fn model(&self) -> Option<String> {
        self.state.lock().ok().and_then(|s| s.model.clone())
    }

    pub fn active_model(&self) -> Option<(String, usize, usize)> {
        self.active.lock().ok().and_then(|a| a.clone())
    }

    pub fn list_models(&self) -> Vec<String> {
        let mut models: Vec<String> = std::fs::read_dir(&self.models_dir)
            .map(|dir| {
                dir.flatten()
                    .filter_map(|e| e.file_name().into_string().ok())
                    .filter(|name| name.ends_with(".onnx"))
                    .collect()
            })
            .unwrap_or_default();
        models.sort();
        models
    }

    /// Loads a model from the models folder in the background; the engine
    /// switches to it between frames once it is ready.
    pub fn select_model(&self, name: &str) {
        self.update_state(|s| s.model = Some(name.to_string()));
        if let Ok(mut pending) = self.pending_model.lock() {
            *pending = Some(self.models_dir.join(name));
        }
        self.wake.notify_one();
    }

    /// Called by the decoder for every frame; replaces a frame the engine
    /// hasn't started on yet.
    pub fn submit(&self, frame: Decoded) {
        if let Ok(mut input) = self.input.lock()
            && input.replace(frame).is_some()
        {
            self.stats.skipped.fetch_add(1, Ordering::Relaxed);
        }
        self.wake.notify_one();
    }

    fn set_status(&self, status: String) {
        if let Ok(mut s) = self.status.lock() {
            *s = status;
        }
    }

    fn update_state(&self, change: impl FnOnce(&mut SavedState)) {
        let Ok(mut state) = self.state.lock() else { return };
        change(&mut state);
        let path = crate::config::state_path();
        let text = toml::to_string(&*state).unwrap_or_default();
        if let Err(err) = path.parent().map_or(Ok(()), std::fs::create_dir_all).and_then(|()| std::fs::write(&path, text)) {
            log::warn!("Can't save {}: {err}", path.display());
        }
    }

    fn run(self: Arc<Self>) {
        // (model path, backend, result)
        let (loaded_tx, loaded_rx) = mpsc::channel::<(PathBuf, Backend, Result<DepthModel, String>)>();
        let mut model: Option<DepthModel> = None;
        let mut post = PostProcessor::default();
        let mut gpu_post: Option<GpuPost> = None;
        let mut last_stream = None;
        let mut last_run: Option<Instant> = None;
        let mut rate_window = (Instant::now(), 0u32);
        let mut resized = Vec::new();
        loop {
            if let Some(path) = self.pending_model.lock().ok().and_then(|mut p| p.take()) {
                self.set_status(format!("loading {}", display_name(&path)));
                let tx = loaded_tx.clone();
                let tensorrt = self.tensorrt;
                let pending = self.tensorrt_pending.clone();
                // CUDA first, so depth starts within a second; then TensorRT,
                // whose first engine build for a model takes about 90 s.
                let _ = std::thread::Builder::new().name("depth-load".into()).spawn(move || {
                    let cache = crate::config::cache_dir().join("tensorrt");
                    let cuda = DepthModel::load(&path, Backend::Cuda, &cache);
                    let cuda_ok = cuda.is_ok();
                    let _ = tx.send((path.clone(), Backend::Cuda, cuda));
                    if tensorrt && cuda_ok {
                        pending.store(true, Ordering::Relaxed);
                        let trt = DepthModel::load(&path, Backend::TensorRt, &cache);
                        pending.store(false, Ordering::Relaxed);
                        let _ = tx.send((path, Backend::TensorRt, trt));
                    }
                });
            }
            while let Ok((path, backend, result)) = loaded_rx.try_recv() {
                // A model chosen since this one started loading wins.
                let wanted = self.model().map(|m| self.models_dir.join(m));
                if wanted.as_ref() != Some(&path) {
                    continue;
                }
                match result {
                    Ok(loaded) => {
                        if let Ok(mut active) = self.active.lock() {
                            *active = Some((loaded.name.clone(), loaded.width, loaded.height));
                        }
                        let building = if self.tensorrt_pending.load(Ordering::Relaxed) {
                            "; building the TensorRT engine (about 90 s the first time)"
                        } else {
                            ""
                        };
                        self.set_status(format!(
                            "ready: {} ({}x{}, {}{building})",
                            loaded.name,
                            loaded.width,
                            loaded.height,
                            loaded.backend.label()
                        ));
                        // Same model and size: no need to restart smoothing.
                        if model.as_ref().is_none_or(|m| m.name != loaded.name) {
                            post.reset();
                            if let Some(g) = &mut gpu_post {
                                g.reset();
                            }
                        }
                        model = Some(loaded);
                    }
                    // TensorRT is optional: stay on CUDA.
                    Err(err) if backend == Backend::TensorRt => {
                        log::warn!("TensorRT unavailable, staying on CUDA: {err}");
                        if let Some(m) = &model {
                            self.set_status(format!("ready: {} ({}x{}, CUDA)", m.name, m.width, m.height));
                        }
                    }
                    Err(err) => {
                        log::warn!("Can't load depth model: {err}");
                        self.set_status(format!("model failed: {err}"));
                    }
                }
            }

            let frame = {
                let Ok(input) = self.input.lock() else { return };
                let (mut input, _) = self
                    .wake
                    .wait_timeout_while(input, Duration::from_millis(250), |i| i.is_none())
                    .unwrap_or_else(|e| e.into_inner());
                input.take()
            };
            let Some(frame) = frame else {
                if rate_window.0.elapsed() > Duration::from_secs(2) {
                    self.stats.rate_x10.store(0, Ordering::Relaxed);
                }
                continue;
            };
            let Some(model) = model.as_mut() else { continue };
            if !self.enabled() || (self.subscribers.load(Ordering::Relaxed) == 0 && self.save.is_none()) {
                continue;
            }
            let rate = self.rate();
            if rate > 0
                && let Some(last) = last_run
                && last.elapsed() < Duration::from_secs_f64(1.0 / f64::from(rate)) - Duration::from_millis(1)
            {
                self.stats.skipped.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            last_run = Some(Instant::now());

            let stream = (frame.tag.stream, frame.tag.epoch);
            if last_stream != Some(stream) {
                post.reset();
                if let Some(g) = &mut gpu_post {
                    g.reset();
                }
                last_stream = Some(stream);
            }
            let (fw, fh) = frame.size;
            let same_size = (fw, fh) == (model.width, model.height);
            let infer_start = Instant::now();
            let pixels = model.width * model.height;
            // Keep the model output on the GPU for GPU post-processing.
            let on_device = self.gpu_post.load(Ordering::Relaxed)
                && matches!(frame.pixels, Pixels::Gpu(_))
                && (gpu_post.is_some() || {
                    match GpuPost::new(pixels) {
                        Ok(g) => gpu_post = Some(g),
                        Err(err) => {
                            log::warn!("GPU post-processing unavailable ({err}); using the CPU");
                            self.gpu_post.store(false, Ordering::Relaxed);
                        }
                    }
                    gpu_post.is_some()
                });
            if on_device && gpu_post.as_ref().is_some_and(|g| g.pixels() != pixels) {
                gpu_post = GpuPost::new(pixels).ok();
            }
            let result = match &frame.pixels {
                Pixels::Rgb(rgb) if same_size => model.infer(rgb).map(Output::Host),
                Pixels::Rgb(rgb) => {
                    // The model changed size since this stream's decoder started.
                    resize_rgb(rgb, fw, fh, model.width, model.height, &mut resized);
                    model.infer(&resized).map(Output::Host)
                }
                Pixels::Gpu(tensor) if same_size && on_device => model.infer_on_device(tensor.ptr).map(Output::Device),
                Pixels::Gpu(tensor) if same_size => model.infer_gpu(tensor.ptr).map(Output::Host),
                // The decoder restarts at the new size on the next keyframe.
                Pixels::Gpu(_) => continue,
            };
            let output = match result {
                Ok(output) => output,
                Err(err) => {
                    log::warn!("Depth inference failed: {err}");
                    continue;
                }
            };
            let infer_end = Instant::now();
            let infer_time = infer_end - infer_start;
            let data = match (output, gpu_post.as_mut()) {
                (Output::Host(raw), _) => post.process(&raw, Instant::now()),
                (Output::Device(raw), Some(g)) => match g.process(raw, Instant::now()) {
                    Ok(data) => data,
                    Err(err) => {
                        log::warn!("GPU post-processing failed: {err}");
                        continue;
                    }
                },
                (Output::Device(_), None) => continue,
            };
            let done = Instant::now();
            let maps = self.stats.maps.fetch_add(1, Ordering::Relaxed) + 1;
            let map = Arc::new(DepthMap {
                stream: frame.tag.stream,
                client: frame.tag.client,
                seq: maps,
                epoch: frame.tag.epoch,
                frame_index: frame.tag.index,
                after_loss: frame.tag.after_loss,
                width: model.width,
                height: model.height,
                data,
                frame_queued: frame.tag.queued,
                decoded: frame.decoded,
                infer_start,
                infer_end,
                done,
            });

            let us = |d: Duration| u32::try_from(d.as_micros()).unwrap_or(u32::MAX);
            self.stats.decode_us.store(us(frame.decoded - frame.tag.queued), Ordering::Relaxed);
            self.stats.infer_us.store(us(infer_time), Ordering::Relaxed);
            self.stats.total_us.store(us(done - frame.tag.queued), Ordering::Relaxed);
            rate_window.1 += 1;
            let window = rate_window.0.elapsed();
            if window >= Duration::from_secs(1) {
                let rate_x10 = (f64::from(rate_window.1) * 10.0 / window.as_secs_f64()).round() as u32;
                self.stats.rate_x10.store(rate_x10, Ordering::Relaxed);
                rate_window = (Instant::now(), 0);
            }
            if let Some((dir, every)) = &self.save
                && (maps - 1) % every == 0
            {
                let rgb = match &frame.pixels {
                    Pixels::Rgb(rgb) if same_size => Ok(rgb.clone()),
                    Pixels::Rgb(_) => Ok(resized.clone()),
                    Pixels::Gpu(tensor) => tensor.download_rgb(),
                };
                match rgb {
                    Ok(rgb) => save_snapshot(dir, &map, &rgb),
                    Err(err) => log::warn!("Can't save depth snapshot: {err}"),
                }
            }
            if let Ok(mut latest) = self.latest.lock() {
                *latest = Some(map);
                self.map_ready.notify_all();
            }
        }
    }
}

/// The widescreen EdgePad family's 512x288 model (the Quest's standard tier),
/// built by tools/make_host_model.py. Its 672x384 sibling is the
/// higher-quality host choice.
pub const DEFAULT_MODEL: &str = "zipdepth_wide_512x288.onnx";

/// Picks a default: the 512x288 model, else the first.
fn preferred_model(models: &[String]) -> Option<String> {
    models.iter().find(|m| m.as_str() == DEFAULT_MODEL).or_else(|| models.first()).cloned()
}

fn display_name(path: &Path) -> String {
    path.file_stem().and_then(|s| s.to_str()).unwrap_or("model").to_string()
}

/// Nearest-neighbour RGB24 resize; only used for the frames in flight when
/// the model changes size.
fn resize_rgb(src: &[u8], sw: usize, sh: usize, dw: usize, dh: usize, out: &mut Vec<u8>) {
    out.clear();
    out.reserve(dw * dh * 3);
    for y in 0..dh {
        let sy = (y * sh / dh).min(sh - 1);
        for x in 0..dw {
            let sx = (x * sw / dw).min(sw - 1);
            let i = (sy * sw + sx) * 3;
            out.extend_from_slice(&src[i..i + 3]);
        }
    }
}

/// Writes the frame and its depth map as PNGs, for checking that they match.
fn save_snapshot(dir: &Path, map: &DepthMap, rgb: &[u8]) {
    let stem = format!("s{}e{}-f{:06}", map.stream, map.epoch, map.frame_index);
    let write = |name: String, data: &[u8], color: png::ColorType| -> std::io::Result<()> {
        std::fs::create_dir_all(dir)?;
        let file = std::io::BufWriter::new(std::fs::File::create(dir.join(name))?);
        let mut encoder = png::Encoder::new(file, map.width as u32, map.height as u32);
        encoder.set_color(color);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.write_header()?.write_image_data(data)?;
        Ok(())
    };
    let result = write(format!("{stem}-frame.png"), rgb, png::ColorType::Rgb)
        .and_then(|()| write(format!("{stem}-depth.png"), &map.data, png::ColorType::Grayscale));
    if let Err(err) = result {
        log::warn!("Can't save depth snapshot in {}: {err}", dir.display());
    }
}

/// What the engine needs to know about the frame a decoded image came from.
#[derive(Clone, Copy)]
pub struct FrameTag {
    /// Unique per decoder, so the engine can tell streams apart.
    pub stream: u64,
    pub client: Option<IpAddr>,
    pub epoch: u32,
    pub index: u32,
    pub after_loss: bool,
    /// When the frame was handed to the decoder.
    pub queued: Instant,
}

/// A decoded frame at the model's input size: RGB24, or the input tensor
/// already in GPU memory.
pub struct Decoded {
    pub tag: FrameTag,
    pub decoded: Instant,
    pub size: (usize, usize),
    pub pixels: Pixels,
}

static NEXT_STREAM: AtomicU64 = AtomicU64::new(1);

/// Decodes one video flow's frames with NVDEC for the depth engine. Lives
/// on the video tap's thread; decoding is synchronous (about a millisecond).
pub struct DepthFeed {
    depth: Arc<Depth>,
    client: Option<IpAddr>,
    decoder: Option<(NvDecoder, u64, (usize, usize))>,
    epoch: Option<u32>,
    /// The decoder couldn't be created for this epoch; don't retry every keyframe.
    failed: bool,
}

impl DepthFeed {
    pub fn new(depth: Arc<Depth>, client: Option<IpAddr>) -> DepthFeed {
        DepthFeed { depth, client: client.map(|ip| ip.to_canonical()), decoder: None, epoch: None, failed: false }
    }

    pub fn push(&mut self, frame: &Frame, codec: Option<Codec>) {
        if !self.depth.enabled() {
            self.decoder = None;
            return;
        }
        if self.epoch != Some(frame.epoch) {
            self.decoder = None;
            self.epoch = Some(frame.epoch);
            self.failed = false;
        }
        let model_size = self.depth.active_model().map(|(_, w, h)| (w, h));
        // A new model size: start again at the next keyframe at that size.
        if self.decoder.as_ref().is_some_and(|(_, _, size)| Some(*size) != model_size) {
            self.decoder = None;
        }
        if self.decoder.is_none() {
            // A decoder can only start on a keyframe.
            let (Some(codec), true, Some((width, height)), false) = (codec, frame.idr, model_size, self.failed) else {
                return;
            };
            let gpu_frames = self.depth.gpu_frames.load(Ordering::Relaxed);
            match NvDecoder::new(codec, width, height, gpu_frames) {
                Ok(decoder) => {
                    log::info!("Host depth decoding {codec:?} with NVDEC at {width}x{height}");
                    self.decoder = Some((decoder, NEXT_STREAM.fetch_add(1, Ordering::Relaxed), (width, height)));
                }
                Err(err) => {
                    log::warn!("Host depth decoder failed: {err}");
                    self.failed = true;
                    return;
                }
            }
        }
        let Some((decoder, stream, size)) = &mut self.decoder else { return };
        let queued = Instant::now();
        match decoder.decode(&frame.data, frame.index) {
            Ok(Some(pixels)) => self.depth.submit(Decoded {
                tag: FrameTag {
                    stream: *stream,
                    client: self.client,
                    epoch: frame.epoch,
                    index: frame.index,
                    after_loss: frame.after_loss,
                    queued,
                },
                decoded: Instant::now(),
                size: *size,
                pixels,
            }),
            Ok(None) => {}
            Err(err) => {
                log::warn!("Host depth decoder: {err}; restarting at the next keyframe");
                self.decoder = None;
            }
        }
    }
}
