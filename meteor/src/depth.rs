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
use crate::nvdec::Pixels;
use crate::video_decoder::{self,Backend as DecodeBackend,Decoder as VideoDecoder};

/// Where a model run left its output.
enum Output {
    Host(Vec<f32>),
    Resident(crate::vulkan_processing::ResidentDepth),
    /// Device address of the model's output buffer.
    Device(u64),
}
use crate::onnx::{Backend, DepthModel};
use crate::postprocess::{DEPTH_TAU_SECONDS, PostProcessor};
use crate::stream_info::Codec;
use crate::vda::{self, VdaModel};
use crate::vda_vulkan;
fn is_vda(name:&str)->bool {name==vda::ID || vda_vulkan::is_model(name)}
use crate::video_tap::Frame;

/// A loaded depth model.
enum Engine {
    /// Single-frame, on ONNX Runtime.
    Plain(Box<DepthModel>),
    /// Single-frame, on ncnn (Vulkan).
    Ncnn(Box<NcnnModel>),
    Vda(Box<VdaModel>),
    VdaVulkan(Box<vda_vulkan::Model>),
}

impl Engine {
    fn cpu(&self) -> bool {
        match self {
            Engine::Plain(m) => m.backend == Backend::Cpu,
            Engine::Ncnn(m) => m.cpu,
            Engine::Vda(_) | Engine::VdaVulkan(_) => false,
        }
    }
    fn load(models_dir: &Path, name: &str, backend: Backend, cache: &Path, gpu: Option<&str>) -> Result<Engine, String> {
        if vda_vulkan::is_model(name) {
            if backend==Backend::Cpu {return Err("VDA requires GPU inference".into());}
            return vda_vulkan::Model::load(models_dir,name,gpu).map(|m|Engine::VdaVulkan(Box::new(m)));
        }
        if name == vda::ID {
            if backend == Backend::Cpu {
                return Err("VDA requires GPU inference; select an EdgePad model for CPU".into());
            }
            VdaModel::load(models_dir, backend, cache).map(|m| Engine::Vda(Box::new(m)))
        } else if is_ncnn(name) {
            NcnnModel::load_on_gpu(&models_dir.join(name), backend == Backend::Cpu, gpu).map(|m| Engine::Ncnn(Box::new(m)))
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
            Engine::VdaVulkan(m) => m.id.clone(),
        }
    }

    /// The depth map's size.
    fn output_size(&self) -> (usize, usize) {
        match self {
            Engine::Plain(m) => (m.width, m.height),
            Engine::Ncnn(m) => (m.width, m.height),
            Engine::Vda(_) => (vda::WIDTH, vda::HEIGHT),
            Engine::VdaVulkan(m) => (m.width,m.height),
        }
    }

    /// The size the decoder reduces frames to.
    fn input_size(&self) -> (usize, usize) {
        match self {
            Engine::Plain(m) => (m.width, m.height),
            Engine::Ncnn(m) => (m.width, m.height),
            Engine::Vda(_) | Engine::VdaVulkan(_) => vda::DECODE_SIZE,
        }
    }

