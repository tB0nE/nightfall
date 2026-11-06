//! Explicit local PIN submission. Credentials never leave this process except
//! in the authenticated loopback request; PINs arrive over stdin, not argv.
use base64::Engine;
use std::io::Read;
use std::time::Duration;

fn validate_pin(pin: &str) -> Result<(), String> {
    if pin.len()!=4 || !pin.bytes().all(|b|b.is_ascii_digit()) {
        return Err("Enter the four digits shown in Nightfall.".into());
    }
    Ok(())
}

fn submit(agent: &ureq::Agent, url: &str, state: &super::State, pin: &str) -> Result<(),String> {
    validate_pin(pin)?;
    let authorization=base64::engine::general_purpose::STANDARD.encode(format!("{}:{}",state.user,state.password));
    let body=serde_json::json!({"pin":pin,"name":"Nightfall"}).to_string();
    let mut response=agent.post(url).header("Authorization",&format!("Basic {authorization}"))
        .header("Content-Type","application/json").send(body.as_bytes())
        .map_err(|_|"Cannot submit the PIN. Check that Meteor's built-in host is running.".to_string())?;
    let bytes=response.body_mut().with_config().limit(4096).read_to_string()
        .map_err(|_|"The host returned an invalid pairing response.".to_string())?;
    let reply:serde_json::Value=serde_json::from_str(&bytes)
        .map_err(|_|"The host returned an invalid pairing response.".to_string())?;
    if reply.get("status").and_then(|v|v.as_bool())!=Some(true) {
        return Err("No pending pairing request accepted the PIN. Open pairing in Nightfall and try again.".into());
    }
    Ok(())
}

pub fn command() -> Result<(),String> {
    let mut input=String::new();
    std::io::stdin().take(65).read_to_string(&mut input).map_err(|_|"Cannot read the PIN.".to_string())?;
    if input.len()>64 {return Err("Enter the four digits shown in Nightfall.".into());}
    let pin=input.trim();validate_pin(pin)?;
    let state=super::load_state();
    let base=state.base.filter(|base|super::BASES.contains(base))
        .ok_or("Start Meteor's built-in host before pairing.")?;
    if state.choice!=super::Choice::Bundled || state.user.is_empty() || state.password.is_empty() {
        return Err("Start Meteor's built-in host before pairing.".into());
    }
    // The bundled host uses a self-signed certificate. This private agent can
    // only reach the fixed numeric loopback endpoint, and follows no redirects.
    let agent:ureq::Agent=ureq::Agent::config_builder()
        .tls_config(ureq::tls::TlsConfig::builder().disable_verification(true).build())
        .max_redirects(0).timeout_global(Some(Duration::from_secs(8))).build().into();
    submit(&agent,&format!("https://127.0.0.1:{}/api/pin",base+1),&state,pin)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_exact_four_ascii_digits() {
        assert!(validate_pin("0123").is_ok());
        for pin in ["", "123", "12345", "１２３４", "12a4", "12\n4"] {assert!(validate_pin(pin).is_err());}
    }
    #[test]
    fn submits_authenticated_pin_and_checks_host_status() {
        for accepted in [true,false] {
            let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let url=format!("http://{}/api/pin",listener.local_addr().unwrap());
            let server=std::thread::spawn(move || {
                use std::io::Write;
                let (mut stream,_)=listener.accept().unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
                let mut request=Vec::new();let mut byte=[0];
                while !request.ends_with(b"\r\n\r\n") {stream.read_exact(&mut byte).unwrap();request.push(byte[0]);}
                let headers=String::from_utf8(request).unwrap();
                assert!(headers.to_lowercase().contains("authorization: basic dxnlcjpwyxnz"));
                let length=headers.lines().find_map(|line|line.to_lowercase().strip_prefix("content-length:").map(|v|v.trim().parse::<usize>().unwrap())).unwrap();
                let mut body=vec![0;length];stream.read_exact(&mut body).unwrap();
                let body:serde_json::Value=serde_json::from_slice(&body).unwrap();assert_eq!(body["pin"],"0123");
                let response=format!("{{\"status\":{accepted}}}");
                write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",response.len(),response).unwrap();
            });
            let state=super::super::State{user:"user".into(),password:"pass".into(),..Default::default()};
            assert_eq!(submit(&ureq::Agent::new_with_defaults(),&url,&state,"0123").is_ok(),accepted);
            server.join().unwrap();
        }
    }
}
