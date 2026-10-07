//! Video Depth Anything Small, 518x294, causal streaming: a temporal depth
//! model that keeps eight hidden-state histories between frames instead of
//! seeing each frame alone. From the model researcher's
//! `reports/METEOR_VDA_S_518X294_INTEGRATION_REQUEST.md`
//! (`nightfall-temporal-zipdepth`).
//!
//! Two ONNX graphs, both verified against their SHA-256 before use:
//! - the cold start, run on the first frame after any reset. Its eight
//!   states seed the history. TensorRT builds it in fp32 at optimisation
//!   level 0, which the researcher found was the only exact build.
//! - the recurrent step, run on every later frame with the packed history.
//!   It's built in TensorRT fp16 (about 3.5 ms on an RTX 3090).
//!
//! On CUDA (while the TensorRT engines build) both run in fp32.
//!
//! Per frame, everything stays on the GPU (`kernels/vda.cu`): the decoded
//! 720p frame is resized with OpenCV's INTER_CUBIC and normalised, the 31
//! selected states are gathered into the cache inputs, and the new states
//! are stored as f16, as in the reference. The history follows the
//! reference exactly (`History`). Optionally, the depth map is then softened
//! with a Gaussian blur (`edge_softening`), so the headset's stretch to the
//! screen doesn't show the 518x294 grid as steps on hard edges.
//!
//! The state is reset (and the next frame cold-starts) on a new stream, a
//! gap between frames, a hard cut, or a non-finite output.

use std::collections::HashMap;
use std::ffi::{c_int, c_uint, c_void};
use std::fmt::Write as _;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use sha2::{Digest, Sha256};

use crate::nvdec::{Api, CuContext, CuDevicePtr, check, launch, load_functions, primary_context};
use crate::onnx::Backend;

#[cfg(feature = "onnxruntime")]
mod ort_graph;

/// The model's name in the models menu and state.toml.
pub const ID: &str = "vda_s_518x294";
pub const LABEL: &str = "Video Depth Anything Small (518x294)";
pub const STEP_FILE: &str = "vda_s_streaming_step_518x294.onnx";
pub const COLD_FILE: &str = "vda_s_cold_start_518x294.onnx";
const STEP_SHA256: &str = "98e62bd266218fd8b95293033502476797ba3673228d3417e140f5a96d9f714f";
const COLD_SHA256: &str = "dd4df8ab533e19e9610083da8d3eefe1ac398648cba519deee605230493486e0";

pub const WIDTH: usize = 518;
pub const HEIGHT: usize = 294;
/// The decoder reduces frames to 720p with the footprint average (close to
/// the reference's INTER_AREA to 1280x720), then vda_resize_normalize
/// resizes that to the model's input with INTER_CUBIC, as the reference does.
pub const DECODE_SIZE: (usize, usize) = (1280, 720);

/// States the recurrent step attends to.
const HISTORY: usize = 31;
/// (tokens, channels) of the eight states; each history is [tokens, 31, channels].
const STATES: [(usize, usize); 8] =
    [(777, 192), (777, 192), (209, 384), (209, 384), (777, 64), (777, 64), (3108, 64), (3108, 64)];
/// History slots in the state pool: the history holds at most 42 distinct
/// states, plus the one being written.
const SLOTS: usize = 44;

/// A longer pause between frames restarts the history: the model has no
/// timestamps, so stale frames mustn't pass for neighbours.
const MAX_GAP: Duration = Duration::from_millis(500);
/// Mean absolute change of the 16x9 thumbnail (in normalised units, about
/// 0.22 of the 0..1 range each) that counts as a hard cut.
const CUT_THRESHOLD: f32 = 1.0;
const THUMB_VALUES: usize = 3 * 9 * 16;
/// The readback buffer: the non-finite flag, then the thumbnail.
const THUMB_OFFSET: usize = 16;

/// Edge softening levels for the tray: label and Gaussian sigma in depth
/// texels (0 = off). One texel is about 5 screen pixels on a 1440p stream.
/// On the headset, the warp's steps on hard edges disappear from about
/// 0.75 (tested 2026-10-06); below about 0.35 the kernel, sampled at whole
/// texels, barely reaches the neighbours at all.
pub const SOFTENING: [(&str, f32); 4] = [("Off", 0.0), ("Light", 0.75), ("Medium", 0.85), ("High", 1.0)];
/// The default level (Medium).
pub const DEFAULT_SOFTENING: usize = 2;

/// TensorRT builder settings, part of each engine's cache key.
const STEP_OPT_LEVEL: u8 = 4;
const COLD_OPT_LEVEL: u8 = 0;

const PTX: &str = concat!(include_str!("../kernels/vda.ptx"), "\0");

/// Whether both graphs are in the models folder.
pub fn present(models_dir: &Path) -> bool {
    models_dir.join(STEP_FILE).is_file() && models_dir.join(COLD_FILE).is_file()
}

/// The reference's history list (validate_tensorrt_sequence.py, following
/// video_depth_stream.py): the first state stays, the list grows to 42
/// entries and then drops its second entry with each new state, and every
/// step attends to entries [0, 1] and the newest 29. Entries are slots in
/// the state pool.
#[derive(Debug)]
struct History {
    list: Vec<usize>,
    steps: usize,
}

impl History {
    fn seeded(slot: usize) -> History {
        History { list: vec![slot; HISTORY + 1], steps: 0 }
    }

    fn select(&self) -> [c_int; HISTORY] {
        let n = self.list.len();
        let mut out = [0; HISTORY];
        for (i, slot) in self.list[..2].iter().chain(&self.list[n - (HISTORY - 2)..]).enumerate() {
            out[i] = *slot as c_int;
        }
        out
    }

    /// A pool slot that no entry refers to.
    fn free_slot(&self) -> usize {
        (0..SLOTS).find(|s| !self.list.contains(s)).expect("the pool has a spare slot")
    }

    fn push(&mut self, slot: usize) {
        self.steps += 1;
        self.list.push(slot);
        if self.steps + 32 > 42 {
            self.list.remove(1);
        }
    }
}

/// One frame's result. `depth` is the f32 depth map in GPU memory, valid
/// until the next frame.
pub struct StepReport {
    pub depth: CuDevicePtr,
    /// Why this frame cold-started, if it did.
    pub reset: Option<String>,
    /// Resize, cut check and state packing.
    pub prepare: Duration,
    pub model: Duration,
    /// Storing the new states and the non-finite check.
    pub store: Duration,
    /// Edge softening (zero when it's off).
    pub soften: Duration,
}

/// One graph with its outputs bound to GPU memory.
struct Graph {
    runner: Runner,
    /// depth, then the eight new states (f32).
    outputs: Vec<CuDevicePtr>,
    /// "from cache" or "built in N s".
    engine: String,
}

// Two of these exist per model, so the size difference doesn't matter.
#[allow(clippy::large_enum_variant)]
enum Runner {
    /// ONNX Runtime, which owns the outputs. Field order is drop order: the
    /// binding holds the output tensors, which the allocator must outlive.
    #[cfg(feature = "onnxruntime")]
    Ort(ort_graph::OrtGraph),
    /// TensorRT without ONNX Runtime (src/tensorrt.rs). Meteor owns the
    /// outputs and the stream; `release` frees them with the engine.
    Native { engine: Option<crate::tensorrt::Engine>, stream: *mut c_void },
}

