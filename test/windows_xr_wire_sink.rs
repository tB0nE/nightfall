// Local Windows delivery proof using Meteor's production framing validator.
#[path = "../meteor/src/xr_wire.rs"]
mod xr_wire;
use std::{io::{self, Write}, net::TcpListener, time::{Duration, Instant}};
fn main() -> io::Result<()> {
    let args: Vec<_> = std::env::args().collect();
    let port: u16 = args.get(1).ok_or(io::ErrorKind::InvalidInput)?.parse().map_err(|_| io::ErrorKind::InvalidInput)?;
    let mut output = std::fs::File::create(args.get(2).ok_or(io::ErrorKind::InvalidInput)?)?;
    let expected_y=args.get(3).map(|value|value.parse::<f32>().map_err(|_|io::ErrorKind::InvalidInput)).transpose()?;
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST,port))?;
    println!("wire_sink_port={}",listener.local_addr()?.port());
    io::stdout().flush()?;
    listener.set_nonblocking(true)?;
    let deadline = Instant::now()+Duration::from_secs(20);
    let mut socket = loop {
        match listener.accept() {
            Ok((socket,_)) => break socket,
            Err(e) if e.kind()==io::ErrorKind::WouldBlock && Instant::now()<deadline => std::thread::sleep(Duration::from_millis(10)),
            Err(e) => return Err(e),
        }
    };
    socket.set_nonblocking(false)?;
    socket.set_read_timeout(Some(Duration::from_secs(5)))?;
    socket.set_write_timeout(Some(Duration::from_secs(5)))?;
    let mut reader = xr_wire::Reader::default();
    let mut count = 0u64;
    while let Some(frame) = reader.read(&mut socket)? {
        if let Some(expected)=expected_y {
            let centre=(frame.header.views[1]+frame.header.views[12])*0.5;
            if (centre-expected).abs()>0.001 {
                return Err(io::Error::other(format!("Projection centre_y={centre}, expected tracked centre_y={expected}")));
            }
        }
        output.write_all(&frame.payload)?;
        let mut ack = b"NFXA".to_vec();
        ack.extend_from_slice(&frame.header.sequence.to_le_bytes());
        ack.extend_from_slice(&frame.header.frame_id.to_le_bytes());
        socket.write_all(&ack)?;
        count+=1;
        println!("validated_frame={} size={}x{} bytes={}",count,frame.header.width,frame.header.height,frame.payload.len());
    }
    let mut ack = b"NFXE".to_vec(); ack.extend_from_slice(&count.to_le_bytes());
    socket.write_all(&ack)?;
    output.flush()?;
    if count==0 { return Err(io::ErrorKind::UnexpectedEof.into()); }
    println!("PASS: {} frames and clean END through Meteor wire validator",count);
    Ok(())
}
