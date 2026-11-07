//! User-triggered access setup for virtual keyboard, mouse and gamepads.
use std::{path::Path, sync::{Arc, atomic::{AtomicBool, Ordering}}, time::Duration};

#[derive(Debug, PartialEq, Eq)]
pub enum Status { Ready, Missing, Denied, Unavailable(String) }

pub fn check() -> Status { check_path(Path::new("/dev/uinput")) }

fn check_path(path: &Path) -> Status {
    use std::os::unix::fs::OpenOptionsExt;
    match std::fs::OpenOptions::new().read(true).write(true).custom_flags(libc::O_NONBLOCK).open(path) {
        Ok(_) => Status::Ready,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Status::Missing,
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => Status::Denied,
        Err(e) => Status::Unavailable(e.to_string()),
    }
}

// Fixed script only: no paths, usernames or content supplied by a network client.
// uaccess grants the active local seat access; no world-writable devices or
// permanent membership in a privileged input group. Rule precedes seat-late.
const SETUP: &str = r#"set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
command -v udevadm >/dev/null
if [ ! -e /dev/uinput ]; then modprobe uinput; fi
mkdir -p /etc/udev/rules.d
rule=$(mktemp /etc/udev/rules.d/.nightfall-input.XXXXXX)
trap 'rm -f "$rule"' EXIT
cat > "$rule" <<'RULES'
# Nightfall Meteor: virtual input for the active desktop seat.
KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"
KERNEL=="uhid", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uhid"
RULES
chmod 0644 "$rule"
mv -f "$rule" /etc/udev/rules.d/70-nightfall-input.rules
udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=misc --sysname-match=uinput
if [ -e /dev/uhid ]; then udevadm trigger --action=add --subsystem-match=misc --sysname-match=uhid; fi
udevadm settle --timeout=5
"#;

#[derive(Default)]
pub struct Access { busy: AtomicBool }
impl Access {
    pub fn busy(&self) -> bool { self.busy.load(Ordering::Acquire) }
    pub fn setup(self: &Arc<Self>) {
        if self.busy.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).is_err() { return; }
        let access = self.clone();
        let runtime = tokio::runtime::Handle::current();
        std::thread::spawn(move || {
            let result = install();
            access.busy.store(false, Ordering::Release);
            runtime.spawn(async move {
                match result {
                    Ok(()) => {
                        crate::desktop::notify("Virtual input enabled", "Restarting Meteor so the host can enable keyboard, mouse and gamepad input. Any active stream will disconnect.").await;
                        crate::restart();
                    }
                    Err(error) => crate::desktop::notify("Input setup did not finish", &error).await,
                }
            });
        });
    }
}

fn install() -> Result<(), String> {
    if check() == Status::Ready { return Ok(()); }
    let output = std::process::Command::new("pkexec").args(["/bin/sh", "-c", SETUP])
        .output().map_err(|e| format!("Cannot request administrator approval: {e}. Your administrator can configure uinput access instead."))?;
    if !output.status.success() {
        return Err(format!("Administrator approval was cancelled or input setup failed ({}). {}", output.status,
            String::from_utf8_lossy(&output.stderr).trim().chars().take(400).collect::<String>()));
    }
    for _ in 0..25 {
        if check() == Status::Ready { return Ok(()); }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err("Rules were installed, but this desktop session still cannot access uinput. Log out and back in, or ask your administrator to check seat/device access.".into())
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn detects_missing_and_accessible_nodes_without_changing_permissions() {
        let root = std::env::temp_dir().join(format!("meteor-input-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("uinput");
        assert_eq!(check_path(&path), Status::Missing);
        std::fs::write(&path, b"").unwrap();
        assert_eq!(check_path(&path), Status::Ready);
        if unsafe {libc::geteuid()} != 0 {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path,std::fs::Permissions::from_mode(0o400)).unwrap();
            assert_eq!(check_path(&path),Status::Denied);
        }
        assert!(matches!(check_path(&root), Status::Unavailable(_)));
        std::fs::remove_dir_all(root).unwrap();
    }
}
