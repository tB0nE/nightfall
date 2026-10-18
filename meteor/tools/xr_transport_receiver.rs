//! Loopback-only diagnostic receiver. Not compiled into the Meteor application.
#[path = "../src/xr_wire.rs"]
mod xr_wire;
use std::{
    env,
    fs::File,
    io::{self, Write},
    net::TcpListener,
    path::PathBuf,
    time::{Duration, Instant},
};

fn main() -> io::Result<()> {
    let out = PathBuf::from(env::args().nth(1).expect("output directory required"));
    let listener = TcpListener::bind(("127.0.0.1", 0))?;
    listener.set_nonblocking(true)?;
    println!("PORT {}", listener.local_addr()?.port());
    io::stdout().flush()?;
    let start = Instant::now();
    let mut stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(e)
                if e.kind() == io::ErrorKind::WouldBlock
                    && start.elapsed() < Duration::from_secs(10) =>
            {
                std::thread::sleep(Duration::from_millis(5))
            }
            Err(e) => return Err(e),
        }
    };
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    stream.set_write_timeout(Some(Duration::from_secs(5)))?;
    stream.set_nodelay(true)?;
    let mut video = File::create(out.join("received.h264"))?;
    let mut metadata = File::create(out.join("received.jsonl"))?;
    let mut reader = xr_wire::Reader::default();
    let (mut frames, mut offset) = (0u64, 0u64);
    while let Some(frame) = reader.read(&mut stream)? {
        let h = frame.header;
        video.write_all(&frame.payload)?;
        video.flush()?;
        writeln!(
            metadata,
            "{{\"epoch\":{},\"sequence\":{},\"frame_id\":{},\"display_time_ns\":{},\"offset\":{},\"bytes\":{},\"width\":{},\"height\":{},\"view_values\":{:?}}}",
            h.epoch,
            h.sequence,
            h.frame_id,
            h.display_ns,
            offset,
            h.payload_len,
            h.width,
            h.height,
            h.views
        )?;
        metadata.flush()?;
        offset += h.payload_len as u64;
        frames += 1;
        stream.write_all(b"NFXA")?;
        stream.write_all(&h.sequence.to_le_bytes())?;
        stream.write_all(&h.frame_id.to_le_bytes())?;
    }
    stream.write_all(b"NFXE")?;
    stream.write_all(&frames.to_le_bytes())?;
    println!("PASS received={frames} bytes={offset}");
    Ok(())
}
