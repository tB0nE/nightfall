//! The Linux desktop: autostart and notifications (freedesktop.org specs).

use std::path::{Path, PathBuf};

/// Meteor's entry in `~/.config/autostart`.
fn autostart_path() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .unwrap_or_default();
    base.join("autostart").join("nightfall-meteor.desktop")
}

/// What autostart runs: the AppImage itself (`$APPIMAGE`, set by its
/// runtime), else this binary.
pub fn launcher() -> Option<PathBuf> {
    std::env::var_os("APPIMAGE").map(PathBuf::from).or_else(|| std::env::current_exe().ok())
}

pub fn autostart_enabled() -> bool {
    autostart_path().is_file()
}

/// Turns autostart on or off.
pub fn set_autostart(on: bool) -> Result<(), String> {
    let path = autostart_path();
    if !on {
        return match std::fs::remove_file(&path) {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => Err(format!("{}: {err}", path.display())),
            _ => Ok(()),
        };
    }
    let exe = launcher().ok_or("can't tell where Meteor is")?;
    let entry = format!(
        "[Desktop Entry]\n\
         Type=Application\n\
         Name=Nightfall Meteor\n\
         Comment=Host depth and microphone for Nightfall on Meta Quest\n\
         Exec={}\n\
         Terminal=false\n\
         X-GNOME-Autostart-enabled=true\n\
         X-KDE-autostart-after=panel\n",
        quote_exec(&exe)
    );
    path.parent().map_or(Ok(()), std::fs::create_dir_all).map_err(|e| e.to_string())?;
    std::fs::write(&path, entry).map_err(|e| format!("{}: {e}", path.display()))
}

/// On every start: the first run of the AppImage turns autostart on (running
/// it is taken as the wish to use Meteor), and an entry pointing at an
/// AppImage that has since moved is updated.
pub fn update_autostart() {
    let Some(appimage) = std::env::var_os("APPIMAGE").map(PathBuf::from) else { return };
    let marker = crate::config::config_dir().join("autostart-offered");
    if !marker.exists() {
        let _ = marker.parent().map(std::fs::create_dir_all);
        let _ = std::fs::write(&marker, "Meteor turned autostart on once; it won't again.\n");
        match set_autostart(true) {
            Ok(()) => log::info!("Autostart on ({})", autostart_path().display()),
            Err(err) => log::warn!("Can't turn autostart on: {err}"),
        }
        return;
    }
    if autostart_enabled() && exec_of(&autostart_path()).as_deref() != Some(appimage.as_path()) {
        match set_autostart(true) {
            Ok(()) => log::info!("Autostart now starts {}", appimage.display()),
            Err(err) => log::warn!("Can't update autostart: {err}"),
        }
    }
}

/// The program an entry's Exec line runs.
fn exec_of(entry: &Path) -> Option<PathBuf> {
    let text = std::fs::read_to_string(entry).ok()?;
    let exec = text.lines().find_map(|l| l.strip_prefix("Exec="))?;
    Some(PathBuf::from(unquote_exec(exec)))
}

