//! macOS desktop integration: notifications, the pairing approval dialog,
//! the clipboard and opening links. Uses the system's own tools
//! (`osascript`, `pbcopy`, `open`), so it needs no signed app bundle.
//!
//! Text is always passed to AppleScript as `argv`, never spliced into the
//! script, so a peer address or an error message can't inject a command.

use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

/// Runs a short AppleScript whose `on run argv` handler reads `args`.
fn osascript(lines: &[&str], args: &[&str]) -> tokio::process::Command {
    let mut command = tokio::process::Command::new("/usr/bin/osascript");
    for line in lines {
        command.arg("-e").arg(line);
    }
    command.args(args).stdin(Stdio::null()).kill_on_drop(true);
    command
}

/// Shows a notification. Best effort: failures are only logged.
pub async fn notify(summary: &str, body: &str) {
    let result = osascript(
        &[
            "on run argv",
            "display notification (item 2 of argv) with title \"Nightfall Meteor\" subtitle (item 1 of argv)",
            "end run",
        ],
        &[summary, body],
    )
    .stdout(Stdio::null())
    .stderr(Stdio::piped())
    .output()
    .await;
    match result {
        Ok(output) if output.status.success() => {}
        Ok(output) => log::info!(
            "Couldn't show a notification ({}): {summary}",
            String::from_utf8_lossy(&output.stderr).trim()
        ),
        Err(error) => log::info!("Couldn't show a notification ({error}): {summary}"),
    }
}

pub async fn copy_text(text: &str) -> std::io::Result<()> {
    use tokio::io::AsyncWriteExt;
    let mut child = tokio::process::Command::new("/usr/bin/pbcopy").stdin(Stdio::piped()).spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(text.as_bytes()).await?;
    }
    let status = child.wait().await?;
    if status.success() { Ok(()) } else { Err(std::io::Error::other(format!("pbcopy exited with {status}"))) }
}

pub fn open_web_url(url: String) {
    if let Err(error) = std::process::Command::new("/usr/bin/open").arg(&url).spawn() {
        log::warn!("Can't open {url}: {error}");
    }
}

const AGENT_LABEL: &str = "io.github.tb0ne.nightfall.meteor";

/// `~/Library/LaunchAgents/<label>.plist`, which starts Meteor at login.
fn agent_path() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_default()
        .join("Library/LaunchAgents")
        .join(format!("{AGENT_LABEL}.plist"))
}

pub fn autostart_enabled() -> bool {
    agent_path().is_file()
}

/// Escapes text for a plist string.
fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

/// Turns Start at login on or off. The agent starts this executable (inside
/// Meteor.app when installed) in the user's GUI session; nothing runs as root.
pub fn set_autostart(on: bool) -> Result<(), String> {
    let path = agent_path();
    if !on {
        return match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(format!("{}: {error}", path.display())),
        };
    }
    let exe = std::env::current_exe().map_err(|e| format!("can't find Meteor's executable: {e}"))?;
    let plist = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\">\n<dict>\n\
         \t<key>Label</key><string>{AGENT_LABEL}</string>\n\
         \t<key>ProgramArguments</key><array><string>{}</string></array>\n\
         \t<key>RunAtLoad</key><true/>\n\
         \t<key>LimitLoadToSessionType</key><string>Aqua</string>\n\
         \t<key>ProcessType</key><string>Interactive</string>\n\
         </dict>\n</plist>\n",
        xml_escape(&exe.to_string_lossy())
    );
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    std::fs::write(&path, plist).map_err(|e| format!("{}: {e}", path.display()))
}

/// The answer to a pairing dialog.
#[derive(Debug, PartialEq)]
enum Answer {
    Approve,
    Reject,
    /// Timed out or closed without a choice.
    None,
}

fn parse_answer(stdout: &str) -> Answer {
    // `display dialog` prints "button returned:Approve, gave up:false".
    let gave_up = stdout.contains("gave up:true");
    match stdout.split(',').next().and_then(|s| s.trim().strip_prefix("button returned:")) {
        Some("Approve") if !gave_up => Answer::Approve,
        Some("Reject") => Answer::Reject,
        _ => Answer::None,
    }
}

/// Asks the user to approve a headset's pairing PIN. The dialog closes
/// itself when the request is answered elsewhere (the menu bar) or expires.
pub async fn host_pairing_popup(pairing: Arc<crate::host::pairing::Pairing>, request: String) -> Result<(), String> {
    let Some(pending) = pairing.pending().filter(|p| p.id == request) else { return Ok(()) };
    let message = format!(
        "A Nightfall headset at {} wants to stream this Mac.\n\nPIN: {}\n\n\
         Compare it with the PIN in your headset, and approve only if they match.",
        pending.peer, pending.pin
    );
    let child = osascript(
        &[
            "on run argv",
            "try",
            "set answer to display dialog (item 1 of argv) with title \"Pair Nightfall headset?\" \
             buttons {\"Reject\", \"Approve\"} default button \"Approve\" cancel button \"Reject\" \
             with icon caution giving up after 60",
            "return \"button returned:\" & (button returned of answer) & \", gave up:\" & (gave up of answer)",
            "on error number -128",
            "return \"button returned:Reject, gave up:false\"",
            "end try",
            "end run",
        ],
        &[&message],
    )
    .stdout(Stdio::piped())
    .stderr(Stdio::null())
    .spawn()
    .map_err(|e| format!("can't show the pairing dialog: {e}"))?;
    let output = child.wait_with_output();
    tokio::pin!(output);
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let answer = loop {
        tokio::select! {
            result = &mut output => {
                let output = result.map_err(|e| e.to_string())?;
                break parse_answer(&String::from_utf8_lossy(&output.stdout));
            }
            // Dropping the future kills osascript (kill_on_drop), closing the dialog.
            _ = tick.tick() => if !pairing.pending().is_some_and(|p| p.id == request) { return Ok(()) },
        }
    };
    match answer {
        Answer::Approve => pairing.approve(&request),
        Answer::Reject => pairing.reject(&request),
        Answer::None => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_plist_text() {
        assert_eq!(xml_escape("/Apps/A&B <x>.app"), "/Apps/A&amp;B &lt;x&gt;.app");
    }

    #[test]
    fn reads_dialog_answers() {
        assert_eq!(parse_answer("button returned:Approve, gave up:false\n"), Answer::Approve);
        assert_eq!(parse_answer("button returned:Reject, gave up:false"), Answer::Reject);
        // The default button is reported when the dialog times out.
        assert_eq!(parse_answer("button returned:Approve, gave up:true"), Answer::None);
        assert_eq!(parse_answer(""), Answer::None);
    }
}
