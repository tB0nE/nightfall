//! Forwards a client's Sunshine traffic through Meteor's own ports.
//!
//! Everything is passed through untouched (HTTPS stays end-to-end between
//! the client and Sunshine, so pairing is unaffected) with one exception:
//! Sunshine's RTSP SETUP replies name the UDP ports for video, audio, and
//! control (`Transport: ...;server_port=47998`). Those are rewritten to
//! Meteor's ports so the client sends its UDP traffic here too.
//!
//! Two things are read on the way through without changing anything: the
//! client's RTSP ANNOUNCE (codec, resolution, encryption; see stream_info),
//! and the video packets, which are copied to the video tap after they have
//! been forwarded.

use std::collections::{HashMap, HashSet};
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::Mutex;

use crate::depth::{Depth, DepthFeed};
use crate::ports::{Channel, PortMap, Proto};
use crate::stream_info::{AnnounceSniffer, Codec, StreamInfo};
use crate::video_dump::VideoDump;
use crate::video_tap::{TapStats, VideoTap};

const UDP_FLOW_IDLE: Duration = Duration::from_secs(30);
const MAX_RTSP_HEADER: usize = 64 * 1024;

#[derive(Default)]
pub struct Stats {
    pub tcp_connections: AtomicUsize,
    pub udp_flows: AtomicUsize,
    pub bytes_to_client: AtomicU64,
    pub bytes_to_sunshine: AtomicU64,
    pub tap: Arc<TapStats>,
    /// Addresses with an open video flow: the clients streaming right now.
    pub video_clients: std::sync::Mutex<HashSet<IpAddr>>,
}

impl Stats {
    pub fn is_streaming(&self, ip: IpAddr) -> bool {
        self.video_clients.lock().is_ok_and(|c| c.contains(&ip.to_canonical()))
    }

    fn set_streaming(&self, ip: IpAddr, streaming: bool) {
        if let Ok(mut clients) = self.video_clients.lock() {
            if streaming {
                clients.insert(ip.to_canonical());
            } else {
                clients.remove(&ip.to_canonical());
            }
        }
    }
}

#[derive(Clone)]
pub struct Proxy {
    pub map: PortMap,
    pub sunshine_host: String,
    pub stats: Arc<Stats>,
    /// From the most recent RTSP ANNOUNCE.
    pub stream: Arc<std::sync::Mutex<Option<StreamInfo>>>,
    /// `--dump-video`: write the tapped video here.
    pub dump_dir: Option<PathBuf>,
    pub depth: Option<Arc<Depth>>,
}

impl Proxy {
    pub fn new(
        map: PortMap,
        sunshine_host: String,
        stats: Arc<Stats>,
        dump_dir: Option<PathBuf>,
        depth: Option<Arc<Depth>>,
    ) -> Proxy {
        Proxy { map, sunshine_host, stats, stream: Arc::default(), dump_dir, depth }
    }

    pub async fn start(&self) -> io::Result<()> {
        for ch in crate::ports::CHANNELS {
            let port = self.map.meteor(ch);
            match ch.proto {
                Proto::Tcp => {
                    let listener = bind_tcp(port).await?;
                    tokio::spawn(self.clone().run_tcp(listener, ch));
                }
                Proto::Udp => {
                    let socket = Arc::new(bind_udp(port).await?);
                    tokio::spawn(self.clone().run_udp(socket, ch));
                }
            }
            log::info!(
                "{:>7} {:?} :{port} -> {}:{}",
                ch.name,
                ch.proto,
                self.sunshine_host,
                self.map.sunshine(ch)
            );
        }
        Ok(())
    }

    fn upstream(&self, ch: Channel) -> String {
        let host = &self.sunshine_host;
        let port = self.map.sunshine(ch);
        if host.contains(':') { format!("[{host}]:{port}") } else { format!("{host}:{port}") }
    }

    async fn run_tcp(self, listener: TcpListener, ch: Channel) {
        loop {
            let (client, peer) = match listener.accept().await {
                Ok(accepted) => accepted,
                Err(err) => {
                    log::warn!("{} accept failed: {err}", ch.name);
                    continue;
                }
            };
            let proxy = self.clone();
            tokio::spawn(async move {
                proxy.stats.tcp_connections.fetch_add(1, Ordering::Relaxed);
                if let Err(err) = proxy.forward_tcp(client, ch).await {
                    log::debug!("{} connection from {peer} ended: {err}", ch.name);
                }
                proxy.stats.tcp_connections.fetch_sub(1, Ordering::Relaxed);
            });
            log::debug!("{} connection from {peer}", ch.name);
        }
    }