/// Quotes a path for an Exec line: inside double quotes, `"`, `` ` ``, `$`
/// and `\` are escaped with a backslash.
fn quote_exec(path: &Path) -> String {
    let mut out = String::from("\"");
    for c in path.to_string_lossy().chars() {
        if matches!(c, '"' | '`' | '$' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

fn unquote_exec(exec: &str) -> String {
    let Some(inner) = exec.strip_prefix('"').and_then(|e| e.strip_suffix('"')) else {
        return exec.split_whitespace().next().unwrap_or_default().to_string();
    };
    let mut out = String::new();
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        out.push(if c == '\\' { chars.next().unwrap_or('\\') } else { c });
    }
    out
}

/// Shows a desktop notification. Best effort: a desktop without a
/// notification service just logs it.
pub async fn notify(summary: &str, body: &str) {
    let result = async {
        let connection = zbus::Connection::session().await?;
        let hints: std::collections::HashMap<&str, zbus::zvariant::Value> = Default::default();
        connection
            .call_method(
                Some("org.freedesktop.Notifications"),
                "/org/freedesktop/Notifications",
                Some("org.freedesktop.Notifications"),
                "Notify",
                &("Nightfall Meteor", 0u32, "", summary, body, Vec::<&str>::new(), hints, -1i32),
            )
            .await?;
        Ok::<(), zbus::Error>(())
    }
    .await;
    if let Err(err) = result {
        log::info!("Couldn't show a notification ({err}): {summary}");
    }
}

pub async fn copy_text(text: &str) -> std::io::Result<()> {
    // KDE exposes its clipboard manager over the same session bus as the tray.
    // Other desktops normally provide wl-copy or xclip. Never execute the text.
    if let Ok(connection) = zbus::Connection::session().await {
        if matches!(tokio::time::timeout(std::time::Duration::from_secs(2),
            connection.call_method(Some("org.kde.klipper"), "/klipper",
                Some("org.kde.klipper.klipper"), "setClipboardContents", &(text,))).await, Ok(Ok(_))) {
            return Ok(());
        }
    }
    use tokio::io::AsyncWriteExt;
    let candidates = [("wl-copy", vec!["--type", "text/plain;charset=utf-8"]),
                      ("xclip", vec!["-selection", "clipboard"])];
    for (program, arguments) in candidates {
        let result = tokio::time::timeout(std::time::Duration::from_secs(3), async {
            let mut child = tokio::process::Command::new(program).args(arguments)
                .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null()).kill_on_drop(true).spawn()?;
            let mut input = child.stdin.take().unwrap();
            input.write_all(text.as_bytes()).await?;
            drop(input);
            if child.wait().await?.success() { Ok(()) }
            else { Err(std::io::Error::other("Clipboard tool failed")) }
        }).await;
        if matches!(result, Ok(Ok(()))) { return Ok(()); }
    }
    Err(std::io::Error::other("Clipboard unavailable. Enable your desktop clipboard manager or install wl-clipboard (Wayland) / xclip (X11)."))
}

pub fn watch_xr_approval(trust: std::sync::Arc<crate::xr_trust::Trust>) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
        loop {
            tick.tick().await;
            if let Some((key, code)) = trust.take_notification() {
                let trust = trust.clone();
                tokio::spawn(async move {
                    if let Err(error) = xr_approval_popup(trust, key, code).await {
                        log::warn!("XR approval popup unavailable ({error}); use Approve in Meteor's tray menu");
                    }
                });
            }
        }
    });
}

/// Let the desktop resolve browser preferences. Child xdg-open processes can
/// otherwise inherit an isolated Meteor profile and launch its fallback browser.
pub fn open_web_url(url: String) {
    tokio::spawn(async move {
        if let Err(error) = portal_open_web_url(&url).await {
            log::debug!("Desktop URL portal unavailable ({error}); using xdg-open");
            if let Err(error) = std::process::Command::new("xdg-open").arg(&url).spawn() {
                log::warn!("Cannot open web link: {error}");
            }
        }
    });
}

async fn portal_open_web_url(url: &str) -> zbus::Result<()> {
    use futures_lite::StreamExt;
    let connection = zbus::Connection::session().await?;
    let sender = connection.unique_name().expect("session connection has a unique name")
        .as_str().trim_start_matches(':').replace('.', "_");
    let path = format!("/org/freedesktop/portal/desktop/request/{sender}/nightfall");
    let request = zbus::Proxy::new(&connection, "org.freedesktop.portal.Desktop", path.as_str(),
        "org.freedesktop.portal.Request").await?;
    // Subscribe before opening: the portal may immediately dispatch the browser.
    let mut response = request.receive_signal("Response").await?;
    let portal = zbus::Proxy::new(&connection, "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop", "org.freedesktop.portal.OpenURI").await?;
    let options: std::collections::HashMap<&str,zbus::zvariant::Value> = [
        ("handle_token",zbus::zvariant::Value::from("nightfall")),
        ("ask",zbus::zvariant::Value::Bool(false)),
    ].into();
    let _handle: zbus::zvariant::OwnedObjectPath = portal.call("OpenURI", &("",url,options)).await?;
    match tokio::time::timeout(std::time::Duration::from_secs(60),response.next()).await {
        Ok(Some(signal)) => {
            let (status,_): (u32,std::collections::HashMap<String,zbus::zvariant::OwnedValue>) = signal.body().deserialize()?;
            // Cancellation is intentional: don't launch a fallback browser.
            if status>1 {return Err(zbus::Error::Failure("Desktop could not open the link".into()));}
        }
        _ => {
            let _:zbus::Result<()> = request.call("Close", &()).await;
            log::info!("Desktop link request expired");
        }
    }
    Ok(())
}

