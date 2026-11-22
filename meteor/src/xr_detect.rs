//! What kind of VR game an install folder holds, from its files alone: which
//! VR APIs it ships and whether it uses anti-cheat. Decides which runtime a
//! game can use (docs/plans/active/windows-pcvr-routing.md, part A). It never
//! runs or opens the game's executables, and it doesn't follow links.
use std::path::Path;
use serde::{Deserialize, Serialize};

/// Folders deeper than this aren't looked at. Unreal games keep their
/// third-party DLLs about five levels down
/// (`Engine/Binaries/ThirdParty/OpenXR/win64`).
const MAX_DEPTH: usize = 8;
/// Entries looked at per game, so a huge install can't stall Setup.
const MAX_ENTRIES: usize = 60_000;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Detection {
    /// Ships the OpenVR loader (`openvr_api.dll`).
    #[serde(default)]
    pub openvr: bool,
    /// Ships the OpenXR loader (`openxr_loader.dll`).
    #[serde(default)]
    pub openxr: bool,
    /// The anti-cheat found, e.g. "EasyAntiCheat".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub anticheat: Option<String>,
    /// The scan stopped at MAX_ENTRIES, so something may have been missed.
    #[serde(default)]
    pub partial: bool,
}

/// The runtime a game should use, by the plan's rules (after the user's own choice).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// Anti-cheat: our Monado DLL is unsigned and loads into the game's process.
    AntiCheat,
    /// OpenVR: needs SteamVR.
    OpenVr,
    /// Native OpenXR, without OpenVR: can try Monado.
    OpenXr,
    /// Nothing recognised: SteamVR, the safe default.
    Unknown,
}

impl Detection {
    pub fn kind(&self) -> Kind {
        if self.anticheat.is_some() {
            Kind::AntiCheat
        } else if self.openvr {
            // Both loaders: SteamVR until the game has been tested on Monado.
            Kind::OpenVr
        } else if self.openxr {
            Kind::OpenXr
        } else {
            Kind::Unknown
        }
    }

    /// Why the game runs where it does, for the tray and the headset.
    pub fn reason(&self) -> String {
        match self.kind() {
            Kind::AntiCheat => format!("anti-cheat: {}", self.anticheat.as_deref().unwrap_or("detected")),
            Kind::OpenVr if self.openxr => "OpenVR and OpenXR".into(),
            Kind::OpenVr => "OpenVR game".into(),
            Kind::OpenXr => "native OpenXR".into(),
            Kind::Unknown => "VR API not detected".into(),
        }
    }

    /// Only a plain native OpenXR game may be offered Monado.
    pub fn may_use_monado(&self) -> bool {
        self.kind() == Kind::OpenXr && !self.partial
    }
}

fn anticheat(name: &str, is_dir: bool) -> Option<&'static str> {
    if is_dir {
        return match name {
            "easyanticheat" | "easyanticheat_eos" => Some("EasyAntiCheat"),
            "battleye" => Some("BattlEye"),
            _ => None,
        };
    }
    match name {
        "start_protected_game.exe" | "easyanticheat_x64.dll" | "easyanticheat_eos_setup.exe" | "easyanticheat_setup.exe" => Some("EasyAntiCheat"),
        "beclient_x64.dll" | "beservice_x64.exe" => Some("BattlEye"),
        _ => None,
    }
}

/// Scans an install folder. An unreadable folder gives an empty Detection
/// (Kind::Unknown), which routes to SteamVR.
pub fn scan(install_dir: &Path) -> Detection {
    let mut found = Detection::default();
    let mut queue = std::collections::VecDeque::from([(install_dir.to_path_buf(), 0usize)]);
    let mut seen = 0usize;
    while let Some((dir, depth)) = queue.pop_front() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            seen += 1;
            if seen > MAX_ENTRIES {
                found.partial = true;
                return found;
            }
            // symlink_metadata: links and junctions are never followed.
            let Ok(meta) = entry.path().symlink_metadata() else { continue };
            if meta.file_type().is_symlink() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
            if let Some(kind) = anticheat(&name, meta.is_dir()) {
                found.anticheat.get_or_insert_with(|| kind.to_string());
            }
            if meta.is_dir() {
                if depth + 1 < MAX_DEPTH {
                    queue.push_back((entry.path(), depth + 1));
                }
            } else if name == "openvr_api.dll" {
                found.openvr = true;
            } else if name == "openxr_loader.dll" {
                found.openxr = true;
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn game(files: &[&str]) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static N: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!("meteor-detect-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        let _ = std::fs::remove_dir_all(&root);
        for file in files {
            let path = root.join(file);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, b"").unwrap();
        }
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn a_unity_steamvr_game_is_openvr() {
        let dir = game(&["Game.exe", "Game_Data/Plugins/x86_64/openvr_api.dll"]);
        let found = scan(&dir);
        assert_eq!(found.kind(), Kind::OpenVr);
        assert_eq!(found.reason(), "OpenVR game");
        assert!(!found.may_use_monado());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_unreal_openxr_game_may_use_monado() {
        let dir = game(&["Game/Binaries/Win64/Game-Win64-Shipping.exe", "Engine/Binaries/ThirdParty/OpenXR/win64/openxr_loader.dll"]);
        let found = scan(&dir);
        assert_eq!(found.kind(), Kind::OpenXr);
        assert!(found.may_use_monado());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn both_loaders_stay_on_steamvr() {
        let dir = game(&["Engine/Binaries/ThirdParty/OpenVR/OpenVRv1_5_17/Win64/openvr_api.dll", "Engine/Binaries/ThirdParty/OpenXR/win64/openxr_loader.dll"]);
        let found = scan(&dir);
        assert_eq!(found.kind(), Kind::OpenVr);
        assert_eq!(found.reason(), "OpenVR and OpenXR");
        assert!(!found.may_use_monado());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn anti_cheat_wins_over_everything() {
        for (file, name) in [("EasyAntiCheat/EasyAntiCheat_EOS_Setup.exe", "EasyAntiCheat"), ("BattlEye/BEService_x64.exe", "BattlEye"), ("start_protected_game.exe", "EasyAntiCheat")] {
            let dir = game(&[file, "Plugins/openxr_loader.dll"]);
            let found = scan(&dir);
            assert_eq!(found.kind(), Kind::AntiCheat, "{file}");
            assert_eq!(found.anticheat.as_deref(), Some(name));
            assert_eq!(found.reason(), format!("anti-cheat: {name}"));
            assert!(!found.may_use_monado());
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn a_missing_folder_or_nothing_recognised_is_unknown() {
        assert_eq!(scan(Path::new("/nonexistent/meteor-detect")).kind(), Kind::Unknown);
        let dir = game(&["readme.txt", "bin/game.exe"]);
        assert_eq!(scan(&dir).kind(), Kind::Unknown);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn too_deep_is_not_looked_at() {
        let deep = format!("{}openxr_loader.dll", "d/".repeat(MAX_DEPTH));
        let dir = game(&[&deep]);
        assert!(!scan(&dir).openxr);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_catalog_form_round_trips_and_stays_small() {
        let found = Detection { openvr: true, openxr: false, anticheat: Some("BattlEye".into()), partial: false };
        let text = serde_json::to_string(&found).unwrap();
        assert_eq!(serde_json::from_str::<Detection>(&text).unwrap(), found);
        assert_eq!(serde_json::to_string(&Detection::default()).unwrap(), r#"{"openvr":false,"openxr":false,"partial":false}"#);
    }
}
