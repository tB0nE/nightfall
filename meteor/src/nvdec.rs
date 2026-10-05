//! Hardware video decoding with NVDEC, called directly through the NVIDIA
//! driver's libraries (`libcuda`, `libnvcuvid`), loaded at run time.
//!
//! - Low latency: each frame goes to NVIDIA's bitstream parser marked
//!   CUVID_PKT_ENDOFPICTURE, with no display delay, so the frame is decoded
//!   and handed back inside the same call (no waiting for the next frame,
//!   which is what made the ffmpeg child process a frame late).
//! - Frames are decoded at full size and reduced to the model's input with
//!   the Quest's 4x4 footprint average, so host depth sees the same input as
//!   on-device depth (NVDEC's own scaler takes one sample per pixel, which
//!   aliases text and fine detail).
//! - The frame number travels through the parser as the timestamp, so each
//!   output names its exact frame.
//! - GPU output (the default): a small CUDA kernel
//!   (`kernels/nv12_to_tensor.cu`) turns the decoded frame straight into the
//!   model's input tensor in GPU memory, which ONNX Runtime reads in place.
//!   Nothing goes through the CPU. CPU output (RGB24) remains for when the
//!   kernel can't load.
//!
//! Struct layouts follow NVIDIA's nv-codec-headers (`dynlink_nvcuvid.h`,
//! `dynlink_cuviddec.h`, `dynlink_cuda.h`; MIT licensed). `c_ulong` is the
//! headers' `tcu_ulong`.

use std::ffi::{c_char, c_int, c_uint, c_ulong, c_void};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};

use libloading::Library;

use crate::stream_info::Codec;

type CuResult = c_int;
pub(crate) type CuContext = *mut c_void;
pub(crate) type CuDevicePtr = u64;

const CUVID_PKT_TIMESTAMP: c_ulong = 0x02;
const CUVID_PKT_ENDOFPICTURE: c_ulong = 0x08;
const CODEC_H264: c_int = 4;
const CODEC_HEVC: c_int = 8;
const CODEC_AV1: c_int = 11;
const SURFACE_NV12: c_int = 0;
const SURFACE_P016: c_int = 1;
const CREATE_PREFER_CUVID: c_ulong = 0x04;
const MEMORY_HOST: c_int = 1;
const MEMORY_DEVICE: c_int = 2;

#[repr(C)]
struct VideoFormat {
    codec: c_int,
    frame_rate: [c_uint; 2],
    progressive_sequence: u8,
    bit_depth_luma_minus8: u8,
    bit_depth_chroma_minus8: u8,
    min_num_decode_surfaces: u8,
    coded_width: c_uint,
    coded_height: c_uint,
    display_area: [c_int; 4], // left, top, right, bottom
    chroma_format: c_int,
    bitrate: c_uint,
    display_aspect_ratio: [c_int; 2],
    /// video_format:3, video_full_range_flag:1, reserved:4
    signal_bits: u8,
    color_primaries: u8,
    transfer_characteristics: u8,
    matrix_coefficients: u8,
    seqhdr_data_length: c_uint,
}

#[repr(C)]
struct SourceDataPacket {
    flags: c_ulong,
    payload_size: c_ulong,
    payload: *const u8,
    timestamp: i64,
}

#[repr(C)]
struct ParserDispInfo {
    picture_index: c_int,
    progressive_frame: c_int,
    top_field_first: c_int,
    repeat_first_field: c_int,
    timestamp: i64,
}

type SequenceCallback = unsafe extern "C" fn(*mut c_void, *mut VideoFormat) -> c_int;
type DecodeCallback = unsafe extern "C" fn(*mut c_void, *mut c_void) -> c_int;
type DisplayCallback = unsafe extern "C" fn(*mut c_void, *mut ParserDispInfo) -> c_int;

#[repr(C)]
struct ParserParams {
    codec_type: c_int,
    max_num_decode_surfaces: c_uint,
    clock_rate: c_uint,
    error_threshold: c_uint,
    max_display_delay: c_uint,
    bitfields: c_uint, // bAnnexb:1, bMemoryOptimize:1, reserved:30
    reserved1: [c_uint; 4],
    user_data: *mut c_void,
    sequence_callback: Option<SequenceCallback>,
    decode_picture: Option<DecodeCallback>,
    display_picture: Option<DisplayCallback>,
    get_operating_point: *mut c_void,
    get_sei_msg: *mut c_void,
    reserved2: [*mut c_void; 5],
    ext_video_info: *mut c_void,
}

#[repr(C)]
struct DecodeCreateInfo {
    width: c_ulong,
    height: c_ulong,
    num_decode_surfaces: c_ulong,
    codec_type: c_int,
    chroma_format: c_int,
    creation_flags: c_ulong,
    bit_depth_minus8: c_ulong,
    intra_decode_only: c_ulong,
    max_width: c_ulong,
    max_height: c_ulong,
    reserved1: c_ulong,
    display_area: [i16; 4],
    output_format: c_int,
    deinterlace_mode: c_int,
    target_width: c_ulong,
    target_height: c_ulong,
    num_output_surfaces: c_ulong,
    vid_lock: *mut c_void,
    target_rect: [i16; 4],
    enable_histogram: c_ulong,
    reserved2: [c_ulong; 4],
}

