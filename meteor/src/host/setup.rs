//! First run: opens the Setup window once, on the first start with a tray.
fn local_host(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]")
}

/// Opens Setup the first time. An existing install has this marker already,
/// so it isn't opened on anyone who has set up by hand.
pub fn offer(config: &crate::config::Config) {
    let marker = crate::config::config_dir().join("host-setup-offered");
    if marker.exists() || !local_host(&config.sunshine_host) { return; }
    let result=std::fs::create_dir_all(crate::config::config_dir())
        .and_then(|()|std::fs::write(&marker,"Setup was offered; it stays in Meteor's menu.\n"));
    if let Err(error)=result {log::warn!("Cannot remember the setup offer: {error}");return;}
    crate::setup_window::open();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_a_host_on_this_pc_counts_as_local() {
        assert!(!local_host("10.0.0.13"));assert!(local_host("::1"));assert!(local_host("127.0.0.1"));
    }
}
