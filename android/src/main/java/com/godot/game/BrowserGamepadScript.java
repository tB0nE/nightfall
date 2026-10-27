package com.godot.game;

/** Experimental Quest-pad adapter. Native physical Gamepad API devices remain intact. */
final class BrowserGamepadScript {
    static String source() {
        return """
            (() => {
              if (!window.NightfallQuestPad || window.__nightfallQuestPadInstalled) return;
              const policy = document.permissionsPolicy || document.featurePolicy;
              if (policy && !policy.allowsFeature('gamepad')) return;
              window.__nightfallQuestPadInstalled = true;
              const original = navigator.getGamepads ? navigator.getGamepads.bind(navigator) : () => [];
              let state = null, received = 0, connected = null;
              function pads() {
                const result = Array.from(original());
                if (state && performance.now() - received < 500) {
                  // Prefer a matching provider-native pad when available. The
                  // software path is only needed when WebView doesn't expose it.
                  if (state.nativeName && result.some(p => p && p.id.toLowerCase().includes(state.nativeName.toLowerCase()))) return result;
                  let index = result.findIndex(p => !p);
                  if (index < 0) index = result.length;
                  if (index < 4) result[index] = Object.freeze({
                    id: state.id || 'Nightfall Quest controllers', index, connected: true, mapping: 'standard',
                    timestamp: state.time, axes: Object.freeze(state.axes.slice()),
                    buttons: Object.freeze(state.buttons.map(value => Object.freeze({value, pressed: value > 0.5, touched: value > 0})))
                  });
                }
                return result;
              }
              Object.defineProperty(navigator, 'getGamepads', {value: pads, configurable: true});
              function notify() {
                const current = pads().find(p => p && p.id === (state && state.id || 'Nightfall Quest controllers')) || null;
                if (!!current !== !!connected || (current && connected && (current.index !== connected.index || current.id !== connected.id))) {
                  if (connected) {const e = new Event('gamepaddisconnected'); Object.defineProperty(e,'gamepad',{value:connected}); dispatchEvent(e);}
                  if (current) {const e = new Event('gamepadconnected'); Object.defineProperty(e,'gamepad',{value:current}); dispatchEvent(e);}
                }
                connected = current;
              }
              NightfallQuestPad.onmessage = e => {
                try {state = JSON.parse(e.data); received = performance.now(); notify();} catch (_) {state = null;}
              };
              let pending = 0;
              function poll() {
                const now = performance.now();
                if (!pending || now - pending > 100) {pending = now || 1; NightfallQuestPad.postMessage('poll');}
                notify(); requestAnimationFrame(poll);
              }
              const receive = NightfallQuestPad.onmessage;
              NightfallQuestPad.onmessage = e => {pending = 0; receive(e);};
              addEventListener('pagehide', () => {state = null; notify();});
              poll();
            })();
            """;
    }
}