#[repr(C)]
struct ProcParams {
    progressive_frame: c_int,
    second_field: c_int,
    top_field_first: c_int,
    unpaired_field: c_int,
    reserved_flags: c_uint,
    reserved_zero: c_uint,
    raw_input_dptr: u64,
    raw_input_pitch: c_uint,
    raw_input_format: c_uint,
    raw_output_dptr: u64,
    raw_output_pitch: c_uint,
    reserved1: c_uint,
    output_stream: *mut c_void,
    reserved: [c_uint; 46],
    histogram_dptr: *mut u64,
    reserved2: [*mut c_void; 1],
}

#[repr(C)]
struct Memcpy2D {
    src_x_in_bytes: usize,
    src_y: usize,
    src_memory_type: c_int,
    src_host: *const c_void,
    src_device: CuDevicePtr,
    src_array: *mut c_void,
    src_pitch: usize,
    dst_x_in_bytes: usize,
    dst_y: usize,
    dst_memory_type: c_int,
    dst_host: *mut c_void,
    dst_device: CuDevicePtr,
    dst_array: *mut c_void,
    dst_pitch: usize,
    width_in_bytes: usize,
    height: usize,
}

/// The driver entry points we use (also used by gpu_post.rs).
pub(crate) struct Api {
    _cuda: Library,
    _cuvid: Library,
    pub(crate) cu_init: unsafe extern "C" fn(c_uint) -> CuResult,
    pub(crate) cu_device_get: unsafe extern "C" fn(*mut c_int, c_int) -> CuResult,
    pub(crate) cu_primary_ctx_retain: unsafe extern "C" fn(*mut CuContext, c_int) -> CuResult,
    pub(crate) cu_ctx_push: unsafe extern "C" fn(CuContext) -> CuResult,
    pub(crate) cu_ctx_pop: unsafe extern "C" fn(*mut CuContext) -> CuResult,
    cu_memcpy_2d: unsafe extern "C" fn(*const Memcpy2D) -> CuResult,
    pub(crate) cu_memcpy_dtoh: unsafe extern "C" fn(*mut c_void, CuDevicePtr, usize) -> CuResult,
    #[cfg_attr(not(test), allow(dead_code))] // used by gpu_post's tests
    pub(crate) cu_memcpy_htod: unsafe extern "C" fn(CuDevicePtr, *const c_void, usize) -> CuResult,
    pub(crate) cu_mem_alloc: unsafe extern "C" fn(*mut CuDevicePtr, usize) -> CuResult,
    pub(crate) cu_mem_free: unsafe extern "C" fn(CuDevicePtr) -> CuResult,
    pub(crate) cu_module_load_data: unsafe extern "C" fn(*mut *mut c_void, *const c_void) -> CuResult,
    pub(crate) cu_module_get_function: unsafe extern "C" fn(*mut *mut c_void, *mut c_void, *const c_char) -> CuResult,
    pub(crate) cu_launch_kernel: unsafe extern "C" fn(
        *mut c_void,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        c_uint,
        *mut c_void,
        *mut *mut c_void,
        *mut *mut c_void,
    ) -> CuResult,
    pub(crate) cu_ctx_synchronize: unsafe extern "C" fn() -> CuResult,
    create_parser: unsafe extern "C" fn(*mut *mut c_void, *mut ParserParams) -> CuResult,
    parse_data: unsafe extern "C" fn(*mut c_void, *mut SourceDataPacket) -> CuResult,
    destroy_parser: unsafe extern "C" fn(*mut c_void) -> CuResult,
    create_decoder: unsafe extern "C" fn(*mut *mut c_void, *mut DecodeCreateInfo) -> CuResult,
    destroy_decoder: unsafe extern "C" fn(*mut c_void) -> CuResult,
    decode_picture: unsafe extern "C" fn(*mut c_void, *mut c_void) -> CuResult,
    map_frame: unsafe extern "C" fn(*mut c_void, c_int, *mut u64, *mut c_uint, *mut ProcParams) -> CuResult,
    unmap_frame: unsafe extern "C" fn(*mut c_void, u64) -> CuResult,
}

static API: OnceLock<Result<Api, String>> = OnceLock::new();

pub(crate) fn api() -> Result<&'static Api, String> {
    API.get_or_init(load_api).as_ref().map_err(Clone::clone)
}

fn load_api() -> Result<Api, String> {
    let (cuda_name, cuvid_name) =
        if cfg!(windows) { ("nvcuda.dll", "nvcuvid.dll") } else { ("libcuda.so.1", "libnvcuvid.so.1") };
    // SAFETY: the NVIDIA driver libraries; loading runs their initializers.
    let cuda = unsafe { Library::new(cuda_name) }.map_err(|e| format!("{cuda_name}: {e}"))?;
    let cuvid = unsafe { Library::new(cuvid_name) }.map_err(|e| format!("{cuvid_name}: {e}"))?;
    macro_rules! sym {
        ($lib:expr, $name:literal) => {
            // SAFETY: the signature matches the nv-codec-headers declaration.
            *unsafe { $lib.get($name) }.map_err(|e| format!("{}: {e}", String::from_utf8_lossy($name)))?
        };
    }
    let api = Api {
        cu_init: sym!(cuda, b"cuInit"),
        cu_device_get: sym!(cuda, b"cuDeviceGet"),
        cu_primary_ctx_retain: sym!(cuda, b"cuDevicePrimaryCtxRetain"),
        cu_ctx_push: sym!(cuda, b"cuCtxPushCurrent_v2"),
        cu_ctx_pop: sym!(cuda, b"cuCtxPopCurrent_v2"),
        cu_memcpy_2d: sym!(cuda, b"cuMemcpy2D_v2"),
        cu_memcpy_dtoh: sym!(cuda, b"cuMemcpyDtoH_v2"),
        cu_memcpy_htod: sym!(cuda, b"cuMemcpyHtoD_v2"),
        cu_mem_alloc: sym!(cuda, b"cuMemAlloc_v2"),
        cu_mem_free: sym!(cuda, b"cuMemFree_v2"),
        cu_module_load_data: sym!(cuda, b"cuModuleLoadData"),
        cu_module_get_function: sym!(cuda, b"cuModuleGetFunction"),
        cu_launch_kernel: sym!(cuda, b"cuLaunchKernel"),
        cu_ctx_synchronize: sym!(cuda, b"cuCtxSynchronize"),
        create_parser: sym!(cuvid, b"cuvidCreateVideoParser"),
        parse_data: sym!(cuvid, b"cuvidParseVideoData"),
        destroy_parser: sym!(cuvid, b"cuvidDestroyVideoParser"),
        create_decoder: sym!(cuvid, b"cuvidCreateDecoder"),
        destroy_decoder: sym!(cuvid, b"cuvidDestroyDecoder"),
        decode_picture: sym!(cuvid, b"cuvidDecodePicture"),
        map_frame: sym!(cuvid, b"cuvidMapVideoFrame64"),
        unmap_frame: sym!(cuvid, b"cuvidUnmapVideoFrame64"),
        _cuda: cuda,
        _cuvid: cuvid,
    };
    Ok(api)
}