impl Graph {
    fn native(&self) -> bool {
        matches!(self.runner, Runner::Native { .. })
    }

    /// Frees a native graph's engine, stream and outputs (ONNX Runtime's
    /// free themselves on drop).
    fn release(&mut self, api: &Api, ctx: CuContext) {
        // Without the onnxruntime feature, Native is the only kind.
        #[allow(irrefutable_let_patterns)]
        let Runner::Native { engine, stream } = &mut self.runner else { return };
        // SAFETY: our own engine, stream and allocations, in the pushed
        // context, with no run in flight (runs are synchronous).
        unsafe {
            (api.cu_ctx_push)(ctx);
            drop(engine.take());
            if !stream.is_null() {
                (api.cu_stream_destroy)(*stream);
                *stream = ptr::null_mut();
            }
            for p in self.outputs.drain(..) {
                (api.cu_mem_free)(p);
            }
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
        }
    }
}

struct Kernels {
    clear: *mut c_void,
    resize: *mut c_void,
    thumb: *mut c_void,
    append: *mut c_void,
    check: *mut c_void,
    pack: *mut c_void,
    blur: *mut c_void,
}

pub struct VdaModel {
    step: Graph,
    cold: Graph,
    api: &'static Api,
    ctx: CuContext,
    kernels: Kernels,
    /// The model input, [3, HEIGHT, WIDTH] f32.
    image: CuDevicePtr,
    /// Packed cache inputs, [tokens, 31, channels] f32.
    packed: [CuDevicePtr; 8],
    /// State pools, [SLOTS, tokens, channels] f16.
    pool: [CuDevicePtr; 8],
    /// The non-finite flag and the thumbnail.
    readback: CuDevicePtr,
    /// The softened depth map, [HEIGHT, WIDTH] f32.
    softened: CuDevicePtr,
    /// The blur's intermediate, [HEIGHT, WIDTH] f32.
    blurred: CuDevicePtr,
    /// A decoded frame uploaded from system memory (`--cpu-frames`).
    staging: Option<(CuDevicePtr, usize)>,
    history: Option<History>,
    pending_reset: Option<String>,
    last_frame: Option<Instant>,
    thumb: Option<Vec<f32>>,
    /// Gaussian sigma of the edge softening in depth texels; 0 is off.
    pub edge_softening: f32,
    pub name: String,
    /// Engines, precision and where they came from, for the status line.
    pub description: String,
    /// Meteor's own buffers, in bytes.
    pub buffer_bytes: usize,
}

// SAFETY: the context and kernel handles are only used with the context
// pushed; the model is used by one thread at a time.
unsafe impl Send for VdaModel {}

impl VdaModel {
    /// Verifies and loads both graphs, then warms them up. On TensorRT the
    /// first load builds both engines (several minutes), then they come
    /// from `cache_dir`.
    pub fn load(models_dir: &Path, backend: Backend, cache_dir: &Path) -> Result<VdaModel, String> {
        let started = Instant::now();
        let step_path = models_dir.join(STEP_FILE);
        let cold_path = models_dir.join(COLD_FILE);
        verify(&step_path, STEP_SHA256)?;
        verify(&cold_path, COLD_SHA256)?;
        let (api, ctx) = primary_context()?;
        let free_before = free_memory(api, ctx);
        let identity = crate::nvdec::gpu_identity(api, ctx);
        let mut cold = open_graph(&cold_path, backend, false, COLD_OPT_LEVEL, cache_dir, COLD_SHA256, &identity, api, ctx)?;
        let step = match open_graph(&step_path, backend, true, STEP_OPT_LEVEL, cache_dir, STEP_SHA256, &identity, api, ctx) {
            Ok(step) => step,
            Err(err) => {
                cold.release(api, ctx);
                return Err(err);
            }
        };
        let names = [c"vda_clear", c"vda_resize_normalize", c"vda_thumb", c"vda_append", c"vda_check", c"vda_pack", c"vda_blur"];
        let k = load_functions(api, ctx, PTX, &names)?;
        let kernels = Kernels { clear: k[0], resize: k[1], thumb: k[2], append: k[3], check: k[4], pack: k[5], blur: k[6] };
        let precision = match backend {
            Backend::Cuda => "CUDA fp32".to_string(),
            Backend::TensorRt => {
                let native = if step.native() { " (native)" } else { "" };
                format!("TensorRT{native} fp16 step ({}), fp32 cold start ({})", step.engine, cold.engine)
            }
        };
        let mut model = VdaModel {
            step,
            cold,
            api,
            ctx,
            kernels,
            image: 0,
            packed: [0; 8],
            pool: [0; 8],
            readback: 0,
            softened: 0,
            blurred: 0,
            staging: None,
            history: None,
            pending_reset: Some("start".into()),
            last_frame: None,
            thumb: None,
            edge_softening: SOFTENING[DEFAULT_SOFTENING].1,
            name: ID.to_string(),
            description: precision,
            buffer_bytes: 0,
        };
        model.allocate()?;
        let cold_ms = model.warm_up()?;
        if let (Some(before), Some(after)) = (free_before, free_memory(api, ctx)) {
            let used = before.saturating_sub(after);
            log::info!(
                "{LABEL}: {} MiB of GPU memory in use ({} MiB Meteor buffers, the rest engines and workspace)",
                used >> 20,
                model.buffer_bytes >> 20
            );
        }
        log::info!(
            "Loaded {LABEL} ({}) in {:.1} s; warm cold start {cold_ms:.2} ms",
            model.description,
            started.elapsed().as_secs_f64()
        );
        Ok(model)
    }

    /// The next frame starts a new history.
    pub fn reset(&mut self, reason: &str) {
        if self.pending_reset.is_none() {
            self.pending_reset = Some(reason.to_string());
        }
    }

    /// Runs on a decoded frame in GPU memory: planar RGB floats in 0..1 at
    /// `size` (DECODE_SIZE, unless the stream is smaller).
    pub fn infer_device(&mut self, frame: CuDevicePtr, size: (usize, usize)) -> Result<StepReport, String> {
        self.with_context(|m| m.run(frame, size))
    }

    /// Runs on a decoded RGB24 frame in system memory (`--cpu-frames`).
    pub fn infer_rgb(&mut self, rgb: &[u8], size: (usize, usize)) -> Result<StepReport, String> {
        let plane = size.0 * size.1;
        if rgb.len() != plane * 3 {
            return Err(format!("frame is {} bytes, expected {}", rgb.len(), plane * 3));
        }
        let mut planar = vec![0f32; plane * 3];
        for (i, px) in rgb.chunks_exact(3).enumerate() {
            for c in 0..3 {
                planar[c * plane + i] = f32::from(px[c]) / 255.0;
            }
        }
        self.with_context(|m| {
            let bytes = plane * 3 * 4;
            if m.staging.is_none_or(|(_, size)| size != bytes) {
                if let Some((old, _)) = m.staging.take() {
                    // SAFETY: our own allocation, no longer in use.
                    unsafe { (m.api.cu_mem_free)(old) };
                }
                let mut ptr = 0;
                // SAFETY: allocation in the pushed context.
                check("cuMemAlloc", unsafe { (m.api.cu_mem_alloc)(&mut ptr, bytes) })?;
                m.staging = Some((ptr, bytes));
            }
            let (staging, _) = m.staging.expect("just allocated");
            // SAFETY: staging holds `bytes` bytes.
            check("cuMemcpyHtoD", unsafe { (m.api.cu_memcpy_htod)(staging, planar.as_ptr().cast(), bytes) })?;
            m.run(staging, size)
        })
    }

