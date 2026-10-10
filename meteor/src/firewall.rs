//! Checks that the firewall lets the Quest reach Meteor. A blocked port is
//! silent: the Quest doesn't find Meteor and quietly uses on-device depth,
//! so the tray says so and offers to open the ports.
//!
//! firewalld is queried without privileges (the zone of the interface the
//! default route uses). ufw's rules need root to read, so an active ufw is
//! reported as unknown. Opening the ports runs one `pkexec` command, only
//! when the user chooses "Allow" in the tray.

use std::process::Command;

use crate::ports::{CHANNELS, PortMap, Proto};

/// The ports the Quest connects to, by protocol.
pub fn ports(map: &PortMap, discovery: u16) -> Vec<(u16, Proto)> {
    let mut ports = vec![
        (discovery, Proto::Tcp),
        (crate::depth_server::DEFAULT_DEPTH_PORT, Proto::Tcp),
        (crate::mic::DEFAULT_MIC_PORT, Proto::Udp),
    ];
    ports.extend(CHANNELS.iter().map(|c| (map.meteor(*c), c.proto)));
    ports.sort_by_key(|&(port, proto)| (proto == Proto::Udp, port));
    ports
}

fn spec((port, proto): (u16, Proto)) -> String {
    format!("{port}/{}", if proto == Proto::Tcp { "tcp" } else { "udp" })
}

#[derive(Clone, Debug, PartialEq)]
pub enum Status {
    Checking,
    /// No firewall, or every port is open.
    Open,
    /// firewalld blocks these in this zone.
    Blocked { zone: String, ports: Vec<(u16, Proto)> },
    /// ufw is active; its rules can't be read without root.
    Ufw,
}

fn run(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Queries the firewall. Takes a few hundred milliseconds.
pub fn check(ports: &[(u16, Proto)]) -> Status {
    if run("firewall-cmd", &["--state"]).as_deref() == Some("running") {
        let zone = zone();
        if run("firewall-cmd", &["--permanent", &format!("--zone={zone}"), "--get-target"]).as_deref() == Some("ACCEPT") {
            return Status::Open;
        }
        let services: Vec<String> = run("firewall-cmd", &[&format!("--zone={zone}"), "--list-services"])
            .unwrap_or_default()
            .split_whitespace()
            .map(str::to_string)
            .collect();
        let service_ports: Vec<String> = services
            .iter()
            .filter_map(|s| run("firewall-cmd", &[&format!("--info-service={s}")]))
            .flat_map(|info| {
                info.lines()
                    .find_map(|l| l.trim().strip_prefix("ports:").map(|p| p.split_whitespace().map(str::to_string).collect::<Vec<_>>()))
                    .unwrap_or_default()
            })
            .collect();
        let blocked: Vec<(u16, Proto)> = ports
            .iter()
            .copied()
            .filter(|&p| {
                // --query-port understands the zone's port ranges.
                let open = run("firewall-cmd", &[&format!("--zone={zone}"), &format!("--query-port={}", spec(p))]).as_deref() == Some("yes");
                !open && !service_ports.iter().any(|s| covers(s, p))
            })
            .collect();
        return if blocked.is_empty() { Status::Open } else { Status::Blocked { zone, ports: blocked } };
    }
    if run("systemctl", &["is-active", "--quiet", "ufw"]).is_some() {
        return Status::Ufw;
    }
    Status::Open
}

/// The zone of the default route's interface, else the default zone.
fn zone() -> String {
    let device = run("ip", &["-o", "route", "get", "1.1.1.1"])
        .and_then(|r| r.split_whitespace().skip_while(|w| *w != "dev").nth(1).map(str::to_string));
    device
        .and_then(|d| run("firewall-cmd", &[&format!("--get-zone-of-interface={d}")]))
        .or_else(|| run("firewall-cmd", &["--get-default-zone"]))
        .unwrap_or_else(|| "public".into())
}

/// Whether a service's `1025-65535/udp` or `48010/tcp` covers a port.
fn covers(service_port: &str, (port, proto): (u16, Proto)) -> bool {
    let Some((range, p)) = service_port.split_once('/') else { return false };
    if p != if proto == Proto::Tcp { "tcp" } else { "udp" } {
        return false;
    }
    let (lo, hi) = range.split_once('-').unwrap_or((range, range));
    matches!((lo.parse::<u16>(), hi.parse::<u16>()), (Ok(lo), Ok(hi)) if (lo..=hi).contains(&port))
}

/// Opens the ports, asking for the password through pkexec. Blocks until
/// the user answers.
pub fn allow(status: &Status, ports: &[(u16, Proto)]) -> Result<(), String> {
    let script = match status {
        Status::Blocked { zone, ports } => {
            let adds: Vec<String> = ports.iter().map(|&p| format!("--add-port={}", spec(p))).collect();
            format!("firewall-cmd --permanent --zone={zone} {} && firewall-cmd --reload", adds.join(" "))
        }
        Status::Ufw => {
            let rules: Vec<String> = ports.iter().map(|&p| format!("ufw allow {}", spec(p))).collect();
            rules.join(" && ")
        }
        _ => return Ok(()),
    };
    log::info!("Opening the firewall: {script}");
    let status = Command::new("pkexec").args(["sh", "-c", &script]).status().map_err(|e| format!("pkexec: {e}"))?;
    if status.success() { Ok(()) } else { Err(format!("the firewall change didn't happen ({status})")) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_the_default_ports() {
        let map = PortMap::new(47989, 1000).unwrap();
        let specs: Vec<String> = ports(&map, 47900).into_iter().map(spec).collect();
        assert_eq!(
            specs,
            ["47900/tcp", "47901/tcp", "48984/tcp", "48989/tcp", "49010/tcp", "47902/udp", "48998/udp", "48999/udp", "49000/udp", "49002/udp"]
        );
    }

    #[test]
    fn service_ranges_cover_ports() {
        assert!(covers("1025-65535/udp", (48998, Proto::Udp)));
        assert!(!covers("1025-65535/udp", (48998, Proto::Tcp)));
        assert!(covers("47900/tcp", (47900, Proto::Tcp)));
        assert!(!covers("22/tcp", (47900, Proto::Tcp)));
    }
}
