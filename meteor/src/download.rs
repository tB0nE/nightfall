//! The VDA download: TensorRT from NVIDIA and VDA's files, fetched
//! when the user chooses VDA in the tray.
//!
//! TensorRT comes from NVIDIA's own package server. The libraries wheel is
//! 3.7 GB, but the server answers range requests, so only the three files
//! this GPU needs are read: `libnvinfer`, the ONNX parser and the GPU's
//! builder resource (0.4 to 0.55 GB compressed). If the pinned URL stops
//! answering, the package's index on the same server is read for the same
//! file name.
//!
//! Each file's stored bytes go to `<name>.download` first. A dropped
//! connection is retried (RETRIES times, with back-off) from where it
//! stopped, by range request, and a download cancelled or interrupted by
//! quitting continues from there next time. A finished file is inflated,
//! checked against the SHA-256 in the wheel's `RECORD`, pinned below, and
//! renamed into `tensorrt::install_dir()`. A file under its final name has
//! been verified, and `libnvinfer` comes last, so a half-done download
//! never looks installed.
//!
//! VDA's two graphs and their shared weights (126 MB) come from our release
//! (or `METEOR_VDA_URL`) into the models folder, checked against the hashes
//! in vda.rs.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use sha2::{Digest, Sha256};

/// `tensorrt_cu13_libs` 10.16.1.11 for Linux x86_64 (glibc 2.28 or newer).
const WHEEL_URL: &str =
    "https://pypi.nvidia.com/tensorrt-cu13-libs/tensorrt_cu13_libs-10.16.1.11-py3-none-manylinux_2_28_x86_64.whl";
const WHEEL_SIZE: u64 = 3_728_705_565;
const WHEEL_DIR: &str = "tensorrt_libs/";
/// The package's index, read for the wheel's URL if the pinned one moves.
const WHEEL_INDEX_URL: &str = "https://pypi.nvidia.com/tensorrt-cu13-libs/";
/// Times a dropped connection is resumed before the download gives up.
const RETRIES: u32 = 5;
/// The suffix of a file still being downloaded.
const DOWNLOADING: &str = "download";

/// What the user agrees to by downloading.
pub const LICENCE_URL: &str = "https://docs.nvidia.com/deeplearning/tensorrt/latest/reference/sla.html";

/// Where the VDA graphs are published. `METEOR_VDA_URL` overrides it (a
/// folder URL ending in `/`).
const VDA_URL: &str = "https://github.com/tB0nE/nightfall/releases/download/meteor-vda-s-518x294/";

/// A file in the wheel's `tensorrt_libs/`, from its `RECORD`.
struct WheelFile {
    name: &'static str,
    sha256: &'static str,
    size: u64,
    compressed: u64,
}

const NVINFER: WheelFile = WheelFile {
    name: "libnvinfer.so.10",
    sha256: "6637a7f7117f80281c206ee79ebaf2a8b7f0f4d6b62a375856839d9260a4105a",
    size: 662_824_456,
    compressed: 308_031_727,
};
const PARSER: WheelFile = WheelFile {
    name: "libnvonnxparser.so.10",
    sha256: "09cda8eddce7f53f039fbffc3c30a4d066dc7759464331ca8ccf3fa461b48cf7",
    size: 5_058_816,
    compressed: 2_017_876,
};