    /// Copies a depth map back (for CPU post-processing).
    pub fn download_depth(&self, depth: CuDevicePtr) -> Result<Vec<f32>, String> {
        let mut out = vec![0f32; WIDTH * HEIGHT];
        self.with_context_ref(|m| {
            // SAFETY: the depth output holds WIDTH * HEIGHT floats.
            check("cuMemcpyDtoH", unsafe { (m.api.cu_memcpy_dtoh)(out.as_mut_ptr().cast(), depth, out.len() * 4) })
        })?;
        Ok(out)
    }

    fn run(&mut self, frame: CuDevicePtr, (sw, sh): (usize, usize)) -> Result<StepReport, String> {
        let started = Instant::now();
        let now = Instant::now();
        self.launch_clear()?;
        self.launch_resize(frame, sw, sh)?;
        self.launch_thumb()?;
        let (_, thumb) = self.read_back(true)?;

        let mut reset = self.pending_reset.take();
        if reset.is_none() && self.history.is_none() {
            reset = Some("start".into());
        }
        if reset.is_none()
            && let Some(last) = self.last_frame
            && now.duration_since(last) > MAX_GAP
        {
            reset = Some(format!("{} ms since the last frame", now.duration_since(last).as_millis()));
        }
        if reset.is_none()
            && let Some(previous) = &self.thumb
        {
            let change = previous.iter().zip(&thumb).map(|(a, b)| (a - b).abs()).sum::<f32>() / THUMB_VALUES as f32;
            if change > CUT_THRESHOLD {
                reset = Some(format!("hard cut (change {change:.2})"));
            }
        }
        self.last_frame = Some(now);
        self.thumb = Some(thumb);

        let result = if reset.is_some() { self.cold_start(started) } else { self.step(started) };
        match result {
            Ok(mut report) => {
                report.reset = reset;
                if self.edge_softening > 0.0 {
                    let softening = Instant::now();
                    self.launch_blur(report.depth, self.blurred, true)?;
                    self.launch_blur(self.blurred, self.softened, false)?;
                    sync(self.api)?;
                    report.depth = self.softened;
                    report.soften = softening.elapsed();
                }
                Ok(report)
            }
            Err(err) => {
                // Don't carry anything from a failed frame into the next one.
                self.history = None;
                self.pending_reset = Some(format!("after an error ({err})"));
                Err(err)
            }
        }
    }

    fn cold_start(&mut self, started: Instant) -> Result<StepReport, String> {
        self.history = None;
        sync(self.api)?;
        let prepared = Instant::now();
        self.run_graph(true).map_err(|e| format!("cold start: {e}"))?;
        let ran = Instant::now();
        let slot = 0;
        self.store_states(&self.cold.outputs.clone(), slot)?;
        let depth = self.cold.outputs[0];
        self.history = Some(History::seeded(slot));
        Ok(StepReport {
            depth,
            reset: None,
            prepare: prepared - started,
            model: ran - prepared,
            store: ran.elapsed(),
            soften: Duration::ZERO,
        })
    }

    fn step(&mut self, started: Instant) -> Result<StepReport, String> {
        let history = self.history.as_ref().expect("a history after the cold start");
        let selection = history.select();
        let slot = history.free_slot();
        for (i, &(tokens, channels)) in STATES.iter().enumerate() {
            self.launch_pack(i, tokens, channels, selection)?;
        }
        sync(self.api)?;
        let prepared = Instant::now();
        self.run_graph(false).map_err(|e| format!("step: {e}"))?;
        let ran = Instant::now();
        self.store_states(&self.step.outputs.clone(), slot)?;
        self.history.as_mut().expect("checked above").push(slot);
        let depth = self.step.outputs[0];
        Ok(StepReport {
            depth,
            reset: None,
            prepare: prepared - started,
            model: ran - prepared,
            store: ran.elapsed(),
            soften: Duration::ZERO,
        })
    }

    /// Stores a graph's eight new states in `slot` and checks them and the
    /// depth for non-finite values.
    fn store_states(&self, outputs: &[CuDevicePtr], slot: usize) -> Result<(), String> {
        for (i, &(tokens, channels)) in STATES.iter().enumerate() {
            let n = tokens * channels;
            self.launch_append(outputs[i + 1], n, self.pool[i] + (slot * n * 2) as u64)?;
        }
        self.launch_check(outputs[0], WIDTH * HEIGHT)?;
        let (flag, _) = self.read_back(false)?;
        match flag {
            0 => Ok(()),
            1 => Err("non-finite temporal state".into()),
            2 => Err("non-finite depth".into()),
            _ => Err("non-finite depth and temporal state".into()),
        }
    }

    /// Cold start and three steps on a blank frame, so the first real frame
    /// doesn't pay for lazy initialisation. Returns the cold start's time.
    fn warm_up(&mut self) -> Result<f64, String> {
        let blank = vec![0.5f32; 3 * WIDTH * HEIGHT];
        self.with_context(|m| {
            let mut cold_ms = 0.0;
            for i in 0..2 {
                // SAFETY: image holds 3 * WIDTH * HEIGHT floats.
                check("cuMemcpyHtoD", unsafe {
                    (m.api.cu_memcpy_htod)(m.image, blank.as_ptr().cast(), blank.len() * 4)
                })?;
                let report = m.cold_start(Instant::now()).map_err(|e| format!("warm-up: {e}"))?;
                cold_ms = report.model.as_secs_f64() * 1000.0;
                if i == 1 {
                    for _ in 0..3 {
                        m.step(Instant::now()).map_err(|e| format!("warm-up: {e}"))?;
                    }
                }
            }
            m.history = None;
            m.pending_reset = Some("start".into());
            Ok(cold_ms)
        })
    }

    fn allocate(&mut self) -> Result<(), String> {
        let mut sizes = vec![3 * WIDTH * HEIGHT * 4, THUMB_OFFSET + THUMB_VALUES * 4, WIDTH * HEIGHT * 4, WIDTH * HEIGHT * 4];
        sizes.extend(STATES.iter().map(|(t, c)| t * HISTORY * c * 4));
        sizes.extend(STATES.iter().map(|(t, c)| SLOTS * t * c * 2));
        self.buffer_bytes = sizes.iter().sum();
        let mut ptrs = Vec::with_capacity(sizes.len());
        let result = self.with_context(|m| {
            for bytes in &sizes {
                let mut ptr = 0;
                // SAFETY: allocation in the pushed context; freed in Drop.
                check("cuMemAlloc", unsafe { (m.api.cu_mem_alloc)(&mut ptr, *bytes) })?;
                ptrs.push(ptr);
            }
            Ok(())
        });
        let mut it = ptrs.into_iter();
        self.image = it.next().unwrap_or(0);
        self.readback = it.next().unwrap_or(0);
        self.softened = it.next().unwrap_or(0);
        self.blurred = it.next().unwrap_or(0);
        for p in &mut self.packed {
            *p = it.next().unwrap_or(0);
        }
        for p in &mut self.pool {
            *p = it.next().unwrap_or(0);
        }
        result
    }

