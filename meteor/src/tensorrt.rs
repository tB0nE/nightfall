//! TensorRT without ONNX Runtime, through the shim in native/tensorrt.cpp.
//!
//! `libnvinfer` and `libnvonnxparser` are opened at run time, so Meteor
//! builds and runs as a plain proxy without them. They're looked for in:
//!
//! - `tensorrt_dir` in meteor.toml;
//! - the VDA download's folder (`install_dir()`);
//! - the development venv's `tensorrt_libs` (`target/bench-venv`);
//! - the library path, by soname.
//!
//! Running an engine needs only `libnvinfer`; building one also needs this
//! GPU's builder resource (`libnvinfer_builder_resource_smNN`), which
//! TensorRT opens itself from its own folder (its RPATH is `$ORIGIN`).
//!
//! Engines are built from the ONNX file once per model, GPU and TensorRT
//! version, and cached as plans by the caller.

use std::ffi::{CStr, CString, c_char, c_int, c_void};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[repr(C)]
struct RawEngine {
    _private: [u8; 0],
}

type LogFn = extern "C" fn(c_int, *const c_char);

unsafe extern "C" {
    fn trt_init(nvinfer: *const c_char, parser: *const c_char, log: LogFn, err: *mut c_char, err_len: usize) -> i32;
    fn trt_build(
        onnx: *const c_char,
        fp16: c_int,
        opt_level: c_int,
        timing_cache: *const c_char,
        plan: *mut *mut c_void,
        plan_size: *mut usize,
        err: *mut c_char,
        err_len: usize,
    ) -> c_int;
    fn trt_free(plan: *mut c_void);
    fn trt_load(plan: *const c_void, plan_size: usize, err: *mut c_char, err_len: usize) -> *mut RawEngine;
    fn trt_destroy(engine: *mut RawEngine);
    fn trt_io_count(engine: *mut RawEngine) -> i32;
    fn trt_io_name(engine: *mut RawEngine, i: i32) -> *const c_char;
    fn trt_io_is_input(engine: *mut RawEngine, name: *const c_char) -> c_int;
    fn trt_io_dtype(engine: *mut RawEngine, name: *const c_char) -> i32;
    fn trt_io_shape(engine: *mut RawEngine, name: *const c_char, dims: *mut i64, max: i32) -> i32;
    fn trt_set_address(engine: *mut RawEngine, name: *const c_char, address: u64) -> c_int;
    fn trt_enqueue(engine: *mut RawEngine, stream: *mut c_void) -> c_int;
}

/// TensorRT's severities: internal error, error, warning, info, verbose.
extern "C" fn log_message(severity: c_int, message: *const c_char) {
    // SAFETY: TensorRT passes a NUL-terminated string valid for the call.
    let text = unsafe { CStr::from_ptr(message) }.to_string_lossy();
    match severity {
        // The builder reports each tactic it rejects as an error; the build
        // still succeeds with another.
        1 if text.contains("Skipping tactic") => log::debug!("TensorRT: {text}"),
        0 | 1 => log::error!("TensorRT: {text}"),
        2 => log::warn!("TensorRT: {text}"),
        3 => log::debug!("TensorRT: {text}"),
        _ => log::trace!("TensorRT: {text}"),
    }
}

const ERR_LEN: usize = 1024;

fn message(buf: &[u8]) -> String {
    CStr::from_bytes_until_nul(buf).map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

fn c_path(path: &Path) -> Result<CString, String> {
    CString::new(path.as_os_str().as_encoded_bytes()).map_err(|_| format!("{}: NUL in path", path.display()))
}

/// The TensorRT the VDA download installs, and the headers' version.
pub const VERSION: &str = "10.16.1";
const NVINFER: &str = if cfg!(windows) { "nvinfer_10.dll" } else { "libnvinfer.so.10" };
const PARSER: &str = if cfg!(windows) { "nvonnxparser_10.dll" } else { "libnvonnxparser.so.10" };

/// The version once TensorRT has opened. A failure isn't kept, so
/// TensorRT installed later (the VDA download) is found without a restart.
static OPENED: Mutex<Option<String>> = Mutex::new(None);
static CONFIGURED: OnceLock<Option<PathBuf>> = OnceLock::new();

/// Sets `tensorrt_dir` from meteor.toml, before the first init().
pub fn configure(dir: Option<PathBuf>) {
    let _ = CONFIGURED.set(dir);
}

/// Where the VDA download puts TensorRT.
pub fn install_dir() -> PathBuf {
    crate::config::data_dir().join("runtime").join(format!("tensorrt-{VERSION}"))
}

/// Folders that have both libraries, in the order they're tried.
fn candidates() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = CONFIGURED.get().cloned().flatten().into_iter().collect();
    dirs.push(install_dir());
    // target/{debug,release}/nightfall-meteor, or target/release/deps/<test>
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            dirs.push(parent.join("tensorrt"));
        }
        for target in exe.ancestors().skip(1).take(3) {
            #[cfg(windows)]
            {
                dirs.push(target.join("bench-venv/Lib/site-packages/tensorrt_libs"));
            }
            #[cfg(not(windows))]
            {
                let Ok(pythons) = std::fs::read_dir(target.join("bench-venv/lib")) else { continue };
                dirs.extend(pythons.flatten().map(|p| p.path().join("site-packages/tensorrt_libs")));
            }
        }
    }
    dirs.retain(|d| d.join(NVINFER).is_file() && d.join(PARSER).is_file());
    dirs
}