/// Builder resources by compute capability (major * 10 + minor).
const BUILDERS: [(u32, WheelFile); 7] = [
    (75, WheelFile {
        name: "libnvinfer_builder_resource_sm75.so.10.16.1",
        sha256: "e735551edd3b63342d76e1bbe0fc873496f6ee99878af33d4c8c798d38e05b97",
        size: 115_939_120,
        compressed: 94_073_812,
    }),
    (80, WheelFile {
        name: "libnvinfer_builder_resource_sm80.so.10.16.1",
        sha256: "339c7a4979fa52410040977ead36be963e0843ca9197f1cd08d3df3d312d8d4c",
        size: 186_554_160,
        compressed: 162_559_073,
    }),
    (86, WheelFile {
        name: "libnvinfer_builder_resource_sm86.so.10.16.1",
        sha256: "922796875978139aac04c625f06b53665faafa7caca88cf3b690f54e054564de",
        size: 175_875_888,
        compressed: 152_078_869,
    }),
    (89, WheelFile {
        name: "libnvinfer_builder_resource_sm89.so.10.16.1",
        sha256: "00b9ec534cb2489d8046ccd439fbbbd512590adb3b6ca509cd8dac6c507a44d6",
        size: 184_932_144,
        compressed: 160_883_272,
    }),
    (90, WheelFile {
        name: "libnvinfer_builder_resource_sm90.so.10.16.1",
        sha256: "b90ca522993573b4f88212978f6a9d6306ddea5c23664e6171226bb490f87296",
        size: 453_793_584,
        compressed: 425_664_133,
    }),
    (100, WheelFile {
        name: "libnvinfer_builder_resource_sm100.so.10.16.1",
        sha256: "589277c3b8a525923905ace33599d88330317db017db7b3f61ac13e976af4c88",
        size: 282_760_992,
        compressed: 256_059_986,
    }),
    (120, WheelFile {
        name: "libnvinfer_builder_resource_sm120.so.10.16.1",
        sha256: "37d5e476db50daa4088c25ebf6ede0e1eff14ab1aa8df03cf07407a07eeec07f",
        size: 261_945_120,
        compressed: 235_163_147,
    }),
];

/// The graphs this download fetched, so "Remove VDA" deletes only those.
const DOWNLOADED_MODELS: &str = "downloaded-models.txt";

/// What a download would fetch.
pub struct Plan {
    /// TensorRT files missing from the install folder, builder resource
    /// first and libnvinfer last.
    tensorrt: Vec<&'static WheelFile>,
    /// VDA graphs missing from the models folder: (file, SHA-256, bytes).
    graphs: Vec<(&'static str, &'static str, u64)>,
    models_dir: PathBuf,
}

impl Plan {
    /// Bytes to download.
    pub fn bytes(&self) -> u64 {
        self.tensorrt.iter().map(|f| f.compressed).sum::<u64>() + self.graphs.iter().map(|g| g.2).sum::<u64>()
    }

    /// Bytes on disk afterwards, plus the stored bytes kept until each file
    /// is inflated.
    fn disk_bytes(&self) -> u64 {
        self.tensorrt.iter().map(|f| f.size + f.compressed).sum::<u64>() + self.graphs.iter().map(|g| g.2).sum::<u64>()
    }

    pub fn is_empty(&self) -> bool {
        self.tensorrt.is_empty() && self.graphs.is_empty()
    }
}

/// This GPU's builder resource. A GPU between two listed ones (say sm87)
/// can't use either, so only exact matches count.
fn builder_for(major: i32, minor: i32) -> Option<&'static WheelFile> {
    let cc = u32::try_from(major * 10 + minor).ok()?;
    BUILDERS.iter().find(|(sm, _)| *sm == cc).map(|(_, file)| file)
}

/// What's missing for VDA. Fails when this GPU can't use the download.
pub fn plan(models_dir: &Path) -> Result<Plan, String> {
    let (major, minor) = crate::nvdec::compute_capability()?;
    let builder = builder_for(major, minor)
        .ok_or_else(|| format!("TensorRT {} has no builder for this GPU (compute capability {major}.{minor})", crate::tensorrt::VERSION))?;
    let dir = crate::tensorrt::install_dir();
    let tensorrt = [builder, &PARSER, &NVINFER].into_iter().filter(|f| !dir.join(f.name).is_file()).collect();
    let graphs = crate::vda::FILES
        .into_iter()
        .filter(|(file, _, _)| !models_dir.join(file).is_file())
    .collect();
    Ok(Plan { tensorrt, graphs, models_dir: models_dir.to_path_buf() })
}

