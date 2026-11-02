#!/usr/bin/python3
"""Verify the compatibility tab through Nightfall's native input and navigation.
Requires the updated DEV APK, running Linux lab and a foreground/worn headset.
Only a generated test page's numeric counters are exported.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from nf import request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restore-netflix', action='store_true')
    args = parser.parse_args()
    from test_guard import HeadsetTestGuard
    with HeadsetTestGuard(90):
        collect(args)


def collect(args):
    adb = os.environ.get('ADB', 'adb')
    directory = ROOT / '.build-cache/browser-quest-linux' / ('touch-check-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    directory.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'limits': 'Generated-page interaction, not Netflix playback or physical-controller comfort.'}

    def evaluate(expr):
        response = request({'cmd': 'eval', 'expr': expr}, timeout=3)
        if not response.get('ok'):
            raise RuntimeError(response.get('error', 'Native bridge failure'))
        return response.get('value')

    def wait_for(expr, seconds=12):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if evaluate(expr):
                return
            time.sleep(.25)
        raise RuntimeError('State did not settle: ' + expr)

    def key(code, down, modifiers=0):
        evaluate(f'browser_prototype._gamepad_bridge().browserKeyFor(browser_prototype.browser_id,{code},{str(down).lower()},{modifiers})')
        time.sleep(.035)

    def navigate(url):
        evaluate('browser_prototype.navigation_action("address")')
        # The frontend selects all; no clipboard or profile inspection.
        for char in url:
            modifiers = 0
            if 'a' <= char <= 'z': code = ord(char) - ord('a') + 29
            elif '0' <= char <= '9': code = ord(char) - ord('0') + 7
            else:
                code = {':': 74, '/': 76, '.': 56, '-': 69, '?': 76, '=': 70}[char]
                if char in ':?': modifiers = 1
            key(code, True, modifiers); key(code, False, modifiers)
        key(66, True); key(66, False)

    try:
        for port in (47950, 6083):
            subprocess.run([adb, 'forward', f'tcp:{port}', f'tcp:{port}'], check=True, timeout=5)
        if not evaluate('browser_prototype.active'):
            evaluate('browser_prototype.start()')
        wait_for('browser_prototype.uploader.poll_browser_prototype() == 2')
        evaluate('browser_prototype._gamepad_bridge().browserLinuxFramesFor(browser_prototype.browser_id,true)')
        wait_for('browser_prototype._gamepad_bridge().browserLinuxFramesActiveFor(browser_prototype.browser_id)')
        time.sleep(2)
        compat_id = int(evaluate('browser_prototype.selected_page'))
        width, height = evaluate('[browser_prototype.render_size.x,browser_prototype.render_size.y]')
        started = time.monotonic()
        navigate('http://127.0.0.1:6082/input-probe.html')
        wait_for('browser_prototype.navigation.get("address","") == "http://127.0.0.1:6082/input-probe.html"')
        time.sleep(1)

        def pointer(nx, ny, action):
            evaluate(f'browser_prototype._gamepad_bridge().browserPointerFor(browser_prototype.browser_id,{float(nx*width)},{float(ny*height)},{action})')
            time.sleep(.06)

        for nx, ny in ((.5, .2), (.5, .6)):
            pointer(nx, ny, 0); pointer(nx, ny, 1)
        for code in (29, 124): key(code, True); key(code, False)
        pointer(.94, .025, 7); time.sleep(.2)
        pointer(.94, .085, 0); pointer(.94, .085, 1)
        time.sleep(.6)
        before_drag = json.load(urllib.request.urlopen('http://127.0.0.1:6083/', timeout=3))['input']['scroll_y']
        pointer(.95, .5, 0)
        for y in (.46, .4, .34, .28): pointer(.95, y, 2)
        pointer(.95, .28, 1)
        time.sleep(1)
        data = json.load(urllib.request.urlopen('http://127.0.0.1:6083/', timeout=3))['input']
        report['input'] = data
        if data['clicks'] < 1 or data['input_length'] != 1 or data['insert_count'] != 1:
            raise RuntimeError('Tap, typing or Insert failed')
        if data['touch_starts'] < 3 or data['touch_ends'] + data['touch_cancels'] < data['touch_starts']:
            raise RuntimeError('Touch lifecycle failed')
        if data['scroll_y'] - before_drag < 50:
            raise RuntimeError('Drag-to-scroll failed independently of thumbstick scroll')
        if data['profile_actions'] != 1 or data['scrollbar_width'] != 0:
            raise RuntimeError('Desktop hover-menu or scrollbar hiding failed')
        key(93, True); key(93, False)
        status = json.loads(subprocess.check_output([adb, 'shell', 'run-as', 'app.nightfall.browserlab', 'cat', 'files/linux/touch-status.json'], text=True, timeout=5))
        report['touch'] = status
        # With default display density, a content-only window's CSS viewport
        # must fill the source; compare to actual source dimensions, not the
        # potentially differently sized Nightfall output Surface.
        frame = json.loads(subprocess.check_output([adb, 'shell', 'run-as', 'app.nightfall.browserlab', 'cat', 'files/linux/direct-frame-status.json'], text=True, timeout=5))
        if not (0 <= frame['source_width'] - status['viewport_width'] <= 2 and
                0 <= frame['source_height'] - status['viewport_height'] <= 2):
            raise RuntimeError('Browser chrome or unexpected viewport scaling remains')
        report['source_size'] = [frame['source_width'], frame['source_height']]
        evaluate('browser_prototype.tab_action("new")')
        wait_for('not browser_prototype._gamepad_bridge().browserLinuxFramesActiveFor(browser_prototype.browser_id)')
        wait_for(f'browser_prototype.selected_page != {compat_id}')
        for _ in range(12):
            audio = json.loads(subprocess.check_output([adb, 'shell', 'run-as', 'app.nightfall.browserlab', 'cat', 'files/linux/audio-status.json'], text=True, timeout=5))
            media = json.load(urllib.request.urlopen('http://127.0.0.1:6083/', timeout=3))['input']
            if audio['state'] == 'stopped' and media['media_paused']: break
            time.sleep(.25)
        else: raise RuntimeError('Hidden compatibility tab kept audio or media active')
        report['audio_stopped_on_switch'] = True
        ordinary_id = int(evaluate('browser_prototype.selected_page'))
        evaluate(f'browser_prototype.tab_action("select",{compat_id})')
        wait_for('browser_prototype._gamepad_bridge().browserLinuxFramesActiveFor(browser_prototype.browser_id)')
        time.sleep(2)
        evaluate(f'browser_prototype.tab_action("close",{ordinary_id})')
        report['ordinary_tab_round_trip'] = True
        pointer(.5, .2, 0); pointer(.5, .2, 1)
        for _ in range(16):
            audio = json.loads(subprocess.check_output([adb, 'shell', 'run-as', 'app.nightfall.browserlab', 'cat', 'files/linux/audio-status.json'], text=True, timeout=5))
            media = json.load(urllib.request.urlopen('http://127.0.0.1:6083/', timeout=3))['input']
            if audio.get('play_state') == 3 and audio.get('nonzero_pcm_samples', 0) > 0 and not media['media_paused']: break
            time.sleep(.25)
        else: raise RuntimeError('No active audio before close test')
        evaluate(f'browser_prototype.tab_action("close",{compat_id})')
        wait_for('not browser_prototype.active and not browser_prototype.closing')
        for _ in range(16):
            audio = json.loads(subprocess.check_output([adb, 'shell', 'run-as', 'app.nightfall.browserlab', 'cat', 'files/linux/audio-status.json'], text=True, timeout=5))
            media = json.load(urllib.request.urlopen('http://127.0.0.1:6083/', timeout=3))['input']
            if audio['state'] == 'stopped' and media['media_paused']: break
            time.sleep(.25)
        else: raise RuntimeError('Closed compatibility tab kept audio or media active')
        report['audio_stopped_on_close'] = True
        evaluate('browser_prototype.start()')
        wait_for('browser_prototype.uploader.poll_browser_prototype() == 2')
        evaluate('browser_prototype._gamepad_bridge().browserLinuxFramesFor(browser_prototype.browser_id,true)')
        wait_for('browser_prototype._gamepad_bridge().browserLinuxFramesActiveFor(browser_prototype.browser_id)')
        time.sleep(2)
        report['duration_s'] = time.monotonic() - started
        if args.restore_netflix:
            navigate('https://www.netflix.com/watch/81936146')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
    finally:
        output = directory / 'summary.json'
        output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'summary': str(output), **report}, indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