pub async fn host_setup_popup(view: std::sync::Arc<crate::host::view::View>) -> zbus::Result<()> {
    use futures_lite::StreamExt;
    let connection=zbus::Connection::session().await?;
    let proxy=zbus::Proxy::new(&connection,"org.freedesktop.Notifications",
        "/org/freedesktop/Notifications","org.freedesktop.Notifications").await?;
    let mut actions=proxy.receive_signal("ActionInvoked").await?;
    let mut closed=proxy.receive_signal("NotificationClosed").await?;
    let hints:std::collections::HashMap<&str,zbus::zvariant::Value>=
        [("resident",zbus::zvariant::Value::Bool(true))].into();
    let (action,body)=if view.binary.is_some() {
        ("Use Meteor-Vibepollo","No Sunshine-compatible host was detected. Use Meteor-Vibepollo for Nightfall? Meteor will run it with its own settings. You can change this later in Meteor's tray.")
    } else {
        ("Download and set up","No Sunshine-compatible host was detected. Download and set up Meteor-Vibepollo for Nightfall? Meteor will check the download, run the host with its own settings and restart. Nothing is installed until you accept. You can also set it up later in the tray.")
    };
    let id:u32=proxy.call("Notify", &("Nightfall Meteor",0u32,"",
        "Set up a streaming host?",body,vec!["setup",action,"later","Not now"],hints,0i32)).await?;
    let timeout=tokio::time::sleep(std::time::Duration::from_secs(300));tokio::pin!(timeout);
    loop {
        tokio::select! {
            _=&mut timeout=>break,
            signal=closed.next()=>{
                let Some(signal)=signal else {break};
                if signal.body().deserialize::<(u32,u32)>().is_ok_and(|(notification,_)|notification==id) {break;}
            },
            signal=actions.next()=>{
                let Some(signal)=signal else {break};
                if let Ok((notification,action))=signal.body().deserialize::<(u32,String)>() {
                    if notification!=id {continue;}
                    if action=="setup" {
                        if view.binary.is_some() {view.switch(crate::host::Choice::Bundled);}
                        else {view.download_and_switch();}
                    }
                    if action=="setup" || action=="later" {break;}
                }
            }
        }
    }
    let _:zbus::Result<()>=proxy.call("CloseNotification", &(id,)).await;
    Ok(())
}

pub async fn input_setup_popup(input: std::sync::Arc<crate::host::input::Access>) -> zbus::Result<()> {
    use futures_lite::StreamExt;
    let connection=zbus::Connection::session().await?;
    let proxy=zbus::Proxy::new(&connection,"org.freedesktop.Notifications",
        "/org/freedesktop/Notifications","org.freedesktop.Notifications").await?;
    let mut actions=proxy.receive_signal("ActionInvoked").await?;
    let id:u32=proxy.call("Notify", &("Nightfall Meteor",0u32,"",
        "Enable Nightfall keyboard and controller input?",
        "Meteor cannot access virtual input devices. Enable access for the active desktop session? This requires administrator approval, installs a device-access rule, and restarts Meteor. Any active stream will disconnect. You can also set this up later in the tray.",
        vec!["setup","Enable input","later","Not now"],std::collections::HashMap::<&str,zbus::zvariant::Value>::new(),60_000i32)).await?;
    let timeout=tokio::time::sleep(std::time::Duration::from_secs(60));tokio::pin!(timeout);
    loop {
        tokio::select! {
            _=&mut timeout=>break,
            signal=actions.next()=>{
                let Some(signal)=signal else {break};
                if let Ok((notification,action))=signal.body().deserialize::<(u32,String)>() {
                    if notification!=id {continue;}
                    if action=="setup" {input.setup();break;}
                    if action=="later" {break;}
                }
            }
        }
    }
    let _:zbus::Result<()>=proxy.call("CloseNotification", &(id,)).await;
    Ok(())
}