/// The download's state, for the tray.
#[derive(Clone, Debug, PartialEq)]
pub enum State {
    Idle,
    Running,
    Failed(String),
    Done,
}

/// Shared between the download thread and the tray.
pub struct Download {
    pub state: Mutex<State>,
    pub done: AtomicU64,
    pub total: AtomicU64,
    pub cancel: AtomicBool,
}

impl Default for Download {
    fn default() -> Self {
        Download { state: Mutex::new(State::Idle), done: AtomicU64::new(0), total: AtomicU64::new(0), cancel: AtomicBool::new(false) }
    }
}

impl Download {
    pub fn state(&self) -> State {
        self.state.lock().map_or(State::Idle, |s| s.clone())
    }

    fn set(&self, state: State) {
        if let Ok(mut s) = self.state.lock() {
            *s = state;
        }
    }

    /// Runs `plan` on this thread. Returns once everything is installed, or
    /// with the reason it stopped (also kept in `state`).
    pub fn run(&self, plan: &Plan) -> Result<(), String> {
        self.cancel.store(false, Ordering::Relaxed);
        self.done.store(0, Ordering::Relaxed);
        self.total.store(plan.bytes(), Ordering::Relaxed);
        self.set(State::Running);
        let result = self.fetch(plan);
        self.set(match &result {
            Ok(()) => State::Done,
            Err(err) => State::Failed(err.clone()),
        });
        result
    }

    fn fetch(&self, plan: &Plan) -> Result<(), String> {
        let install = crate::tensorrt::install_dir();
        std::fs::create_dir_all(&install).map_err(|e| format!("{}: {e}", install.display()))?;
        std::fs::create_dir_all(&plan.models_dir).map_err(|e| format!("{}: {e}", plan.models_dir.display()))?;
        let need = plan.disk_bytes() + 200_000_000;
        if let Some(free) = free_space(&install)
            && free < need
        {
            return Err(format!("not enough disk space: {} MB free, {} MB needed", free / 1_000_000, need / 1_000_000));
        }
        let agent = agent();
        for (file, sha256, size) in &plan.graphs {
            let base = std::env::var("METEOR_VDA_URL").unwrap_or_else(|_| VDA_URL.to_string());
            let url = format!("{base}{file}");
            log::info!("VDA download: {url}");
            let path = plan.models_dir.join(file);
            let raw = downloading(&path);
            self.resumable(&agent, &url, 0, *size, &raw)?;
            let reader = std::fs::File::open(&raw).map_err(|e| format!("{}: {e}", raw.display()))?;
            // A bad file starts again next time.
            let installed = install_verified(reader, &path, sha256);
            let _ = std::fs::remove_file(&raw);
            installed?;
            let mut list = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(install.join(DOWNLOADED_MODELS))
                .map_err(|e| e.to_string())?;
            let _ = writeln!(list, "{file}");
        }
        if plan.tensorrt.is_empty() {
            return Ok(());
        }
        let wheel = Wheel::open(&agent)?;
        for file in &plan.tensorrt {
            let member = wheel.member(&format!("{WHEEL_DIR}{}", file.name))?;
            if member.compressed != file.compressed {
                return Err(format!("{} in NVIDIA's package isn't the expected size", file.name));
            }
            log::info!("VDA download: {} from NVIDIA ({} MB)", file.name, file.compressed / 1_000_000);
            let path = install.join(file.name);
            let raw = downloading(&path);
            // Progress counts the bytes received, before inflating.
            self.resumable(&agent, &wheel.url, wheel.data_start(&agent, &member)?, member.compressed, &raw)?;
            let body = std::io::BufReader::new(std::fs::File::open(&raw).map_err(|e| format!("{}: {e}", raw.display()))?);
            let reader: Box<dyn Read> = match member.method {
                0 => Box::new(body),
                8 => Box::new(flate2::read::DeflateDecoder::new(body)),
                m => return Err(format!("NVIDIA's package uses compression method {m}")),
            };
            let installed = install_verified(reader, &path, file.sha256);
            let _ = std::fs::remove_file(&raw);
            installed?;
        }
        Ok(())
    }

