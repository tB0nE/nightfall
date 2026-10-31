package app.nightfall.browserlab;

import android.app.Activity;
import android.os.Bundle;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.content.Intent;

/** Disposable browser experiment. No Nightfall state, DRM secrets or VM profiles. */
public final class BrowserLabActivity extends Activity {
    private WebView web;
    private TextView status;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        status = new TextView(this);
        status.setText("ARM64 Linux userspace experiment. This is not a VM or a production browser.");
        layout.addView(status);
        CheckBox unsafe = new CheckBox(this);
        unsafe.setText("Disable Chrome sandbox (lab test only)");
        layout.addView(unsafe);
        Button start = new Button(this);
        start.setText("Start Linux browser");
        layout.addView(start);
        Button reload = new Button(this);
        reload.setText("Open / reload Linux desktop");
        layout.addView(reload);
        Button stop = new Button(this);
        stop.setText("Stop Linux browser and audio");
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, BrowserLabService.class));
            web.loadUrl("about:blank");
            status.setText("Linux browser stopped");
        });
        layout.addView(stop);
        web = new WebView(this);
        web.getSettings().setJavaScriptEnabled(true);
        web.getSettings().setDomStorageEnabled(true);
        web.setWebViewClient(new WebViewClient());
        layout.addView(web, new LinearLayout.LayoutParams(-1, 0, 1));
        setContentView(layout);
        start.setOnClickListener(v -> launch(unsafe.isChecked()));
        reload.setOnClickListener(v -> openDesktop());
        if (getIntent().getBooleanExtra("start_lab", false)) {
            unsafe.setChecked(getIntent().getBooleanExtra("unsafe_no_sandbox", false));
            launch(unsafe.isChecked());
        }
    }

    private void launch(boolean unsafe) {
        Intent start = new Intent(this, BrowserLabService.class);
        start.putExtra("unsafe_no_sandbox", unsafe);
        startForegroundService(start);
        status.setText("Starting Linux browser and headset audio");
        web.postDelayed(() -> { status.setText(BrowserLabService.status); openDesktop(); }, 10000);
    }

    private void openDesktop() {
        web.loadUrl("http://127.0.0.1:6082/vnc.html?autoconnect=true&resize=scale");
    }
}
