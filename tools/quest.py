#!/usr/bin/env python3
"""Run Nightfall on a Quest without wearing it, for agents and scripts.

  quest.py status               # device, battery, awake, installed app, running pid
  quest.py awake                # act as if worn, and keep the Guardian dialog away
  quest.py sleep                # undo awake
  quest.py install APK          # adb install -r, retried (the first try often fails)
  quest.py launch [--fresh]     # start Nightfall; --fresh force-stops it first
  quest.py stop
  quest.py forward              # forward the dev bridge port (see tools/nf.py)
  quest.py shot OUT.png         # the system's view, via the Quest's own capture service
  quest.py logcat [-n 200]      # Nightfall's process only

In-app state, UI and per-panel screenshots come from tools/nf.py, which needs a
dev build. See docs/testing.md.
"""

import argparse
import subprocess
import sys
import time

PACKAGE = 'app.nightfall.quest'
ACTIVITY = 'com.godot.game.GodotAppLauncher'
BRIDGE_PORT = 47950
SCREENSHOTS = '/sdcard/Oculus/Screenshots'


class Adb:
    def __init__(self, serial=None):
        self.prefix = ['adb'] + (['-s', serial] if serial else [])

    def run(self, *args, check=True, binary=False):
        result = subprocess.run(self.prefix + list(args), capture_output=True, check=False)
        if check and result.returncode != 0:
            raise RuntimeError(f"adb {' '.join(args)}: {result.stderr.decode(errors='replace').strip()}")
        return result.stdout if binary else result.stdout.decode(errors='replace')

    def shell(self, command, check=True):
        return self.run('shell', command, check=check).strip()

    def pid(self, package):
        return self.shell(f'pidof {package}', check=False) or None


def focused(adb):
    """The activity in front: the app pauses (and its bridge goes quiet)
    whenever something else, such as the Guardian dialog, is."""
    for line in adb.shell('dumpsys activity activities').splitlines():
        if 'topResumedActivity=' in line:
            return line.split()[-2] if len(line.split()) >= 2 else line.strip()
    return '?'


def status(adb, package):
    model = adb.shell('getprop ro.product.model')
    battery = adb.shell('dumpsys battery')
    level = next((line.split(':')[1].strip() for line in battery.splitlines() if 'level:' in line), '?')
    wake = next((line.split('=')[1] for line in adb.shell('dumpsys power').splitlines() if 'mWakefulness=' in line), '?')
    version = next((line.split('=')[1] for line in adb.shell(f'dumpsys package {package}').splitlines()
                    if 'versionName=' in line), None)
    print(f'{model}: battery {level}%, {wake.lower()}')
    print(f'{package}: {version or "not installed"}, ' + (f'running (pid {adb.pid(package)})' if adb.pid(package) else 'not running'))
    front = focused(adb)
    print(f'in front: {front}' + ('' if front.startswith(package) else f' ({package} is paused behind it)'))


def install(adb, apk, attempts=3):
    for attempt in range(1, attempts + 1):
        result = subprocess.run(adb.prefix + ['install', '-r', apk], capture_output=True, text=True)
        if result.returncode == 0 and 'Success' in result.stdout:
            print(f'installed {apk}')
            return
        error = (result.stderr or result.stdout).strip().splitlines()[-1:] or ['?']
        if 'INSTALL_FAILED_UPDATE_INCOMPATIBLE' in error[0]:
            # A signing mismatch: never uninstall to get past it, it wipes the user's pairing.
            raise RuntimeError(f'{error[0]} (signed with a different key; not uninstalling)')
        print(f'install attempt {attempt} failed: {error[0]}', file=sys.stderr)
        time.sleep(2)
    raise RuntimeError(f'install failed after {attempts} attempts')


def launch(adb, package, fresh):
    if fresh:
        adb.shell(f'am force-stop {package}')
    adb.shell(f'am start -n {package}/{ACTIVITY}')
    # The first start after an install takes a while.
    for _ in range(120):
        if adb.pid(package):
            print(f'{package} running (pid {adb.pid(package)})')
            return
        time.sleep(0.25)
    raise RuntimeError(f'{package} did not start')


def shot(adb, out):
    before = set(adb.shell(f'ls {SCREENSHOTS}', check=False).split())
    adb.shell('am startservice -n com.oculus.metacam/.capture.CaptureService -a TAKE_SCREENSHOT', check=False)
    for _ in range(40):
        time.sleep(0.25)
        new = sorted(set(adb.shell(f'ls {SCREENSHOTS}', check=False).split()) - before)
        if new:
            time.sleep(0.5)  # let the file finish writing
            data = adb.run('exec-out', f'cat {SCREENSHOTS}/{new[-1]}', binary=True)
            adb.shell(f'rm {SCREENSHOTS}/{new[-1]}', check=False)
            break
    else:
        # Older system software: the plain Android capture (often black on Quest).
        data = adb.run('exec-out', 'screencap -p', binary=True)
    if not data:
        raise RuntimeError('no screenshot (is the headset awake? try `quest.py awake`)')
    with open(out, 'wb') as file:
        file.write(data)
    print(f'{out}: {len(data)} bytes')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--serial', help='adb device serial')
    parser.add_argument('--package', default=PACKAGE)
    commands = parser.add_subparsers(dest='cmd', required=True)
    commands.add_parser('status')
    commands.add_parser('awake')
    commands.add_parser('sleep')
    install_cmd = commands.add_parser('install')
    install_cmd.add_argument('apk')
    launch_cmd = commands.add_parser('launch')
    launch_cmd.add_argument('--fresh', action='store_true')
    commands.add_parser('stop')
    commands.add_parser('forward')
    shot_cmd = commands.add_parser('shot')
    shot_cmd.add_argument('out')
    logcat = commands.add_parser('logcat')
    logcat.add_argument('-n', type=int, default=200)
    args = parser.parse_args(argv)
    adb = Adb(args.serial)

    try:
        if args.cmd == 'status':
            status(adb, args.package)
        elif args.cmd == 'awake':
            # The proximity sensor reads "worn": the display and apps keep running.
            adb.shell('am broadcast -a com.oculus.vrpowermanager.prox_close')
            # Waking a headset on a desk brings up the Guardian boundary
            # dialog, which pauses the app behind it.
            adb.shell('setprop debug.oculus.guardian_pause 0')
            print('headset acts as worn, without the Guardian dialog, until `quest.py sleep` (or a reboot)')
        elif args.cmd == 'sleep':
            adb.shell('am broadcast -a com.oculus.vrpowermanager.automation_disable')
            adb.shell("setprop debug.oculus.guardian_pause ''", check=False)
            print('proximity sensor and Guardian back to normal (a reboot restores both for certain)')
        elif args.cmd == 'install':
            install(adb, args.apk)
        elif args.cmd == 'launch':
            launch(adb, args.package, args.fresh)
        elif args.cmd == 'stop':
            adb.shell(f'am force-stop {args.package}')
        elif args.cmd == 'forward':
            adb.run('forward', f'tcp:{BRIDGE_PORT}', f'tcp:{BRIDGE_PORT}')
            print(f'127.0.0.1:{BRIDGE_PORT} -> headset; try `tools/nf.py ping`')
        elif args.cmd == 'shot':
            shot(adb, args.out)
        elif args.cmd == 'logcat':
            pid = adb.pid(args.package)
            if not pid:
                raise RuntimeError(f'{args.package} is not running')
            print(adb.run('logcat', '-d', '-t', str(args.n), f'--pid={pid}'), end='')
    except (RuntimeError, FileNotFoundError) as error:
        print(f'quest: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
