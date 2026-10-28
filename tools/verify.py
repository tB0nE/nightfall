#!/usr/bin/env python3
"""One entry point for checking Nightfall and Meteor without a person in the headset.

  verify.py unit      Meteor's Rust tests and the GDScript suite (no GPU)
  verify.py depth     Meteor host depth keeps up with a jittery 72 fps stream (GPU)
  verify.py ui        the app on this PC, in a headless gamescope, driven via its
                      dev bridge: welcome, menu reach, tabs, screenshots (GPU)
  verify.py quest     the headset: status, launch, bridge, welcome screen
                      (needs a dev build installed; it starts the app, so ask first)

Each check writes build/verify/<check>-<time>/summary.json:
  {"check", "ok", "duration_s", "metrics": {...}, "failures": [...], "artifacts": [...]}
and prints one line per check. Exit status is 0 only if every check passed.
See docs/testing.md for which check covers which change. Run it with the
host's Python (/usr/bin/python3): a containerised python3 can't see ffmpeg,
gamescope or the GPU.
"""

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'tools'
sys.path.insert(0, str(TOOLS))
import nf  # noqa: E402
import quest  # noqa: E402

GODOT = os.environ.get('NIGHTFALL_GODOT_EDITOR') or shutil.which('godot') or '/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64'
CACHE = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'nightfall-verify'
USER_MODELS = Path.home() / '.local/share/nightfall-meteor/models'


