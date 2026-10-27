//! Narrow WebView adapter. Filtering policy lives in upstream adblock-rust.
use adblock::{
    Engine,
    lists::{FilterSet, ParseOptions},
    request::Request,
};
use jni::{
    JNIEnv,
    objects::{JClass, JString},
    sys::{jboolean, jstring},
};
use std::sync::{Mutex, OnceLock};

static ENGINE: OnceLock<Mutex<Option<Engine>>> = OnceLock::new();
fn engine() -> &'static Mutex<Option<Engine>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

fn compile(rules: &str) -> Engine {
    let mut filters = FilterSet::new(false);
    filters.add_filter_list(rules.to_owned(), ParseOptions::default());
    Engine::new_with_filter_set(filters)
}

fn blocked(url: &str, source: &str, kind: &str, method: &str) -> bool {
    let Ok(request) = Request::new(url, source, kind, method) else {
        return false;
    };
    engine()
        .lock()
        .ok()
        .and_then(|guard| {
            guard
                .as_ref()
                .map(|e| e.check_network_request(&request).should_block())
        })
        .unwrap_or(false)
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_godot_game_BrowserAdblock_nativeInstall(
    mut env: JNIEnv,
    _: JClass,
    rules: JString,
) -> jboolean {
    let Ok(text) = env.get_string(&rules) else {
        return 0;
    };
    let text: String = text.into();
    if text.len() > 16 * 1024 * 1024 {
        return 0;
    }
    // Parse on the update worker; only publication takes the request mutex.
    let Ok(replacement) = std::panic::catch_unwind(|| compile(&text)) else {
        return 0;
    };
    let Ok(mut guard) = engine().lock() else {
        return 0;
    };
    *guard = Some(replacement);
    1
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_godot_game_BrowserAdblock_nativeRelease(_: JNIEnv, _: JClass) {
    if let Ok(mut guard) = engine().lock() {
        *guard = None;
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_godot_game_BrowserAdblock_nativeBlocked(
    mut env: JNIEnv,
    _: JClass,
    url: JString,
    source: JString,
    kind: JString,
    method: JString,
) -> jboolean {
    let (Ok(url), Ok(source), Ok(kind)) = (
        env.get_string(&url),
        env.get_string(&source),
        env.get_string(&kind),
    ) else {
        return 0;
    };
    let (url, source, kind): (String, String, String) = (url.into(), source.into(), kind.into());
    let Ok(method) = env.get_string(&method) else {
        return 0;
    };
    let method: String = method.into();
    std::panic::catch_unwind(|| blocked(&url, &source, &kind, &method)).unwrap_or(false) as jboolean
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_godot_game_BrowserAdblock_nativeSelectors(
    mut env: JNIEnv,
    _: JClass,
    url: JString,
) -> jstring {
    let Ok(url) = env.get_string(&url) else {
        return std::ptr::null_mut();
    };
    let url: String = url.into();
    let selectors = std::panic::catch_unwind(|| {
        engine()
            .lock()
            .ok()
            .and_then(|guard| {
                guard
                    .as_ref()
                    .map(|e| e.url_cosmetic_resources(&url).hide_selectors)
            })
            .unwrap_or_default()
    })
    .unwrap_or_default();
    let text = serde_json::to_string(&selectors).unwrap_or_else(|_| "[]".into());
    env.new_string(text)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn upstream_rules_exceptions_types_and_cosmetics() {
        let e = compile(
            "||ads.example^\n@@||ads.example/allowed^\n||track.example^$third-party\n||images.example^$image\nsite.example##.sponsor",
        );
        let check = |url, source, kind| {
            e.check_network_request(&Request::new(url, source, kind, "GET").unwrap())
                .should_block()
        };
        assert!(check(
            "https://ads.example/banner",
            "https://site.example/",
            "script"
        ));
        assert!(!check(
            "https://ads.example/allowed",
            "https://site.example/",
            "script"
        ));
        assert!(check(
            "https://track.example/a",
            "https://site.example/",
            "xmlhttprequest"
        ));
        assert!(!check(
            "https://track.example/a",
            "https://track.example/",
            "xmlhttprequest"
        ));
        assert!(check(
            "https://images.example/a",
            "https://site.example/",
            "image"
        ));
        assert!(!check(
            "https://images.example/a",
            "https://site.example/",
            "script"
        ));
        assert!(
            e.url_cosmetic_resources("https://site.example/")
                .hide_selectors
                .contains(".sponsor")
        );
    }
}