    /// Binds our input buffers and runs a graph.
    fn run_graph(&mut self, cold: bool) -> Result<(), String> {
        let image_ptr = self.image;
        let packed = self.packed;
        let api = self.api;
        let graph = if cold { &mut self.cold } else { &mut self.step };
        match &mut graph.runner {
            Runner::Native { engine: Some(engine), stream } => {
                engine.set_address("image", image_ptr)?;
                if !cold {
                    for (i, &cache) in packed.iter().enumerate() {
                        engine.set_address(&format!("cache_{i}"), cache)?;
                    }
                }
                engine.enqueue(*stream)?;
                // SAFETY: our stream, in the pushed context.
                check("cuStreamSynchronize", unsafe { (api.cu_stream_synchronize)(*stream) })
            }
            Runner::Native { engine: None, .. } => Err("the engine was released".into()),
            #[cfg(feature = "onnxruntime")]
            Runner::Ort(graph) => graph.run(image_ptr, if cold { None } else { Some(packed) }),
        }
    }

    fn launch_clear(&self) -> Result<(), String> {
        let mut flag = self.readback;
        // SAFETY: the argument matches vda_clear; the context is current.
        unsafe { launch(self.api, self.kernels.clear, (1, 1), (1, 1), &mut [(&mut flag as *mut u64).cast()]) }
    }

    fn launch_resize(&self, frame: CuDevicePtr, sw: usize, sh: usize) -> Result<(), String> {
        let (mut src, mut out) = (frame, self.image);
        let (mut sw, mut sh) = (sw as c_int, sh as c_int);
        let (mut w, mut h) = (WIDTH as c_int, HEIGHT as c_int);
        let mut args: [*mut c_void; 6] = [
            (&mut src as *mut u64).cast(),
            (&mut sw as *mut c_int).cast(),
            (&mut sh as *mut c_int).cast(),
            (&mut w as *mut c_int).cast(),
            (&mut h as *mut c_int).cast(),
            (&mut out as *mut u64).cast(),
        ];
        let grid = ((WIDTH as c_uint).div_ceil(16), (HEIGHT as c_uint).div_ceil(16));
        // SAFETY: the arguments match vda_resize_normalize; the frame holds
        // 3 * sw * sh floats.
        unsafe { launch(self.api, self.kernels.resize, grid, (16, 16), &mut args) }
    }

    fn launch_thumb(&self) -> Result<(), String> {
        let (mut image, mut thumb) = (self.image, self.readback + THUMB_OFFSET as u64);
        let (mut w, mut h) = (WIDTH as c_int, HEIGHT as c_int);
        let mut args: [*mut c_void; 4] = [
            (&mut image as *mut u64).cast(),
            (&mut w as *mut c_int).cast(),
            (&mut h as *mut c_int).cast(),
            (&mut thumb as *mut u64).cast(),
        ];
        // SAFETY: the arguments match vda_thumb (256 threads, one block per cell).
        unsafe { launch(self.api, self.kernels.thumb, (16, 9), (256, 1), &mut args) }
    }

    fn launch_append(&self, state: CuDevicePtr, n: usize, slot: CuDevicePtr) -> Result<(), String> {
        let (mut state, mut slot, mut flag) = (state, slot, self.readback);
        let mut n = n as c_int;
        let mut args: [*mut c_void; 4] = [
            (&mut state as *mut u64).cast(),
            (&mut n as *mut c_int).cast(),
            (&mut slot as *mut u64).cast(),
            (&mut flag as *mut u64).cast(),
        ];
        // SAFETY: the arguments match vda_append; state holds n floats and
        // slot n halves.
        unsafe { launch(self.api, self.kernels.append, ((n as c_uint).div_ceil(256), 1), (256, 1), &mut args) }
    }

    fn launch_check(&self, values: CuDevicePtr, n: usize) -> Result<(), String> {
        let (mut values, mut flag) = (values, self.readback);
        let mut n = n as c_int;
        let mut args: [*mut c_void; 3] =
            [(&mut values as *mut u64).cast(), (&mut n as *mut c_int).cast(), (&mut flag as *mut u64).cast()];
        // SAFETY: the arguments match vda_check; values holds n floats.
        unsafe { launch(self.api, self.kernels.check, ((n as c_uint).div_ceil(256), 1), (256, 1), &mut args) }
    }

    fn launch_pack(&self, i: usize, tokens: usize, channels: usize, selection: [c_int; HISTORY]) -> Result<(), String> {
        let (mut pool, mut out) = (self.pool[i], self.packed[i]);
        let (mut t, mut c) = (tokens as c_int, channels as c_int);
        let mut selection = selection;
        let mut args: [*mut c_void; 5] = [
            (&mut pool as *mut u64).cast(),
            (&mut t as *mut c_int).cast(),
            (&mut c as *mut c_int).cast(),
            (&mut selection as *mut [c_int; HISTORY]).cast(),
            (&mut out as *mut u64).cast(),
        ];
        let total = (tokens * HISTORY * channels) as c_uint;
        // SAFETY: the arguments match vda_pack (Selection is 31 ints); every
        // selected slot is below SLOTS.
        unsafe { launch(self.api, self.kernels.pack, (total.div_ceil(256), 1), (256, 1), &mut args) }
    }

    fn launch_blur(&self, input: CuDevicePtr, output: CuDevicePtr, horizontal: bool) -> Result<(), String> {
        let (mut input, mut output) = (input, output);
        let (mut w, mut h) = (WIDTH as c_int, HEIGHT as c_int);
        let mut sigma = self.edge_softening;
        let mut horizontal = c_int::from(horizontal);
        let mut args: [*mut c_void; 6] = [
            (&mut input as *mut u64).cast(),
            (&mut output as *mut u64).cast(),
            (&mut w as *mut c_int).cast(),
            (&mut h as *mut c_int).cast(),
            (&mut sigma as *mut f32).cast(),
            (&mut horizontal as *mut c_int).cast(),
        ];
        let grid = ((WIDTH as c_uint).div_ceil(16), (HEIGHT as c_uint).div_ceil(16));
        // SAFETY: the arguments match vda_blur; both buffers hold WIDTH *
        // HEIGHT floats and differ.
        unsafe { launch(self.api, self.kernels.blur, grid, (16, 16), &mut args) }
    }

    /// Waits for the queued kernels and reads the flag (and the thumbnail).
    fn read_back(&self, thumb: bool) -> Result<(u32, Vec<f32>), String> {
        let mut bytes = vec![0u8; if thumb { THUMB_OFFSET + THUMB_VALUES * 4 } else { 4 }];
        // SAFETY: readback holds this many bytes; the copy waits for the
        // default stream.
        check("cuMemcpyDtoH", unsafe { (self.api.cu_memcpy_dtoh)(bytes.as_mut_ptr().cast(), self.readback, bytes.len()) })?;
        let flag = u32::from_le_bytes(bytes[..4].try_into().expect("4 bytes"));
        let values = bytes
            .get(THUMB_OFFSET..)
            .unwrap_or_default()
            .chunks_exact(4)
            .map(|b| f32::from_le_bytes(b.try_into().expect("4 bytes")))
            .collect();
        Ok((flag, values))
    }

