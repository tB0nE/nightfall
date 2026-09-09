package com.godot.game;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;
import android.util.Log;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;

/** App-owned diagnostic logging and permissionless Downloads export. */
public final class DiagnosticLog {
    private static final String TAG = "NightfallDiagnostics";
    private static final String CURRENT_FILE = "depth-current.log";
    private static final String PREVIOUS_FILE = "depth-previous.log";
    private static final String GODOT_CURRENT_FILE = "nightfall-current.log";
    private static final String GODOT_PREVIOUS_FILE = "nightfall-previous.log";
    private static final String JNI_RESULT_FILE = "jni_result.txt";
    private static final SimpleDateFormat LINE_TIME =
            new SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US);

    private static Context appContext;
    private static File currentFile;

    private DiagnosticLog() {}

    public static synchronized void initialize(Context context) {
        if (appContext != null) return;
        appContext = context.getApplicationContext();
        File files = appContext.getFilesDir();
        currentFile = new File(files, CURRENT_FILE);
        File previous = new File(files, PREVIOUS_FILE);
        if (previous.exists() && !previous.delete()) {
            Log.w(TAG, "Could not remove previous depth diagnostic log");
        }
        if (currentFile.exists() && !currentFile.renameTo(previous)) {
            Log.w(TAG, "Could not rotate current depth diagnostic log");
        }
        append("I", TAG, "Session started", null);
        append("I", TAG, deviceSummary(), null);
        append("I", TAG, appSummary(appContext), null);
        append("I", TAG, memorySummary(), null);
    }

    public static void info(String tag, String message) {
        Log.i(tag, message);
        append("I", tag, message, null);
    }

    public static void warn(String tag, String message, Throwable error) {
        if (error == null) Log.w(tag, message); else Log.w(tag, message, error);
        append("W", tag, message, error);
    }

    public static void error(String tag, String message, Throwable error) {
        if (error == null) Log.e(tag, message); else Log.e(tag, message, error);
        append("E", tag, message, error);
    }

    private static synchronized void append(String level, String tag, String message, Throwable error) {
        if (currentFile == null) return;
        try (FileOutputStream stream = new FileOutputStream(currentFile, true);
             OutputStreamWriter writer = new OutputStreamWriter(stream, StandardCharsets.UTF_8)) {
            writer.write(String.format(Locale.US, "[%s] %s/%s: %s%n",
                    LINE_TIME.format(new Date()), level, tag, message));
            if (error != null) {
                // Android intentionally ships only ZipDepth-384-GPU. Keep
                // expected absent-model diagnostics useful without filling
                // every report with repeated AssetManager stack traces.
                if (error instanceof FileNotFoundException) {
                    writer.write(error.toString());
                    writer.write('\n');
                } else {
                    StringWriter stack = new StringWriter();
                    error.printStackTrace(new PrintWriter(stack));
                    writer.write(stack.toString());
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Could not append diagnostic log", e);
        }
    }

    public static synchronized String export(Context context) {
        Context app = context.getApplicationContext();
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return "ERROR: Downloads export requires Android 10 or newer";
        }
        String stamp = new SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US).format(new Date());
        String name = "Nightfall-diagnostics-" + stamp + ".txt";
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, name);
        values.put(MediaStore.MediaColumns.MIME_TYPE, "text/plain");
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/Nightfall");
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);

        ContentResolver resolver = app.getContentResolver();
        Uri uri = null;
        try {
            uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
            if (uri == null) throw new IllegalStateException("MediaStore returned no destination");
            try (OutputStream stream = resolver.openOutputStream(uri, "w");
                 OutputStreamWriter writer = new OutputStreamWriter(stream, StandardCharsets.UTF_8)) {
                writer.write("Nightfall diagnostic report\n");
                writer.write("Exported: " + LINE_TIME.format(new Date()) + "\n");
                writer.write(deviceSummary() + "\n");
                writer.write(appSummary(app) + "\n");
                writer.write(memorySummary() + "\n");
                writer.write("Note: this report may contain host names and network addresses.\n");
                appendFile(writer, "Native library initialization", new File(app.getFilesDir(), JNI_RESULT_FILE));
                appendFile(writer, "Previous Nightfall session", new File(app.getFilesDir(), GODOT_PREVIOUS_FILE));
                appendFile(writer, "Previous depth session", new File(app.getFilesDir(), PREVIOUS_FILE));
                appendFile(writer, "Current Nightfall session", new File(app.getFilesDir(), GODOT_CURRENT_FILE));
                appendFile(writer, "Current depth session", new File(app.getFilesDir(), CURRENT_FILE));
            }
            values.clear();
            values.put(MediaStore.MediaColumns.IS_PENDING, 0);
            resolver.update(uri, values, null, null);
            info(TAG, "Exported diagnostics to Download/Nightfall/" + name);
            return "Download/Nightfall/" + name;
        } catch (Exception e) {
            if (uri != null) resolver.delete(uri, null, null);
            error(TAG, "Diagnostic export failed", e);
            return "ERROR: " + e.getClass().getSimpleName() + ": " + e.getMessage();
        }
    }

    private static void appendFile(OutputStreamWriter writer, String title, File file) throws Exception {
        writer.write("\n===== " + title + " =====\n");
        if (!file.exists()) {
            writer.write("(not available)\n");
            return;
        }
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(
                new FileInputStream(file), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                writer.write(line);
                writer.write('\n');
            }
        }
    }

    private static String deviceSummary() {
        return String.format(Locale.US,
                "Device: manufacturer=%s model=%s device=%s hardware=%s board=%s sdk=%d android=%s abi=%s",
                Build.MANUFACTURER, Build.MODEL, Build.DEVICE, Build.HARDWARE, Build.BOARD, Build.VERSION.SDK_INT,
                Build.VERSION.RELEASE, Build.SUPPORTED_ABIS.length > 0 ? Build.SUPPORTED_ABIS[0] : "unknown");
    }

    private static String appSummary(Context app) {
        try {
            String version = app.getPackageManager().getPackageInfo(app.getPackageName(), 0).versionName;
            return "App: " + app.getPackageName() + " " + version;
        } catch (Exception ignored) {
            return "App: " + app.getPackageName();
        }
    }

    private static String memorySummary() {
        Runtime runtime = Runtime.getRuntime();
        long mib = 1024L * 1024L;
        return String.format(Locale.US,
                "Java heap: used=%dMiB free=%dMiB max=%dMiB",
                (runtime.totalMemory() - runtime.freeMemory()) / mib,
                runtime.freeMemory() / mib, runtime.maxMemory() / mib);
    }
}