/// Opens TensorRT once it can. Returns its version (for example `10.16.1`).
pub fn init() -> Result<String, String> {
    let mut opened = OPENED.lock().map_err(|_| "TensorRT's lock is poisoned".to_string())?;
    if let Some(version) = opened.as_ref() {
        return Ok(version.clone());
    }
    let result = (|| {
        let mut pairs: Vec<(CString, CString)> = Vec::new();
        for dir in candidates() {
            pairs.push((c_path(&dir.join(NVINFER))?, c_path(&dir.join(PARSER))?));
        }
        pairs.push((CString::new(NVINFER).expect("no NUL"), CString::new(PARSER).expect("no NUL")));
        let mut errors = Vec::new();
        for (nvinfer, parser) in &pairs {
            let mut err = [0u8; ERR_LEN];
            // SAFETY: NUL-terminated names, a log callback that outlives the
            // process, and an error buffer of the stated size.
            let version = unsafe { trt_init(nvinfer.as_ptr(), parser.as_ptr(), log_message, err.as_mut_ptr().cast(), ERR_LEN) };
            if version >= 0 {
                log::info!("TensorRT: {}", nvinfer.to_string_lossy());
                return Ok(format!("{}.{}.{}", version / 10000, version / 100 % 100, version % 100));
            }
            errors.push(message(&err));
        }
        Err(format!("TensorRT not found ({})", errors.join("; ")))
    })();
    if let Ok(version) = &result {
        *opened = Some(version.clone());
    }
    result
}

/// Builder settings, part of the engine's cache key.
pub struct BuildOptions {
    pub fp16: bool,
    pub opt_level: u8,
}

/// Builds an engine in a child process (`nightfall-meteor --build-tensorrt`)
/// and writes it to `plan`. Building in Meteor's own process leaves TensorRT
/// in a state where the VDA step engine then produces non-finite depth
/// (found 2026-10-07; the same plan loaded in a fresh process is fine).
/// A child also gives back the builder's memory when it exits, and a crash
/// in the builder can't take the proxy down.
pub fn build_in_child(onnx: &Path, options: &BuildOptions, plan: &Path, timing_cache: &Path) -> Result<(), String> {
    // Tests run from the test binary, so they point this at Meteor's.
    let exe = match std::env::var_os("METEOR_BUILDER") {
        Some(exe) => exe.into(),
        None => std::env::current_exe().map_err(|e| format!("can't find Meteor's executable: {e}"))?,
    };
    let status = std::process::Command::new(&exe)
        .env("METEOR_PARENT", std::process::id().to_string())
        .arg("--build-tensorrt")
        .arg(onnx)
        .arg(plan)
        .arg(timing_cache)
        .arg(if options.fp16 { "fp16" } else { "fp32" })
        .arg(options.opt_level.to_string())
        .status()
        .map_err(|e| format!("can't start the engine build ({}): {e}", exe.display()))?;
    if !status.success() {
        return Err(format!("the engine build failed ({status})"));
    }
    Ok(())
}

/// The child's side of build_in_child: `<onnx> <plan> <timing cache>
/// <fp16|fp32> <optimisation level>`. Returns the exit code.
pub fn build_command(args: &[String], tensorrt_dir: Option<PathBuf>) -> i32 {
    let [onnx, plan, timing, precision, opt_level] = args else {
        log::error!("--build-tensorrt needs <onnx> <plan> <timing cache> <fp16|fp32> <level>");
        return 2;
    };
    let Ok(opt_level) = opt_level.parse() else {
        log::error!("bad optimisation level {opt_level}");
        return 2;
    };
    configure(tensorrt_dir);
    exit_with_parent();
    let options = BuildOptions { fp16: precision == "fp16", opt_level };
    let plan = Path::new(plan);
    let result = build(Path::new(onnx), &options, Path::new(timing)).and_then(|bytes| {
        let partial = plan.with_extension("partial");
        std::fs::write(&partial, &bytes)
            .and_then(|()| std::fs::rename(&partial, plan))
            .map_err(|e| format!("{}: {e}", plan.display()))
    });
    match result {
        Ok(()) => 0,
        Err(err) => {
            log::error!("{err}");
            1
        }
    }
}