pub(crate) fn check(what: &str, rc: CuResult) -> Result<(), String> {
    if rc == 0 { Ok(()) } else { Err(format!("{what} failed (CUDA error {rc})")) }
}

/// Everything the parser callbacks touch. Boxed, so its address is stable
/// for the parser's user-data pointer.
struct State {
    api: &'static Api,
    decoder: *mut c_void,
    coded: (u32, u32),
    /// The decoded frame's size (the stream's display area).
    surface: (usize, usize),
    /// The model's input size.
    target: (usize, usize),
    bit_depth_minus8: u8,
    full_range: bool,
    matrix: u8,
    /// NV12 (or the high bytes of P016) copied back from the GPU.
    nv12: Vec<u8>,
    p016: Vec<u8>,
    /// The NV12-to-tensor kernel, when frames stay on the GPU.
    kernel: Option<*mut c_void>,
    pool: Option<Arc<TensorPool>>,
    output: Option<(i64, Pixels)>,
    error: Option<String>,
}

/// A decoded frame at the target size.
pub enum Pixels {
    /// Packed RGB24 in system memory.
    Rgb(Vec<u8>),
    /// The model's input tensor (planar RGB floats, 0..1) in GPU memory.
    Gpu(GpuTensor),
}

/// GPU buffers for input tensors, reused frame to frame. Freed when the
/// decoder and every tensor from it are gone.
pub struct TensorPool {
    api: &'static Api,
    ctx: CuContext,
    bytes: usize,
    free: Mutex<Vec<CuDevicePtr>>,
}

// SAFETY: the context pointer is only used to push it around driver calls.
unsafe impl Send for TensorPool {}
unsafe impl Sync for TensorPool {}

impl TensorPool {
    fn take(&self) -> Result<CuDevicePtr, String> {
        if let Some(ptr) = self.free.lock().ok().and_then(|mut f| f.pop()) {
            return Ok(ptr);
        }
        let mut ptr = 0;
        // SAFETY: allocation in the (current) primary context.
        check("cuMemAlloc", unsafe { (self.api.cu_mem_alloc)(&mut ptr, self.bytes) })?;
        Ok(ptr)
    }
}

impl Drop for TensorPool {
    fn drop(&mut self) {
        let free = self.free.get_mut().map(std::mem::take).unwrap_or_default();
        // SAFETY: no tensor refers to these any more (each holds the pool).
        unsafe {
            (self.api.cu_ctx_push)(self.ctx);
            for ptr in free {
                (self.api.cu_mem_free)(ptr);
            }
            let mut popped = ptr::null_mut();
            (self.api.cu_ctx_pop)(&mut popped);
        }
    }
}

/// One input tensor in GPU memory; goes back to its pool when dropped.
pub struct GpuTensor {
    pub ptr: CuDevicePtr,
    pub width: usize,
    pub height: usize,
    pool: Arc<TensorPool>,
}

impl GpuTensor {
    /// Copies the tensor back as packed RGB24 (for snapshots).
    pub fn download_rgb(&self) -> Result<Vec<u8>, String> {
        let plane = self.width * self.height;
        let mut floats = vec![0f32; plane * 3];
        let api = self.pool.api;
        // SAFETY: floats holds exactly the tensor's bytes.
        let rc = unsafe {
            (api.cu_ctx_push)(self.pool.ctx);
            let rc = (api.cu_memcpy_dtoh)(floats.as_mut_ptr().cast(), self.ptr, plane * 3 * 4);
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
            rc
        };
        check("cuMemcpyDtoH", rc)?;
        let mut rgb = Vec::with_capacity(plane * 3);
        for i in 0..plane {
            for c in 0..3 {
                rgb.push((floats[c * plane + i] * 255.0).round() as u8);
            }
        }
        Ok(rgb)
    }
}

impl Drop for GpuTensor {
    fn drop(&mut self) {
        if let Ok(mut free) = self.pool.free.lock() {
            free.push(self.ptr);
        }
    }
}

pub struct NvDecoder {
    api: &'static Api,
    ctx: CuContext,
    parser: *mut c_void,
    state: Box<State>,
}