    async fn forward_tcp(&self, client: TcpStream, ch: Channel) -> io::Result<()> {
        let upstream = TcpStream::connect(self.upstream(ch)).await?;
        client.set_nodelay(true)?;
        upstream.set_nodelay(true)?;
        let (mut client_rx, mut client_tx) = client.into_split();
        let (mut up_rx, mut up_tx) = upstream.into_split();
        let stats = self.stats.clone();
        let to_sunshine = async {
            let n = if ch.name == "rtsp" {
                copy_rtsp_requests(&mut client_rx, &mut up_tx, &stats.bytes_to_sunshine, &self.stream).await
            } else {
                copy_counted(&mut client_rx, &mut up_tx, &stats.bytes_to_sunshine).await
            };
            let _ = up_tx.shutdown().await;
            n
        };
        let to_client = async {
            let n = if ch.name == "rtsp" {
                copy_rtsp_replies(&mut up_rx, &mut client_tx, &self.map, &stats.bytes_to_client).await
            } else {
                copy_counted(&mut up_rx, &mut client_tx, &stats.bytes_to_client).await
            };
            let _ = client_tx.shutdown().await;
            n
        };
        let (a, b) = tokio::join!(to_sunshine, to_client);
        a.and(b).map(|_| ())
    }

    /// One upstream socket per client address, so Sunshine sees each client
    /// as a distinct peer and its replies can be routed back.
    async fn run_udp(self, listener: Arc<UdpSocket>, ch: Channel) {
        let flows: Arc<Mutex<HashMap<SocketAddr, Arc<UdpSocket>>>> = Arc::default();
        let mut buf = vec![0u8; 65536];
        loop {
            let (len, client) = match listener.recv_from(&mut buf).await {
                Ok(received) => received,
                Err(err) => {
                    // Windows reports an ICMP port-unreachable from an earlier
                    // send as a receive error; it isn't fatal.
                    log::debug!("{} receive failed: {err}", ch.name);
                    continue;
                }
            };
            let upstream = {
                let mut flows_guard = flows.lock().await;
                match flows_guard.get(&client) {
                    Some(socket) => socket.clone(),
                    None => match self.open_udp_flow(ch).await {
                        Ok(socket) => {
                            flows_guard.insert(client, socket.clone());
                            tokio::spawn(self.clone().relay_udp_replies(
                                socket.clone(),
                                listener.clone(),
                                client,
                                flows.clone(),
                                ch,
                            ));
                            socket
                        }
                        Err(err) => {
                            log::warn!("{} flow for {client} failed: {err}", ch.name);
                            continue;
                        }
                    },
                }
            };
            if upstream.send(&buf[..len]).await.is_ok() {
                self.stats.bytes_to_sunshine.fetch_add(len as u64, Ordering::Relaxed);
            }
        }
    }

