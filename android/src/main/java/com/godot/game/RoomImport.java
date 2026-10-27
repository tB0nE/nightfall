package com.godot.game;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Imports a user's own 3D room (.glb) through the system file picker. The
 * picker needs no storage permission and reaches any file on the headset,
 * downloaded or copied over USB. The file is copied into app storage, so the
 * room stays available after the picker's grant expires.
 */
final class RoomImport {
    static final int REQUEST = 0x4E46;
    static final long MAX_BYTES = 64L * 1024 * 1024;

    // idle, picking, copying, done, cancelled, or failed:<reason>; polled by Godot.
    private static volatile String status = "idle";
    private static volatile String destination;

    private RoomImport() {}

    static String status() { return status; }

    static void pick(Activity activity, String destinationPath) {
        destination = destinationPath;
        status = "picking";
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[] {"model/gltf-binary", "application/octet-stream"});
        try {
            activity.startActivityForResult(intent, REQUEST);
        } catch (RuntimeException failure) {
            status = "failed:No file picker is available";
            DiagnosticLog.error("RoomImport", "Could not open the file picker", failure);
        }
    }

    /** True when the result was this picker's. */
    static boolean handle(Activity activity, int request, int result, Intent data) {
        if (request != REQUEST) return false;
        Uri uri = data == null ? null : data.getData();
        if (result != Activity.RESULT_OK || uri == null) {
            status = "cancelled";
            return true;
        }
        status = "copying";
        new Thread(() -> status = copy(activity, uri, destination), "RoomImport").start();
        return true;
    }

    private static String copy(Activity activity, Uri uri, String destinationPath) {
        File target = new File(destinationPath);
        File partial = new File(destinationPath + ".part");
        File parent = target.getParentFile();
        if (parent != null && !parent.isDirectory() && !parent.mkdirs()) return "failed:Could not create the rooms folder";
        long total = 0;
        byte[] header = new byte[4];
        int headerBytes = 0;
        try (InputStream in = activity.getContentResolver().openInputStream(uri);
             OutputStream out = new FileOutputStream(partial)) {
            if (in == null) return "failed:The file could not be opened";
            byte[] buffer = new byte[64 * 1024];
            int read;
            while ((read = in.read(buffer)) > 0) {
                while (headerBytes < 4 && headerBytes < total + read) {
                    header[headerBytes] = buffer[(int) (headerBytes - total)];
                    headerBytes++;
                }
                total += read;
                if (total > MAX_BYTES) {
                    partial.delete();
                    return "failed:The room is larger than 64 MB";
                }
                out.write(buffer, 0, read);
            }
        } catch (Exception failure) {
            partial.delete();
            DiagnosticLog.error("RoomImport", "Copy failed", failure);
            return "failed:The file could not be read";
        }
        // A binary glTF starts with the ASCII magic "glTF".
        if (headerBytes < 4 || header[0] != 'g' || header[1] != 'l' || header[2] != 'T' || header[3] != 'F') {
            partial.delete();
            return "failed:That isn't a .glb file";
        }
        if (target.exists() && !target.delete()) {
            partial.delete();
            return "failed:Could not replace the previous room";
        }
        if (!partial.renameTo(target)) {
            partial.delete();
            return "failed:Could not save the room";
        }
        DiagnosticLog.info("RoomImport", "Imported a " + total + "-byte room");
        return "done";
    }
}
