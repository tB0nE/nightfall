package com.godot.game;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import com.godot.game.diagnostics.Log;

/** Diagnostic playback alternative: same PCM16/game AudioTrack path as Moonlight. */
public final class AudioOutput {
    private static AudioTrack track;
    private static short[] pcm = new short[0];
    private static int channels, sampleRate;
    private static long writtenFrames, headWraps, lastHead;

    public static synchronized boolean open(int rate, int count, int period) {
        close();
        if (count != 1 && count != 2) return false;
        int mask = count == 2 ? AudioFormat.CHANNEL_OUT_STEREO : AudioFormat.CHANNEL_OUT_MONO;
        int packetBytes = period * count * 2;
        int minimum = AudioTrack.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT);
        if (minimum <= 0) return false;
        for (int attempt = 0; attempt < 4; attempt++) {
            boolean lowLatency = attempt < 2;
            if (lowLatency && AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC) != rate) continue;
            int bytes = attempt % 2 == 0 ? packetBytes * 2 : Math.max(minimum, packetBytes * 2);
            bytes = ((bytes + packetBytes - 1) / packetBytes) * packetBytes;
            try {
                AudioTrack.Builder builder = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).build())
                    .setAudioFormat(new AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(rate).setChannelMask(mask).build())
                    .setTransferMode(AudioTrack.MODE_STREAM).setBufferSizeInBytes(bytes);
                if (lowLatency) builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY);
                track = builder.build();
                if (track.getState() != AudioTrack.STATE_INITIALIZED) throw new IllegalStateException("uninitialized AudioTrack");
                channels = count;
                sampleRate = rate;
                writtenFrames = headWraps = lastHead = 0;
                pcm = new short[period * count];
                track.play();
                Log.i("AudioOutput", "AudioTrack PCM16 USAGE_GAME rate=" + rate + " channels=" + count
                    + " bytes=" + bytes + " lowLatency=" + lowLatency + " session=" + track.getAudioSessionId());
                return true;
            } catch (RuntimeException e) {
                Log.w("AudioOutput", "AudioTrack attempt " + attempt + " failed: " + e);
                close();
            }
        }
        return false;
    }

    public static synchronized boolean write(float[] samples, int frames) {
        if (track == null || frames <= 0 || samples.length < frames * channels) return false;
        // Bound backlog, as Moonlight does; do not increase latency indefinitely.
        if (latencyMs() > 40) return false;
        int count = frames * channels;
        if (pcm.length < count) pcm = new short[count];
        for (int i = 0; i < count; i++) {
            float value = samples[i];
            if (!Float.isFinite(value)) value = 0;
            pcm[i] = (short)Math.max(-32768, Math.min(32767, Math.round(value * 32768.0f)));
        }
        int offset = 0;
        while (offset < count) {
            int n = track.write(pcm, offset, count - offset, AudioTrack.WRITE_BLOCKING);
            if (n <= 0) {
                Log.w("AudioOutput", "AudioTrack write failed: " + n);
                return false;
            }
            offset += n;
            writtenFrames += n / channels;
        }
        return true;
    }

    public static synchronized int latencyMs() {
        if (track == null || sampleRate == 0) return 0;
        long head = Integer.toUnsignedLong(track.getPlaybackHeadPosition());
        if (head < lastHead) headWraps += 1L << 32;
        lastHead = head;
        return (int)(Math.max(0, writtenFrames - headWraps - head) * 1000 / sampleRate);
    }

    public static synchronized void pause() { if (track != null) track.pause(); }
    public static synchronized void resume() { if (track != null) track.play(); }
    public static synchronized void close() {
        if (track != null) {
            try { track.pause(); track.flush(); } catch (RuntimeException ignored) {}
            track.release();
            track = null;
        }
        writtenFrames = headWraps = lastHead = 0;
    }
}
