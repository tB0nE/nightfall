//! Polls the bundled host for a pending Moonlight pairing request and shows a
//! Windows balloon notification so the user can approve with one click instead
//! of having to find and manually enter the PIN.
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
        let pin_url = format!("https://127.0.0.1:{}/api/pin", base + 1);
        let approve_url = format!("https://127.0.0.1:{}/api/pin", base + 1);
        let mut was_pending = false;
        loop {
            std::thread::sleep(Duration::from_millis(800));
            if weak.upgrade().is_none() { break; }
            let result = check_pending(&agent, &pin_url, &authorization);
            let pending = result.is_some();
            if pending && !was_pending {
                let pin = result.unwrap_or_default();
                log::info!("Pairing watch: incoming pairing request detected (pin={}), showing balloon", pin);
                crate::tray_windows::queue_pairing_balloon(pin, approve_url.clone(), authorization.clone());
            }
            was_pending = pending;
        }
    }).ok();
}

/// Returns `Some(pin)` when a pairing session is pending; `None` otherwise.
/// `pin` is the 4-digit code reported by the client, or empty string if not yet received.
fn check_pending(agent: &ureq::Agent, url: &str, authorization: &str) -> Option<String> {
    let mut response = agent.get(url)
        .header("Authorization", &format!("Basic {authorization}"))
        .call()
        .ok()?;
    let text = response.body_mut().with_config().limit(1024).read_to_string().ok()?;
    let reply: serde_json::Value = serde_json::from_str(&text).ok()?;
    if reply.get("pending").and_then(|v| v.as_bool()) != Some(true) {
        return None;
    }
    let pin = reply.get("pin").and_then(|v| v.as_str()).unwrap_or("").to_string();
    Some(pin)
}
