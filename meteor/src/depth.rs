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
//!
//! Single-frame models (EdgePad) run on ncnn's Vulkan backend
//! (`<name>.ncnn.param`, see `ncnn.rs`) or on ONNX Runtime (`<name>.onnx`);
//! when both are there, ncnn wins unless `METEOR_NCNN=off`. Video Depth
//! Anything (`vda.rs`) is a pair of graphs with a temporal state, on
//! TensorRT.

use std::collections::BTreeMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::gpu_post::GpuPost;
use crate::ncnn::{self, NcnnModel};
use crate::nvdec::{NvDecoder, Pixels};

/// Where a model run left its output.
enum Output {
    Host(Vec<f32>),
    /// Device address of the model's output buffer.
    Device(u64),
}
use crate::onnx::{Backend, DepthModel};
use crate::postprocess::{DEPTH_TAU_SECONDS, PostProcessor};
use crate::stream_info::Codec;
use crate::vda::{self, VdaModel};
use crate::video_tap::Frame;

/// A loaded depth model.
enum Engine {
    /// Single-frame, on ONNX Runtime.
    Plain(Box<DepthModel>),
    /// Single-frame, on ncnn (Vulkan).
    Ncnn(Box<NcnnModel>),
    Vda(Box<VdaModel>),
}

impl Engine {
    fn load(models_dir: &Path, name: &str, backend: Backend, cache: &Path) -> Result<Engine, String> {
        if name == vda::ID {
            VdaModel::load(models_dir, backend, cache).map(|m| Engine::Vda(Box::new(m)))
        } else if is_ncnn(name) {
            NcnnModel::load(&models_dir.join(name)).map(|m| Engine::Ncnn(Box::new(m)))
        } else {
            DepthModel::load(&models_dir.join(name), backend, cache).map(|m| Engine::Plain(Box::new(m)))
        }
    }

    /// The name in the models menu and state.toml.
    fn id(&self) -> String {
        match self {
            Engine::Plain(m) => format!("{}.onnx", m.name),
            Engine::Ncnn(m) => format!("{}{}", m.name, ncnn::PARAM_SUFFIX),
            Engine::Vda(m) => m.name.clone(),
        }
    }

    /// The depth map's size.
    fn output_size(&self) -> (usize, usize) {
        match self {
            Engine::Plain(m) => (m.width, m.height),
            Engine::Ncnn(m) => (m.width, m.height),
            Engine::Vda(_) => (vda::WIDTH, vda::HEIGHT),
        }
    }

    /// The size the decoder reduces frames to.
    fn input_size(&self) -> (usize, usize) {
        match self {
            Engine::Plain(m) => (m.width, m.height),
            Engine::Ncnn(m) => (m.width, m.height),
            Engine::Vda(_) => vda::DECODE_SIZE,
        }
    }

    fn describe(&self) -> String {
        let (w, h) = self.output_size();
        match self {
            Engine::Plain(m) => format!("{} ({w}x{h}, {})", m.name, m.backend.label()),
            Engine::Ncnn(m) => format!("{} ({w}x{h}, Vulkan fp16)", m.name),
            Engine::Vda(m) => format!("{} ({w}x{h}, {})", vda::LABEL, m.description),
        }
    }
}

fn is_ncnn(name: &str) -> bool {
    name.ends_with(ncnn::PARAM_SUFFIX)
}

/// A single-frame model's name without its format: `zipdepth_wide_512x288`
/// for both `.onnx` and `.ncnn.param`.
fn stem(name: &str) -> &str {
    name.strip_suffix(ncnn::PARAM_SUFFIX).or_else(|| name.strip_suffix(".onnx")).unwrap_or(name)
}

/// The models menu's name for a model.
pub fn model_label(name: &str) -> String {
    if name == vda::ID { vda::LABEL.to_string() } else { stem(name).to_string() }
}

/// Where Meteor finds the runtimes; each is optional.
pub struct Runtimes<'a> {
    pub onnxruntime: Option<&'a Path>,
    pub ncnn: Option<&'a Path>,
}

/// A model the loading thread finished with.
struct Loaded {
    /// The model that was chosen.
    name: String,
    /// A failure leaves the model running on what loaded before (TensorRT
    /// after CUDA).
    optional: bool,
    /// A single-frame model to serve while `name` keeps loading.
    interim: bool,
    result: Result<Engine, String>,
}