pub async fn host_pairing_popup(pairing: std::sync::Arc<crate::host::pairing::Pairing>, request: String) -> zbus::Result<()> {
    use futures_lite::StreamExt;
    let Some(pending) = pairing.pending().filter(|p|p.id==request) else { return Ok(()) };
    let connection = zbus::Connection::session().await?;
    let proxy = zbus::Proxy::new(&connection, "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications", "org.freedesktop.Notifications").await?;
    let mut actions = proxy.receive_signal("ActionInvoked").await?;
    let hints: std::collections::HashMap<&str, zbus::zvariant::Value> =
        [("resident", zbus::zvariant::Value::Bool(true))].into();
    let body = format!("Nightfall headset at {} requests desktop streaming. PIN: {}. Compare with the PIN in your headset, then approve only if they match. Approval is also available in Meteor's tray.",pending.peer,pending.pin);
    let id: u32 = proxy.call("Notify", &("Nightfall Meteor",0u32,"",
        "Pair Nightfall headset?",body,vec!["approve","Approve","reject","Reject"],hints,60_000i32)).await?;
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
    loop {
        tokio::select! {
            _=tick.tick()=>if !pairing.pending().is_some_and(|p|p.id==request) {break;},
            signal=actions.next()=>{
                let Some(signal)=signal else {break};
                if let Ok((notification,action))=signal.body().deserialize::<(u32,String)>() {
                    if notification!=id {continue;}
                    match action.as_str() {
                        "approve"=>{pairing.approve(&request);break;},
                        "reject"=>{pairing.reject(&request);break;},
                        _=>{},
                    }
                }
            }
        }
    }
    let _:zbus::Result<()>=proxy.call("CloseNotification", &(id,)).await;
    Ok(())
}

async fn xr_approval_popup(trust: std::sync::Arc<crate::xr_trust::Trust>, key: [u8; 32], code: String) -> zbus::Result<()> {
    use futures_lite::StreamExt;
    let connection = zbus::Connection::session().await?;
    let proxy = zbus::Proxy::new(&connection, "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications", "org.freedesktop.Notifications").await?;
    // Subscribe first: a fast response must not be lost between Notify and listen.
    let mut actions = proxy.receive_signal("ActionInvoked").await?;
    let hints: std::collections::HashMap<&str, zbus::zvariant::Value> =
        [("resident", zbus::zvariant::Value::Bool(true))].into();
    let body = format!("Headset code: {code}. Compare this with the code in Nightfall. Approve only if they match. You can also approve in Meteor's tray menu.");
    let id: u32 = proxy.call("Notify", &("Nightfall Meteor", 0u32, "",
        "Approve Nightfall XR headset", body,
        vec!["approve", "Approve", "reject", "Reject"], hints, 60_000i32)).await?;
    let mut tick = tokio::time::interval(std::time::Duration::from_secs(1));
    loop {
        tokio::select! {
            _ = tick.tick() => {
                if !trust.pending().is_some_and(|(pending, _)| pending == key) { break; }
            }
            signal = actions.next() => {
                let Some(signal) = signal else { break; };
                if let Ok((notification, action)) = signal.body().deserialize::<(u32, String)>() {
                    if notification != id { continue; }
                    match action.as_str() {
                        "approve" => {
                            if let Err(error) = trust.approve(key) { log::warn!("XR approval failed: {error}"); }
                            break;
                        }
                        "reject" => { trust.reject(key); break; }
                        _ => {}
                    }
                }
            }
        }
    }
    let _: zbus::Result<()> = proxy.call("CloseNotification", &(id,)).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    #[ignore = "manual desktop integration check; writes Steam launch options to the user's clipboard"]
    async fn copies_installed_steam_options_to_clipboard() {
        let root = crate::config::load().xr.runtime_root();
        crate::xr_library::set_runtime_root(root);
        copy_text(&crate::xr_library::steam_launch_options().unwrap()).await.unwrap();
    }

    #[test]
    fn exec_lines_round_trip() {
        let path = Path::new("/home/me/My Apps/Meteor \"$1\".AppImage");
        let quoted = quote_exec(path);
        assert_eq!(quoted, "\"/home/me/My Apps/Meteor \\\"\\$1\\\".AppImage\"");
        assert_eq!(unquote_exec(&quoted), path.to_string_lossy());
        assert_eq!(unquote_exec("/usr/bin/meteor --no-tray"), "/usr/bin/meteor");
    }
}
