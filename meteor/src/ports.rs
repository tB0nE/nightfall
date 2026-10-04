//! Sunshine's port layout, and the matching ports Meteor listens on.
//!
//! Every Sunshine port is a fixed offset from its configured base port
//! (`port` in sunshine.conf, 47989 by default). Meteor listens on the same
//! layout shifted by `port_offset`, so the two can share one machine.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Proto {
    Tcp,
    Udp,
}

#[derive(Clone, Copy, Debug)]
pub struct Channel {
    pub name: &'static str,
    pub proto: Proto,
    /// Offset from Sunshine's base (HTTP) port.
    pub base_offset: i32,
}

pub const CHANNELS: [Channel; 7] = [
    Channel { name: "https", proto: Proto::Tcp, base_offset: -5 },
    Channel { name: "http", proto: Proto::Tcp, base_offset: 0 },
    Channel { name: "rtsp", proto: Proto::Tcp, base_offset: 21 },
    Channel { name: "video", proto: Proto::Udp, base_offset: 9 },
    Channel { name: "control", proto: Proto::Udp, base_offset: 10 },
    Channel { name: "audio", proto: Proto::Udp, base_offset: 11 },
    Channel { name: "mic", proto: Proto::Udp, base_offset: 13 },
];

#[derive(Clone, Debug)]
pub struct PortMap {
    pub sunshine_base: u16,
    pub offset: u16,
}

impl PortMap {
    pub fn new(sunshine_base: u16, offset: u16) -> Result<Self, String> {
        let map = PortMap { sunshine_base, offset };
        for ch in CHANNELS {
            let sunshine = i32::from(sunshine_base) + ch.base_offset;
            let meteor = sunshine + i32::from(offset);
            if !(1..=65535).contains(&sunshine) || !(1..=65535).contains(&meteor) {
                return Err(format!("{} port out of range (base {sunshine_base}, offset {offset})", ch.name));
            }
        }
        // A small offset would make Meteor try to listen on Sunshine's own ports.
        for a in CHANNELS {
            for b in CHANNELS {
                if a.proto == b.proto && map.meteor(a) == map.sunshine(b) {
                    return Err(format!(
                        "port_offset {offset} puts Meteor's {} port on Sunshine's {} port ({})",
                        a.name, b.name, map.meteor(a)
                    ));
                }
            }
        }
        Ok(map)
    }

    pub fn sunshine(&self, ch: Channel) -> u16 {
        (i32::from(self.sunshine_base) + ch.base_offset) as u16
    }

    pub fn meteor(&self, ch: Channel) -> u16 {
        self.sunshine(ch) + self.offset
    }

    pub fn channel(name: &str) -> Channel {
        *CHANNELS.iter().find(|c| c.name == name).expect("known channel")
    }

    /// Meteor's port for one of Sunshine's ports, if it's one Meteor proxies.
    pub fn to_meteor(&self, sunshine_port: u16, proto: Proto) -> Option<u16> {
        CHANNELS
            .iter()
            .find(|c| c.proto == proto && self.sunshine(**c) == sunshine_port)
            .map(|c| self.meteor(*c))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_layout() {
        let map = PortMap::new(47989, 1000).unwrap();
        assert_eq!(map.sunshine(PortMap::channel("https")), 47984);
        assert_eq!(map.sunshine(PortMap::channel("rtsp")), 48010);
        assert_eq!(map.meteor(PortMap::channel("http")), 48989);
        assert_eq!(map.meteor(PortMap::channel("video")), 48998);
        assert_eq!(map.to_meteor(47999, Proto::Udp), Some(48999));
        assert_eq!(map.to_meteor(47999, Proto::Tcp), None);
    }

    #[test]
    fn rejects_overlapping_offset() {
        // Meteor's video port (47998 + 1) would land on Sunshine's control port.
        assert!(PortMap::new(47989, 1).is_err());
    }
}