// SAFETY: the CUDA context is pushed around every call, so the decoder may
// move between threads; it is only ever used by one thread at a time.
unsafe impl Send for NvDecoder {}

impl NvDecoder {
    /// `gpu_output`: hand back GPU tensors (Pixels::Gpu) instead of RGB24.
    pub fn new(codec: Codec, width: usize, height: usize, gpu_output: bool) -> Result<NvDecoder, String> {
        let codec_type = match codec {
            Codec::H264 => CODEC_H264,
            Codec::Hevc => CODEC_HEVC,
            Codec::Av1 => CODEC_AV1,
            Codec::PyroWave => return Err("PyroWave can't be decoded with NVDEC".into()),
        };
        let (api, ctx) = primary_context()?;
        let target = (width & !1, height & !1);
        let kernel = if gpu_output {
            match load_kernel(api, ctx) {
                Ok(kernel) => Some(kernel),
                Err(err) => {
                    log::warn!("GPU frame conversion unavailable ({err}); converting on the CPU");
                    None
                }
            }
        } else {
            None
        };
        let pool = kernel.map(|_| {
            Arc::new(TensorPool { api, ctx, bytes: target.0 * target.1 * 3 * 4, free: Mutex::new(Vec::new()) })
        });
        let mut state = Box::new(State {
            api,
            decoder: ptr::null_mut(),
            coded: (0, 0),
            surface: (0, 0),
            target,
            bit_depth_minus8: 0,
            full_range: false,
            matrix: 1,
            nv12: Vec::new(),
            p016: Vec::new(),
            kernel,
            pool,
            output: None,
            error: None,
        });
        let mut params = ParserParams {
            codec_type,
            max_num_decode_surfaces: 1, // raised by the sequence callback
            clock_rate: 0,
            error_threshold: 0,
            max_display_delay: 0,
            bitfields: 0,
            reserved1: [0; 4],
            user_data: (&mut *state as *mut State).cast(),
            sequence_callback: Some(on_sequence),
            decode_picture: Some(on_decode),
            display_picture: Some(on_display),
            get_operating_point: ptr::null_mut(),
            get_sei_msg: ptr::null_mut(),
            reserved2: [ptr::null_mut(); 5],
            ext_video_info: ptr::null_mut(),
        };
        let mut parser = ptr::null_mut();
        // SAFETY: params outlives the call; the state it points to is boxed
        // and lives as long as the parser.
        check("cuvidCreateVideoParser", unsafe { (api.create_parser)(&mut parser, &mut params) })?;
        Ok(NvDecoder { api, ctx, parser, state })
    }

    /// Decodes one complete frame. Returns it at the target size, or None if
    /// the decoder produced nothing for it (for example a frame before the
    /// first keyframe).
    pub fn decode(&mut self, data: &[u8], frame_number: u32) -> Result<Option<Pixels>, String> {
        let mut packet = SourceDataPacket {
            flags: CUVID_PKT_ENDOFPICTURE | CUVID_PKT_TIMESTAMP,
            payload_size: data.len() as c_ulong,
            payload: data.as_ptr(),
            timestamp: i64::from(frame_number),
        };
        self.state.output = None;
        // SAFETY: the context is pushed for the duration of the parse; the
        // callbacks run synchronously inside it on this thread.
        let rc = unsafe {
            (self.api.cu_ctx_push)(self.ctx);
            let rc = (self.api.parse_data)(self.parser, &mut packet);
            let mut popped = ptr::null_mut();
            (self.api.cu_ctx_pop)(&mut popped);
            rc
        };
        if let Some(err) = self.state.error.take() {
            return Err(err);
        }
        check("cuvidParseVideoData", rc)?;
        Ok(match self.state.output.take() {
            Some((ts, frame)) if ts == i64::from(frame_number) => Some(frame),
            Some((ts, _)) => {
                log::warn!("NVDEC returned frame {ts} while decoding {frame_number}; dropped");
                None
            }
            None => None,
        })
    }
}

impl Drop for NvDecoder {
    fn drop(&mut self) {
        // SAFETY: destroy the parser before the decoder and the state it uses.
        unsafe {
            (self.api.cu_ctx_push)(self.ctx);
            (self.api.destroy_parser)(self.parser);
            if !self.state.decoder.is_null() {
                (self.api.destroy_decoder)(self.state.decoder);
            }
            let mut popped = ptr::null_mut();
            (self.api.cu_ctx_pop)(&mut popped);
        }
    }
}