    fn with_context<T>(&mut self, f: impl FnOnce(&mut Self) -> Result<T, String>) -> Result<T, String> {
        // SAFETY: pushing our retained primary context around driver calls.
        unsafe { (self.api.cu_ctx_push)(self.ctx) };
        let result = f(self);
        let mut popped = ptr::null_mut();
        // SAFETY: popping what we pushed.
        unsafe { (self.api.cu_ctx_pop)(&mut popped) };
        result
    }

    fn with_context_ref<T>(&self, f: impl FnOnce(&Self) -> Result<T, String>) -> Result<T, String> {
        // SAFETY: as with_context.
        unsafe { (self.api.cu_ctx_push)(self.ctx) };
        let result = f(self);
        let mut popped = ptr::null_mut();
        // SAFETY: popping what we pushed.
        unsafe { (self.api.cu_ctx_pop)(&mut popped) };
        result
    }
}

#[cfg(test)]
impl VdaModel {
    /// Runs on an already normalised model input; `first` cold-starts.
    fn infer_normalized(&mut self, image: &[f32], first: bool) -> Result<(Vec<f32>, StepReport), String> {
        let report = self.with_context(|m| {
            // SAFETY: image holds 3 * WIDTH * HEIGHT floats.
            check("cuMemcpyHtoD", unsafe { (m.api.cu_memcpy_htod)(m.image, image.as_ptr().cast(), image.len() * 4) })?;
            if first { m.cold_start(Instant::now()) } else { m.step(Instant::now()) }
        })?;
        Ok((self.download_depth(report.depth)?, report))
    }
}

impl Drop for VdaModel {
    fn drop(&mut self) {
        self.step.release(self.api, self.ctx);
        self.cold.release(self.api, self.ctx);
        let staging = self.staging.map(|(p, _)| p).unwrap_or(0);
        let buffers: Vec<CuDevicePtr> = [self.image, self.readback, self.softened, self.blurred, staging]
            .into_iter()
            .chain(self.packed)
            .chain(self.pool)
            .filter(|&p| p != 0)
            .collect();
        // SAFETY: freeing our own allocations in the pushed context, after
        // the last run (runs are synchronous).
        unsafe {
            (self.api.cu_ctx_push)(self.ctx);
            for p in buffers {
                (self.api.cu_mem_free)(p);
            }
            let mut popped = ptr::null_mut();
            (self.api.cu_ctx_pop)(&mut popped);
        }
    }
}

fn sync(api: &Api) -> Result<(), String> {
    // SAFETY: the caller has the context current.
    check("cuCtxSynchronize", unsafe { (api.cu_ctx_synchronize)() })
}

fn free_memory(api: &Api, ctx: CuContext) -> Option<usize> {
    let (mut free, mut total) = (0usize, 0usize);
    // SAFETY: out-pointers to locals, with the context pushed.
    unsafe {
        (api.cu_ctx_push)(ctx);
        let rc = (api.cu_mem_get_info)(&mut free, &mut total);
        let mut popped = ptr::null_mut();
        (api.cu_ctx_pop)(&mut popped);
        (rc == 0).then_some(free)
    }
}

/// Opens one graph and binds its outputs to GPU memory. On TensorRT, each
/// graph gets its own engine folder named by everything the engine depends
/// on, so a change of any of them builds a new engine rather than loading a
/// stale one. TensorRT runs without ONNX Runtime when its libraries open
/// (`METEOR_TENSORRT=ort` uses ONNX Runtime's TensorRT provider instead).
#[allow(clippy::too_many_arguments)]
fn open_graph(
    path: &Path,
    backend: Backend,
    fp16: bool,
    opt_level: u8,
    cache_dir: &Path,
    sha256: &str,
    gpu: &str,
    api: &'static Api,
    ctx: CuContext,
) -> Result<Graph, String> {
    let file = path.file_name().and_then(|n| n.to_str()).unwrap_or("model");
    if backend == Backend::TensorRt && std::env::var("METEOR_TENSORRT").as_deref() != Ok("ort") {
        match crate::tensorrt::init() {
            Ok(version) => return open_native(path, fp16, opt_level, cache_dir, sha256, gpu, &version, api, ctx),
            Err(err) if cfg!(feature = "onnxruntime") => {
                log::warn!("TensorRT without ONNX Runtime isn't available ({err}); using ONNX Runtime's")
            }
            Err(err) => return Err(format!("{file}: {err}")),
        }
    }
    #[cfg(feature = "onnxruntime")]
    return ort_graph::open(path, backend, fp16, opt_level, cache_dir, sha256, gpu);
    #[cfg(not(feature = "onnxruntime"))]
    Err(format!("{file}: {} isn't available in this build without ONNX Runtime", backend.label()))
}

/// The graph's inputs: the image, and on the step (`with_caches`) the
/// eight packed histories.
fn expected_inputs(with_caches: bool) -> Vec<(String, Vec<i64>)> {
    let mut expected = vec![("image".to_string(), vec![1, 1, 3, HEIGHT as i64, WIDTH as i64])];
    if with_caches {
        expected.extend(
            STATES.iter().enumerate().map(|(i, &(t, c))| (format!("cache_{i}"), vec![t as i64, HISTORY as i64, c as i64])),
        );
    }
    expected
}

/// The depth, then the eight new states.
fn output_shapes() -> Vec<(String, Vec<usize>)> {
    let mut shapes = vec![("depth".to_string(), vec![1usize, 1, HEIGHT, WIDTH])];
    shapes.extend(STATES.iter().enumerate().map(|(i, &(t, c))| (format!("updated_cache_{i}"), vec![t, 1, c])));
    shapes
}

fn engine_dir(cache_dir: &Path, sha256: &str, precision: &str, opt_level: u8, trt: &str, gpu: &str) -> PathBuf {
    cache_dir.join(format!("{ID}-{}-{precision}-opt{opt_level}-trt{trt}-{gpu}", &sha256[..12]))
}

/// The native engine in its engine folder, next to ONNX Runtime's.
const NATIVE_PLAN: &str = "native.plan";
const NATIVE_TIMING_CACHE: &str = "native.timing";