    /// Counts bytes for the progress, and stops when cancelled.
    fn counting<'a, R: Read + 'a>(&'a self, inner: R) -> impl Read + 'a {
        Counting { inner, download: self }
    }

    /// Fetches bytes `start..start + len` of `url` into `path`, carrying on
    /// from whatever `path` already holds, and resuming after a dropped
    /// connection up to RETRIES times.
    fn resumable(&self, agent: &ureq::Agent, url: &str, start: u64, len: u64, path: &Path) -> Result<(), String> {
        let fail = |e: std::io::Error| format!("{}: {e}", path.display());
        let mut have = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        if have > len {
            std::fs::remove_file(path).map_err(fail)?;
            have = 0;
        }
        if have > 0 {
            log::info!("Resuming {} at {} of {} MB", path.display(), have / 1_000_000, len / 1_000_000);
        }
        self.done.fetch_add(have, Ordering::Relaxed);
        let mut failures = 0;
        while have < len {
            let attempt = (|| -> Result<(), String> {
                let response = agent
                    .get(url)
                    .header("Range", format!("bytes={}-{}", start + have, start + len - 1))
                    .call()
                    .map_err(|e| format!("{url}: {e}"))?;
                let mut out = std::fs::OpenOptions::new().create(true).append(true).open(path).map_err(fail)?;
                match response.status().as_u16() {
                    206 => {}
                    // The server ignored the range: start the file again.
                    200 => {
                        out.set_len(0).map_err(fail)?;
                        self.done.fetch_sub(have, Ordering::Relaxed);
                        have = 0;
                        if start > 0 {
                            return Err(format!("{url} doesn't answer range requests"));
                        }
                    }
                    status => return Err(format!("{url}: HTTP {status}")),
                }
                let mut body = self.counting(response.into_body().into_reader().take(len - have));
                std::io::copy(&mut body, &mut out).map_err(|e| format!("{url}: {e}"))?;
                Ok(())
            })();
            have = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
            if let Err(err) = attempt {
                failures += 1;
                if self.cancel.load(Ordering::Relaxed) || failures > RETRIES {
                    return Err(err);
                }
                let wait = Duration::from_secs(2u64.pow(failures).min(30));
                log::warn!("{err}; resuming in {} s ({failures} of {RETRIES})", wait.as_secs());
                std::thread::sleep(wait);
            }
        }
        Ok(())
    }
}

/// Where `path` is written while it's still downloading.
fn downloading(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".");
    name.push(DOWNLOADING);
    path.with_file_name(name)
}

struct Counting<'a, R> {
    inner: R,
    download: &'a Download,
}

impl<R: Read> Read for Counting<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.download.cancel.load(Ordering::Relaxed) {
            return Err(std::io::Error::other("cancelled"));
        }
        let n = self.inner.read(buf)?;
        self.download.done.fetch_add(n as u64, Ordering::Relaxed);
        Ok(n)
    }
}

fn agent() -> ureq::Agent {
    ureq::Agent::config_builder()
        .timeout_connect(Some(Duration::from_secs(20)))
        // A stalled read gives up; a slow but moving one doesn't.
        .timeout_recv_body(None)
        .timeout_global(None)
        .user_agent(concat!("nightfall-meteor/", env!("CARGO_PKG_VERSION")))
        .build()
        .into()
}

