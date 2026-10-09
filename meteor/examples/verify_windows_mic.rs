#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::net::UdpSocket;
    use std::time::{Duration, Instant};
    use wasapi::{DeviceEnumerator, Direction, SampleType, StreamMode, WaveFormat};

    wasapi::initialize_mta().ok()?;
    let devices = DeviceEnumerator::new()?.get_device_collection(&Direction::Capture)?;
    let device = (&devices).into_iter().filter_map(Result::ok)
        .find(|d| d.get_friendlyname().ok().is_some_and(|n| n.contains("CABLE Output")))
        .ok_or("CABLE Output recording endpoint missing")?;
    let mut client = device.get_iaudioclient()?;
    let format = WaveFormat::new(16, 16, &SampleType::Int, 48_000, 1, None);
    client.initialize_client(&format, &Direction::Capture, &StreamMode::PollingShared {
        autoconvert: true, buffer_duration_hns: 500_000,
    })?;
    let capture = client.get_audiocaptureclient()?;
    client.start_stream()?;

    let sender = std::thread::spawn(|| -> std::io::Result<()> {
        std::thread::sleep(Duration::from_millis(300));
        let socket = UdpSocket::bind("127.0.0.1:0")?;
        let mut tick = Instant::now();
        for seq in 0u32..200 {
            let mut packet = [0u8; 976];
            packet[..4].copy_from_slice(b"NFMC");
            packet[4] = 1;
            packet[8..12].copy_from_slice(&seq.to_le_bytes());
            packet[12..16].copy_from_slice(&(seq * 480).to_le_bytes());
            for i in 0..480 {
                let sample = (6000.0 * (std::f64::consts::TAU * 440.0 * f64::from(seq * 480 + i as u32) / 48000.0).sin()) as i16;
                packet[16 + 2*i..18 + 2*i].copy_from_slice(&sample.to_le_bytes());
            }
            socket.send_to(&packet, "127.0.0.1:47902")?;
            tick += Duration::from_millis(10);
            if let Some(wait) = tick.checked_duration_since(Instant::now()) { std::thread::sleep(wait); }
        }
        Ok(())
    });

    let start = Instant::now();
    let mut total = 0u64;
    let mut active = 0u64;
    let mut peak = 0i32;
    while start.elapsed() < Duration::from_secs(3) {
        if let Some(frames) = capture.get_next_packet_size()? {
            if frames > 0 {
                let mut data = vec![0u8; frames as usize * 2];
                let (read, _) = capture.read_from_device(&mut data)?;
                for pair in data[..read as usize * 2].chunks_exact(2) {
                    let sample = i16::from_le_bytes([pair[0], pair[1]]) as i32;
                    total += 1;
                    if sample.abs() > 500 { active += 1; }
                    peak = peak.max(sample.abs());
                }
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    sender.join().map_err(|_| "sender panicked")??;
    client.stop_stream()?;
    println!("CABLE Output capture: {total} samples, {active} above threshold, peak {peak}");
    if active < 10_000 { return Err("microphone tone did not reach CABLE Output".into()); }
    Ok(())
}

#[cfg(not(windows))]
fn main() {}
