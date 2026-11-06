//! Polls the bundled host for a pending Moonlight pairing request and shows a
//! Windows balloon notification so the user can click to approve instead of
//! having to find and enter the PIN manually.
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;

pub fn start(supervisor: &Arc<super::Supervisor>) {
    let base = supervisor.instance.base;
    let weak = Arc::downgrade(supervisor);
    std::thread::Builder::new().name("pair-watch".into()).spawn(move || {
        let state = super::load_state();
        if state.user.is_empty() || state.password.is_empty() {
            log::warn!("Pairing watch: no host credentials, notifications disabled");
            return;
        }
        let authorization = base64::engine::general_purpose::STANDARD
            .encode(format!("{}:{}", state.user, state.password));
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .tls_config(ureq::tls::TlsConfig::builder().disable_verification(true).build())
            .max_redirects(0)
            .timeout_global(Some(Duration::from_secs(5)))
            .build()
            .into();
        let url = format!("https://127.0.0.1:{}/api/pin", base + 1);
        let clients_url = format!("https://localhost:{}/clients", base + 1);
        let mut was_pending = false;
        loop {
            std::thread::sleep(Duration::from_millis(800));
            if weak.upgrade().is_none() { break; }
            let pending = check_pending(&agent, &url, &authorization);
            if pending && !was_pending {
                log::info!("Pairing watch: incoming pairing request detected, showing balloon");
                crate::tray_windows::queue_pairing_balloon(clients_url.clone());
            }
            was_pending = pending;
        }
    }).ok();
}

fn check_pending(agent: &ureq::Agent, url: &str, authorization: &str) -> bool {
    let mut response = match agent.get(url)
        .header("Authorization", &format!("Basic {authorization}"))
        .call()
    {
        Ok(r) => r,
        Err(_) => return false,
    };
    let text = match response.body_mut().with_config().limit(1024).read_to_string() {
        Ok(t) => t,
        Err(_) => return false,
    };
    let reply: serde_json::Value = match serde_json::from_str(&text) {
        Ok(v) => v,
        Err(_) => return false,
    };
    reply.get("pending").and_then(|v| v.as_bool()) == Some(true)
}
