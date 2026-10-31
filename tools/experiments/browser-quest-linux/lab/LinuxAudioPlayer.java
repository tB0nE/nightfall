package app.nightfall.browserlab;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;

/** Streams the lab's own PulseAudio monitor to Android. Never records a microphone. */
final class LinuxAudioPlayer {
    private final Context context;
    private final File base;
    private volatile boolean running;
    private volatile Process source;
    private volatile AudioTrack track;
    private volatile float gain = 1f;
    private Thread worker;

    LinuxAudioPlayer(Context context, File base) { this.context = context; this.base = base; }

    void start() {
        running = true;
        worker = new Thread(this::pump, "LinuxAudioPipe");
        worker.start();
    }

    void stop() {
        running = false;
        Process p = source;
        if (p != null) p.destroy();
        AudioTrack t = track;
        if (t != null) { try { t.pause(); } catch (IllegalStateException ignored) {} }
    }

    private void report(String state, long bytes, long nonzero, int peak, String error) {
        try {
            JSONObject data = new JSONObject();
            data.put("state", state); data.put("pcm_bytes_written", bytes);
            data.put("nonzero_pcm_samples", nonzero); data.put("peak_pcm", peak);
            data.put("sample_rate", 48000); data.put("channels", 2); data.put("focus_gain", gain);
            AudioTrack t = track;
            if (t != null) {
                data.put("playback_head_frames", t.getPlaybackHeadPosition() & 0xffffffffL);
                data.put("play_state", t.getPlayState());
            }
            if (error != null) data.put("error", error);
            File pending = new File(base, "audio-status.tmp");
            try (FileOutputStream output = new FileOutputStream(pending)) {
                output.write(data.toString(2).getBytes("UTF-8"));
            }
            pending.renameTo(new File(base, "audio-status.json"));
        } catch (Exception ignored) {}
    }

    private void pump() {
        AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
        AudioAttributes.Builder attributesBuilder = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_GAME).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE);
        if (android.os.Build.VERSION.SDK_INT >= 32)
            attributesBuilder.setSpatializationBehavior(AudioAttributes.SPATIALIZATION_BEHAVIOR_NEVER);
        AudioAttributes attributes = attributesBuilder.build();
        AudioFocusRequest focus = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes).setOnAudioFocusChangeListener(change -> {
                    gain = change == AudioManager.AUDIOFOCUS_GAIN ? 1f
                            : change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK ? .2f : 0f;
                    AudioTrack t = track;
                    if (t != null) { try { t.setVolume(gain); } catch (IllegalStateException ignored) {} }
                }, new Handler(Looper.getMainLooper())).build();
        long bytes = 0, nonzero = 0;
        int peak = 0;
        try {
            int minimum = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT);
            if (minimum <= 0) throw new IllegalStateException("Unsupported stereo PCM output: " + minimum);
            track = new AudioTrack.Builder().setAudioAttributes(attributes)
                    .setAudioFormat(new AudioFormat.Builder().setSampleRate(48000)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
                    .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(Math.max(minimum * 2, 19200)).build();
            gain = manager.requestAudioFocus(focus) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED ? 1f : 0f;
            track.setVolume(gain);
            track.play();
            // PulseAudio can take a moment to create its monitor after Linux starts.
            for (int attempt = 0; running && attempt < 20; attempt++) {
                ProcessBuilder builder = new ProcessBuilder("/system/bin/sh", new File(base, "enter.sh").getPath(),
                        "/bin/bash", "/tmp/forward-audio.sh");
                builder.environment().put("NF_LINUX_BASE", base.getPath());
                builder.environment().put("NF_LINUX_ID", "1000:1000");
                builder.redirectError(ProcessBuilder.Redirect.appendTo(new File(base, "audio-process.log")));
                source = builder.start();
                byte[] pcm = new byte[8192];
                int pending = 0;
                long lastReport = 0;
                try (InputStream input = source.getInputStream()) {
                    while (running) {
                        int count = input.read(pcm, pending, pcm.length - pending);
                        if (count < 0) break;
                        int available = pending + count;
                        int complete = available & ~3; // stereo s16le frames; keep partial reads.
                        for (int i = 0; i < complete; i += 2) {
                            int sample = (short) ((pcm[i] & 255) | (pcm[i + 1] << 8));
                            if (sample != 0) nonzero++;
                            peak = Math.max(peak, Math.abs(sample));
                        }
                        for (int offset = 0; running && offset < complete;) {
                            int written = track.write(pcm, offset, complete - offset, AudioTrack.WRITE_BLOCKING);
                            if (written <= 0) throw new IllegalStateException("AudioTrack write: " + written);
                            offset += written; bytes += written;
                        }
                        pending = available - complete;
                        if (pending != 0) System.arraycopy(pcm, complete, pcm, 0, pending);
                        long now = android.os.SystemClock.elapsedRealtime();
                        if (now - lastReport >= 1000) {
                            report("playing", bytes, nonzero, peak, null); lastReport = now; peak = 0;
                        }
                    }
                }
                source.destroy();
                if (running) Thread.sleep(500);
            }
            if (running) throw new IllegalStateException("Linux audio source repeatedly exited");
        } catch (Exception error) {
            report(running ? "error" : "stopped", bytes, nonzero, peak, error.toString());
        } finally {
            Process p = source; if (p != null) p.destroy();
            AudioTrack t = track;
            if (t != null) { try { t.stop(); } catch (IllegalStateException ignored) {} t.release(); }
            track = null;
            manager.abandonAudioFocusRequest(focus);
        }
    }
}