/// New stream format: (re)create the decoder. Returns the number of decode
/// surfaces for the parser, or 0 on failure.
unsafe extern "C" fn on_sequence(user: *mut c_void, format: *mut VideoFormat) -> c_int {
    // SAFETY: user is our boxed State; format is valid for the call.
    let (state, format) = unsafe { (&mut *user.cast::<State>(), &*format) };
    let surfaces = u32::from(format.min_num_decode_surfaces).max(1) + 2;
    let coded = (format.coded_width, format.coded_height);
    if !state.decoder.is_null() {
        if coded == state.coded && format.bit_depth_luma_minus8 == state.bit_depth_minus8 {
            return surfaces as c_int;
        }
        // SAFETY: the old decoder isn't in use (we're inside the parser).
        unsafe { (state.api.destroy_decoder)(state.decoder) };
        state.decoder = ptr::null_mut();
    }
    // Decode at full size (no NVDEC scaling); copy_frame reduces it.
    let area = format.display_area;
    let tw = ((area[2] - area[0]).max(2) as usize) & !1;
    let th = ((area[3] - area[1]).max(2) as usize) & !1;
    let mut info = DecodeCreateInfo {
        width: c_ulong::from(format.coded_width),
        height: c_ulong::from(format.coded_height),
        num_decode_surfaces: c_ulong::from(surfaces),
        codec_type: format.codec,
        chroma_format: format.chroma_format,
        creation_flags: CREATE_PREFER_CUVID,
        bit_depth_minus8: c_ulong::from(format.bit_depth_luma_minus8),
        intra_decode_only: 0,
        max_width: c_ulong::from(format.coded_width),
        max_height: c_ulong::from(format.coded_height),
        reserved1: 0,
        display_area: [area[0] as i16, area[1] as i16, area[2] as i16, area[3] as i16],
        output_format: if format.bit_depth_luma_minus8 > 0 { SURFACE_P016 } else { SURFACE_NV12 },
        deinterlace_mode: 0, // weave: the stream is progressive
        target_width: tw as c_ulong,
        target_height: th as c_ulong,
        num_output_surfaces: 2,
        vid_lock: ptr::null_mut(),
        target_rect: [0; 4],
        enable_histogram: 0,
        reserved2: [0; 4],
    };
    // SAFETY: info is fully initialised; the context is current.
    let rc = unsafe { (state.api.create_decoder)(&mut state.decoder, &mut info) };
    if rc != 0 {
        state.error = Some(format!(
            "cuvidCreateDecoder failed (CUDA error {rc}) for {}x{} codec {}",
            coded.0, coded.1, format.codec
        ));
        state.decoder = ptr::null_mut();
        return 0;
    }
    state.coded = coded;
    state.surface = (tw, th);
    state.bit_depth_minus8 = format.bit_depth_luma_minus8;
    state.full_range = format.signal_bits & 0x08 != 0;
    state.matrix = format.matrix_coefficients;
    log::info!(
        "NVDEC: {}x{} codec {} {}-bit, decoding {tw}x{th}, reduced to {}x{} (matrix {}, {} range)",
        coded.0,
        coded.1,
        format.codec,
        8 + format.bit_depth_luma_minus8,
        state.target.0,
        state.target.1,
        state.matrix,
        if state.full_range { "full" } else { "limited" }
    );
    surfaces as c_int
}

unsafe extern "C" fn on_decode(user: *mut c_void, pic_params: *mut c_void) -> c_int {
    // SAFETY: user is our boxed State.
    let state = unsafe { &mut *user.cast::<State>() };
    if state.decoder.is_null() {
        return 0;
    }
    // SAFETY: pic_params comes straight from the parser.
    let rc = unsafe { (state.api.decode_picture)(state.decoder, pic_params) };
    if rc != 0 {
        state.error = Some(format!("cuvidDecodePicture failed (CUDA error {rc})"));
        return 0;
    }
    1
}

unsafe extern "C" fn on_display(user: *mut c_void, info: *mut ParserDispInfo) -> c_int {
    // SAFETY: user is our boxed State; info is null at end of stream.
    let state = unsafe { &mut *user.cast::<State>() };
    let Some(info) = (unsafe { info.as_ref() }) else { return 1 };
    match copy_frame(state, info) {
        Ok(frame) => {
            state.output = Some((info.timestamp, frame));
            1
        }
        Err(err) => {
            state.error = Some(err);
            0
        }
    }
}

fn copy_frame(state: &mut State, info: &ParserDispInfo) -> Result<Pixels, String> {
    let api = state.api;
    let mut proc_params = ProcParams {
        progressive_frame: info.progressive_frame,
        second_field: 0,
        top_field_first: info.top_field_first,
        unpaired_field: 0,
        reserved_flags: 0,
        reserved_zero: 0,
        raw_input_dptr: 0,
        raw_input_pitch: 0,
        raw_input_format: 0,
        raw_output_dptr: 0,
        raw_output_pitch: 0,
        reserved1: 0,
        output_stream: ptr::null_mut(),
        reserved: [0; 46],
        histogram_dptr: ptr::null_mut(),
        reserved2: [ptr::null_mut(); 1],
    };
    let mut device_ptr: u64 = 0;
    let mut pitch: c_uint = 0;
    // SAFETY: maps a decoded surface; unmapped below on every path.
    check("cuvidMapVideoFrame", unsafe {
        (api.map_frame)(state.decoder, info.picture_index, &mut device_ptr, &mut pitch, &mut proc_params)
    })?;
    let (w, h) = state.target;
    let (sw, sh) = state.surface;
    if let (Some(kernel), Some(pool), 0) = (state.kernel, state.pool.clone(), state.bit_depth_minus8) {
        let coefficients = Coefficients::new(state.matrix, state.full_range);
        let frame = (device_ptr, pitch as usize, state.surface);
        let converted = convert_on_gpu(api, kernel, &pool, frame, state.target, &coefficients);
        // SAFETY: unmapping the surface mapped above, after the kernel finished.
        unsafe { (api.unmap_frame)(state.decoder, device_ptr) };
        return converted.map(|ptr| Pixels::Gpu(GpuTensor { ptr, width: w, height: h, pool }));
    }
    let bytes_per_sample = if state.bit_depth_minus8 > 0 { 2 } else { 1 };
    // Luma rows, then half as many chroma rows, contiguous at this pitch
    // (the chroma plane starts at pitch * height for an even height).
    let rows = sh + sh / 2;
    let row_bytes = sw * bytes_per_sample;
    let host = if bytes_per_sample == 1 { &mut state.nv12 } else { &mut state.p016 };
    host.resize(row_bytes * rows, 0);
    let copy = Memcpy2D {
        src_x_in_bytes: 0,
        src_y: 0,
        src_memory_type: MEMORY_DEVICE,
        src_host: ptr::null(),
        src_device: device_ptr,
        src_array: ptr::null_mut(),
        src_pitch: pitch as usize,
        dst_x_in_bytes: 0,
        dst_y: 0,
        dst_memory_type: MEMORY_HOST,
        dst_host: host.as_mut_ptr().cast(),
        dst_device: 0,
        dst_array: ptr::null_mut(),
        dst_pitch: row_bytes,
        width_in_bytes: row_bytes,
        height: rows,
    };
    // SAFETY: host holds row_bytes * rows bytes; the source is the mapped frame.
    let copied = check("cuMemcpy2D", unsafe { (api.cu_memcpy_2d)(&copy) });
    // SAFETY: unmapping the surface mapped above.
    unsafe { (api.unmap_frame)(state.decoder, device_ptr) };
    copied?;
    if bytes_per_sample == 2 {
        // P016: keep the high byte of each sample. HDR (PQ) frames will look
        // washed out until tone mapping is added; see the plan's HDR risk.
        state.nv12.clear();
        state.nv12.extend(state.p016.chunks_exact(2).map(|s| s[1]));
    }
    Ok(Pixels::Rgb(nv12_box_to_rgb(&state.nv12, sw, sh, w, h, state.matrix, state.full_range)))
}