    async fn open_udp_flow(&self, ch: Channel) -> io::Result<Arc<UdpSocket>> {
        let target = tokio::net::lookup_host(self.upstream(ch))
            .await?
            .next()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "Sunshine host not found"))?;
        let local: SocketAddr = if target.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" }.parse().unwrap();
        let socket = UdpSocket::bind(local).await?;
        socket.connect(target).await?;
        Ok(Arc::new(socket))
    }

    async fn relay_udp_replies(
        self,
        upstream: Arc<UdpSocket>,
        listener: Arc<UdpSocket>,
        client: SocketAddr,
        flows: Arc<Mutex<HashMap<SocketAddr, Arc<UdpSocket>>>>,
        ch: Channel,
    ) {
        self.stats.udp_flows.fetch_add(1, Ordering::Relaxed);
        log::debug!("{} flow opened for {client}", ch.name);
        let tap = if ch.name == "video" {
            self.stats.set_streaming(client.ip(), true);
            self.start_video_tap(client, &upstream)
        } else {
            None
        };
        let mut buf = vec![0u8; 65536];
        loop {
            match tokio::time::timeout(UDP_FLOW_IDLE, upstream.recv(&mut buf)).await {
                Ok(Ok(len)) => {
                    if listener.send_to(&buf[..len], client).await.is_ok() {
                        self.stats.bytes_to_client.fetch_add(len as u64, Ordering::Relaxed);
                    }
                    if let Some(tap) = &tap {
                        tap.push(&buf[..len]);
                    }
                }
                // Sunshine not listening yet shows up as a refused receive; keep the flow.
                Ok(Err(err)) if err.kind() == io::ErrorKind::ConnectionRefused => {}
                Ok(Err(err)) => {
                    log::debug!("{} flow for {client} failed: {err}", ch.name);
                    break;
                }
                Err(_) => break, // idle
            }
        }
        flows.lock().await.remove(&client);
        if ch.name == "video" {
            self.stats.set_streaming(client.ip(), false);
        }
        self.stats.udp_flows.fetch_sub(1, Ordering::Relaxed);
        log::debug!("{} flow closed for {client}", ch.name);
    }

    fn start_video_tap(&self, client: SocketAddr, upstream: &UdpSocket) -> Option<VideoTap> {
        let info = self.stream.lock().ok().and_then(|s| s.clone());
        match &info {
            Some(info) if info.video_encrypted => {
                log::info!("Video for {client} is encrypted; Meteor can't read it (no host depth)");
                return None;
            }
            Some(info) if info.codec == Some(Codec::PyroWave) => {
                log::info!("Video for {client} is PyroWave; Meteor can't decode it (no host depth)");
                return None;
            }
            Some(info) => log::debug!(
                "Tapping video for {client}: {:?} {}x{} at {} fps",
                info.codec, info.width, info.height, info.fps
            ),
            None => log::debug!("Tapping video for {client} (no ANNOUNCE seen; codec from the bitstream)"),
        }
        // Loopback from Sunshine shouldn't lose packets, given room to buffer.
        enlarge_receive_buffer(upstream);
        let mut dump = self.dump_dir.clone().map(VideoDump::new);
        let mut depth = self.depth.clone().filter(|d| d.available()).map(|d| DepthFeed::new(d, Some(client.ip())));
        Some(VideoTap::start(format!("video tap {client}"), info, self.stats.tap.clone(), move |frame, codec| {
            if let Some(dump) = &mut dump {
                dump.write(frame, codec);
            }
            if let Some(depth) = &mut depth {
                depth.push(frame, codec);
            }
        }))
    }
}

/// Asks for an 8 MB receive buffer (the kernel may cap it at net.core.rmem_max).
fn enlarge_receive_buffer(socket: &UdpSocket) {
    let sock = socket2::SockRef::from(socket);
    let _ = sock.set_recv_buffer_size(8 * 1024 * 1024);
    if let Ok(size) = sock.recv_buffer_size() {
        log::debug!("video upstream receive buffer: {} KB", size / 1024);
    }
}

async fn bind_tcp(port: u16) -> io::Result<TcpListener> {
    match crate::net::tcp_listener(port).await {
        Ok(listener) => Ok(listener),
        Err(_) => TcpListener::bind(("0.0.0.0", port)).await,
    }
}

async fn bind_udp(port: u16) -> io::Result<UdpSocket> {
    match crate::net::udp_socket(port).await {
        Ok(socket) => Ok(socket),
        Err(_) => UdpSocket::bind(("0.0.0.0", port)).await,
    }
}

async fn copy_counted<R, W>(reader: &mut R, writer: &mut W, counter: &AtomicU64) -> io::Result<u64>
where
    R: AsyncReadExt + Unpin,
    W: AsyncWriteExt + Unpin,
{
    let mut buf = vec![0u8; 64 * 1024];
    let mut total = 0u64;
    loop {
        let n = reader.read(&mut buf).await?;
        if n == 0 {
            return Ok(total);
        }
        writer.write_all(&buf[..n]).await?;
        counter.fetch_add(n as u64, Ordering::Relaxed);
        total += n as u64;
    }
}

