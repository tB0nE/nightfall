package com.godot.game;

/** Local probe; never injects or emulates Gamepad API devices. */
final class BrowserGamepadProbe {
    static final String URL = "https://nightfall.invalid/gamepad";
    static String html() {
        return "<!doctype html><meta name='viewport' content='width=device-width'>"
            + "<title>Nightfall gamepad diagnostic</title><style>body{background:#182438;color:#edf2ff;font:24px monospace;padding:30px}button{font:inherit;padding:16px}pre{white-space:pre-wrap}</style>"
            + "<h1>Gamepad diagnostic</h1><p>Pair a physical Bluetooth/USB gamepad, click Activate, then press buttons and move sticks. No subscription needed.</p>"
            + "<button id='activate'>Activate</button><pre id='out'></pre>"
            + "<p>This checks WebView support, not Xbox compatibility. No input leaves this page. Use Home to exit.</p>"
            + "<script>let activated=false;document.getElementById('activate').onclick=()=>activated=true;"
            + "function tick(){let lines=['Secure context: '+isSecureContext,'Focused: '+document.hasFocus(),'Activated: '+activated,'Gamepad API: '+(typeof navigator.getGamepads)];"
            + "try{if(navigator.getGamepads)for(const p of navigator.getGamepads()){if(!p)continue;lines.push('Pad '+p.index+': '+p.id+' / '+p.mapping,'Buttons: '+p.buttons.map((b,i)=>b.pressed?i+\":\"+b.value.toFixed(2):null).filter(Boolean).join(' '),'Axes: '+p.axes.map(a=>a.toFixed(2)).join(' '));}}catch(e){lines.push(e.name+': '+e.message);}"
            + "document.getElementById('out').textContent=lines.join('\\n');requestAnimationFrame(tick);}tick();</script>";
    }
}