/// open_graph on TensorRT without ONNX Runtime: loads the cached plan, or
/// builds and caches it, then allocates and binds the outputs.
#[allow(clippy::too_many_arguments)]
fn open_native(
    path: &Path,
    fp16: bool,
    opt_level: u8,
    cache_dir: &Path,
    sha256: &str,
    gpu: &str,
    version: &str,
    api: &'static Api,
    ctx: CuContext,
) -> Result<Graph, String> {
    use crate::tensorrt::{BuildOptions, Engine};
    let file = path.file_name().and_then(|n| n.to_str()).unwrap_or("model");
    let precision = if fp16 { "fp16" } else { "fp32" };
    let dir = engine_dir(cache_dir, sha256, precision, opt_level, version, gpu);
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let plan_path = dir.join(NATIVE_PLAN);

    // SAFETY: pushing our retained primary context around TensorRT and
    // driver calls; popped below.
    unsafe { (api.cu_ctx_push)(ctx) };
    let mut graph = Graph { runner: Runner::Native { engine: None, stream: ptr::null_mut() }, outputs: Vec::new(), engine: String::new() };
    let result = (|| {
        let started = Instant::now();
        let cached = std::fs::read(&plan_path).ok().and_then(|plan| {
            Engine::load(&plan).map_err(|e| log::warn!("{file}: rebuilding the TensorRT engine ({e})")).ok()
        });
        let mut engine = match cached {
            Some(engine) => {
                graph.engine = "from cache".into();
                engine
            }
            None => {
                log::info!("{file}: building the TensorRT {precision} engine (several minutes the first time)");
                let options = BuildOptions { fp16, opt_level };
                crate::tensorrt::build_in_child(path, &options, &plan_path, &dir.join(NATIVE_TIMING_CACHE))
                    .map_err(|e| format!("{file} (TensorRT): {e}"))?;
                let plan = std::fs::read(&plan_path).map_err(|e| format!("{}: {e}", plan_path.display()))?;
                graph.engine = format!("built in {:.0} s", started.elapsed().as_secs_f64());
                Engine::load(&plan).map_err(|e| format!("{file} (TensorRT): {e}"))?
            }
        };
        log::info!("{file}: TensorRT {precision} engine {} (native, {})", graph.engine, dir.display());

        for (name, shape) in expected_inputs(fp16) {
            let found = engine.tensor(&name).filter(|t| t.input && t.dtype == 0).map(|t| t.shape.clone());
            if found.as_ref() != Some(&shape) {
                return Err(format!("{file}: expected f32 input {name} {shape:?}, found {found:?}"));
            }
        }
        for (name, shape) in output_shapes() {
            let expected: Vec<i64> = shape.iter().map(|&d| d as i64).collect();
            let found = engine.tensor(&name).filter(|t| !t.input && t.dtype == 0).map(|t| t.shape.clone());
            if found.as_ref() != Some(&expected) {
                return Err(format!("{file}: expected f32 output {name} {expected:?}, found {found:?}"));
            }
            let mut ptr = 0;
            // SAFETY: allocation in the pushed context; freed in Graph::release.
            check("cuMemAlloc", unsafe { (api.cu_mem_alloc)(&mut ptr, shape.iter().product::<usize>() * 4) })?;
            graph.outputs.push(ptr);
            engine.set_address(&name, ptr)?;
        }
        let mut stream = ptr::null_mut();
        // SAFETY: an out-pointer to a local, in the pushed context.
        check("cuStreamCreate", unsafe { (api.cu_stream_create)(&mut stream, 0) })?;
        graph.runner = Runner::Native { engine: Some(engine), stream };
        Ok(())
    })();
    let mut popped = ptr::null_mut();
    // SAFETY: popping what we pushed.
    unsafe { (api.cu_ctx_pop)(&mut popped) };
    match result {
        Ok(()) => Ok(graph),
        Err(err) => {
            graph.release(api, ctx);
            Err(err)
        }
    }
}

/// A file's size and modification time.
type FileStamp = (u64, Option<SystemTime>);

/// Files already verified this run.
static VERIFIED: OnceLock<Mutex<HashMap<PathBuf, FileStamp>>> = OnceLock::new();