    fn describe(&self) -> String {
        let (w, h) = self.output_size();
        match self {
            Engine::Plain(m) => format!("{} ({w}x{h}, {})", m.name, m.backend.label()),
            Engine::Ncnn(m) => format!("{} ({w}x{h}, {})", m.name,
                if m.cpu { format!("CPU fp32, {} threads", crate::onnx::cpu_threads()) } else { format!("Vulkan fp16, {}",m.gpu_name.as_deref().unwrap_or("unknown GPU")) }),
            Engine::Vda(m) => format!("{} ({w}x{h}, {})", vda::LABEL, m.description),
            Engine::VdaVulkan(m) => format!("{} (Vulkan, {})",model_label(&m.id),m.gpu_name),
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
    match stem(name) {
        vda::ID => "VDA 518×294 (TensorRT)".into(),
        vda_vulkan::FULL => "VDA 518×294 (Vulkan)".into(),
        vda_vulkan::FAST => "VDA Performance 392×224 (Vulkan)".into(),
        "zipdepth_edgepad_384" => "EdgePad-384".into(),
        "zipdepth_wide_512x288" => "EdgePad-512".into(),
        "zipdepth_wide_672x384" => "EdgePad-672".into(),
        "zipdepth_edgepad_256" => "EdgePad-256 (lower GPU load)".to_string(),
        other => other.to_string(),
    }
}

/// One menu entry selects a complete inference configuration atomically.
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct DepthChoice {pub model:String,pub gpu:Option<String>,pub cpu:bool}
#[derive(Clone,Debug)]
pub struct DepthGroup {pub label:String,pub choices:Vec<DepthChoice>}

fn build_choice_groups(models:&[String],gpu_names:Vec<String>,legacy_gpu:bool,supported:impl Fn(Option<&str>)->bool)->Vec<DepthGroup> {
        let portable:Vec<_>=models.iter().filter(|m|is_ncnn(m)||vda_vulkan::is_model(m)).cloned().collect();
        let choices=|gpu:Option<String>|portable.iter().filter(|m| !vda_vulkan::is_model(m) || supported(gpu.as_deref())).map(|m|DepthChoice{model:m.clone(),gpu:gpu.clone(),cpu:false}).collect::<Vec<_>>();
        let mut groups=Vec::new();
        let mut legacy_added=false;
        for gpu in gpu_names {
            let mut entries=choices(Some(gpu.clone()));
            if legacy_gpu && !legacy_added && gpu.to_lowercase().contains("nvidia") {
                entries.extend(models.iter().filter(|m|!is_ncnn(m) && !vda_vulkan::is_model(m)).map(|m|DepthChoice{model:m.clone(),gpu:None,cpu:false}));
                legacy_added=true;
            }
            groups.push(DepthGroup{label:gpu,choices:entries});
        }
        if legacy_gpu && !legacy_added {
            groups.push(DepthGroup{label:"NVIDIA GPU".into(),choices:models.iter().filter(|m|!is_ncnn(m) && !vda_vulkan::is_model(m)).map(|m|DepthChoice{model:m.clone(),gpu:None,cpu:false}).collect()});
        }
        groups.push(DepthGroup{label:"CPU".into(),choices:models.iter().filter(|m|!is_vda(m)).map(|m|DepthChoice{model:m.clone(),gpu:None,cpu:true}).collect()});
        groups.retain(|g|!g.choices.is_empty());groups
}

/// Where Meteor finds the runtimes; each is optional.
pub struct Runtimes<'a> {
    pub onnxruntime: Option<&'a Path>,
    pub ncnn: Option<&'a Path>,
}

/// A model the loading thread finished with.
struct Loaded {
    generation: u64,
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
pub const RATES: [u32; 7] = [0, 20, 30, 60, 72, 90, 120];

/// The tray's choices, remembered across restarts in state.toml.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
struct SavedState {
    cpu_inference: bool,
    edgepad_gpu: Option<String>,
    decode: video_decoder::Settings,
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
    edge_alignment: bool,
    contour_cleanup: bool,
}

impl Default for SavedState {
    fn default() -> Self {
        SavedState { cpu_inference: false, edgepad_gpu: None, decode: video_decoder::Settings::default(), enabled: true, model: None, rate: 0, model_smoothing: BTreeMap::new(), edge_softening: vda::DEFAULT_SOFTENING, edge_alignment: true, contour_cleanup: true }
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
    /// Portable VDA preparation shares the inference GPU: don't queue filtering
    /// behind a long temporal model. Short EdgePad jobs retain pipelined input.
    inference_busy:AtomicBool,
    tensorrt: bool,
    /// Which runtimes loaded: ONNX Runtime, ncnn.
    onnx_ok: bool,
    ncnn_ok: bool,
    /// A TensorRT engine is being built.
    pub tensorrt_pending: Arc<AtomicBool>,
    available: AtomicBool,
    state: Mutex<SavedState>,
    status: Mutex<String>,
    decoder_status: Mutex<String>,
    /// Name and output size of the model in use.
    active: Mutex<Option<(String, usize, usize)>>,
    /// The size the decoder reduces frames to for that model.
    input_size: Mutex<Option<(usize, usize)>>,
    pending_model: Mutex<Option<String>>,
    load_generation: AtomicU64,
    input: Mutex<Option<Decoded>>,
    wake: Condvar,
    pub latest: Mutex<Option<Arc<DepthMap>>>,
    /// Signalled with `latest` whenever a new map is ready.
    pub map_ready: Condvar,
    /// Clients connected to the depth port. The model only runs while there
    /// is one (or while saving snapshots); decoding continues so an active
    /// stream keeps its video history.
    pub subscribers: AtomicU32,
    save: Option<(PathBuf, u64)>,
}

impl SavedState {
    fn matches_choice(&self,choice:&DepthChoice)->bool {
        self.model.as_ref()==Some(&choice.model) && self.cpu_inference==choice.cpu
            && (choice.cpu || (!is_ncnn(&choice.model) && !vda_vulkan::is_model(&choice.model)) || self.edgepad_gpu==choice.gpu)
    }
    fn apply_choice(&mut self,choice:&DepthChoice) {
        self.cpu_inference=choice.cpu;self.edgepad_gpu=choice.gpu.clone();self.model=Some(choice.model.clone());
    }
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
            .and_then(|exe| {
                let parent = exe.parent()?;
                let dir = if cfg!(windows) {
                    parent.join("share/nightfall-meteor/models")
                } else {
                    parent.join("../share/nightfall-meteor/models")
                };
                dir.is_dir().then_some(dir)
            });
        let depth = Arc::new(Depth {
            models_dir,
            bundled_dir,
            download: crate::download::Download::default(),
            stats: DepthStats::default(),
            gpu_frames: AtomicBool::new(true),
            gpu_post: AtomicBool::new(true),
            inference_busy:AtomicBool::new(false),
            tensorrt,
            onnx_ok,
            ncnn_ok,
            tensorrt_pending: Arc::default(),
            available: AtomicBool::new(false),
            state: Mutex::new(state),
            status: Mutex::new("starting".into()),
            decoder_status: Mutex::new("Waiting for video".into()),
            active: Mutex::new(None),
            input_size: Mutex::new(None),
            pending_model: Mutex::new(None),
            load_generation: AtomicU64::new(0),
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

    pub fn cpu_inference(&self) -> bool {
        self.state.lock().is_ok_and(|s| s.cpu_inference)
    }

    pub fn choice_groups(&self)->Vec<DepthGroup> {
        let models=self.list_models();let names=self.depth_gpu_names();
        let legacy=names.iter().any(|n|n.to_lowercase().contains("nvidia")) || (names.is_empty() && models.iter().any(|m|!is_ncnn(m)&&!vda_vulkan::is_model(m)) && (crate::onnx::cuda_backend_present() || crate::tensorrt::installed()));
        build_choice_groups(&models,names,legacy,vda_vulkan::gpu_supported)
    }
    pub fn choice_selected(&self,choice:&DepthChoice)->bool {
        let Ok(mut state)=self.state.lock().map(|s|s.clone()) else {return false;};
        if !state.cpu_inference && state.edgepad_gpu.is_none() && (is_ncnn(&choice.model) || vda_vulkan::is_model(&choice.model)) {
            state.edgepad_gpu=ncnn::resolved_gpu_name(None).ok();
        }
        state.matches_choice(choice)
    }
    pub fn select_choice(&self,choice:&DepthChoice) {
        if !self.choice_groups().iter().any(|g|g.choices.contains(choice)) {self.set_status("Selected GPU/model combination is unavailable".into());return;}
        self.update_state(|s| {s.apply_choice(choice);});
        self.queue_model(&choice.model);
    }
    pub fn selection_label(&self)->String {
        self.model().map(|m|format!("{} — {}",model_label(&m),self.depth_gpu_label())).unwrap_or_else(||"none".into())
    }

    pub fn depth_gpu_names(&self) -> Vec<String> { ncnn::gpu_names() }
    pub fn depth_gpu(&self) -> Option<String> { self.state.lock().ok().and_then(|s|s.edgepad_gpu.clone()) }
    pub fn depth_gpu_label(&self) -> String {
        if self.cpu_inference() { return "CPU".into(); }
        if self.model().as_deref().is_some_and(|m|!is_ncnn(m)&&!vda_vulkan::is_model(m)) {return "NVIDIA (default CUDA GPU)".into();}
        self.depth_gpu().unwrap_or_else(||ncnn::resolved_gpu_name(None).map(|name|format!("Auto ({name})")).unwrap_or_else(|_|"Auto".into()))
    }
    pub fn decode_settings(&self) -> video_decoder::Settings {
        self.state.lock().map(|s|s.decode.clone()).unwrap_or_default()
    }
    pub fn set_decode_backend(&self,backend:DecodeBackend) {
        self.update_state(|s|s.decode.backend=backend);
        log::info!("Depth decoder requested: {} (next keyframe/stream)",backend.label());
        self.set_decoder_status("Decoder change pending: next keyframe/stream".into());
    }
    pub fn set_vaapi_device(&self,device:Option<String>) {
        if device.as_ref().is_some_and(|d| !video_decoder::vaapi_devices().iter().any(|(path,_)|path==d)) {return;}
        self.update_state(|s|s.decode.vaapi_device=device);
        self.set_decoder_status("Decode device change pending: next keyframe/stream".into());
    }
    pub fn set_cpu_processing(&self,on:bool) {
        self.update_state(|s|s.decode.cpu_processing=on);
        self.set_decoder_status("Processing change pending: next keyframe/stream".into());
    }
    pub fn decoder_status(&self)->String {self.decoder_status.lock().map(|s|s.clone()).unwrap_or_default()}
    fn set_decoder_status(&self,value:String) {
        if let Ok(mut status)=self.decoder_status.lock() { *status=value; }
    }

    /// Depth smoothing for the chosen model.
    pub fn smoothing(&self) -> bool {
        self.state.lock().is_ok_and(|s| {
            let model = s.model.as_deref().unwrap_or_default();
            s.model_smoothing.get(stem(model)).copied().unwrap_or(!is_vda(model))
        })
    }

    pub fn set_smoothing(&self, on: bool) {
        self.update_state(|s| {
            let model = stem(s.model.as_deref().unwrap_or_default()).to_string();
            s.model_smoothing.insert(model, on);
        });
        log::info!("Depth smoothing {}", if on { "on" } else { "off" });
    }

    pub fn edge_alignment(&self) -> bool {
        self.state.lock().is_ok_and(|s| s.edge_alignment)
    }

    pub fn set_edge_alignment(&self, on: bool) {
        self.update_state(|s| s.edge_alignment = on);
        log::info!("Edge alignment (Bounded-2): {on}");
    }

    pub fn contour_cleanup(&self) -> bool {
        self.state.lock().is_ok_and(|s| s.contour_cleanup)
    }

    pub fn set_contour_cleanup(&self, on: bool) {
        self.update_state(|s| s.contour_cleanup = on);
        log::info!("Contour cleanup (Bounded-4; requires alignment): {on}");
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
        if vda_vulkan::is_model(name) {
            if vda_vulkan::present(&self.models_dir,name) {return self.models_dir.clone();}
            if let Some(dir)=&self.bundled_dir {if vda_vulkan::present(dir,name) {return dir.clone();}}
        }
        if name == vda::ID {
            return self.vda_dir().unwrap_or_else(|| self.models_dir.clone());
        }
        self.model_files().remove(name).unwrap_or_else(|| self.models_dir.clone())
    }

    /// Both VDA graphs must come from one folder. Prefer a complete user
    /// installation over the bundled copy.
    fn vda_dir(&self) -> Option<PathBuf> {
        if vda::present(&self.models_dir) {
            Some(self.models_dir.clone())
        } else {
            self.bundled_dir.as_ref().filter(|dir| vda::present(dir)).cloned()
        }
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
        if self.vda_dir().is_some() && (self.onnx_ok || crate::tensorrt::installed()) {
            models.push(vda::ID.to_string());
        }
        if self.ncnn_ok && vda_vulkan::available() {
            for id in [vda_vulkan::FULL,vda_vulkan::FAST] {
                if vda_vulkan::present(&self.models_dir,id) || self.bundled_dir.as_ref().is_some_and(|d|vda_vulkan::present(d,id)) {models.push(id.into());}
            }
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
        if !self.download.reserve() {
            return;
        }
        let depth = self.clone();
        let launched = std::thread::Builder::new().name("vda-download".into()).spawn(move || {
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
        if let Err(error)=launched {
            if let Ok(mut state)=self.download.state.lock() { *state=crate::download::State::Failed(error.to_string()); }
        }
    }

    pub fn vulkan_vda_offers(&self) -> Vec<(&'static str,u64)> {
        if self.download.state()==crate::download::State::Running || !vda_vulkan::available() ||
            !self.depth_gpu_names().iter().any(|gpu|vda_vulkan::gpu_supported(Some(gpu))) { return vec![]; }
        [vda_vulkan::FULL,vda_vulkan::FAST].into_iter()
            .filter(|id|!crate::vda_assets::installed(&self.models_dir,id) &&
                !self.bundled_dir.as_ref().is_some_and(|directory|crate::vda_assets::installed(directory,id)))
            .filter_map(|id|crate::vda_assets::bytes(id).ok().map(|bytes|(id,bytes))).collect()
    }

    pub fn download_vulkan_vda(self: &Arc<Self>, id: &'static str) {
        if !vda_vulkan::is_model(id) || !self.download.reserve() { return; }
        let depth=self.clone();
        if let Err(error)=std::thread::Builder::new().name("vda-vulkan-download".into()).spawn(move || {
            match depth.download.run_vulkan(&depth.models_dir,id) {
                Ok(())=> {
                    log::info!("Vulkan VDA installed: {id}; select it under GPU / model");
                    #[cfg(target_os="linux")]
                    if let Ok(runtime)=tokio::runtime::Builder::new_current_thread().enable_all().build() {
                        runtime.block_on(crate::desktop::notify("Vulkan VDA ready", "Select the downloaded model under your GPU in Meteor's GPU / model menu. Your current model is unchanged."));
                    }
                }
                Err(error)=>log::warn!("Vulkan VDA download stopped: {error}"),
            }
        }) {
            if let Ok(mut state)=self.download.state.lock() { *state=crate::download::State::Failed(error.to_string()); }
        }
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
        if is_vda(name) && self.cpu_inference() {
            self.set_status("VDA requires GPU inference; switch inference to GPU first".into());
            return;
        }
        self.update_state(|s| s.model = Some(name.to_string()));
        self.queue_model(name);
    }
    fn queue_model(&self,name:&str) {
        if let Ok(mut pending) = self.pending_model.lock() {
            self.load_generation.fetch_add(1, Ordering::Relaxed);
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
        let mut gpu_refinement: Option<crate::gpu_refinement::GpuRefinement> = None;
        let mut vulkan_post:Option<crate::vulkan_processing::Processor>=None;
        let mut vulkan_post_key:Option<(String,String,usize,usize)>=None;
        let mut resident_disabled=false;
        let mut refinement_size = None;
        let mut last_stream = None;
        let mut pace = RatePace::default();
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
                let generation = self.load_generation.load(Ordering::Relaxed);
                let cpu = self.cpu_inference();
                let gpu = self.depth_gpu();
                let target_gpu=ncnn::resolved_gpu_name(gpu.as_deref()).ok();
                // Never silently keep GPU inference running after CPU was
                // requested (including when the replacement fails to load).
                if model.as_ref().is_some_and(|m| m.cpu() != cpu || ((is_ncnn(&name)||vda_vulkan::is_model(&name)) && !cpu && match m {Engine::Ncnn(old)=>old.gpu_name!=target_gpu,Engine::VdaVulkan(old)=>Some(old.gpu_name.clone())!=target_gpu,_=>true})) {
                    model = None;
                    gpu_post = None;
                    post.reset();
                    if let Ok(mut active) = self.active.lock() { *active = None; }
                    if let Ok(mut latest) = self.latest.lock() { *latest = None; }
                }
                self.set_status(format!("loading {}", model_label(&name)));
                let tx = loaded_tx.clone();
                let tensorrt = self.tensorrt;
                let pending = self.tensorrt_pending.clone();
                let models_dir = self.model_dir(&name);
                let cuda_present = !is_ncnn(&name) && !vda_vulkan::is_model(&name) && crate::onnx::cuda_backend_present();
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
                        let _ = tx.send(Loaded { generation, name: name.clone(), optional, interim, result });
                    };
                    if cpu {
                        send(false, false, Engine::load(&models_dir, &name, Backend::Cpu, &cache, gpu.as_deref()));
                        return;
                    }
                    if is_ncnn(&name) || vda_vulkan::is_model(&name) {
                        send(false, false, Engine::load(&models_dir, &name, Backend::Cuda, &cache, gpu.as_deref()));
                        return;
                    }
                    if let Some((dir, interim)) = interim {
                        pending.store(tensorrt, Ordering::Relaxed);
                        let backend = if is_ncnn(&interim) { Backend::Cuda } else { Backend::TensorRt };
                        send(false, true, Engine::load(&dir, &interim, backend, &cache, gpu.as_deref()));
                    }
                    let cuda_ok = !cuda_present || {
                        let cuda = Engine::load(&models_dir, &name, Backend::Cuda, &cache, gpu.as_deref());
                        let ok = cuda.is_ok();
                        send(false, false, cuda);
                        ok
                    };
                    if !tensorrt && !cuda_present {
                        send(false, false, Err("no backend: TensorRT is turned off and there is no CUDA provider".into()));
                    } else if tensorrt && cuda_ok {
                        pending.store(true, Ordering::Relaxed);
                        let trt = Engine::load(&models_dir, &name, Backend::TensorRt, &cache, gpu.as_deref());
                        pending.store(false, Ordering::Relaxed);
                        // TensorRT is optional when CUDA is there.
                        send(cuda_present, false, trt);
                    }
                });
            }
            while let Ok(Loaded { generation, name, optional, interim, result }) = loaded_rx.try_recv() {
                // A model chosen since this one started loading wins.
                if generation != self.load_generation.load(Ordering::Relaxed) || self.model().as_ref() != Some(&name) {
                    continue;
                }
                match result {
                    Ok(loaded) => {
                        vulkan_post=None;vulkan_post_key=None;resident_disabled=false;
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
                            (true, Engine::Ncnn(_) | Engine::VdaVulkan(_)) => "",
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
                        if is_vda(&name) {
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
            let now = Instant::now();
            if inference_rate_limited(frame.rate_limited,rate,&pace,now) {
                self.stats.skipped.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            pace.ran(rate, now);

            let stream = (frame.tag.stream, frame.tag.epoch);
            if last_stream != Some(stream) {
                vulkan_post=None;vulkan_post_key=None;resident_disabled=false;
                refinement_size = None;
                gpu_refinement = None;
                post.reset();
                if let Some(g) = &mut gpu_post {
                    g.reset();
                }
                if let Engine::Vda(m) = engine {m.reset("new stream");}
                if let Engine::VdaVulkan(m) = engine {m.reset();}
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
            // was. Portable RGB Vulkan frames use resident depth below; the
            // ncnn C-API fallback and CUDA-input path still use host outputs.
            let device_output = match engine {
                Engine::Vda(_) => true,
                Engine::Plain(m) => m.backend != Backend::Cpu && matches!(frame.pixels, Pixels::Gpu(_)),
                Engine::Ncnn(_) | Engine::VdaVulkan(_) => false,
            };
            let on_device = !self.decode_settings().cpu_processing && self.gpu_post.load(Ordering::Relaxed)
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
            let resident_gpu=if matches!(&frame.pixels,Pixels::Rgb(_)) && !self.decode_settings().cpu_processing && self.gpu_frames.load(Ordering::Relaxed) && self.gpu_post.load(Ordering::Relaxed) {
                match engine {Engine::Ncnn(m) if !m.cpu=>m.gpu_name.clone(),Engine::VdaVulkan(m)=>Some(m.gpu_name.clone()),_=>None}
            }else{None};
            if let Some(gpu)=resident_gpu.as_ref() {
                let key=(engine.id(),gpu.clone(),width,height);
                if vulkan_post_key.as_ref()!=Some(&key) {
                    vulkan_post_key=Some(key);post.reset();resident_disabled=false;
                    vulkan_post=match crate::vulkan_processing::Processor::new(Some(gpu),(width,height)) {
                        Ok(processor)=>{log::info!("Depth postprocessing: Vulkan resident on {gpu}, {width}x{height}");Some(processor)},
                        Err(error)=>{log::warn!("Vulkan postprocessing unavailable: {error}; using CPU reference");None},
                    };
                }
            }
            let resident_enabled=resident_gpu.is_some() && vulkan_post.is_some() && !resident_disabled;
            let mut vda_report = None;
            let busy=InferenceBusy::new(&self.inference_busy);
            let result = match engine {
                Engine::Plain(model) => match &frame.pixels {
                    Pixels::Gpu(tensor) if same_size && model.backend == Backend::Cpu => {
                        tensor.download_rgb().and_then(|rgb| model.infer(&rgb)).map(Output::Host)
                    }
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
                    Pixels::Rgb(rgb) if same_size && resident_enabled => {
                        match model.infer_resident(rgb,vulkan_post.as_mut().unwrap()) {
                            Ok(depth)=>Ok(Output::Resident(depth)),
                            Err(error)=>{log::warn!("Resident EdgePad unavailable: {error}; using host depth transfer until model/stream change");resident_disabled=true;model.infer(rgb).map(Output::Host)},
                        }
                    },
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
                Engine::VdaVulkan(model) => {
                    model.cpu_processing=self.decode_settings().cpu_processing || !self.gpu_frames.load(Ordering::Relaxed);
                    let sigma=vda::SOFTENING[self.edge_softening()].1;
                    match &frame.pixels {
                        Pixels::Rgb(rgb) if resident_enabled => match model.infer_rgb_resident(rgb,frame.size,frame.decoded,sigma) {
                            Ok(Some(depth))=>Ok(Output::Resident(depth)),
                            Ok(None)=>model.infer_rgb(rgb,frame.size,frame.decoded,sigma).map(Output::Host),
                            Err(error)=>Err(error),
                        },
                        Pixels::Rgb(rgb) => model.infer_rgb(rgb,frame.size,frame.decoded,sigma).map(Output::Host),
                        Pixels::Gpu(tensor) => tensor.download().and_then(|rgb|model.infer_planar(&rgb,frame.size,frame.decoded,sigma)).map(Output::Host),
                    }
                }
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
            drop(busy);
            let output = match result {
                Ok(output) => {
                    failures = 0;
                    output
                }
                Err(err) => {
                    log::warn!("Depth inference failed: {err}");
                    if matches!(engine, Engine::Vda(_) | Engine::VdaVulkan(_)) {
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
            let mut vulkan_processed=false;
            let mut data = match (output, gpu_post.as_mut()) {
                (Output::Resident(raw),_) => {
                    let result=match (&mut vulkan_post,&frame.pixels) {
                        (Some(processor),Pixels::Rgb(rgb))=>processor.process_resident(&raw,rgb,frame.size,Instant::now(),depth_tau,self.edge_alignment(),self.contour_cleanup()),
                        _=>Err("Resident depth processor/guide unavailable".into()),
                    };
                    match result {
                        Ok(data)=>{vulkan_processed=true;data},
                        Err(error)=>{
                            log::warn!("Resident postprocessing failed: {error}; using host reference until model/stream change");vulkan_post=None;resident_disabled=true;post.reset();
                            match raw.download(){Ok(raw)=>post.process(&raw,Instant::now()),Err(error)=>{log::warn!("Resident depth readback failed: {error}");continue;} }
                        }
                    }
                },
                (Output::Host(raw), _) => {
                    let gpu=if !self.decode_settings().cpu_processing && self.gpu_frames.load(Ordering::Relaxed) && self.gpu_post.load(Ordering::Relaxed) {
                        match engine {
                            Engine::Ncnn(model) if !model.cpu=>model.gpu_name.clone(),
                            Engine::VdaVulkan(model)=>Some(model.gpu_name.clone()),
                            _=>None,
                        }
                    }else{None};
                    if let (Some(gpu),Pixels::Rgb(rgb))=(gpu,&frame.pixels) {
                        let key=(engine.id(),gpu.clone(),width,height);
                        if vulkan_post_key.as_ref()!=Some(&key) {
                            vulkan_post_key=Some(key);post.reset();
                            vulkan_post=match crate::vulkan_processing::Processor::new(Some(&gpu),(width,height)) {
                                Ok(processor)=>{log::info!("Depth postprocessing: Vulkan on {gpu}, {width}x{height}");Some(processor)},
                                Err(error)=>{log::warn!("Vulkan postprocessing unavailable: {error}; using CPU reference");None},
                            };
                        }
                        if let Some(processor)=vulkan_post.as_mut() {
                            match processor.process(&raw,rgb,frame.size,Instant::now(),depth_tau,self.edge_alignment(),self.contour_cleanup()) {
                                Ok(data)=>{vulkan_processed=true;data},
                                Err(error)=>{log::warn!("Vulkan postprocessing failed: {error}; using CPU reference");vulkan_post=None;post.reset();post.process(&raw,Instant::now())},
                            }
                        }else{post.process(&raw,Instant::now())}
                    }else{post.process(&raw,Instant::now())}
                },
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
            // Optional spatial refinement, after smoothing and before
            // sending/snapshots. Never writes back into temporal history.
            // No colour download or additional work when disabled.
            if self.edge_alignment() && !vulkan_processed {
                let start = Instant::now();
                let cleanup = self.contour_cleanup();
                let mut processed = false;
                if let Pixels::Gpu(tensor) = &frame.pixels && !self.decode_settings().cpu_processing {
                    if refinement_size != Some(pixels) {
                        refinement_size = Some(pixels);
                        gpu_refinement = match crate::gpu_refinement::GpuRefinement::new(pixels) {
                            Ok(gpu) => Some(gpu),
                            Err(err) => {
                                log::warn!("CUDA refinement unavailable ({err}); using slower CPU reference");
                                None
                            }
                        };
                    }
                    if let Some(gpu) = &gpu_refinement {
                        match gpu.process(&data, (width, height), tensor.ptr, (tensor.width, tensor.height), cleanup) {
                            Ok(refined) => { data = refined; processed = true; }
                            Err(err) => {
                                log::warn!("CUDA refinement failed ({err}); using slower CPU reference until next stream/model size");
                                gpu_refinement = None;
                            }
                        }
                    }
                }
                if !processed {
                    let guide = match &frame.pixels {
                        Pixels::Rgb(rgb) => Ok(std::borrow::Cow::Borrowed(rgb.as_slice())),
                        Pixels::Gpu(tensor) => tensor.download_rgb().map(std::borrow::Cow::Owned),
                    };
                    match guide {
                        Ok(rgb) => data = crate::refinement::process(&data, (width, height), &rgb, frame.size, cleanup),
                        Err(err) => log::warn!("Depth refinement skipped: guide download failed: {err}"),
                    }
                }
                log::debug!("Depth refinement: alignment=true cleanup={cleanup} backend={} map={width}x{height} guide={fw}x{fh} {:.2}ms (including transfers)", if processed { "CUDA" } else { "CPU" }, start.elapsed().as_secs_f64() * 1000.0);
            }
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
                && (maps - 1).is_multiple_of(*every)
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
            .filter(|m| !is_vda(m) && models.contains(m))
            .or_else(|| preferred_model(&models.iter().filter(|m| !is_vda(m)).cloned().collect::<Vec<_>>()));
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

/// Paces depth to the tray's rate on a fixed schedule, not "a period since
/// the last run": a frame may be up to half a period early, and each run moves
/// the schedule on by one period. Measuring from the last run dropped every
/// frame that arrived a little early, so a 72 Hz cap on a 72 fps stream ran
/// at ~55 Hz.
#[derive(Default)]
struct RatePace {due:Option<Instant>}
impl RatePace {
    fn ready(&self,rate:u32,now:Instant)->bool {
        rate==0 || self.due.is_none_or(|due|now+period(rate)/2>=due)
    }
    fn ran(&mut self,rate:u32,now:Instant) {
        if rate==0 {self.due=None;return;}
        let period=period(rate);
        // After a pause, start over rather than catch up.
        self.due=Some(match self.due {Some(due) if now<due+period=>due+period,_=>now+period});
    }
}
fn period(rate:u32)->Duration {Duration::from_secs_f64(1.0/rate as f64)}

fn inference_rate_limited(prepared_at_rate:bool,rate:u32,pace:&RatePace,now:Instant)->bool {
    // Portable decoding limits expensive preparation before inference. Applying
    // a second independent cap after its variable CPU/download time would drop
    // otherwise valid maps whenever they arrive slightly closer together.
    !prepared_at_rate && !pace.ready(rate,now)
}

struct InferenceBusy<'a>(&'a AtomicBool);
impl<'a> InferenceBusy<'a> {
    fn new(flag:&'a AtomicBool)->Self {flag.store(true,Ordering::Release);Self(flag)}
}
impl Drop for InferenceBusy<'_> {fn drop(&mut self){self.0.store(false,Ordering::Release);}}
fn prepare_video_frame(rate_ready:bool,portable_gpu:bool,inference_busy:bool)->bool {
    rate_ready && !(portable_gpu&&inference_busy)
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
    pub rate_limited: bool,
}

static NEXT_STREAM: AtomicU64 = AtomicU64::new(1);

/// Decodes a video tap without delaying proxy forwarding. Output retains the
/// timestamp of its source packet, including decoder-reordered frames.
pub struct DepthFeed {
    depth: Arc<Depth>,
    client: Option<IpAddr>,
    decoder: Option<(VideoDecoder,u64,(usize,usize),DecodeBackend)>,
    epoch: Option<u32>,
    settings: Option<video_decoder::Settings>,
    inference_affinity: Option<String>,
    rejected: Vec<DecodeBackend>,
    tags: BTreeMap<u32,FrameTag>,
    last_output: Option<Instant>,
    pace: RatePace,
}
impl DepthFeed {
    pub fn new(depth:Arc<Depth>,client:Option<IpAddr>)->Self {
        Self {depth,client:client.map(|ip|ip.to_canonical()),decoder:None,epoch:None,
            settings:None,inference_affinity:None,rejected:Vec::new(),tags:BTreeMap::new(),last_output:None,pace:RatePace::default()}
    }
    fn initialize(&mut self,codec:Codec,size:(usize,usize),settings:&video_decoder::Settings)->bool {
        let gpu_name=ncnn::resolved_gpu_name(self.depth.depth_gpu().as_deref()).unwrap_or_default();
        let prefer_amd=self.depth.model().as_deref()!=Some(vda::ID) && gpu_name.to_lowercase().contains("amd");
        for backend in settings.candidates(prefer_amd) {
            if self.rejected.contains(&backend) {continue;}
            let auto_device=video_decoder::vaapi_devices().into_iter().find(|(_,label)|label.starts_with("AMD"));
            let device=settings.vaapi_device.as_deref().or_else(||auto_device.as_ref().map(|(path,_)|path.as_str()));
            let gpu_frames=self.depth.gpu_frames.load(Ordering::Relaxed) && !settings.cpu_processing;
            match VideoDecoder::new(codec,backend,device,size,gpu_frames) {
                Ok(mut decoder)=> {
                    let portable_gpu=gpu_frames && !self.depth.cpu_inference() && !gpu_name.is_empty() && matches!(decoder,VideoDecoder::Ffmpeg(_));
                    if portable_gpu && let VideoDecoder::Ffmpeg(decoder)=&mut decoder {decoder.set_processing_gpu(gpu_name.clone());}
                    let device_label=if backend==DecodeBackend::Vaapi {device.unwrap_or("driver default")} else {""};
                    let description=format!("{} {device_label}; processing {}",backend.label(),if backend==DecodeBackend::Nvdec && gpu_frames {"CUDA/Auto"} else if portable_gpu {"Vulkan"} else {"CPU"});
                    self.depth.set_decoder_status(description.clone());
                    log::info!("Host depth decoding {codec:?}: {description}, {}x{}",size.0,size.1);
                    self.tags.clear();self.last_output=None;self.pace=RatePace::default();
                    self.decoder=Some((decoder,NEXT_STREAM.fetch_add(1,Ordering::Relaxed),size,backend));
                    return true;
                }
                Err(error)=> {self.rejected.push(backend);log::warn!("Depth decoder {} unavailable: {error}",backend.label());
                    self.depth.set_decoder_status(format!("{} failed: {error}",backend.label()));}
            }
        } false
    }
    pub fn push(&mut self,frame:&Frame,codec:Option<Codec>) {
        if !self.depth.enabled() {self.decoder=None;self.tags.clear();return;}
        let requested=self.depth.decode_settings();
        let affinity=if frame.idr && requested.backend==DecodeBackend::Auto {
            if self.depth.model().as_deref()==Some(vda::ID) {Some("NVIDIA VDA".into())}
            else {ncnn::resolved_gpu_name(self.depth.depth_gpu().as_deref()).ok()}
        } else {self.inference_affinity.clone()};
        if self.epoch!=Some(frame.epoch) || (frame.idr && (self.settings.as_ref()!=Some(&requested) || affinity!=self.inference_affinity)) {
            self.decoder=None;self.tags.clear();self.rejected.clear();
            self.epoch=Some(frame.epoch);self.settings=Some(requested.clone());
            self.inference_affinity=affinity;
        }
        let settings=self.settings.clone().unwrap_or(requested);
        let Some(size)=self.depth.input_size() else {return;};
        if let Some((decoder,_,target,_))=&mut self.decoder && *target!=size {decoder.set_target(size);*target=size;}
        // Auto may retry the same IDR once per backend if surface/profile
        // initialization fails only when the first packet is submitted.
        for _ in 0..3 {
            if self.decoder.is_none() {
                let (Some(codec),true)=(codec,frame.idr) else {return;};
                if !self.initialize(codec,size,&settings) {return;}
            }
            let Some((decoder,stream,target,backend))=&mut self.decoder else {return;};
            let queued=Instant::now();
            self.tags.insert(frame.index,FrameTag {stream:*stream,client:self.client,epoch:frame.epoch,index:frame.index,after_loss:frame.after_loss,queued});
            while self.tags.len()>128 {self.tags.pop_first();}
            let rate=self.depth.rate();
            let rate_limited=rate>0 && matches!(decoder,VideoDecoder::Ffmpeg(_));
            // The same schedule as the engine's (RatePace), so a frame
            // arriving fractionally early isn't deferred by a whole frame.
            let interested=self.depth.subscribers.load(Ordering::Relaxed)>0 || self.depth.save.is_some();
            let rate_ready=interested && self.pace.ready(rate,queued);
            let portable_gpu=matches!(decoder,VideoDecoder::Ffmpeg(decoder) if decoder.gpu_preparation())
                && self.depth.active_model().is_some_and(|(id,_,_)|vda_vulkan::is_model(&id));
            let want_pixels=prepare_video_frame(rate_ready,portable_gpu,self.depth.inference_busy.load(Ordering::Acquire));
            if rate_ready && !want_pixels {self.depth.stats.skipped.fetch_add(1,Ordering::Relaxed);}
            match decoder.decode(&frame.data,frame.index,want_pixels) {
                Ok(outputs)=> {
                    for (index,pixels) in outputs {
                        if let Some(tag)=self.tags.remove(&index) {
                            self.depth.submit(Decoded {tag,decoded:Instant::now(),size:*target,pixels,rate_limited});
                            self.last_output=Some(queued);
                            self.pace.ran(rate,queued);
                        } else {log::warn!("Ignoring decoded frame {index}: source metadata unavailable");}
                    }
                    return;
                }
                Err(error)=> {
                    log::warn!("Depth decoder {} failed: {error}",backend.label());
                    self.depth.set_decoder_status(format!("{} failed: {error}",backend.label()));
                    // First-packet hardware/profile failures may choose the
                    // next Auto backend. Later bitstream errors retry this
                    // decoder at the next IDR rather than banning it forever.
                    if settings.backend==DecodeBackend::Auto && frame.idr && self.last_output.is_none() {self.rejected.push(*backend);}
                    self.decoder=None;
                    if settings.backend!=DecodeBackend::Auto || !frame.idr {return;}
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "../tools/depth_hardware_benchmark.rs"]
mod hardware_benchmark;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn busy_gpu_skips_portable_preparation_without_stalling_other_backends() {
        assert!(!prepare_video_frame(true,true,true));
        assert!(prepare_video_frame(true,true,false));
        assert!(prepare_video_frame(true,false,true));
        assert!(!prepare_video_frame(false,true,false));
        let flag=AtomicBool::new(false);
        {let _busy=InferenceBusy::new(&flag);assert!(flag.load(Ordering::Acquire));}
        assert!(!flag.load(Ordering::Acquire));
    }

    #[test]
    fn model_groups_filter_cpu_and_gpu_capabilities() {
        let models=vec!["zipdepth_edgepad_256.ncnn.param".into(),vda_vulkan::FULL.into(),vda_vulkan::FAST.into()];
        let groups=build_choice_groups(&models,vec!["Supported GPU".into(),"Unsupported VDA GPU".into()],false,|gpu|gpu!=Some("Unsupported VDA GPU"));
        let supported=groups.iter().find(|g|g.label=="Supported GPU").unwrap();assert_eq!(supported.choices.len(),3);
        let unsupported=groups.iter().find(|g|g.label=="Unsupported VDA GPU").unwrap();assert_eq!(unsupported.choices.len(),1);
        let cpu=groups.iter().find(|g|g.label=="CPU").unwrap();assert_eq!(cpu.choices.len(),1);assert!(cpu.choices[0].cpu);
        assert_eq!(groups.len(),3);
        let no_gpu=build_choice_groups(&models,vec![],false,|_|false);assert_eq!(no_gpu.len(),1);assert_eq!(no_gpu[0].label,"CPU");
    }
    #[test]
    fn one_choice_updates_and_persists_the_complete_configuration() {
        let mut state=SavedState {cpu_inference:true,model:Some("old.onnx".into()),..SavedState::default()};
        let choice=DepthChoice {model:vda_vulkan::FAST.into(),gpu:Some("AMD GPU".into()),cpu:false};
        state.apply_choice(&choice);
        let saved=toml::to_string(&state).unwrap();let restored:SavedState=toml::from_str(&saved).unwrap();
        assert_eq!(restored.model.as_deref(),Some(vda_vulkan::FAST));assert_eq!(restored.edgepad_gpu,choice.gpu);assert!(!restored.cpu_inference);
    }

    #[test]
    fn legacy_tensorrt_selection_ignores_retained_edgepad_gpu_preference() {
        let state=SavedState {model:Some(vda::ID.into()),edgepad_gpu:Some("AMD GPU".into()),..SavedState::default()};
        assert!(state.matches_choice(&DepthChoice {model:vda::ID.into(),gpu:None,cpu:false}));
        assert!(!state.matches_choice(&DepthChoice {model:vda::ID.into(),gpu:None,cpu:true}));
    }

    #[test]
    fn legacy_onnx_gpu_models_remain_available_without_offering_them_on_amd() {
        let models=vec!["custom_edgepad.onnx".into(),vda::ID.into()];
        let groups=build_choice_groups(&models,vec!["AMD".into()],false,|_|false);
        assert_eq!(groups.len(),1);assert_eq!(groups[0].label,"CPU");
        let groups=build_choice_groups(&models,vec!["NVIDIA".into()],true,|_|false);
        let legacy=groups.iter().find(|g|g.label=="NVIDIA").unwrap();assert_eq!(legacy.choices.len(),2);
        assert!(legacy.choices.iter().all(|c|!c.cpu && c.gpu.is_none()));
        let models=vec!["zipdepth_edgepad_256.ncnn.param".into(),vda::ID.into(),vda_vulkan::FULL.into()];
        let groups=build_choice_groups(&models,vec!["AMD RX480".into(),"NVIDIA RTX3090".into()],true,|_|true);
        assert_eq!(groups.len(),3);
        let nvidia=groups.iter().find(|g|g.label=="NVIDIA RTX3090").unwrap();
        assert!(nvidia.choices.iter().any(|c|c.model==vda::ID));
        assert!(nvidia.choices.iter().any(|c|c.model==vda_vulkan::FULL));
        assert!(!groups[0].choices.iter().any(|c|c.model==vda::ID));
    }

    #[test]
    fn portable_preparation_is_not_rate_limited_twice() {
        let start=Instant::now();
        let mut pace=RatePace::default();
        pace.ran(20,start);
        assert!(!inference_rate_limited(true,20,&pace,start+Duration::from_millis(5)));
        assert!(inference_rate_limited(false,20,&pace,start+Duration::from_millis(20)));
        assert!(!inference_rate_limited(false,20,&pace,start+Duration::from_millis(50)));
        assert!(!inference_rate_limited(false,0,&pace,start));
    }

    #[test]
    fn pace_keeps_a_jittery_stream_at_the_cap() {
        // 72 fps arriving up to 4 ms early or late, capped at 72 Hz: every
        // frame runs.
        let start=Instant::now();
        let mut pace=RatePace::default();
        let jitter=[0i64,-4,3,-2,4,-4,0,2];
        let mut runs=0;
        for i in 0..720i64 {
            let at=start+Duration::from_micros((i*13_889+jitter[i as usize%8]*1000+10_000) as u64);
            if pace.ready(72,at) {pace.ran(72,at);runs+=1;}
        }
        assert_eq!(runs,720);
    }

    #[test]
    fn pace_holds_a_lower_cap_on_average() {
        // 72 fps capped at 20 Hz: 10 s gives 200 runs, give or take one.
        let start=Instant::now();
        let mut pace=RatePace::default();
        let runs=(0..720u64).map(|i|start+Duration::from_micros(i*13_889))
            .filter(|&at|{let ready=pace.ready(20,at);if ready {pace.ran(20,at);} ready}).count();
        assert!((199..=201).contains(&runs),"{runs}");
    }

    #[test]
    fn reads_an_older_state_file() {
        let text = "enabled = true\nmodel = \"vda_s_518x294\"\nrate = 120\nsmoothing = false\nedge_softening = 2\n";
        let state: SavedState = toml::from_str(text).unwrap();
        assert_eq!(state.model.as_deref(), Some("vda_s_518x294"));
        assert_eq!(state.rate, 120);
        assert!(state.model_smoothing.is_empty());
        assert!(!state.cpu_inference);
        assert_eq!(state.decode,video_decoder::Settings::default());
        assert!(state.edge_alignment);
        assert!(state.contour_cleanup);
    }

    #[test]
    fn refinement_choices_survive_restart() {
        for on in [false, true] {
            let state = SavedState { edge_alignment: on, contour_cleanup: on, ..SavedState::default() };
            let restored: SavedState = toml::from_str(&toml::to_string(&state).unwrap()).unwrap();
            assert_eq!(restored.edge_alignment, on);
            assert_eq!(restored.contour_cleanup, on);
        }
    }

    #[test]
    fn cpu_choice_survives_restart() {
        let state = SavedState { cpu_inference: true, ..SavedState::default() };
        let restored: SavedState = toml::from_str(&toml::to_string(&state).unwrap()).unwrap();
        assert!(restored.cpu_inference);
    }

    #[test]
    fn edgepad_gpu_choice_survives_restart_without_affecting_cpu_or_model() {
        let state=SavedState {edgepad_gpu:Some("AMD Radeon RX480".into()),model:Some(vda::ID.into()),..SavedState::default()};
        let restored:SavedState=toml::from_str(&toml::to_string(&state).unwrap()).unwrap();
        assert_eq!(restored.edgepad_gpu,state.edgepad_gpu);
        assert_eq!(restored.model,state.model);
        assert!(!restored.cpu_inference);
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