/// Rates offered in the tray. 0 means every frame the stream delivers.
pub const RATES: [u32; 6] = [0, 30, 60, 72, 90, 120];

/// The tray's choices, remembered across restarts in state.toml.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
struct SavedState {
    enabled: bool,
    model: Option<String>,
    rate: u32,
    /// The per-pixel depth smoothing in post-processing, per model (by
    /// stem), once the user has set it. Unset, it's off for VDA, which is
    /// temporally steady already (smoothing adds about 40 ms of lag), and on
    /// for the EdgePad models. (Older files have a single `smoothing`
    /// switch, which is ignored; reusing that key for this table would
    /// make them fail to parse.)
    model_smoothing: BTreeMap<String, bool>,
    /// VDA's edge softening, an index into vda::SOFTENING.
    edge_softening: usize,
}

impl Default for SavedState {
    fn default() -> Self {
        SavedState { enabled: true, model: None, rate: 0, model_smoothing: BTreeMap::new(), edge_softening: vda::DEFAULT_SOFTENING }
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
    /// Models shipped with Meteor (the AppImage's
    /// `usr/share/nightfall-meteor/models`); a file of the same name in
    /// models_dir wins.
    bundled_dir: Option<PathBuf>,
    /// The VDA download (TensorRT and the graphs), started from the tray.
    pub download: crate::download::Download,
    pub stats: DepthStats,
    /// Keep decoded frames on the GPU (default); `--cpu-frames` turns it off.
    pub gpu_frames: AtomicBool,
    /// Post-process on the GPU when frames are on the GPU (default);
    /// `--cpu-post` turns it off.
    pub gpu_post: AtomicBool,
    tensorrt: bool,
    /// Which runtimes loaded: ONNX Runtime, ncnn.
    onnx_ok: bool,
    ncnn_ok: bool,
    /// A TensorRT engine is being built.
    pub tensorrt_pending: Arc<AtomicBool>,
    available: AtomicBool,
    state: Mutex<SavedState>,
    status: Mutex<String>,
    /// Name and output size of the model in use.
    active: Mutex<Option<(String, usize, usize)>>,
    /// The size the decoder reduces frames to for that model.
    input_size: Mutex<Option<(usize, usize)>>,
    pending_model: Mutex<Option<String>>,
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
    /// Loads the runtimes, then the selected model in the background. Depth
    /// stays unavailable (and Meteor a plain proxy) if no runtime or model
    /// loads.
    pub fn start(runtimes: Runtimes, tensorrt: bool, models_dir: PathBuf, save: Option<(PathBuf, u64)>) -> Arc<Depth> {
        let state: SavedState = std::fs::read_to_string(crate::config::state_path())
            .ok()
            .and_then(|text| toml::from_str(&text).ok())
            .unwrap_or_default();
        let mut errors = Vec::new();
        let onnx_ok = match crate::onnx::init(runtimes.onnxruntime) {
            Ok(source) => {
                log::info!("ONNX Runtime: {source}");
                true
            }
            Err(err) => {
                errors.push(err);
                false
            }
        };
        let ncnn_ok = if std::env::var("METEOR_NCNN").as_deref() == Ok("off") {
            false
        } else {
            match ncnn::init(runtimes.ncnn) {
                Ok(source) => {
                    log::info!("Vulkan: {source}");
                    true
                }
                Err(err) => {
                    errors.push(err);
                    false
                }
            }
        };
        let bundled_dir = std::env::current_exe()
            .ok()
            .and_then(|exe| Some(exe.parent()?.join("../share/nightfall-meteor/models")))
            .filter(|dir| dir.is_dir());
        let depth = Arc::new(Depth {
            models_dir,
            bundled_dir,
            download: crate::download::Download::default(),
            stats: DepthStats::default(),
            gpu_frames: AtomicBool::new(true),
            gpu_post: AtomicBool::new(true),
            tensorrt,
            onnx_ok,
            ncnn_ok,
            tensorrt_pending: Arc::default(),
            available: AtomicBool::new(false),
            state: Mutex::new(state),
            status: Mutex::new("starting".into()),
            active: Mutex::new(None),
            input_size: Mutex::new(None),
            pending_model: Mutex::new(None),
            input: Mutex::new(None),
            wake: Condvar::new(),
            latest: Mutex::new(None),
            map_ready: Condvar::new(),
            subscribers: AtomicU32::new(0),
            save,
        });
        for err in &errors {
            log::info!("Not available: {err}");
        }
        let models = depth.list_models();
        let wanted = depth.state.lock().ok().and_then(|s| s.model.clone());
        // A model saved in the other format still counts.
        let chosen = wanted
            .and_then(|w| models.iter().find(|m| **m == w || (w != vda::ID && stem(m) == stem(&w))).cloned())
            .or_else(|| preferred_model(&models));
        let Some(chosen) = chosen else {
            let msg = if onnx_ok || ncnn_ok {
                format!("off: no models in {}", depth.models_dir.display())
            } else {
                format!("off: {}", errors.join("; "))
            };
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

    /// Depth smoothing for the chosen model.
    pub fn smoothing(&self) -> bool {
        self.state.lock().is_ok_and(|s| {
            let model = s.model.as_deref().unwrap_or_default();
            s.model_smoothing.get(stem(model)).copied().unwrap_or(model != vda::ID)
        })
    }

    pub fn set_smoothing(&self, on: bool) {
        self.update_state(|s| {
            let model = stem(s.model.as_deref().unwrap_or_default()).to_string();
            s.model_smoothing.insert(model, on);
        });
        log::info!("Depth smoothing {}", if on { "on" } else { "off" });
    }

    /// The edge softening level (an index into vda::SOFTENING).
    pub fn edge_softening(&self) -> usize {
        self.state.lock().map_or(vda::DEFAULT_SOFTENING, |s| s.edge_softening.min(vda::SOFTENING.len() - 1))
    }

    pub fn set_edge_softening(&self, level: usize) {
        let level = level.min(vda::SOFTENING.len() - 1);
        self.update_state(|s| s.edge_softening = level);
        log::info!("Edge softening: {}", vda::SOFTENING[level].0);
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

    fn input_size(&self) -> Option<(usize, usize)> {
        self.input_size.lock().ok().and_then(|s| *s)
    }

    /// Model files by name, with the folder each is in: the bundled ones,
    /// then the user's, which win.
    fn model_files(&self) -> BTreeMap<String, PathBuf> {
        let mut files = BTreeMap::new();
        for dir in self.bundled_dir.iter().chain([&self.models_dir]) {
            for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                if let Ok(name) = entry.file_name().into_string() {
                    files.insert(name, dir.clone());
                }
            }
        }
        files
    }

    /// The folder a model is loaded from.
    fn model_dir(&self, name: &str) -> PathBuf {
        if name == vda::ID {
            return self.models_dir.clone();
        }
        self.model_files().remove(name).unwrap_or_else(|| self.models_dir.clone())
    }

    /// The models a loaded runtime can run: each single-frame model once, as
    /// `.ncnn.param` (with its `.bin`) or else `.onnx`, and VDA's files
    /// once, as `vda::ID`, when TensorRT is there for them.
    pub fn list_models(&self) -> Vec<String> {
        let found = self.model_files();
        let files: Vec<&String> = found.keys().collect();
        let has = |name: &str| found.contains_key(name);
        let mut stems: Vec<&str> = files
            .iter()
            .filter(|f| (is_ncnn(f) || f.ends_with(".onnx")) && !vda::is_file(f))
            .map(|f| stem(f))
            .collect();
        stems.sort();
        stems.dedup();
        let mut models: Vec<String> = stems
            .into_iter()
            .filter_map(|s| {
                let param = format!("{s}{}", ncnn::PARAM_SUFFIX);
                if self.ncnn_ok && has(&param) && has(&format!("{s}.ncnn.bin")) {
                    Some(param)
                } else {
                    let onnx = format!("{s}.onnx");
                    (self.onnx_ok && has(&onnx)).then_some(onnx)
                }
            })
            .collect();
        if vda::present(&self.models_dir) && (self.onnx_ok || crate::tensorrt::init().is_ok()) {
            models.push(vda::ID.to_string());
        }
        models.sort();
        models
    }

    /// When VDA isn't usable but the download would make it so: the bytes
    /// to download. None while a download runs.
    pub fn vda_offer(&self) -> Option<u64> {
        if self.download.state() == crate::download::State::Running || self.list_models().iter().any(|m| m == vda::ID) {
            return None;
        }
        crate::download::plan(&self.models_dir).ok().filter(|p| !p.is_empty()).map(|p| p.bytes())
    }

    /// Downloads what VDA needs in the background, then switches to it. The
    /// current model keeps serving meanwhile.
    pub fn download_vda(self: &Arc<Self>) {
        if self.download.state() == crate::download::State::Running {
            return;
        }
        let depth = self.clone();
        let _ = std::thread::Builder::new().name("vda-download".into()).spawn(move || {
            let plan = match crate::download::plan(&depth.models_dir) {
                Ok(plan) => plan,
                Err(err) => {
                    log::warn!("VDA download: {err}");
                    if let Ok(mut s) = depth.download.state.lock() {
                        *s = crate::download::State::Failed(err);
                    }
                    return;
                }
            };
            log::info!("VDA download: {} MB", plan.bytes() / 1_000_000);
            match depth.download.run(&plan) {
                Ok(()) => {
                    log::info!("VDA download finished");
                    if depth.list_models().iter().any(|m| m == vda::ID) {
                        depth.select_model(vda::ID);
                    } else {
                        log::warn!("VDA was downloaded but still isn't usable: {}", crate::tensorrt::init().err().unwrap_or_default());
                    }
                }
                Err(err) => log::warn!("VDA download stopped: {err}"),
            }
        });
    }

    /// Deletes what the VDA download installed, after switching away from
    /// VDA if it's in use.
    pub fn remove_vda_download(&self) {
        if self.model().as_deref() == Some(vda::ID) {
            let models: Vec<String> = self.list_models().into_iter().filter(|m| m != vda::ID).collect();
            if let Some(other) = preferred_model(&models) {
                self.select_model(&other);
            }
        }
        match crate::download::remove(&self.models_dir) {
            Ok(()) => log::info!("Removed the VDA download"),
            Err(err) => log::warn!("Can't remove the VDA download: {err}"),
        }
        if let Ok(mut s) = self.download.state.lock() {
            *s = crate::download::State::Idle;
        }
    }

    /// Loads a model from the models folder in the background; the engine
    /// switches to it between frames once it is ready.
    pub fn select_model(&self, name: &str) {
        self.update_state(|s| s.model = Some(name.to_string()));
        if let Ok(mut pending) = self.pending_model.lock() {
            *pending = Some(name.to_string());
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
        let (loaded_tx, loaded_rx) = mpsc::channel::<Loaded>();
        let mut model: Option<Engine> = None;
        let mut post = PostProcessor::default();
        let mut gpu_post: Option<GpuPost> = None;
        let mut last_stream = None;
        let mut last_run: Option<Instant> = None;
        let mut rate_window = (Instant::now(), 0u32);
        let mut resized = Vec::new();
        let mut telemetry = vda::Telemetry::default();
        // VDA frames that failed in a row; after a few, go back to the
        // previous model.
        let mut failures = 0;
        // The last single-frame model in use, to fall back to.
        let mut fallback: Option<String> = None;
        loop {
            if let Some(name) = self.pending_model.lock().ok().and_then(|mut p| p.take()) {
                self.set_status(format!("loading {}", model_label(&name)));
                let tx = loaded_tx.clone();
                let tensorrt = self.tensorrt;
                let pending = self.tensorrt_pending.clone();
                let models_dir = self.model_dir(&name);
                let cuda_present = crate::onnx::cuda_backend_present();
                // Without CUDA, VDA has nothing to run on while its engines
                // build (minutes the first time), so a single-frame model
                // serves until it's ready, unless one already does.
                let interim = (name == vda::ID && !cuda_present && model.is_none())
                    .then(|| preferred_model(&self.list_models().into_iter().filter(|m| m != vda::ID).collect::<Vec<_>>()))
                    .flatten()
                    .map(|m| (self.model_dir(&m), m));
                // ncnn models load once, in about a second. ONNX models load
                // on CUDA first, so depth starts within a second; then on
                // TensorRT, whose first engine build for a model takes about
                // 90 s. Without the CUDA provider, TensorRT only.
                let _ = std::thread::Builder::new().name("depth-load".into()).spawn(move || {
                    let cache = crate::config::cache_dir().join("tensorrt");
                    let send = |optional, interim, result| {
                        let _ = tx.send(Loaded { name: name.clone(), optional, interim, result });
                    };
                    if is_ncnn(&name) {
                        send(false, false, Engine::load(&models_dir, &name, Backend::Cuda, &cache));
                        return;
                    }
                    if let Some((dir, interim)) = interim {
                        pending.store(tensorrt, Ordering::Relaxed);
                        let backend = if is_ncnn(&interim) { Backend::Cuda } else { Backend::TensorRt };
                        send(false, true, Engine::load(&dir, &interim, backend, &cache));
                    }
                    let cuda_ok = !cuda_present || {
                        let cuda = Engine::load(&models_dir, &name, Backend::Cuda, &cache);
                        let ok = cuda.is_ok();
                        send(false, false, cuda);
                        ok
                    };
                    if !tensorrt && !cuda_present {
                        send(false, false, Err("no backend: TensorRT is turned off and there is no CUDA provider".into()));
                    } else if tensorrt && cuda_ok {
                        pending.store(true, Ordering::Relaxed);
                        let trt = Engine::load(&models_dir, &name, Backend::TensorRt, &cache);
                        pending.store(false, Ordering::Relaxed);
                        // TensorRT is optional when CUDA is there.
                        send(cuda_present, false, trt);
                    }
                });
            }
            while let Ok(Loaded { name, optional, interim, result }) = loaded_rx.try_recv() {
                // A model chosen since this one started loading wins.
                if self.model().as_ref() != Some(&name) {
                    continue;
                }
                match result {
                    Ok(loaded) => {
                        if let Ok(mut active) = self.active.lock() {
                            let (w, h) = loaded.output_size();
                            *active = Some((loaded.id(), w, h));
                        }
                        if let Ok(mut size) = self.input_size.lock() {
                            *size = Some(loaded.input_size());
                        }
                        let building = match (self.tensorrt_pending.load(Ordering::Relaxed), &loaded) {
                            _ if interim => "; loading Video Depth Anything (the first time builds its TensorRT engines, several minutes)",
                            (false, _) => "",
                            (true, Engine::Vda(_)) => "; building the TensorRT engines (several minutes the first time)",
                            (true, Engine::Plain(_)) => "; building the TensorRT engine (about 90 s the first time)",
                            (true, Engine::Ncnn(_)) => "",
                        };
                        self.set_status(format!("ready: {}{building}", loaded.describe()));
                        // Same model and size: no need to restart smoothing.
                        if model.as_ref().is_none_or(|m| m.id() != loaded.id()) {
                            post.reset();
                            if let Some(g) = &mut gpu_post {
                                g.reset();
                            }
                        }
                        if let Engine::Plain(_) | Engine::Ncnn(_) = loaded {
                            fallback = Some(loaded.id());
                        }
                        failures = 0;
                        model = Some(loaded);
                    }
                    Err(err) if interim => log::warn!("Can't load a model to use while VDA loads: {err}"),
                    Err(err) if optional => {
                        log::warn!("TensorRT unavailable, staying on CUDA: {err}");
                        if let Some(m) = &model {
                            self.set_status(format!("ready: {}", m.describe()));
                        }
                    }
                    Err(err) => {
                        log::warn!("Can't load depth model: {err}");
                        self.set_status(format!("model failed: {err}"));
                        if name == vda::ID {
                            self.fall_back(model.as_ref().map(Engine::id).or(fallback.clone()), &err);
                        }
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
            let Some(engine) = model.as_mut() else { continue };
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
                if let Engine::Vda(m) = engine {
                    m.reset("new stream");
                }
                last_stream = Some(stream);
            }
            let depth_tau = if self.smoothing() { DEPTH_TAU_SECONDS } else { 0.0 };
            post.depth_tau = depth_tau;
            let (fw, fh) = frame.size;
            let input = engine.input_size();
            let (width, height) = engine.output_size();
            let same_size = (fw, fh) == input;
            let infer_start = Instant::now();
            let pixels = width * height;
            // Keep the model output on the GPU for GPU post-processing. VDA's
            // output is always on the GPU; an ONNX model's is when its input
            // was; ncnn's comes back to the CPU.
            let device_output = match engine {
                Engine::Vda(_) => true,
                Engine::Plain(_) => matches!(frame.pixels, Pixels::Gpu(_)),
                Engine::Ncnn(_) => false,
            };
            let on_device = self.gpu_post.load(Ordering::Relaxed)
                && device_output
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
            let mut vda_report = None;
            let result = match engine {
                Engine::Plain(model) => match &frame.pixels {
                    Pixels::Rgb(rgb) if same_size => model.infer(rgb).map(Output::Host),
                    Pixels::Rgb(rgb) => {
                        // The model changed size since this stream's decoder started.
                        resize_rgb(rgb, fw, fh, input.0, input.1, &mut resized);
                        model.infer(&resized).map(Output::Host)
                    }
                    Pixels::Gpu(tensor) if same_size && on_device => model.infer_on_device(tensor.ptr).map(Output::Device),
                    Pixels::Gpu(tensor) if same_size => model.infer_gpu(tensor.ptr).map(Output::Host),
                    // The decoder restarts at the new size on the next keyframe.
                    Pixels::Gpu(_) => continue,
                },
                Engine::Ncnn(model) => match &frame.pixels {
                    Pixels::Rgb(rgb) if same_size => model.infer(rgb).map(Output::Host),
                    Pixels::Rgb(rgb) => {
                        resize_rgb(rgb, fw, fh, input.0, input.1, &mut resized);
                        model.infer(&resized).map(Output::Host)
                    }
                    // Vulkan can't read CUDA memory: the input comes back
                    // to the CPU (1.8 MB at 512x288).
                    Pixels::Gpu(tensor) if same_size => {
                        tensor.download().and_then(|planar| model.infer_planar(&planar)).map(Output::Host)
                    }
                    Pixels::Gpu(_) => continue,
                },
                Engine::Vda(model) => {
                    model.edge_softening = vda::SOFTENING[self.edge_softening()].1;
                    let report = match &frame.pixels {
                        Pixels::Gpu(tensor) if same_size => model.infer_device(tensor.ptr, frame.size),
                        Pixels::Rgb(rgb) if same_size => model.infer_rgb(rgb, frame.size),
                        Pixels::Rgb(rgb) => {
                            resize_rgb(rgb, fw, fh, input.0, input.1, &mut resized);
                            model.infer_rgb(&resized, input)
                        }
                        Pixels::Gpu(_) => continue,
                    };
                    report.and_then(|report| {
                        let output =
                            if on_device { Ok(Output::Device(report.depth)) } else { model.download_depth(report.depth).map(Output::Host) };
                        vda_report = Some(report);
                        output
                    })
                }
            };
            let output = match result {
                Ok(output) => {
                    failures = 0;
                    output
                }
                Err(err) => {
                    log::warn!("Depth inference failed: {err}");
                    if matches!(engine, Engine::Vda(_)) {
                        failures += 1;
                        if failures >= 3 {
                            model = None;
                            self.fall_back(fallback.clone(), &format!("{failures} failed frames in a row ({err})"));
                        }
                    }
                    continue;
                }
            };
            let infer_end = Instant::now();
            let infer_time = infer_end - infer_start;
            let post_start = Instant::now();
            let data = match (output, gpu_post.as_mut()) {
                (Output::Host(raw), _) => post.process(&raw, Instant::now()),
                (Output::Device(raw), Some(g)) => {
                    g.depth_tau = depth_tau;
                    match g.process(raw, Instant::now()) {
                        Ok(data) => data,
                        Err(err) => {
                            log::warn!("GPU post-processing failed: {err}");
                            continue;
                        }
                    }
                }
                (Output::Device(_), None) => continue,
            };
            let done = Instant::now();
            if let Some(report) = &vda_report {
                telemetry.record(report, done - post_start, done - frame.tag.queued, self.stats.skipped.load(Ordering::Relaxed));
            }
            let maps = self.stats.maps.fetch_add(1, Ordering::Relaxed) + 1;
            let map = Arc::new(DepthMap {
                stream: frame.tag.stream,
                client: frame.tag.client,
                seq: maps,
                epoch: frame.tag.epoch,
                frame_index: frame.tag.index,
                after_loss: frame.tag.after_loss,
                width,
                height,
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
                    Pixels::Rgb(rgb) if same_size => Ok((rgb.clone(), frame.size)),
                    Pixels::Rgb(_) => Ok((resized.clone(), input)),
                    Pixels::Gpu(tensor) => tensor.download_rgb().map(|rgb| (rgb, (tensor.width, tensor.height))),
                };
                match rgb {
                    Ok((rgb, size)) => save_snapshot(dir, &map, &rgb, size),
                    Err(err) => log::warn!("Can't save depth snapshot: {err}"),
                }
            }
            if let Ok(mut latest) = self.latest.lock() {
                *latest = Some(map);
                self.map_ready.notify_all();
            }
        }
    }

    /// Goes back to `previous` (or the default single-frame model) after
    /// VDA failed to load or run.
    fn fall_back(&self, previous: Option<String>, why: &str) {
        let models = self.list_models();
        let target = previous
            .filter(|m| m != vda::ID && models.contains(m))
            .or_else(|| preferred_model(&models.iter().filter(|m| *m != vda::ID).cloned().collect::<Vec<_>>()));
        let Some(target) = target else {
            log::warn!("{} failed ({why}), and there is no other model", vda::LABEL);
            return;
        };
        log::warn!("{} failed ({why}); switching back to {}", vda::LABEL, model_label(&target));
        let active = self.active_model().map(|(name, _, _)| name);
        if active.as_deref() == Some(target.as_str()) {
            // Still loaded: only the choice changes back.
            self.update_state(|s| s.model = Some(target.clone()));
            self.set_status(format!("{} failed: {why}; using {}", vda::LABEL, model_label(&target)));
        } else {
            if let Ok(mut active) = self.active.lock() {
                *active = None;
            }
            self.select_model(&target);
        }
    }
}

/// The widescreen EdgePad family's 512x288 model (the Quest's standard tier),
/// built by tools/make_host_model.py, in either format. Its 672x384 sibling
/// is the higher-quality host choice.
pub const DEFAULT_MODEL: &str = "zipdepth_wide_512x288";

/// Picks a default: the 512x288 model, else the first.
fn preferred_model(models: &[String]) -> Option<String> {
    models.iter().find(|m| *m != vda::ID && stem(m) == DEFAULT_MODEL).or_else(|| models.first()).cloned()
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
/// The frame is `size`, which differs from the map's for VDA.
fn save_snapshot(dir: &Path, map: &DepthMap, rgb: &[u8], (fw, fh): (usize, usize)) {
    let stem = format!("s{}e{}-f{:06}", map.stream, map.epoch, map.frame_index);
    let write = |name: String, data: &[u8], (w, h): (usize, usize), color: png::ColorType| -> std::io::Result<()> {
        std::fs::create_dir_all(dir)?;
        let file = std::io::BufWriter::new(std::fs::File::create(dir.join(name))?);
        let mut encoder = png::Encoder::new(file, w as u32, h as u32);
        encoder.set_color(color);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.write_header()?.write_image_data(data)?;
        Ok(())
    };
    let result = write(format!("{stem}-frame.png"), rgb, (fw, fh), png::ColorType::Rgb)
        .and_then(|()| write(format!("{stem}-depth.png"), &map.data, (map.width, map.height), png::ColorType::Grayscale));
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
        let model_size = self.depth.input_size();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_an_older_state_file() {
        let text = "enabled = true\nmodel = \"vda_s_518x294\"\nrate = 120\nsmoothing = false\nedge_softening = 2\n";
        let state: SavedState = toml::from_str(text).unwrap();
        assert_eq!(state.model.as_deref(), Some("vda_s_518x294"));
        assert_eq!(state.rate, 120);
        assert!(state.model_smoothing.is_empty());
    }

    #[test]
    fn names_models_in_either_format() {
        assert_eq!(stem("zipdepth_wide_512x288.ncnn.param"), "zipdepth_wide_512x288");
        assert_eq!(stem("zipdepth_wide_512x288.onnx"), "zipdepth_wide_512x288");
        assert_eq!(stem(vda::ID), vda::ID);
        let models = ["vda_s_518x294".to_string(), "zipdepth_wide_512x288.ncnn.param".to_string()];
        assert_eq!(preferred_model(&models).as_deref(), Some("zipdepth_wide_512x288.ncnn.param"));
    }
}