/// Checks a graph's SHA-256 (about a second per graph, once per run).
fn verify(path: &Path, expected: &str) -> Result<(), String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let key = (meta.len(), meta.modified().ok());
    let verified = VERIFIED.get_or_init(Mutex::default);
    if verified.lock().is_ok_and(|v| v.get(path) == Some(&key)) {
        return Ok(());
    }
    let mut file = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf).map_err(|e| format!("{}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let mut actual = String::with_capacity(64);
    for byte in hasher.finalize().iter() {
        let _ = write!(actual, "{byte:02x}");
    }
    if actual != expected {
        return Err(format!("{} has SHA-256 {actual}, expected {expected}", path.display()));
    }
    if let Ok(mut v) = verified.lock() {
        v.insert(path.to_path_buf(), key);
    }
    Ok(())
}

/// Collects VDA's per-stage timings and resets, and logs a summary every
/// ten seconds.
#[derive(Default)]
pub struct Telemetry {
    samples: Vec<[f32; 6]>, // prepare, model, store, soften, post, total (ms)
    cold_ms: Vec<f32>,
    resets: Vec<String>,
    skipped_at_start: u64,
    window_start: Option<Instant>,
}

impl Telemetry {
    pub fn record(&mut self, report: &StepReport, post: Duration, total: Duration, skipped: u64) {
        let ms = |d: Duration| d.as_secs_f32() * 1000.0;
        let start = *self.window_start.get_or_insert_with(|| {
            self.skipped_at_start = skipped;
            Instant::now()
        });
        if let Some(reason) = &report.reset {
            log::info!("{LABEL}: cold start ({reason}), {:.2} ms", ms(report.model));
            self.cold_ms.push(ms(report.model));
            self.resets.push(reason.clone());
        } else {
            self.samples.push([ms(report.prepare), ms(report.model), ms(report.store), ms(report.soften), ms(post), ms(total)]);
        }
        let window = start.elapsed();
        if window < Duration::from_secs(10) {
            return;
        }
        let steps = self.samples.len();
        let mut line = format!(
            "{LABEL}: {:.1} steps/s, {} frames skipped",
            steps as f64 / window.as_secs_f64(),
            skipped - self.skipped_at_start
        );
        for (i, stage) in ["prepare", "model", "store", "soften", "post", "frame to map"].iter().enumerate() {
            let mut values: Vec<f32> = self.samples.iter().map(|s| s[i]).collect();
            if values.is_empty() {
                break;
            }
            values.sort_by(f32::total_cmp);
            let pick = |q: f32| values[((values.len() - 1) as f32 * q).round() as usize];
            let _ = write!(line, "; {stage} {:.2}/{:.2} ms", pick(0.5), pick(0.95));
        }
        line.push_str(" (p50/p95)");
        if !self.resets.is_empty() {
            let _ = write!(line, "; {} cold starts: {}", self.resets.len(), self.resets.join(", "));
        }
        log::info!("{line}");
        *self = Telemetry::default();
    }
}

/// OpenCV INTER_CUBIC resize plus the mean/std normalisation, on the CPU:
/// the reference for vda_resize_normalize. `src` is planar RGB floats.
#[cfg(test)]
fn resize_normalize(src: &[f32], sw: usize, sh: usize) -> Vec<f32> {
    const MEAN: [f32; 3] = [0.485, 0.456, 0.406];
    const STD: [f32; 3] = [0.229, 0.224, 0.225];
    fn weights(t: f32) -> [f32; 4] {
        let a = -0.75f32;
        let w0 = ((a * (t + 1.0) - 5.0 * a) * (t + 1.0) + 8.0 * a) * (t + 1.0) - 4.0 * a;
        let w1 = ((a + 2.0) * t - (a + 3.0)) * t * t + 1.0;
        let w2 = ((a + 2.0) * (1.0 - t) - (a + 3.0)) * (1.0 - t) * (1.0 - t) + 1.0;
        [w0, w1, w2, 1.0 - w0 - w1 - w2]
    }
    let taps = |dst: usize, n_dst: usize, n_src: usize| {
        let f = (dst as f32 + 0.5) * (n_src as f32 / n_dst as f32) - 0.5;
        let i = f.floor() as i64;
        let w = weights(f - i as f32);
        let idx: [usize; 4] = std::array::from_fn(|k| (i - 1 + k as i64).clamp(0, n_src as i64 - 1) as usize);
        (idx, w)
    };
    let mut out = vec![0f32; 3 * WIDTH * HEIGHT];
    for y in 0..HEIGHT {
        let (rows, wy) = taps(y, HEIGHT, sh);
        for x in 0..WIDTH {
            let (cols, wx) = taps(x, WIDTH, sw);
            for c in 0..3 {
                let channel = &src[c * sw * sh..];
                let mut sum = 0.0f32;
                for j in 0..4 {
                    let mut across = 0.0f32;
                    for k in 0..4 {
                        across += wx[k] * channel[rows[j] * sw + cols[k]];
                    }
                    sum += wy[j] * across;
                }
                out[c * WIDTH * HEIGHT + y * WIDTH + x] = (sum - MEAN[c]) / STD[c];
            }
        }
    }
    out
}

/// vda_blur on the CPU: both passes.
#[cfg(test)]
fn blur(depth: &[f32], sigma: f32) -> Vec<f32> {
    let radius = ((3.0 * sigma).ceil() as i64).min(8);
    let pass = |src: &[f32], horizontal: bool| -> Vec<f32> {
        let mut out = vec![0f32; WIDTH * HEIGHT];
        for y in 0..HEIGHT as i64 {
            for x in 0..WIDTH as i64 {
                let (mut num, mut den) = (0.0, 0.0);
                for t in -radius..=radius {
                    let (sx, sy) = if horizontal {
                        ((x + t).clamp(0, WIDTH as i64 - 1), y)
                    } else {
                        (x, (y + t).clamp(0, HEIGHT as i64 - 1))
                    };
                    let w = (-0.5 * (t * t) as f32 / (sigma * sigma)).exp();
                    num += w * src[sy as usize * WIDTH + sx as usize];
                    den += w;
                }
                out[y as usize * WIDTH + x as usize] = num / den;
            }
        }
        out
    };
    pass(&pass(depth, true), false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The reference keeps the first state, attends to entries [0, 1] and
    /// the newest 29, and from the 11th step drops the second entry. Slots
    /// must never be reused while an entry still refers to them.
    #[test]
    fn history_follows_the_reference() {
        let mut h = History::seeded(0);
        // Which step wrote each slot (the cold start is step 0).
        let mut step_of = HashMap::from([(0usize, 0usize)]);
        // The Python list, with states named by their step.
        let mut reference = vec![0usize; 32];
        for k in 1..=80 {
            let got: Vec<usize> = h.select().iter().map(|&s| step_of[&(s as usize)]).collect();
            let expected: Vec<usize> = reference[..2].iter().chain(&reference[reference.len() - 29..]).copied().collect();
            assert_eq!(got, expected, "step {k}");
            let slot = h.free_slot();
            h.push(slot);
            step_of.insert(slot, k);
            reference.push(k);
            if k + 32 > 42 {
                reference.remove(1);
            }
        }
        // The seed, then the state from 40 steps back, then the newest.
        assert_eq!(reference.len(), 42);
        assert_eq!(reference[..3], [0, 40, 41]);
    }

    /// The GPU resize matches the CPU reference (which matches cv2.resize
    /// with INTER_CUBIC; checked against the researcher's inputs to 1.5e-6).
    /// Skipped without an NVIDIA GPU.
    /// Both blur passes match the CPU, and a hard edge becomes a slope.
    #[test]
    fn gpu_blur_matches_the_cpu() {
        let (api, ctx) = match primary_context() {
            Ok(c) => c,
            Err(err) => {
                eprintln!("skipping: no CUDA ({err})");
                return;
            }
        };
        let depth: Vec<f32> = (0..WIDTH * HEIGHT).map(|i| if i % WIDTH > 200 + (i / WIDTH) / 2 { 4.0 } else { 1.0 }).collect();
        let sigma = 1.0;
        let expected = blur(&depth, sigma);
        let kernel = load_functions(api, ctx, PTX, &[c"vda_blur"]).unwrap()[0];
        let mut got = vec![0f32; expected.len()];
        unsafe {
            (api.cu_ctx_push)(ctx);
            let (mut a, mut b) = (0u64, 0u64);
            check("cuMemAlloc", (api.cu_mem_alloc)(&mut a, depth.len() * 4)).unwrap();
            check("cuMemAlloc", (api.cu_mem_alloc)(&mut b, depth.len() * 4)).unwrap();
            check("cuMemcpyHtoD", (api.cu_memcpy_htod)(a, depth.as_ptr().cast(), depth.len() * 4)).unwrap();
            for (src, dst, horizontal) in [(a, b, 1), (b, a, 0)] {
                let (mut s, mut d, mut h) = (src, dst, horizontal as c_int);
                let (mut w, mut hh, mut sg) = (WIDTH as c_int, HEIGHT as c_int, sigma);
                let mut args: [*mut c_void; 6] = [
                    (&mut s as *mut u64).cast(),
                    (&mut d as *mut u64).cast(),
                    (&mut w as *mut c_int).cast(),
                    (&mut hh as *mut c_int).cast(),
                    (&mut sg as *mut f32).cast(),
                    (&mut h as *mut c_int).cast(),
                ];
                let grid = ((WIDTH as c_uint).div_ceil(16), (HEIGHT as c_uint).div_ceil(16));
                launch(api, kernel, grid, (16, 16), &mut args).unwrap();
            }
            check("cuMemcpyDtoH", (api.cu_memcpy_dtoh)(got.as_mut_ptr().cast(), a, got.len() * 4)).unwrap();
            (api.cu_mem_free)(a);
            (api.cu_mem_free)(b);
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
        }
        let worst = expected.iter().zip(&got).map(|(a, b)| (a - b).abs()).fold(0.0, f32::max);
        assert!(worst < 1e-4, "worst difference {worst}");
        // Row 0's edge is between x = 200 and 201: now a slope across it.
        assert!(got[199] > 1.05 && got[199] < 2.5 && got[202] > 2.5 && got[202] < 3.95, "{:?}", &got[196..206]);
    }

    #[test]
    fn gpu_resize_matches_the_cpu() {
        let (api, ctx) = match primary_context() {
            Ok(c) => c,
            Err(err) => {
                eprintln!("skipping: no CUDA ({err})");
                return;
            }
        };
        let (sw, sh) = DECODE_SIZE;
        let src: Vec<f32> = (0..3 * sw * sh)
            .map(|i| {
                let (x, y, c) = (i % sw, (i / sw) % sh, i / (sw * sh));
                (((x * 7 + y * 13 + c * 29) % 255) as f32 / 255.0 + ((x / 9 + y / 5) % 2) as f32 * 0.3).min(1.0)
            })
            .collect();
        let expected = resize_normalize(&src, sw, sh);
        let kernel = load_functions(api, ctx, PTX, &[c"vda_resize_normalize"]).unwrap()[0];
        let mut got = vec![0f32; expected.len()];
        unsafe {
            (api.cu_ctx_push)(ctx);
            let (mut s, mut d) = (0u64, 0u64);
            check("cuMemAlloc", (api.cu_mem_alloc)(&mut s, src.len() * 4)).unwrap();
            check("cuMemAlloc", (api.cu_mem_alloc)(&mut d, got.len() * 4)).unwrap();
            check("cuMemcpyHtoD", (api.cu_memcpy_htod)(s, src.as_ptr().cast(), src.len() * 4)).unwrap();
            let (mut a, mut b, mut w, mut h) = (sw as c_int, sh as c_int, WIDTH as c_int, HEIGHT as c_int);
            let mut args: [*mut c_void; 6] = [
                (&mut s as *mut u64).cast(),
                (&mut a as *mut c_int).cast(),
                (&mut b as *mut c_int).cast(),
                (&mut w as *mut c_int).cast(),
                (&mut h as *mut c_int).cast(),
                (&mut d as *mut u64).cast(),
            ];
            let grid = ((WIDTH as c_uint).div_ceil(16), (HEIGHT as c_uint).div_ceil(16));
            launch(api, kernel, grid, (16, 16), &mut args).unwrap();
            check("cuMemcpyDtoH", (api.cu_memcpy_dtoh)(got.as_mut_ptr().cast(), d, got.len() * 4)).unwrap();
            (api.cu_mem_free)(s);
            (api.cu_mem_free)(d);
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
        }
        let worst = expected.iter().zip(&got).map(|(a, b)| (a - b).abs()).fold(0.0, f32::max);
        assert!(worst < 1e-5, "worst difference {worst}");
    }

    fn correlation(a: &[f32], b: &[f32]) -> f64 {
        let n = a.len() as f64;
        let (ma, mb) = (a.iter().map(|&v| f64::from(v)).sum::<f64>() / n, b.iter().map(|&v| f64::from(v)).sum::<f64>() / n);
        let (mut ab, mut aa, mut bb) = (0.0, 0.0, 0.0);
        for (&x, &y) in a.iter().zip(b) {
            let (x, y) = (f64::from(x) - ma, f64::from(y) - mb);
            ab += x * y;
            aa += x * x;
            bb += y * y;
        }
        ab / (aa * bb).sqrt()
    }

    fn read_f32(path: &Path) -> Vec<f32> {
        std::fs::read(path).unwrap().chunks_exact(4).map(|b| f32::from_le_bytes(b.try_into().unwrap())).collect()
    }

    /// The researcher's 75-frame sequence, against their all-TensorRT
    /// reference depth (which matches PyTorch at 0.99994):
    /// - from their normalised inputs (model and history only);
    /// - from the 720p frames, through the resize kernel (the whole path).
    ///
    /// Needs the models and the reference data, so it's ignored by default:
    ///
    /// ```sh
    /// cargo build --release   # engines build in Meteor's own binary
    /// VDA_TEST_DATA=<dir with inputs.f32, frames.u8, ref.f32> \
    /// VDA_TEST_BACKEND=tensorrt cargo test --release -- --ignored --nocapture vda
    /// ```
    #[test]
    #[ignore]
    fn reference_sequence_parity() {
        let data = PathBuf::from(std::env::var("VDA_TEST_DATA").expect("VDA_TEST_DATA"));
        let backend = match std::env::var("VDA_TEST_BACKEND").as_deref() {
            Ok("cuda") => Backend::Cuda,
            _ => Backend::TensorRt,
        };
        // ONNX Runtime for the CUDA backend and METEOR_TENSORRT=ort; native
        // TensorRT finds the venv's libraries itself.
        #[cfg(feature = "onnxruntime")]
        {
            let venv = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/bench-venv/lib");
            let runtime = std::fs::read_dir(&venv)
                .unwrap()
                .flatten()
                .map(|p| p.path().join("site-packages/onnxruntime/capi/libonnxruntime.so.1.30.0"))
                .find(|p| p.exists())
                .expect("ONNX Runtime in target/bench-venv");
            crate::onnx::init(Some(&runtime)).unwrap();
        }
        // Engines build in a child process, which has to be Meteor itself.
        if std::env::var_os("METEOR_BUILDER").is_none() {
            let meteor = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/release/nightfall-meteor");
            // SAFETY: set before any other thread reads the environment.
            unsafe { std::env::set_var("METEOR_BUILDER", meteor) };
        }
        let models = crate::config::default_models_dir();
        let cache = crate::config::cache_dir().join("tensorrt");
        let mut model = VdaModel::load(&models, backend, &cache).unwrap();
        eprintln!("{}", model.description);

        let plane = 3 * WIDTH * HEIGHT;
        let inputs = read_f32(&data.join("inputs.f32"));
        let reference = read_f32(&data.join("ref.f32"));
        let frames = std::fs::read(data.join("frames.u8")).unwrap();
        let count = reference.len() / (WIDTH * HEIGHT);
        let expected = |k: usize| &reference[k * WIDTH * HEIGHT..(k + 1) * WIDTH * HEIGHT];

        let mut correlations = Vec::new();
        let mut model_ms = Vec::new();
        for k in 0..count {
            let (depth, report) = model.infer_normalized(&inputs[k * plane..(k + 1) * plane], k == 0).unwrap();
            assert!(depth.iter().all(|v| v.is_finite()), "frame {k}");
            correlations.push(correlation(&depth, expected(k)));
            if k > 0 {
                model_ms.push(report.model.as_secs_f64() * 1000.0);
            }
        }
        model_ms.sort_by(f64::total_cmp);
        let worst = correlations.iter().copied().fold(1.0, f64::min);
        let mean = correlations.iter().sum::<f64>() / count as f64;
        eprintln!(
            "model inputs: correlation mean {mean:.6}, worst {worst:.6}, last {:.6}; step {:.2} ms median",
            correlations[count - 1],
            model_ms[model_ms.len() / 2]
        );
        assert!(worst > 0.999, "worst-frame correlation {worst}");

        // Whole path from the 720p frames; frame 0 cold-starts on its own.
        model.reset("test");
        let (fw, fh) = DECODE_SIZE;
        let mut correlations = Vec::new();
        let mut timings = Vec::new();
        let mut resets = 0;
        for k in 0..count {
            let rgb = &frames[k * fw * fh * 3..(k + 1) * fw * fh * 3];
            let report = model.infer_rgb(rgb, DECODE_SIZE).unwrap();
            resets += usize::from(report.reset.is_some());
            if k > 0 {
                timings.push([report.prepare, report.model, report.store].map(|d| d.as_secs_f64() * 1000.0));
            }
            correlations.push(correlation(&model.download_depth(report.depth).unwrap(), expected(k)));
        }
        let median = |i: usize| {
            let mut v: Vec<f64> = timings.iter().map(|t| t[i]).collect();
            v.sort_by(f64::total_cmp);
            v[v.len() / 2]
        };
        let worst = correlations.iter().copied().fold(1.0, f64::min);
        let mean = correlations.iter().sum::<f64>() / count as f64;
        eprintln!(
            "720p frames: correlation mean {mean:.6}, worst {worst:.6}; {resets} cold starts; \
             prepare {:.2} ms, model {:.2} ms, store {:.2} ms median",
            median(0),
            median(1),
            median(2)
        );
        assert_eq!(resets, 1, "only the first frame should cold-start");
        assert!(worst > 0.999, "worst-frame correlation {worst}");
    }
}