/// Writes `reader` to `<path>.partial`, checks its SHA-256 and renames it
/// to `path`.
fn install_verified(mut reader: impl Read, path: &Path, sha256: &str) -> Result<(), String> {
    let partial = path.with_extension("partial");
    let fail = |e: std::io::Error| format!("{}: {e}", path.display());
    let result = (|| {
        let mut out = std::io::BufWriter::new(std::fs::File::create(&partial).map_err(fail)?);
        let mut hasher = Sha256::new();
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = reader.read(&mut buf).map_err(fail)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            out.write_all(&buf[..n]).map_err(fail)?;
        }
        out.flush().map_err(fail)?;
        let actual = hex(&hasher.finalize());
        if actual != sha256 {
            return Err(format!("{} has SHA-256 {actual}, expected {sha256}", path.display()));
        }
        std::fs::rename(&partial, path).map_err(fail)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&partial);
    }
    result
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(unix)]
fn free_space(dir: &Path) -> Option<u64> {
    let path = std::ffi::CString::new(dir.as_os_str().as_encoded_bytes()).ok()?;
    // SAFETY: a NUL-terminated path and a zeroed struct for statvfs to fill.
    // The field types are u64 here but narrower on some platforms.
    #[allow(clippy::unnecessary_cast)]
    unsafe {
        let mut stat: libc::statvfs = std::mem::zeroed();
        (libc::statvfs(path.as_ptr(), &mut stat) == 0).then(|| stat.f_bavail as u64 * stat.f_frsize as u64)
    }
}

#[cfg(not(unix))]
fn free_space(_dir: &Path) -> Option<u64> {
    None
}

/// `--download-vda`: runs the download here, logging progress. Returns the
/// exit code.
pub fn command(models_dir: &Path) -> i32 {
    let plan = match plan(models_dir) {
        Ok(plan) => plan,
        Err(err) => {
            log::error!("{err}");
            return 1;
        }
    };
    if plan.is_empty() {
        log::info!("VDA's files are all there");
        return 0;
    }
    log::info!("Downloading {} MB; TensorRT comes from NVIDIA under NVIDIA's licence ({LICENCE_URL})", plan.bytes() / 1_000_000);
    let download = std::sync::Arc::new(Download::default());
    let progress = download.clone();
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_secs(5));
            if progress.state() != State::Running {
                break;
            }
            let mb = |a: &AtomicU64| a.load(Ordering::Relaxed) / 1_000_000;
            log::info!("{} of {} MB", mb(&progress.done), mb(&progress.total));
        }
    });
    let started = std::time::Instant::now();
    match download.run(&plan) {
        Ok(()) => {
            log::info!("Done in {:.0} s; TensorRT is in {}", started.elapsed().as_secs_f64(), crate::tensorrt::install_dir().display());
            0
        }
        Err(err) => {
            log::error!("{err}");
            1
        }
    }
}

