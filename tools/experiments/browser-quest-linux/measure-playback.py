#!/usr/bin/python3
"""Sample direct-display/audio counters during user-confirmed playback; no media or profile access."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from nf import request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--interval', type=float, default=5)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9_-]{1,60}', args.label):
        parser.error('Use a short filename-safe label')
    if not 1 <= args.seconds <= 120 or not 1 <= args.interval <= 60:
        parser.error('Use 1–120 seconds and a 1–60 second interval')
    from test_guard import HeadsetTestGuard
    with HeadsetTestGuard(min(150, int(args.seconds) + 20)):
        collect(args)


def collect(args):
    adb = os.environ.get('ADB', 'adb')
    output = ROOT / '.build-cache/browser-quest-linux/playback' / (
        args.label + '-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '.json')
    output.parent.mkdir(parents=True, exist_ok=True)

    def shell(*command):
        return subprocess.check_output([adb, 'shell', *command], text=True, timeout=8)

    def private_json(name):
        return json.loads(shell('run-as', 'app.nightfall.browserlab', 'cat', 'files/linux/' + name))

    started = time.monotonic()
    samples = []
    while True:
        sample = {'elapsed_s': time.monotonic() - started}
        try:
            sample['direct'] = private_json('direct-frame-status.json')
            sample['audio'] = private_json('audio-status.json')
            reply = request({'cmd': 'eval', 'expr':
                             '[display_refresh_rate,telemetry.app_fps,telemetry.video_update_fps,settings.host.ai_3d_speed]'}, timeout=3)
            if not reply.get('ok'):
                raise RuntimeError(reply.get('error', 'Bridge failed'))
            sample['refresh_app_texture_ai'] = reply['value']
            battery = shell('dumpsys', 'battery')
            for key in ('level', 'temperature'):
                match = re.search(r'^\s*' + key + r':\s*(-?\d+)', battery, re.M)
                if match:
                    sample['battery_' + key] = int(match[1])
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            sample['error'] = str(error)
        samples.append(sample)
        good = [s for s in samples if 'error' not in s]
        summary = {}
        if len(good) >= 2:
            a, b = good[0]['direct'], good[-1]['direct']
            dt = b['elapsed_s'] - a['elapsed_s']
            if dt > 0 and b['posted_frames'] >= a['posted_frames']:
                frames = b['posted_frames'] - a['posted_frames']
                summary['producer_posts_per_s'] = frames / dt
                summary['late_slots_delta'] = b.get('late_slots', 0) - a.get('late_slots', 0)
                summary['changed_samples_delta'] = b['changed_samples'] - a['changed_samples']
                if frames > 0:
                    for field in ('mean_copy_ms', 'mean_draw_ms'):
                        summary[field + '_window'] = (
                            b[field] * b['posted_frames'] - a[field] * a['posted_frames']) / frames
            else:
                summary['producer_restarted_or_stale'] = True
            aa, ab = good[0]['audio'], good[-1]['audio']
            summary['pcm_bytes_delta'] = ab['pcm_bytes_written'] - aa['pcm_bytes_written']
            summary['audio_playhead_frames_delta'] = ab['playback_head_frames'] - aa['playback_head_frames']
            summary['nonzero_audio_samples_delta'] = ab['nonzero_pcm_samples'] - aa['nonzero_pcm_samples']
        complete = time.monotonic() - started >= args.seconds
        result = {'label': args.label, 'complete': complete, 'summary': summary, 'samples': samples,
                  'limits': 'Requires user-confirmed playback. Producer posts are not decoded/unique video frames. Audio counters do not prove lip sync. Temperature is Android battery units (tenths Celsius).'}
        output.write_text(json.dumps(result, indent=2) + '\n')
        if complete:
            print(json.dumps({'output': str(output), 'summary': summary,
                              'samples': len(samples), 'errors': sum('error' in s for s in samples)}, indent=2))
            return
        time.sleep(min(args.interval, max(.05, args.seconds - (time.monotonic() - started))))


if __name__ == '__main__':
    main()