/// A build outliving Meteor would keep the GPU busy for minutes, so the
/// child asks for SIGKILL when its parent goes, and exits if that already
/// happened.
fn exit_with_parent() {
    #[cfg(target_os = "linux")]
    {
        let parent: Option<i32> = std::env::var("METEOR_PARENT").ok().and_then(|p| p.parse().ok());
        // SAFETY: plain syscalls with integer arguments.
        unsafe {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL);
            if parent.is_some_and(|p| libc::getppid() != p) {
                libc::_exit(1);
            }
        }
    }
}

/// Builds a serialized engine from an ONNX file, in this process. Takes
/// minutes for a large model. `timing_cache` is read if present and updated
/// after the build.
fn build(onnx: &Path, options: &BuildOptions, timing_cache: &Path) -> Result<Vec<u8>, String> {
    init()?;
    let onnx = c_path(onnx)?;
    let cache = c_path(timing_cache)?;
    let mut plan: *mut c_void = std::ptr::null_mut();
    let mut size = 0usize;
    let mut err = [0u8; ERR_LEN];
    // SAFETY: NUL-terminated paths, out-pointers to locals, and an error
    // buffer of the stated size. The shim allocates the plan with malloc.
    let rc = unsafe {
        trt_build(
            onnx.as_ptr(),
            c_int::from(options.fp16),
            c_int::from(options.opt_level),
            cache.as_ptr(),
            &mut plan,
            &mut size,
            err.as_mut_ptr().cast(),
            ERR_LEN,
        )
    };
    if rc != 0 {
        return Err(message(&err));
    }
    // SAFETY: the shim returned a buffer of `size` bytes, ours to free once.
    let bytes = unsafe { std::slice::from_raw_parts(plan.cast::<u8>(), size).to_vec() };
    unsafe { trt_free(plan) };
    Ok(bytes)
}

/// One of an engine's inputs or outputs.
#[derive(Debug, Clone, PartialEq)]
pub struct Tensor {
    pub name: String,
    pub input: bool,
    /// TensorRT's DataType: 0 is f32, 1 is f16.
    pub dtype: i32,
    pub shape: Vec<i64>,
}

/// A loaded engine with one execution context.
pub struct Engine {
    raw: *mut RawEngine,
    pub tensors: Vec<Tensor>,
    names: Vec<CString>,
}

// SAFETY: the engine is used from one thread at a time (the depth thread),
// with the CUDA context pushed.
unsafe impl Send for Engine {}

impl Engine {
    /// Loads a serialized engine. Needs the CUDA context current.
    pub fn load(plan: &[u8]) -> Result<Engine, String> {
        init()?;
        let mut err = [0u8; ERR_LEN];
        // SAFETY: the plan outlives the call; TensorRT copies what it needs.
        let raw = unsafe { trt_load(plan.as_ptr().cast(), plan.len(), err.as_mut_ptr().cast(), ERR_LEN) };
        if raw.is_null() {
            return Err(message(&err));
        }
        let mut engine = Engine { raw, tensors: Vec::new(), names: Vec::new() };
        // SAFETY: raw is a live engine; names point into it while it lives.
        unsafe {
            for i in 0..trt_io_count(raw) {
                let name = CStr::from_ptr(trt_io_name(raw, i)).to_owned();
                let mut dims = [0i64; 8];
                let rank = trt_io_shape(raw, name.as_ptr(), dims.as_mut_ptr(), dims.len() as i32).clamp(0, 8);
                engine.tensors.push(Tensor {
                    name: name.to_string_lossy().into_owned(),
                    input: trt_io_is_input(raw, name.as_ptr()) == 1,
                    dtype: trt_io_dtype(raw, name.as_ptr()),
                    shape: dims[..rank as usize].to_vec(),
                });
                engine.names.push(name);
            }
        }
        Ok(engine)
    }

    pub fn tensor(&self, name: &str) -> Option<&Tensor> {
        self.tensors.iter().find(|t| t.name == name)
    }

    /// Points a tensor at GPU memory; it stays bound for later runs.
    pub fn set_address(&mut self, name: &str, address: u64) -> Result<(), String> {
        let index = self.tensors.iter().position(|t| t.name == name).ok_or_else(|| format!("no tensor {name}"))?;
        // SAFETY: a name of this engine; the caller keeps the memory alive
        // while the engine may run on it.
        let rc = unsafe { trt_set_address(self.raw, self.names[index].as_ptr(), address) };
        if rc == 0 { Ok(()) } else { Err(format!("can't bind {name}")) }
    }

    /// Queues one run on `stream`. Needs the CUDA context current and every
    /// tensor bound.
    pub fn enqueue(&mut self, stream: *mut c_void) -> Result<(), String> {
        // SAFETY: a live engine; the caller guarantees the bindings.
        let rc = unsafe { trt_enqueue(self.raw, stream) };
        if rc == 0 { Ok(()) } else { Err("TensorRT couldn't queue the run (see the TensorRT log)".into()) }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: our engine, destroyed once.
        unsafe { trt_destroy(self.raw) };
    }
}
