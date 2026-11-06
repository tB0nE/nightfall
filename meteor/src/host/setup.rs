//! A first-run invitation, never an automatic host installation or switch.
use std::{path::{Path, PathBuf}, sync::Arc};
use super::{Choice, view::View};

fn should_offer(first_run: bool, local: bool, external: bool, bundled: bool, available: bool) -> bool {
    first_run && local && !external && !bundled && available
}

fn local_host(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]")
}

fn installed_in(paths: &[PathBuf], config: &Path) -> bool {
    const NAMES: [&str;5] = ["sunshine", "apollo", "polaris", "vibepollo", "vibeshine"];
    NAMES.iter().any(|name| {
        paths.iter().any(|dir| dir.join(name).is_file()) ||
        config.join(name).join("sunshine.conf").is_file() ||
        config.join(name).join("polaris.conf").is_file()
    })
}

pub fn offer(view: Arc<View>, config: &crate::config::Config) {
    // A CLI/headless invocation does not call this function. Do not offer a
    // download which this build cannot supply, or consume the first-run marker.
    if view.binary.is_none() && super::RELEASE.is_none() { return; }
    let marker = crate::config::config_dir().join("host-setup-offered");
    let paths: Vec<_> = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).collect();
    let config_root=crate::config::config_dir().parent().map(Path::to_path_buf).unwrap_or_default();
    let flatpak = [PathBuf::from("/var/lib/flatpak/app"),
        crate::config::data_dir().parent().unwrap_or(Path::new(".")).join("flatpak/app")]
        .iter().any(|dir| ["dev.lizardbyte.app.Sunshine", "io.github.LizardByte.Sunshine", "io.github.Nonary.vibepollo"]
            .iter().any(|name|dir.join(name).is_dir()));
    let external = !super::other_hosts(None).is_empty() || installed_in(&paths,&config_root) || flatpak;
    let show=should_offer(!marker.exists(),local_host(&config.sunshine_host),external,
        view.state.choice==Choice::Bundled,true);
    // Remember the first eligible GUI launch even if an existing host was
    // detected. Stopping it later must not unexpectedly trigger onboarding.
    if !marker.exists() {
        let result=std::fs::create_dir_all(crate::config::config_dir())
            .and_then(|()|std::fs::write(&marker,"Host setup offered or an existing host detected; tray setup remains available.\n"));
        if let Err(error)=result {log::warn!("Cannot remember host setup offer: {error}");return;}
    }
    if show {
        tokio::spawn(async move {
            if let Err(error)=crate::desktop::host_setup_popup(view).await {
                log::info!("Host setup notification unavailable ({error}); use Set up Meteor-Vibepollo in Meteor's tray");
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn offers_only_on_an_unconfigured_local_first_run() {
        assert!(should_offer(true,true,false,false,true));
        for args in [(false,true,false,false,true),(true,false,false,false,true),
            (true,true,true,false,true),(true,true,false,true,true),(true,true,false,false,false)] {
            assert!(!should_offer(args.0,args.1,args.2,args.3,args.4));
        }
        assert!(!local_host("10.0.0.13"));assert!(local_host("::1"));
    }
    #[test]
    fn recognizes_a_configured_host_even_when_it_is_not_running() {
        let root=std::env::temp_dir().join(format!("meteor-host-detection-{}",std::process::id()));
        std::fs::create_dir_all(root.join("vibepollo")).unwrap();
        assert!(!installed_in(&[],&root));
        std::fs::write(root.join("vibepollo/sunshine.conf"),"port = 49989\n").unwrap();
        assert!(installed_in(&[],&root));
        std::fs::remove_dir_all(root).unwrap();
    }
}