/// Copies the client's RTSP requests to Sunshine unchanged, noting the
/// stream settings from the ANNOUNCE.
async fn copy_rtsp_requests<R, W>(
    reader: &mut R,
    writer: &mut W,
    counter: &AtomicU64,
    stream: &std::sync::Mutex<Option<StreamInfo>>,
) -> io::Result<u64>
where
    R: AsyncReadExt + Unpin,
    W: AsyncWriteExt + Unpin,
{
    let mut sniffer = AnnounceSniffer::default();
    let mut buf = vec![0u8; 16 * 1024];
    let mut total = 0u64;
    loop {
        let n = reader.read(&mut buf).await?;
        if n == 0 {
            return Ok(total);
        }
        writer.write_all(&buf[..n]).await?;
        counter.fetch_add(n as u64, Ordering::Relaxed);
        total += n as u64;
        if let Some(info) = sniffer.feed(&buf[..n]) {
            log::info!(
                "Stream announced: {:?} {}x{} at {} fps, video {}",
                info.codec,
                info.width,
                info.height,
                info.fps,
                if info.video_encrypted { "encrypted" } else { "unencrypted" }
            );
            if let Ok(mut current) = stream.lock() {
                *current = Some(info);
            }
        }
    }
}

/// Copies Sunshine's RTSP replies to the client, rewriting the UDP ports in
/// Transport headers. Encrypted RTSP (`rtspenc://`) can't be read, so it is
/// passed through as-is and the client's UDP traffic would bypass Meteor.
async fn copy_rtsp_replies<R, W>(
    reader: &mut R,
    writer: &mut W,
    map: &PortMap,
    counter: &AtomicU64,
) -> io::Result<u64>
where
    R: AsyncReadExt + Unpin,
    W: AsyncWriteExt + Unpin,
{
    let mut pending: Vec<u8> = Vec::new();
    let mut buf = vec![0u8; 16 * 1024];
    let mut total = 0u64;
    loop {
        // Wait for a complete header block.
        let header_end = loop {
            if let Some(pos) = find(&pending, b"\r\n\r\n") {
                break Some(pos + 4);
            }
            if (!pending.is_empty() && !b"RTSP/".starts_with(&pending[..pending.len().min(5)]))
                || pending.len() > MAX_RTSP_HEADER
            {
                break None;
            }
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                writer.write_all(&pending).await?;
                return Ok(total + pending.len() as u64);
            }
            pending.extend_from_slice(&buf[..n]);
        };
        let Some(header_end) = header_end else {
            log::warn!("RTSP reply isn't plain text (encrypted RTSP?); passing it through unchanged");
            writer.write_all(&pending).await?;
            counter.fetch_add(pending.len() as u64, Ordering::Relaxed);
            return Ok(total + pending.len() as u64 + copy_counted(reader, writer, counter).await?);
        };
        let header = String::from_utf8_lossy(&pending[..header_end]).into_owned();
        let rewritten = rewrite_rtsp_header(&header, map);
        let body_len = content_length(&header);
        writer.write_all(rewritten.as_bytes()).await?;
        pending.drain(..header_end);
        // Body bytes pass through untouched.
        let mut remaining = body_len;
        let from_pending = remaining.min(pending.len());
        writer.write_all(&pending[..from_pending]).await?;
        pending.drain(..from_pending);
        remaining -= from_pending;
        while remaining > 0 {
            let want = remaining.min(buf.len());
            let n = reader.read(&mut buf[..want]).await?;
            if n == 0 {
                return Ok(total);
            }
            writer.write_all(&buf[..n]).await?;
            remaining -= n;
        }
        let sent = (rewritten.len() + body_len) as u64;
        counter.fetch_add(sent, Ordering::Relaxed);
        total += sent;
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

fn content_length(header: &str) -> usize {
    header
        .lines()
        .find_map(|line| {
            let (key, value) = line.split_once(':')?;
            key.trim().eq_ignore_ascii_case("content-length").then(|| value.trim().parse().ok())?
        })
        .unwrap_or(0)
}

pub fn rewrite_rtsp_header(header: &str, map: &PortMap) -> String {
    let mut out = String::with_capacity(header.len() + 16);
    for line in header.split_inclusive("\r\n") {
        let is_transport = line
            .split_once(':')
            .is_some_and(|(key, _)| key.trim().eq_ignore_ascii_case("transport"));
        if is_transport {
            let rewritten = rewrite_server_ports(line, map);
            if rewritten != line {
                log::info!("RTSP {} -> {}", line.trim_end(), rewritten.trim_end());
            }
            out.push_str(&rewritten);
        } else {
            out.push_str(line);
        }
    }
    out
}

/// `server_port=47998` or `server_port=47998-47999` -> Meteor's ports.
fn rewrite_server_ports(line: &str, map: &PortMap) -> String {
    const KEY: &str = "server_port=";
    let Some(start) = line.find(KEY) else { return line.to_string() };
    let value_start = start + KEY.len();
    let value_end = line[value_start..]
        .find(|c: char| !(c.is_ascii_digit() || c == '-'))
        .map_or(line.len(), |i| value_start + i);
    let ports: Vec<String> = line[value_start..value_end]
        .split('-')
        .map(|p| match p.parse::<u16>() {
            Ok(port) => map.to_meteor(port, Proto::Udp).unwrap_or(port).to_string(),
            Err(_) => p.to_string(),
        })
        .collect();
    format!("{}{}{}", &line[..value_start], ports.join("-"), &line[value_end..])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrites_transport_ports() {
        let map = PortMap::new(47989, 1000).unwrap();
        let reply = "RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: DEADBEEF;timeout = 90\r\n\
                     Transport: server_port=47998\r\n\r\n";
        let out = rewrite_rtsp_header(reply, &map);
        assert!(out.contains("Transport: server_port=48998\r\n"));
        assert!(out.contains("CSeq: 3\r\n"));
        let ranged = rewrite_server_ports("Transport: unicast;server_port=48000-48001;source=x\r\n", &map);
        assert_eq!(ranged, "Transport: unicast;server_port=49000-48001;source=x\r\n");
    }

    #[test]
    fn leaves_other_headers_alone() {
        let map = PortMap::new(47989, 1000).unwrap();
        let reply = "RTSP/1.0 200 OK\r\nX-Port: server_port=47998\r\nContent-Length: 5\r\n\r\n";
        assert_eq!(rewrite_rtsp_header(reply, &map), reply);
        assert_eq!(content_length(reply), 5);
    }

    /// A fake Sunshine that echoes on its HTTP (TCP) and video (UDP) ports.
    #[tokio::test]
    async fn forwards_tcp_and_udp_both_ways() {
        let map = PortMap::new(31989, 1000).unwrap();
        let http = PortMap::channel("http");
        let video = PortMap::channel("video");

        let tcp_echo = TcpListener::bind(("127.0.0.1", map.sunshine(http))).await.unwrap();
        tokio::spawn(async move {
            let (mut s, _) = tcp_echo.accept().await.unwrap();
            let mut buf = [0u8; 64];
            let n = s.read(&mut buf).await.unwrap();
            s.write_all(&buf[..n]).await.unwrap();
        });
        let udp_echo = UdpSocket::bind(("127.0.0.1", map.sunshine(video))).await.unwrap();
        tokio::spawn(async move {
            let mut buf = [0u8; 64];
            loop {
                let (n, from) = udp_echo.recv_from(&mut buf).await.unwrap();
                udp_echo.send_to(&buf[..n], from).await.unwrap();
            }
        });

        let stats = Arc::new(Stats::default());
        let proxy = Proxy::new(map.clone(), "127.0.0.1".into(), stats.clone(), None, None);
        proxy.start().await.unwrap();

        let mut tcp = TcpStream::connect(("127.0.0.1", map.meteor(http))).await.unwrap();
        tcp.write_all(b"GET /serverinfo").await.unwrap();
        let mut buf = [0u8; 64];
        let n = tcp.read(&mut buf).await.unwrap();
        assert_eq!(&buf[..n], b"GET /serverinfo");

        let client = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        client.send_to(b"PING", ("127.0.0.1", map.meteor(video))).await.unwrap();
        let (n, from) = tokio::time::timeout(Duration::from_secs(2), client.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&buf[..n], b"PING");
        // Replies come from Meteor's port, where the client sent them.
        assert_eq!(from.port(), map.meteor(video));
        assert_eq!(stats.udp_flows.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn rtsp_stream_rewrites_and_keeps_body() {
        let map = PortMap::new(47989, 1000).unwrap();
        let input = b"RTSP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nv=0\nRTSP/1.0 200 OK\r\nTransport: server_port=47999\r\n\r\n";
        let mut reader = &input[..];
        let mut out = Vec::new();
        let counter = AtomicU64::new(0);
        copy_rtsp_replies(&mut reader, &mut out, &map, &counter).await.unwrap();
        let text = String::from_utf8(out).unwrap();
        assert_eq!(
            text,
            "RTSP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nv=0\nRTSP/1.0 200 OK\r\nTransport: server_port=48999\r\n\r\n"
        );
    }
}