const KERNEL_PTX: &str = concat!(include_str!("../kernels/nv12_to_tensor.ptx"), "\0");

fn load_kernel(api: &Api, ctx: CuContext) -> Result<*mut c_void, String> {
    Ok(load_functions(api, ctx, KERNEL_PTX, &[c"nv12_to_tensor"])?[0])
}

/// The device's primary context (the one ONNX Runtime uses), retained.
pub(crate) fn primary_context() -> Result<(&'static Api, CuContext), String> {
    let api = api()?;
    let mut ctx: CuContext = ptr::null_mut();
    let mut device: c_int = 0;
    // SAFETY: plain driver calls with out-pointers to locals.
    unsafe {
        check("cuInit", (api.cu_init)(0))?;
        check("cuDeviceGet", (api.cu_device_get)(&mut device, 0))?;
        check("cuDevicePrimaryCtxRetain", (api.cu_primary_ctx_retain)(&mut ctx, device))?;
    }
    Ok((api, ctx))
}

/// Loads a NUL-terminated PTX module and looks up kernels in it. The module
/// stays loaded for the life of the process (a few KB).
pub(crate) fn load_functions(
    api: &Api,
    ctx: CuContext,
    ptx: &str,
    names: &[&std::ffi::CStr],
) -> Result<Vec<*mut c_void>, String> {
    let mut module = ptr::null_mut();
    // SAFETY: the PTX is NUL-terminated; the context is pushed around the calls.
    unsafe {
        (api.cu_ctx_push)(ctx);
        let result = check("cuModuleLoadData", (api.cu_module_load_data)(&mut module, ptx.as_ptr().cast())).and_then(|()| {
            names
                .iter()
                .map(|name| {
                    let mut function = ptr::null_mut();
                    check("cuModuleGetFunction", (api.cu_module_get_function)(&mut function, module, name.as_ptr()))
                        .map(|()| function)
                })
                .collect()
        });
        let mut popped = ptr::null_mut();
        (api.cu_ctx_pop)(&mut popped);
        result
    }
}

/// Queues a kernel on the default stream. The caller makes the context current.
///
/// # Safety
/// `params` must point at values matching the kernel's parameters.
pub(crate) unsafe fn launch(
    api: &Api,
    function: *mut c_void,
    grid: (c_uint, c_uint),
    block: (c_uint, c_uint),
    params: &mut [*mut c_void],
) -> Result<(), String> {
    // SAFETY: forwarded to the caller.
    let rc = unsafe {
        (api.cu_launch_kernel)(
            function,
            grid.0,
            grid.1,
            1,
            block.0,
            block.1,
            1,
            0,
            ptr::null_mut(),
            params.as_mut_ptr(),
            ptr::null_mut(),
        )
    };
    check("cuLaunchKernel", rc)
}

/// Runs the kernel on a mapped NV12 surface (pointer, pitch, size) into a
/// pooled tensor buffer of the target size and waits for it, so the surface
/// can be unmapped and the tensor used.
fn convert_on_gpu(
    api: &Api,
    kernel: *mut c_void,
    pool: &TensorPool,
    (nv12, pitch, surface): (CuDevicePtr, usize, (usize, usize)),
    (w, h): (usize, usize),
    c: &Coefficients,
) -> Result<CuDevicePtr, String> {
    let out = pool.take()?;
    let mut src = nv12;
    let mut pitch = pitch as c_int;
    let (mut src_width, mut src_height) = (surface.0 as c_int, surface.1 as c_int);
    let (mut width, mut height) = (w as c_int, h as c_int);
    let mut floats = [c.y_offset, c.y_scale, c.c_scale, c.r_v, c.g_u, c.g_v, c.b_u];
    let mut dst = out;
    let mut params: Vec<*mut c_void> = vec![
        (&mut src as *mut CuDevicePtr).cast(),
        (&mut pitch as *mut c_int).cast(),
        (&mut src_width as *mut c_int).cast(),
        (&mut src_height as *mut c_int).cast(),
        (&mut width as *mut c_int).cast(),
        (&mut height as *mut c_int).cast(),
    ];
    params.extend(floats.iter_mut().map(|f| (f as *mut f32).cast::<c_void>()));
    params.push((&mut dst as *mut CuDevicePtr).cast());
    const BLOCK: c_uint = 16;
    let grid = |n: usize| (n as c_uint).div_ceil(BLOCK);
    // SAFETY: the parameters match the kernel's signature; the context is
    // current (we're inside the parser callback).
    let launched = check("cuLaunchKernel", unsafe {
        (api.cu_launch_kernel)(
            kernel,
            grid(w),
            grid(h),
            1,
            BLOCK,
            BLOCK,
            1,
            0,
            ptr::null_mut(),
            params.as_mut_ptr(),
            ptr::null_mut(),
        )
    })
    .and_then(|()| check("cuCtxSynchronize", unsafe { (api.cu_ctx_synchronize)() }));
    if launched.is_err() && let Ok(mut free) = pool.free.lock() {
        free.push(out);
    }
    launched.map(|()| out)
}

