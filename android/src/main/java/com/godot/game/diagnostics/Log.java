package com.godot.game.diagnostics;

import com.godot.game.DiagnosticLog;

/** Drop-in logger that mirrors DepthEstimator messages to the support log. */
public final class Log {
    private Log() {}

    public static int i(String tag, String message) {
        DiagnosticLog.info(tag, message);
        return 0;
    }

    public static int w(String tag, String message) {
        DiagnosticLog.warn(tag, message, null);
        return 0;
    }

    public static int w(String tag, String message, Throwable error) {
        DiagnosticLog.warn(tag, message, error);
        return 0;
    }

    public static int e(String tag, String message) {
        DiagnosticLog.error(tag, message, null);
        return 0;
    }

    public static int e(String tag, String message, Throwable error) {
        DiagnosticLog.error(tag, message, error);
        return 0;
    }
}