class Check:
    """Collects metrics, failures and artifacts, then writes summary.json."""

    def __init__(self, name, out_root):
        self.name = name
        self.dir = out_root / f"{name}-{time.strftime('%Y%m%d-%H%M%S')}"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.metrics = {}
        self.failures = []
        self.artifacts = []
        self.notes = []
        self.started = time.monotonic()

    def expect(self, condition, failure):
        if not condition:
            self.failures.append(failure)
        return condition

    def artifact(self, path):
        self.artifacts.append(str(path))
        return path

    def finish(self, error=None):
        if error:
            self.failures.append(f'{type(error).__name__}: {error}')
        summary = {
            'check': self.name,
            'ok': not self.failures,
            'duration_s': round(time.monotonic() - self.started, 1),
            'metrics': self.metrics,
            'failures': self.failures,
            'notes': self.notes,
            'artifacts': self.artifacts,
        }
        (self.dir / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
        state = 'PASS' if summary['ok'] else 'FAIL'
        detail = '; '.join(self.failures) if self.failures else ', '.join(f'{k}={v}' for k, v in self.metrics.items())
        print(f"{state} {self.name} ({summary['duration_s']} s): {detail}")
        print(f'     {self.dir / "summary.json"}')
        return summary['ok']


def run_logged(check, name, command, timeout, cwd=ROOT, env=None):
    log = check.artifact(check.dir / f'{name}.log')
    with open(log, 'w') as file:
        result = subprocess.run(command, cwd=cwd, env=env, stdout=file, stderr=subprocess.STDOUT, timeout=timeout)
    return result.returncode, log.read_text(errors='replace')


# --- unit ----------------------------------------------------------------

def check_unit(check, args):
    code, text = run_logged(check, 'cargo-test', ['cargo', 'test', '--release', '--no-default-features'], 1800, cwd=ROOT / 'meteor')
    results = re.findall(r'test result: \w+\. (\d+) passed; (\d+) failed', text)
    check.metrics['rust_passed'] = sum(int(p) for p, _ in results)
    check.metrics['rust_failed'] = sum(int(f) for _, f in results)
    failed = re.findall(r'^test (\S+) \.\.\. FAILED', text, re.M)
    check.expect(code == 0, f"cargo test failed: {', '.join(failed) or 'see cargo-test.log'}")

    env = dict(os.environ, NIGHTFALL_GODOT_EDITOR=GODOT)
    code, text = run_logged(check, 'gdscript', ['bash', 'test/run_gdscript_tests.sh'], 1800, env=env)
    check.metrics['gdscript_ok'] = code == 0
    check.expect(code == 0, 'GDScript tests failed: see gdscript.log')


# --- depth ---------------------------------------------------------------

def need(tool):
    path = shutil.which(tool)
    if not path:
        raise FileNotFoundError(f'{tool} not found on PATH (run with /usr/bin/python3 on the host)')
    return path


def fixture(fps, seconds=12):
    """A 1280x720 HEVC test pattern at `fps`, made once with ffmpeg. Like a game
    stream it has no B-frames: Meteor drops frames that arrive out of order."""
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / f'testsrc2-720p{fps}-{seconds}s-lowdelay.hevc'
    if not path.exists():
        temporary = path.with_suffix('.tmp.hevc')
        with open(CACHE / 'ffmpeg.log', 'w') as log:
            subprocess.run([need('ffmpeg'), '-v', 'error', '-y', '-f', 'lavfi', '-i', f'testsrc2=size=1280x720:rate={fps}',
                            '-t', str(seconds), '-c:v', 'libx265', '-pix_fmt', 'yuv420p', '-tune', 'zerolatency',
                            '-x265-params', f'keyint={fps}:bframes=0:log-level=error', str(temporary)],
                           check=True, stdout=log, stderr=subprocess.STDOUT)
        temporary.replace(path)
    return path


def find_ncnn(explicit):
    candidates = [explicit, os.environ.get('NIGHTFALL_NCNN_LIB'),
                  ROOT / 'meteor/target/appimage/work/stage/libncnn.so.1']
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return Path(candidate)
    raise FileNotFoundError('libncnn.so.1 not found: build the AppImage once, or pass --ncnn / set NIGHTFALL_NCNN_LIB')


def check_depth(check, args):
    binary = ROOT / 'meteor/target/release/nightfall-meteor'
    if not args.no_build:
        code, _ = run_logged(check, 'cargo-build', ['cargo', 'build', '--release', '--no-default-features'], 1800, cwd=ROOT / 'meteor')
        if not check.expect(code == 0, 'cargo build failed: see cargo-build.log'):
            return
    video = fixture(args.fps)
    model = args.model
    if not (USER_MODELS / model).exists():
        raise FileNotFoundError(f'{USER_MODELS / model} is missing (see models/README.md)')
    with tempfile.TemporaryDirectory(prefix='verify-depth-') as temporary:
        work = Path(temporary)
        config = work / 'config/nightfall-meteor'
        config.mkdir(parents=True)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        # Isolated settings: never the user's state.toml or meteor.toml.
        (config / 'meteor.toml').write_text(
            f'discovery_port = {port}\nmodels_dir = {json.dumps(str(USER_MODELS))}\n'
            f'ncnn_lib = {json.dumps(str(find_ncnn(args.ncnn)))}\ntensorrt = false\n')
        (config / 'state.toml').write_text(
            f'enabled = true\nmodel = {json.dumps(model)}\nrate = {args.fps}\ncpu_inference = false\n'
            f'edgepad_gpu = {json.dumps(args.gpu)}\n[decode]\nbackend = "auto"\ncpu_processing = false\n')
        env = dict(os.environ, XDG_CONFIG_HOME=str(work / 'config'), XDG_DATA_HOME=str(work / 'data'),
                   XDG_STATE_HOME=str(work / 'state'), RUST_LOG='nightfall_meteor=info')
        code, text = run_logged(check, 'replay', [str(binary), '--replay', str(video), '--fps', str(args.fps),
                                                  '--jitter-ms', str(args.jitter_ms), '--no-mic', '--no-tray'], 300, env=env)
    done = re.search(r'Replay done: (\d+) frames in, (\d+) maps out, (\d+) skipped', text)
    if not check.expect(code == 0 and done, 'replay did not finish: see replay.log'):
        return
    frames, maps, skipped = (int(x) for x in done.groups())
    ratio = maps / frames
    decoder = re.search(r'Host depth decoding \w+: ([^,]+)', text)
    check.metrics.update(frames=frames, maps=maps, skipped=skipped, map_ratio=round(ratio, 3),
                         maps_per_s=round(args.fps * ratio, 1), requested_hz=args.fps, jitter_ms=args.jitter_ms,
                         decoder=decoder[1].strip() if decoder else '?', model=model)
    check.expect(ratio >= args.min_ratio,
                 f'depth fell behind: {maps} maps for {frames} frames ({args.fps * ratio:.1f} of {args.fps} Hz requested)')


# --- ui (desktop app) ----------------------------------------------------

class DesktopApp:
    """Nightfall on this PC: headless gamescope, isolated user data, dev bridge on."""

    def __init__(self, check, port=nf.PORT):
        self.check = check
        self.port = port
        self.data = Path(tempfile.mkdtemp(prefix='verify-ui-'))
        self.log = check.artifact(check.dir / 'godot.log')
        self.process = None

    def __enter__(self):
        if self._reachable():
            raise RuntimeError(f'something already answers on 127.0.0.1:{self.port}; stop it first')
        env = dict(os.environ, XDG_DATA_HOME=str(self.data), XDG_CONFIG_HOME=str(self.data / 'config'))
        command = [need('gamescope'), '--backend', 'headless', '-W', '1280', '-H', '720', '--',
                   GODOT, '--xr-mode', 'off', '--path', str(ROOT), '--', '--nf-no-xr', '--nf-dev-bridge']
        self.process = subprocess.Popen(command, env=env, stdout=open(self.log, 'w'), stderr=subprocess.STDOUT,
                                        start_new_session=True)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError('the app exited during startup: see godot.log')
            if self._reachable():
                return self
            time.sleep(0.5)
        raise TimeoutError('the dev bridge did not come up within 90 s')

    def _reachable(self):
        try:
            return nf.request({'cmd': 'ping'}, self.port, timeout=2).get('ok', False)
        except (OSError, ValueError):
            return False

    def __call__(self, cmd, **payload):
        return nf.request({'cmd': cmd, **payload}, self.port)

    def __exit__(self, *_):
        if self.process and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
        shutil.rmtree(self.data, ignore_errors=True)


def save_shot(check, reply, name):
    import base64
    if reply.get('ok'):
        path = check.artifact(check.dir / f'{name}.png')
        path.write_bytes(base64.b64decode(reply['png_base64']))


def find(viewports, name):
    return next((v for v in viewports if v['name'] == name), None)


def check_ui(check, args):
    with DesktopApp(check) as app:
        tree = app('ui')['viewports']
        (check.dir / 'ui.json').write_text(json.dumps(tree, indent=2, ensure_ascii=False))
        check.artifact(check.dir / 'ui.json')
        welcome = find(tree, 'welcome')
        if check.expect(welcome, 'no welcome panel'):
            texts = [c.get('text', '') for c in welcome['controls']]
            check.expect('Pair' in texts, f'welcome has no Pair button: {texts}')
        menu = find(tree, 'ui')
        if check.expect(menu and 'panel' in menu, 'no menu panel'):
            distance = menu['panel']['distance']
            check.metrics['menu_distance_m'] = distance
            check.expect(distance <= args.max_reach, f'menu is {distance} m away (reach {args.max_reach} m)')
        tabs = ['Display', 'Stream', 'Control', 'AI 3D', 'Picture']
        for tab in tabs:
            reply = app('press', target=tab)
            check.expect(reply.get('ok') and reply.get('hit'), f'tab {tab}: {reply}')
            save_shot(check, app('screenshot', viewport='ui'), f"menu-{tab.lower().replace(' ', '')}")
        save_shot(check, app('screenshot', viewport='welcome'), 'welcome')
        check.metrics['tabs_pressed'] = len(tabs)
        state = app('state')['state']
        check.metrics['render_fps'] = state.get('fps')
        log = app('log', lines=400)['lines']
    errors = [line for line in Path(check.dir / 'godot.log').read_text(errors='replace').splitlines() if 'SCRIPT ERROR' in line]
    check.metrics['script_errors'] = len(errors)
    check.expect(not errors, f'{len(errors)} script errors, first: {errors[0] if errors else ""}')
    (check.dir / 'app.log').write_text('\n'.join(log) + '\n')
    check.artifact(check.dir / 'app.log')


# --- quest ---------------------------------------------------------------

def check_quest(check, args):
    adb = quest.Adb(args.serial)
    devices = adb.run('devices').splitlines()[1:]
    if not check.expect(any(line.endswith('device') for line in devices), 'no headset connected over adb'):
        return
    adb.shell('am broadcast -a com.oculus.vrpowermanager.prox_close')
    check.notes.append('proximity sensor set to "worn"; `tools/quest.py sleep` undoes it')
    quest.launch(adb, quest.PACKAGE, fresh=args.fresh)
    adb.run('forward', f'tcp:{nf.PORT}', f'tcp:{nf.PORT}')
    deadline = time.monotonic() + 40
    reply = None
    while time.monotonic() < deadline:
        try:
            reply = nf.request({'cmd': 'ping'}, timeout=3)
            break
        except (OSError, ValueError):
            time.sleep(1)
    if not check.expect(reply and reply.get('ok'), 'no dev bridge on the headset: is a dev build installed?'):
        return
    check.metrics['xr'] = reply.get('xr')
    state = nf.request({'cmd': 'state'})['state']
    check.metrics['render_fps'] = state.get('fps')
    (check.dir / 'state.json').write_text(json.dumps(state, indent=2))
    check.artifact(check.dir / 'state.json')
    tree = nf.request({'cmd': 'ui'})['viewports']
    (check.dir / 'ui.json').write_text(json.dumps(tree, indent=2, ensure_ascii=False))
    check.artifact(check.dir / 'ui.json')
    menu = find(tree, 'ui')
    if menu and 'panel' in menu:
        check.metrics['menu_distance_m'] = menu['panel']['distance']
        check.expect(menu['panel']['distance'] <= args.max_reach, f"menu is {menu['panel']['distance']} m away")
    for name in ('ui', 'welcome'):
        save_shot(check, nf.request({'cmd': 'screenshot', 'viewport': name}), name)


CHECKS = {'unit': check_unit, 'depth': check_depth, 'ui': check_ui, 'quest': check_quest}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('checks', nargs='+', choices=sorted(CHECKS))
    parser.add_argument('--out', type=Path, default=ROOT / 'build/verify')
    depth = parser.add_argument_group('depth')
    depth.add_argument('--fps', type=int, default=72, help='stream fps and requested depth rate')
    depth.add_argument('--jitter-ms', type=float, default=4.0)
    depth.add_argument('--min-ratio', type=float, default=0.93, help='maps per frame needed to pass')
    depth.add_argument('--model', default='zipdepth_edgepad_256.ncnn.param')
    depth.add_argument('--gpu', default='NVIDIA GeForce RTX 3090')
    depth.add_argument('--ncnn')
    depth.add_argument('--no-build', action='store_true')
    ui = parser.add_argument_group('ui and quest')
    ui.add_argument('--max-reach', type=float, default=2.5)
    ui.add_argument('--serial')
    ui.add_argument('--fresh', action='store_true', help='quest: restart the app first')
    args = parser.parse_args(argv)

    ok = True
    for name in args.checks:
        check = Check(name, args.out)
        try:
            CHECKS[name](check, args)
            ok = check.finish() and ok
        except Exception as error:  # noqa: BLE001 - every failure belongs in the summary
            ok = check.finish(error) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