/// YUV-to-RGB coefficients for an H.273 matrix and range.
struct Coefficients {
    y_offset: f32,
    y_scale: f32,
    c_scale: f32,
    r_v: f32,
    g_u: f32,
    g_v: f32,
    b_u: f32,
}

impl Coefficients {
    /// 5/6 = BT.601, 9/10 = BT.2020, anything else BT.709 (Sunshine's SDR default).
    fn new(matrix: u8, full_range: bool) -> Coefficients {
        let (kr, kb): (f32, f32) = match matrix {
            5 | 6 => (0.299, 0.114),
            9 | 10 => (0.2627, 0.0593),
            _ => (0.2126, 0.0722),
        };
        let kg = 1.0 - kr - kb;
        let (r_v, b_u) = (2.0 * (1.0 - kr), 2.0 * (1.0 - kb));
        let (y_offset, y_scale, c_scale) =
            if full_range { (0.0, 1.0, 1.0) } else { (16.0, 255.0 / 219.0, 255.0 / 224.0) };
        Coefficients { y_offset, y_scale, c_scale, r_v, g_u: b_u * kb / kg, g_v: r_v * kr / kg, b_u }
    }
}

/// Samples per side of the footprint average (the Quest's TAPS).
const TAPS: usize = 4;

/// Bilinear sample of one channel at (x, y) in texel units (texel centres at
/// +0.5), clamped to the edge; `stride` is 1 for luma, 2 for chroma.
fn bilinear(plane: &[u8], pitch: usize, stride: usize, width: usize, height: usize, x: f32, y: f32) -> f32 {
    let (x, y) = (x - 0.5, y - 0.5);
    let (fx, fy) = (x.floor(), y.floor());
    let (ax, ay) = (x - fx, y - fy);
    let clamp = |v: f32, n: usize| (v as i64).clamp(0, n as i64 - 1) as usize;
    let (x0, x1) = (clamp(fx, width), clamp(fx + 1.0, width));
    let (y0, y1) = (clamp(fy, height), clamp(fy + 1.0, height));
    let at = |x: usize, y: usize| f32::from(plane[pitch * y + stride * x]);
    let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * ax;
    let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * ax;
    top + (bottom - top) * ay
}

