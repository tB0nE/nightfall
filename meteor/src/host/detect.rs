//! Finds other game streaming hosts running on this PC, so the tray can
//! name the one to close before the bundled host takes the default port.

use std::path::Path;

/// Process names of the Sunshine family. Vibepollo's development builds
/// are named after their version (`vibepollo-2.0.0`).
const HOST_NAMES: [&str; 5] = ["sunshine", "apollo", "vibepollo", "vibeshine", "polaris"];

/// Hosts running now, as (pid, name), leaving out `exclude` (the bundled
/// host Meteor started).
pub fn other_hosts(exclude: Option<u32>) -> Vec<(u32, String)> {
    scan(Path::new("/proc"), exclude)
}

fn scan(proc_root: &Path, exclude: Option<u32>) -> Vec<(u32, String)> {
    let Ok(entries) = std::fs::read_dir(proc_root) else { return Vec::new() };
    let mut hosts: Vec<(u32, String)> = entries
        .flatten()
        .filter_map(|entry| {
            let pid: u32 = entry.file_name().to_str()?.parse().ok()?;
            if Some(pid) == exclude {
                return None;
            }
            // comm is cut to 15 bytes, which still holds every name above.
            let comm = std::fs::read_to_string(entry.path().join("comm")).ok()?;
            host_name(comm.trim()).map(|name| (pid, name.to_string()))
        })
        .collect();
    hosts.sort();
    hosts
}

/// "Sunshine" for `sunshine`, "Vibepollo" for `vibepollo-2.0.0`.
fn host_name(comm: &str) -> Option<&'static str> {
    let lower = comm.to_ascii_lowercase();
    let name = HOST_NAMES.iter().find(|name| {
        lower.strip_prefix(**name).is_some_and(|rest| rest.is_empty() || rest.starts_with(['-', '.', '_']))
    })?;
    Some(match *name {
        "sunshine" => "Sunshine",
        "apollo" => "Apollo",
        "vibepollo" => "Vibepollo",
        "vibeshine" => "Vibeshine",
        _ => "Polaris",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_hosts_and_ignores_the_rest() {
        assert_eq!(host_name("sunshine"), Some("Sunshine"));
        assert_eq!(host_name("vibepollo-2.0.0"), Some("Vibepollo"));
        assert_eq!(host_name("Apollo"), Some("Apollo"));
        assert_eq!(host_name("sunshinesvc"), None);
        assert_eq!(host_name("nightfall-meteo"), None);
    }

    #[test]
    fn scans_a_proc_tree() {
        let root = std::env::temp_dir().join(format!("meteor-proc-{}", std::process::id()));
        for (pid, comm) in [("100", "sunshine\n"), ("200", "vibepollo-2.0.0\n"), ("300", "bash\n"), ("self", "x\n")] {
            std::fs::create_dir_all(root.join(pid)).unwrap();
            std::fs::write(root.join(pid).join("comm"), comm).unwrap();
        }
        assert_eq!(scan(&root, Some(200)), vec![(100, "Sunshine".to_string())]);
        assert_eq!(scan(&root, None).len(), 2);
        std::fs::remove_dir_all(&root).unwrap();
    }
}