/// Deletes what the download installed: TensorRT, the graphs it fetched,
/// any unfinished files, and VDA's cached engines.
pub fn remove(models_dir: &Path) -> Result<(), String> {
    let install = crate::tensorrt::install_dir();
    for (file, _, _) in crate::vda::FILES {
        let _ = std::fs::remove_file(downloading(&models_dir.join(file)));
    }
    if let Ok(list) = std::fs::read_to_string(install.join(DOWNLOADED_MODELS)) {
        for file in list.lines().filter(|f| crate::vda::is_file(f)) {
            let _ = std::fs::remove_file(models_dir.join(file));
        }
    }
    let cache = crate::config::cache_dir().join("tensorrt");
    for entry in std::fs::read_dir(&cache).into_iter().flatten().flatten() {
        if entry.file_name().to_string_lossy().starts_with(&format!("{}-", crate::vda::ID)) {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
    if install.exists() {
        std::fs::remove_dir_all(&install).map_err(|e| format!("{}: {e}", install.display()))?;
    }
    Ok(())
}

/// Whether the download installed TensorRT here.
pub fn installed() -> bool {
    crate::tensorrt::install_dir().join(NVINFER.name).is_file()
}

/// A member of the remote wheel.
#[derive(Debug, Clone, PartialEq)]
struct Member {
    method: u16,
    compressed: u64,
    /// Offset of its local header.
    offset: u64,
}

/// The wheel's central directory, read with two range requests.
struct Wheel {
    url: String,
    members: Vec<(String, Member)>,
}

impl Wheel {
    fn open(agent: &ureq::Agent) -> Result<Wheel, String> {
        let (url, tail) = match range(agent, WHEEL_URL, WHEEL_SIZE - 65_536, 65_536) {
            Ok(tail) => (WHEEL_URL.to_string(), tail),
            Err(err) => {
                // Moved? The index lists where the same file is now.
                let url = moved_wheel_url(agent).ok_or(err)?;
                log::info!("NVIDIA's package moved; using {url}");
                let tail = range(agent, &url, WHEEL_SIZE - 65_536, 65_536)?;
                (url, tail)
            }
        };
        let (cd_offset, cd_size) = central_directory(&tail)?;
        let cd = range(agent, &url, cd_offset, cd_size)?;
        Ok(Wheel { members: members(&cd)?, url })
    }

    fn member(&self, name: &str) -> Result<Member, String> {
        self.members.iter().find(|(n, _)| n == name).map(|(_, m)| m.clone()).ok_or_else(|| format!("{name} isn't in NVIDIA's package"))
    }

    /// Where the member's stored (compressed) bytes start in the wheel.
    fn data_start(&self, agent: &ureq::Agent, member: &Member) -> Result<u64, String> {
        let header = range(agent, &self.url, member.offset, 30)?;
        if header.get(..4) != Some(b"PK\x03\x04") {
            return Err("NVIDIA's package has an unexpected layout".into());
        }
        let name_len = u64::from(u16::from_le_bytes([header[26], header[27]]));
        let extra_len = u64::from(u16::from_le_bytes([header[28], header[29]]));
        Ok(member.offset + 30 + name_len + extra_len)
    }
}

/// The wheel's URL from the package's index (a PEP 503 page of links), if
/// it lists the same file name.
fn moved_wheel_url(agent: &ureq::Agent) -> Option<String> {
    let page = agent.get(WHEEL_INDEX_URL).call().ok()?.into_body().read_to_string().ok()?;
    wheel_link(&page, WHEEL_INDEX_URL, WHEEL_URL.rsplit('/').next()?)
}

/// The link to `file` in an index page, made absolute against `base`.
fn wheel_link(page: &str, base: &str, file: &str) -> Option<String> {
    page.split("href=\"").skip(1).filter_map(|s| s.split('"').next()).find_map(|href| {
        let href = href.split('#').next()?;
        if href.rsplit('/').next()? != file {
            return None;
        }
        Some(if href.contains("://") {
            href.to_string()
        } else if let Some(path) = href.strip_prefix('/') {
            let origin: String = base.splitn(4, '/').take(3).collect::<Vec<_>>().join("/");
            format!("{origin}/{path}")
        } else {
            format!("{}{href}", base)
        })
    })
}

fn range_reader(agent: &ureq::Agent, url: &str, start: u64, len: u64) -> Result<impl Read + Send + use<>, String> {
    let response = agent
        .get(url)
        .header("Range", format!("bytes={start}-{}", start + len - 1))
        .call()
        .map_err(|e| format!("NVIDIA's server: {e}"))?;
    if response.status() != 206 {
        return Err(format!("NVIDIA's server didn't answer the range request ({})", response.status()));
    }
    Ok(response.into_body().into_reader().take(len))
}

fn range(agent: &ureq::Agent, url: &str, start: u64, len: u64) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity(len as usize);
    range_reader(agent, url, start, len)?.read_to_end(&mut out).map_err(|e| format!("NVIDIA's server: {e}"))?;
    Ok(out)
}

fn u16_at(b: &[u8], i: usize) -> Option<u64> {
    Some(u64::from(u16::from_le_bytes(b.get(i..i + 2)?.try_into().ok()?)))
}

fn u32_at(b: &[u8], i: usize) -> Option<u64> {
    Some(u64::from(u32::from_le_bytes(b.get(i..i + 4)?.try_into().ok()?)))
}

fn u64_at(b: &[u8], i: usize) -> Option<u64> {
    Some(u64::from_le_bytes(b.get(i..i + 8)?.try_into().ok()?))
}

/// Finds the central directory's offset and size in the zip's last bytes,
/// through the zip64 record when there is one.
fn central_directory(tail: &[u8]) -> Result<(u64, u64), String> {
    let bad = || "NVIDIA's package has an unexpected layout".to_string();
    let find = |sig: &[u8]| tail.windows(4).rposition(|w| w == sig);
    let eocd = find(b"PK\x05\x06").ok_or_else(bad)?;
    let size = u32_at(tail, eocd + 12).ok_or_else(bad)?;
    let offset = u32_at(tail, eocd + 16).ok_or_else(bad)?;
    if offset != 0xFFFF_FFFF && size != 0xFFFF_FFFF {
        return Ok((offset, size));
    }
    let zip64 = find(b"PK\x06\x06").ok_or_else(bad)?;
    Ok((u64_at(tail, zip64 + 48).ok_or_else(bad)?, u64_at(tail, zip64 + 40).ok_or_else(bad)?))
}

/// The central directory's entries, with zip64 sizes and offsets resolved.
fn members(cd: &[u8]) -> Result<Vec<(String, Member)>, String> {
    let bad = || "NVIDIA's package has an unexpected layout".to_string();
    let mut out = Vec::new();
    let mut p = 0;
    while cd.get(p..p + 4) == Some(b"PK\x01\x02") {
        let method = u16_at(cd, p + 10).ok_or_else(bad)? as u16;
        let mut compressed = u32_at(cd, p + 20).ok_or_else(bad)?;
        let size = u32_at(cd, p + 24).ok_or_else(bad)?;
        let name_len = u16_at(cd, p + 28).ok_or_else(bad)? as usize;
        let extra_len = u16_at(cd, p + 30).ok_or_else(bad)? as usize;
        let comment_len = u16_at(cd, p + 32).ok_or_else(bad)? as usize;
        let mut offset = u32_at(cd, p + 42).ok_or_else(bad)?;
        let name = String::from_utf8_lossy(cd.get(p + 46..p + 46 + name_len).ok_or_else(bad)?).into_owned();
        let extra = cd.get(p + 46 + name_len..p + 46 + name_len + extra_len).ok_or_else(bad)?;
        // The zip64 field holds, in order, whichever of the size,
        // compressed size and offset overflowed.
        let mut q = 0;
        while q + 4 <= extra.len() {
            let tag = u16_at(extra, q).ok_or_else(bad)?;
            let len = u16_at(extra, q + 2).ok_or_else(bad)? as usize;
            if tag == 1 {
                let mut k = q + 4;
                let mut next = || {
                    let v = u64_at(extra, k);
                    k += 8;
                    v.ok_or_else(bad)
                };
                if size == 0xFFFF_FFFF {
                    next()?;
                }
                if compressed == 0xFFFF_FFFF {
                    compressed = next()?;
                }
                if offset == 0xFFFF_FFFF {
                    offset = next()?;
                }
            }
            q += 4 + len;
        }
        out.push((name, Member { method, compressed, offset }));
        p += 46 + name_len + extra_len + comment_len;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_a_moved_wheel_in_the_index() {
        let file = "tensorrt_cu13_libs-10.16.1.11-py3-none-manylinux_2_28_x86_64.whl";
        let base = "https://pypi.nvidia.com/tensorrt-cu13-libs/";
        let page = format!(
            "<a href=\"other.whl\">x</a><a href=\"https://files.example.com/a/{file}#sha256=ab\">{file}</a>"
        );
        assert_eq!(wheel_link(&page, base, file).as_deref(), Some(format!("https://files.example.com/a/{file}").as_str()));
        let relative = format!("<a href=\"{file}#sha256=ab\">{file}</a>");
        assert_eq!(wheel_link(&relative, base, file), Some(format!("{base}{file}")));
        let rooted = format!("<a href=\"/packages/{file}\">{file}</a>");
        assert_eq!(wheel_link(&rooted, base, file), Some(format!("https://pypi.nvidia.com/packages/{file}")));
        assert_eq!(wheel_link("<a href=\"tensorrt_cu13_libs-10.16.0.whl\">", base, file), None);
    }

    #[test]
    fn names_unfinished_files() {
        assert_eq!(downloading(Path::new("/m/vda_s_518x294.onnx.data")), Path::new("/m/vda_s_518x294.onnx.data.download"));
        assert_eq!(downloading(Path::new("/t/libnvinfer.so.10")), Path::new("/t/libnvinfer.so.10.download"));
    }

    /// A central directory entry, with a zip64 field for the offset.
    fn entry(name: &str, compressed: u32, offset: Option<u64>) -> Vec<u8> {
        let mut e = b"PK\x01\x02".to_vec();
        e.extend([0u8; 6]); // versions, flags
        e.extend(8u16.to_le_bytes()); // deflate
        e.extend([0u8; 8]); // time, date, crc
        e.extend(compressed.to_le_bytes());
        e.extend(1000u32.to_le_bytes());
        e.extend((name.len() as u16).to_le_bytes());
        e.extend((if offset.is_some() { 12u16 } else { 0 }).to_le_bytes());
        e.extend([0u8; 10]); // comment, disk, attributes
        e.extend((if offset.is_some() { 0xFFFF_FFFFu32 } else { 77 }).to_le_bytes());
        e.extend(name.as_bytes());
        if let Some(offset) = offset {
            e.extend(1u16.to_le_bytes());
            e.extend(8u16.to_le_bytes());
            e.extend(offset.to_le_bytes());
        }
        e
    }

    #[test]
    fn reads_central_directory_entries() {
        let mut cd = entry("tensorrt_libs/a.so", 500, None);
        cd.extend(entry("tensorrt_libs/b.so", 600, Some(5_000_000_000)));
        let members = members(&cd).unwrap();
        assert_eq!(members[0], ("tensorrt_libs/a.so".into(), Member { method: 8, compressed: 500, offset: 77 }));
        assert_eq!(members[1].1.offset, 5_000_000_000);
        assert_eq!(members[1].1.compressed, 600);
    }

    #[test]
    fn finds_the_zip64_central_directory() {
        let mut tail = vec![0u8; 10];
        tail.extend(b"PK\x06\x06");
        tail.extend([0u8; 36]);
        tail.extend(1234u64.to_le_bytes()); // size
        tail.extend(4_000_000_000u64.to_le_bytes()); // offset
        tail.extend(b"PK\x06\x07");
        tail.extend([0u8; 16]);
        tail.extend(b"PK\x05\x06");
        tail.extend([0u8; 8]);
        tail.extend(0xFFFF_FFFFu32.to_le_bytes());
        tail.extend(0xFFFF_FFFFu32.to_le_bytes());
        tail.extend([0u8; 2]);
        assert_eq!(central_directory(&tail).unwrap(), (4_000_000_000, 1234));
    }

    #[test]
    fn picks_the_builder_resource() {
        assert_eq!(builder_for(8, 6).map(|f| f.name), Some("libnvinfer_builder_resource_sm86.so.10.16.1"));
        assert_eq!(builder_for(12, 0).map(|f| f.name), Some("libnvinfer_builder_resource_sm120.so.10.16.1"));
        assert!(builder_for(8, 7).is_none());
        assert!(builder_for(6, 1).is_none());
    }
}