/// A full-size NV12 frame (`src_width` x `src_height`, tightly packed) to
/// packed RGB24 at `width` x `height`, each pixel the average of a 4x4 grid of
/// bilinear samples over its footprint. `matrix` is the H.273
/// matrix_coefficients value. The GPU kernel (kernels/nv12_to_tensor.cu) does
/// the same arithmetic.
pub fn nv12_box_to_rgb(
    nv12: &[u8],
    src_width: usize,
    src_height: usize,
    width: usize,
    height: usize,
    matrix: u8,
    full_range: bool,
) -> Vec<u8> {
    let Coefficients { y_offset: y_off, y_scale, c_scale, r_v, g_u, g_v, b_u } = Coefficients::new(matrix, full_range);
    let (luma, chroma) = nv12.split_at(src_width * src_height);
    let (cw, ch) = (src_width / 2, src_height / 2);
    let (foot_u, foot_v) = (1.0 / width as f32, 1.0 / height as f32);
    let taps = TAPS as f32;
    let mut rgb = Vec::with_capacity(width * height * 3);
    for y in 0..height {
        for x in 0..width {
            let mut sum = [0f32; 3];
            for ty in 0..TAPS {
                for tx in 0..TAPS {
                    let u = (x as f32 + 0.5) * foot_u + ((tx as f32 + 0.5) / taps - 0.5) * foot_u;
                    let v = (y as f32 + 0.5) * foot_v + ((ty as f32 + 0.5) / taps - 0.5) * foot_v;
                    let (u, v) = (u.clamp(0.0, 1.0), v.clamp(0.0, 1.0));
                    let (lx, ly) = (u * src_width as f32, v * src_height as f32);
                    let (cx, cy) = (u * cw as f32, v * ch as f32);
                    let l = (bilinear(luma, src_width, 1, src_width, src_height, lx, ly) - y_off) * y_scale;
                    let cu = (bilinear(chroma, src_width, 2, cw, ch, cx, cy) - 128.0) * c_scale;
                    let cv = (bilinear(&chroma[1..], src_width, 2, cw, ch, cx, cy) - 128.0) * c_scale;
                    sum[0] += (l + r_v * cv).clamp(0.0, 255.0);
                    sum[1] += (l - g_u * cu - g_v * cv).clamp(0.0, 255.0);
                    sum[2] += (l + b_u * cu).clamp(0.0, 255.0);
                }
            }
            rgb.extend(sum.map(|c| (c / (taps * taps)).round_ties_even() as u8));
        }
    }
    rgb
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn struct_sizes_match_the_headers() {
        // 64-bit Linux sizes of the C structs (gcc, nv-codec-headers 13.x).
        assert_eq!(std::mem::size_of::<VideoFormat>(), 64);
        assert_eq!(std::mem::size_of::<SourceDataPacket>(), 32);
        assert_eq!(std::mem::size_of::<ParserDispInfo>(), 24);
        assert_eq!(std::mem::size_of::<ParserParams>(), 136);
        assert_eq!(std::mem::size_of::<DecodeCreateInfo>(), 176);
        assert_eq!(std::mem::size_of::<ProcParams>(), 264);
        assert_eq!(std::mem::size_of::<Memcpy2D>(), 128);
        // Offsets printed by a C program compiled against the headers.
        use std::mem::offset_of;
        assert_eq!(offset_of!(ParserParams, user_data), 40);
        assert_eq!(offset_of!(ParserParams, display_picture), 64);
        assert_eq!(offset_of!(DecodeCreateInfo, vid_lock), 120);
        assert_eq!(offset_of!(DecodeCreateInfo, target_width), 96);
        assert_eq!(offset_of!(ProcParams, output_stream), 56);
        assert_eq!(offset_of!(VideoFormat, matrix_coefficients), 59);
    }

    #[test]
    fn converts_limited_range_bt709() {
        // Flat 4x4 frames reduced to 2x2. Black (Y=16) and white (Y=235),
        // neutral chroma:
        let flat = |y: u8, cb: u8, cr: u8| [vec![y; 16], [cb, cr].repeat(4)].concat();
        assert_eq!(nv12_box_to_rgb(&flat(16, 128, 128), 4, 4, 2, 2, 1, false), vec![0; 12]);
        assert_eq!(nv12_box_to_rgb(&flat(235, 128, 128), 4, 4, 2, 2, 1, false), vec![255; 12]);
        // Pure red in BT.709 limited range: Y=63, Cb=102, Cr=240.
        let rgb = nv12_box_to_rgb(&flat(63, 102, 240), 4, 4, 2, 2, 1, false);
        assert!(rgb[0] >= 250 && rgb[1] <= 5 && rgb[2] <= 5, "{:?}", &rgb[..3]);
    }

    #[test]
    fn averages_detail_instead_of_aliasing() {
        // One-pixel black/white stripes, 16x4 reduced to 2x1: a single sample
        // per pixel would land on one colour; the footprint average is grey.
        let mut nv12: Vec<u8> = (0..64).map(|i| if i % 2 == 0 { 16 } else { 235 }).collect();
        nv12.extend([128u8; 32]);
        let rgb = nv12_box_to_rgb(&nv12, 16, 4, 2, 1, 1, false);
        for c in rgb {
            assert!((120..=135).contains(&c), "{c}");
        }
    }

    /// The kernel and the CPU version must agree byte for byte on a
    /// stream-sized frame. Skipped without an NVIDIA GPU.
    #[test]
    fn gpu_reduction_matches_the_cpu() {
        let Ok((api, ctx)) = primary_context() else {
            eprintln!("skipping: no CUDA");
            return;
        };
        let kernel = load_kernel(api, ctx).unwrap();
        let (sw, sh, w, h) = (2560, 1440, 384, 384);
        // Gradients, fine stripes and noise, in luma and chroma.
        let mut seed = 99u32;
        let nv12: Vec<u8> = (0..sw * sh * 3 / 2)
            .map(|i| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                let (x, y) = (i % sw, i / sw);
                let base = (x * 255 / sw + y % 7 * 20 + if x % 3 == 0 { 60 } else { 0 }) as u32;
                ((base + seed % 9) % 256) as u8
            })
            .collect();
        let expected = nv12_box_to_rgb(&nv12, sw, sh, w, h, 1, false);
        let pool = TensorPool { api, ctx, bytes: w * h * 3 * 4, free: Mutex::new(Vec::new()) };
        let mut floats = vec![0f32; w * h * 3];
        unsafe {
            (api.cu_ctx_push)(ctx);
            let mut src: CuDevicePtr = 0;
            check("cuMemAlloc", (api.cu_mem_alloc)(&mut src, nv12.len())).unwrap();
            check("cuMemcpyHtoD", (api.cu_memcpy_htod)(src, nv12.as_ptr().cast(), nv12.len())).unwrap();
            let c = Coefficients::new(1, false);
            let out = convert_on_gpu(api, kernel, &pool, (src, sw, (sw, sh)), (w, h), &c).unwrap();
            check("cuMemcpyDtoH", (api.cu_memcpy_dtoh)(floats.as_mut_ptr().cast(), out, floats.len() * 4)).unwrap();
            (api.cu_mem_free)(src);
            pool.free.lock().unwrap().push(out);
            let mut popped = ptr::null_mut();
            (api.cu_ctx_pop)(&mut popped);
        }
        let plane = w * h;
        let got: Vec<u8> = (0..plane)
            .flat_map(|i| (0..3).map(move |c| (c, i)))
            .map(|(c, i)| (floats[c * plane + i] * 255.0).round() as u8)
            .collect();
        let diff = expected.iter().zip(&got).filter(|(a, b)| a != b).count();
        assert_eq!(diff, 0, "{diff} of {} bytes differ", expected.len());
    }
}
