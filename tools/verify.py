#!/usr/bin/env python3
"""One entry point for checking Nightfall and Meteor without a person in the headset.

  verify.py unit      Meteor's Rust tests and the GDScript suite (no GPU)
  verify.py depth     Meteor host depth keeps up with a jittery 72 fps stream (GPU)
  verify.py ui        the app on this PC, in a headless gamescope, driven via its
                      dev bridge: welcome, menu reach, tabs, screenshots (GPU)
  verify.py quest     the headset: status, launch, bridge, welcome screen
                      (needs a dev build installed; it starts the app, so ask first)
  verify.py stream    the headset streams this PC through Meteor: fps, network,
                      depth source and rate (needs pairing; ask first)
  verify.py pcvr      PCVR on this PC without the headset: a sample OpenXR app,
                      synthetic tracking, the installed runtime, NVENC and VA-API
  verify.py xr        the app itself in a real OpenXR session on this PC (Meteor's
                      runtime, synthetic tracking): its 3D view, menu, bridge
  verify.py e2e       a test pattern on the streamed monitor, streamed to the
                      headset through Meteor: frames lost, repeats, latency
                      (restarts Meteor, draws on the desktop; ask first)

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

# Bridge ports for runs on this PC: never 47950, which `quest.py forward` may
# have pointed at the headset.
DESKTOP_PORT = 47952
XR_PORT = 47951


class DesktopApp:
    """Nightfall on this PC: headless gamescope, isolated user data, dev bridge on."""

    def __init__(self, check, port=DESKTOP_PORT):
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
                   GODOT, '--xr-mode', 'off', '--path', str(ROOT), '--', '--nf-no-xr', '--nf-dev-bridge',
                   f'--nf-dev-bridge-port={self.port}']
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
    if not check.expect(reply and reply.get('ok'),
                        f'no dev bridge on the headset: is a dev build installed? In front: {quest.focused(adb)}'):
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


# --- stream (headset) ------------------------------------------------------

STATUS = re.compile(r'(?P<w>\d+)x(?P<h>\d+) (?P<fps>\d+)fps (?P<mbps>\d+)Mbps (?P<codec>\S+)'
                    r'.*?Net:(?P<net>\d+|\?)ms.*?(?P<hz>\d+)Hz.*?App:(?P<app>\d+)fps')
DEPTH = re.compile(r'(?P<src>[HM])-AI3D:(?P<ms>[\d.]+)ms/(?P<hz>[\d.]+)Hz')


def parse_status(line):
    """The headset's status line, e.g. '2560x1440 72fps 48Mbps HEVC HW • Net:4ms •
    72Hz • App:72fps • M-AI3D:5.1ms/71.9Hz'."""
    out = {}
    match = STATUS.search(line or '')
    if match:
        out.update(resolution=f"{match['w']}x{match['h']}", stream_fps=int(match['fps']), mbps=int(match['mbps']),
                   codec=match['codec'], display_hz=int(match['hz']), app_fps=int(match['app']))
        if match['net'] != '?':
            out['net_ms'] = int(match['net'])
    depth = DEPTH.search(line or '')
    if depth:
        out.update(depth_source='meteor' if depth['src'] == 'M' else 'headset',
                   depth_ms=float(depth['ms']), depth_hz=float(depth['hz']))
    return out


def connect(args):
    """Presses Connect on the headset, first choosing --server (its label in
    the server list, e.g. 10.0.0.13:47984) when given. Connect otherwise goes
    to whichever server the app has selected."""
    if args.server:
        nf.request({'cmd': 'press', 'target': 'WelcomeChangeServer'})
        time.sleep(1)
        reply = nf.request({'cmd': 'press', 'target': args.server})
        if not reply.get('ok'):
            return reply
        time.sleep(1)
    return nf.request({'cmd': 'press', 'target': 'WelcomeConnect'})


def meteor_info(port=47900):
    import urllib.request
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/meteor', timeout=3) as reply:
            return json.load(reply)
    except OSError:
        return None


def check_stream(check, args):
    """Streams the PC to the headset and checks what the headset reports."""
    adb = quest.Adb(args.serial)
    adb.shell('am broadcast -a com.oculus.vrpowermanager.prox_close')
    adb.shell('setprop debug.oculus.guardian_pause 0')
    quest.launch(adb, quest.PACKAGE, fresh=args.fresh)
    adb.run('forward', f'tcp:{nf.PORT}', f'tcp:{nf.PORT}')
    time.sleep(2)
    started = False
    if not nf.request({'cmd': 'eval', 'expr': 'is_streaming'}).get('value'):
        reply = connect(args)
        if not check.expect(reply.get('ok'), f'no Connect button (is the headset paired?): {reply}'):
            return
        started = True
    try:
        reply = nf.request({'cmd': 'wait', 'expr': 'is_streaming', 'timeout': 40}, timeout=60)
        if not check.expect(reply.get('ok'), f"the stream didn't start: {reply.get('error')}"):
            return
        check.metrics['connect_s'] = reply.get('waited_s')
        time.sleep(args.settle)
        samples = []
        for _ in range(3):
            state = nf.request({'cmd': 'state'})['state']
            sample = parse_status(state.get('status_line', ''))
            meteor = state.get('depth', {}).get('meteor')
            if meteor:
                sample['meteor_received_hz'] = round(meteor.get('received_hz', 0.0), 1)
                sample['meteor_exact_pct'] = round(meteor.get('exact_pct', 0.0), 1)
            samples.append(sample)
            time.sleep(5)
        (check.dir / 'samples.json').write_text(json.dumps(samples, indent=2))
        check.artifact(check.dir / 'samples.json')
        save_shot(check, nf.request({'cmd': 'screenshot', 'viewport': 'ui'}), 'ui')
        last = samples[-1]
        if not check.expect('stream_fps' in last, f"couldn't read the status line: {state.get('status_line')!r}"):
            return
        for key in ('resolution', 'codec', 'stream_fps', 'display_hz', 'mbps', 'net_ms', 'depth_source'):
            if key in last:
                check.metrics[key] = last[key]
        app = min(s.get('app_fps', 0) for s in samples)
        check.metrics['app_fps_min'] = app
        check.expect(app >= 0.9 * last['display_hz'], f"app ran at {app} fps on a {last['display_hz']} Hz display")
        if last.get('depth_source') == 'meteor':
            received = min(s.get('meteor_received_hz', 0.0) for s in samples)
            info = meteor_info() or {}
            ceiling = min(last['stream_fps'], (info.get('depth') or {}).get('max_hz') or last['stream_fps'])
            check.metrics.update(meteor_depth_hz_min=received, meteor_depth_ceiling_hz=ceiling)
            check.expect(received >= 0.9 * ceiling, f'Meteor depth arrived at {received} Hz of {ceiling} Hz')
        elif 'depth_source' in last:
            check.metrics['headset_depth_hz'] = last['depth_hz']
            check.notes.append('depth ran on the headset, so Meteor depth was not checked')
    finally:
        if started:
            nf.request({'cmd': 'eval', 'expr': 'disconnect_stream()'})
            check.notes.append('disconnected the stream it started')


# --- pcvr ------------------------------------------------------------------

XR_INSTALL = Path.home() / '.local/share/nightfall-meteor/xr'


def installed_runtime(choice):
    """The runtime Meteor runs now (its xr-runtime link), or a version prefix,
    or a path."""
    if not choice:
        return (XR_INSTALL / 'xr-runtime').resolve().parent
    path = Path(choice)
    if path.is_dir():
        return path.resolve()
    matches = sorted((XR_INSTALL / 'versions').glob(f'{choice}*'))
    if len(matches) != 1:
        raise FileNotFoundError(f'{len(matches)} installed XR runtimes match {choice!r} in {XR_INSTALL / "versions"}')
    return matches[0]


def check_pcvr(check, args):
    """The external-app smoke (hello_xr, synthetic tracking, real Monado and
    encoder) once per encoder, against an installed runtime."""
    import contextlib
    import io
    sys.path.insert(0, str(ROOT / 'test'))
    import smoke_xr_local_application as smoke
    runtime = installed_runtime(args.runtime)
    check.metrics['runtime'] = runtime.name[:8]
    for encoder in args.encoders.split(','):
        output = io.StringIO()
        error = None
        try:
            with contextlib.redirect_stdout(output):
                smoke.run(ROOT, installed_runtime=runtime, encoder=encoder)
        except Exception as caught:  # noqa: BLE001 - the smoke raises plain errors
            error = caught
        log = check.artifact(check.dir / f'{encoder}.log')
        log.write_text(output.getvalue() + (f'\n{type(error).__name__}: {error}\n' if error else ''))
        found = re.search(r'Smoke diagnostics: (\S+)', output.getvalue())
        session = Path(found[1]) if found else None
        if session:
            check.artifact(session)
        if not check.expect(error is None, f'{encoder}: {str(error).splitlines()[0] if error and str(error) else type(error).__name__} (see {encoder}.log)'):
            continue
        selection = json.loads((session / 'encoder-selection.json').read_text())
        outcome = json.loads((session / 'lifecycle-outcome.json').read_text())
        service = (session / 'service.log').read_text(errors='replace')
        rejected = service.count('METEOR_CAPTURE_FAILED')
        check.metrics[f'{encoder}_frames'] = outcome.get('encoded_frames')
        check.metrics[f'{encoder}_rejected'] = rejected
        check.metrics[f'{encoder}_device'] = selection.get('render_device') or 'nvidia'
        check.expect(selection.get('backend') == encoder, f"{encoder}: the runtime encoded with {selection.get('backend')}")
        check.expect(rejected == 0, f'{encoder}: {rejected} frames rejected by the capture hook')
        check.expect(outcome.get('encoded_frames', 0) >= 60, f"{encoder}: only {outcome.get('encoded_frames')} frames encoded")
    check.notes.append('hello_xr with one projection layer and one XR session; real games (Proton, '
                       'quads, a second session) are not covered yet')


# --- xr (the app in a real OpenXR session on this PC) ------------------------

def decode_frame(check, session, name, frame=-1):
    """One encoded stereo frame (both eyes side by side) as a PNG."""
    video = session / 'monado-stereo.h264'
    out = check.dir / f'{name}.png'
    count = len((session / 'monado-stereo.jsonl').read_text().splitlines())
    index = count - 2 if frame < 0 else frame
    subprocess.run([need('ffmpeg'), '-v', 'error', '-y', '-i', str(video), '-vf', f'select=eq(n\\,{max(index, 0)})',
                    '-frames:v', '1', str(out)], check=True, capture_output=True)
    return check.artifact(out)


def check_xr(check, args):
    """Nightfall under Meteor's XR runtime: a real OpenXR session with synthetic
    tracking. Its encoded frames show the 3D view a headset would get."""
    sys.path.insert(0, str(ROOT / 'test'))
    from run_xr_app import XrAppSession, nightfall_argv
    runtime = installed_runtime(args.runtime)
    data = Path(tempfile.mkdtemp(prefix='verify-xr-'))
    bridge = lambda cmd, **payload: nf.request({'cmd': cmd, **payload}, XR_PORT)
    try:
        with XrAppSession(ROOT, nightfall_argv(ROOT, GODOT, data, XR_PORT), runtime=runtime) as session:
            check.artifact(session.dir)
            session.wait_frames(30, timeout=90)
            deadline = time.monotonic() + 30
            while True:
                try:
                    ping = bridge('ping')
                    break
                except OSError:
                    if time.monotonic() > deadline:
                        raise
                    time.sleep(1)
            check.expect(ping.get('platform') == 'Linux', f'the bridge on port {XR_PORT} is not this PC: {ping}')
            check.expect(ping.get('xr'), 'the app is not in an XR session')
            decode_frame(check, session.dir, 'view-welcome')
            tree = bridge('ui')['viewports']
            (check.dir / 'ui.json').write_text(json.dumps(tree, indent=2, ensure_ascii=False))
            welcome = find(tree, 'welcome')
            check.expect(welcome and any(c.get('text') == 'Pair' for c in welcome['controls']),
                         'no Pair button on the welcome screen')
            # Open the menu as a user would, then check it opened within reach.
            before = session.frames()
            reply = bridge('eval', expr='_toggle_ui()')
            check.expect(reply.get('ok'), f'opening the menu failed: {reply}')
            session.wait_frames(before + 15, timeout=30)
            state = bridge('state')['state']
            menu = state.get('menu', {})
            check.metrics['menu_visible'] = menu.get('visible')
            check.metrics['menu_distance_m'] = menu.get('distance')
            check.expect(menu.get('visible'), 'the menu did not open')
            check.expect(menu.get('distance', 99) <= args.max_reach, f"menu opened {menu.get('distance')} m away")
            decode_frame(check, session.dir, 'view-menu')
            check.metrics['render_fps'] = state.get('fps')
            check.metrics['frames'] = session.frames()
            rejected = session.service_log().count('METEOR_CAPTURE_FAILED')
            check.metrics['rejected'] = rejected
            check.expect(rejected == 0, f'{rejected} frames rejected by the capture hook')
        live = session.dir / 'application-live.log'
        errors = [l for l in live.read_text(errors='replace').splitlines() if 'SCRIPT ERROR' in l] if live.exists() else []
        check.metrics['script_errors'] = len(errors)
        check.expect(not errors, f'{len(errors)} script errors, first: {errors[0] if errors else ""}')
    finally:
        shutil.rmtree(data, ignore_errors=True)


# --- e2e (a test pattern through the whole stream) -------------------------

class RunningMeteor:
    """The Meteor running now: restarts it with extra arguments, then puts it
    back exactly as it was (same command, same environment)."""

    def __init__(self, check, binary=None):
        self.check = check
        self.binary = binary
        pids = subprocess.run(['pgrep', '-x', 'nightfall-meteo'], capture_output=True, text=True).stdout.split()
        if len(pids) != 1:
            raise RuntimeError(f'expected one running Meteor, found {len(pids)}')
        self.pid = int(pids[0])
        proc = Path(f'/proc/{self.pid}')
        self.env = dict(item.split('=', 1) for item in proc.joinpath('environ').read_text().split('\0') if '=' in item)
        argv = proc.joinpath('cmdline').read_text().split('\0')[:-1]
        # An AppImage runs from a temporary mount; restart the AppImage itself.
        if self.env.get('APPIMAGE'):
            argv[0] = self.env['APPIMAGE']
            for name in ('APPDIR', 'APPIMAGE', 'ARGV0', 'OWD'):
                self.env.pop(name, None)
        self.argv = argv
        self.process = None

    def _stop(self, pid):
        os.kill(pid, signal.SIGTERM)
        for _ in range(100):
            if not Path(f'/proc/{pid}').exists():
                return
            time.sleep(0.1)
        os.kill(pid, signal.SIGKILL)

    def _start(self, extra, log_name):
        log = open(self.check.artifact(self.check.dir / log_name), 'w')
        process = subprocess.Popen(self.argv + extra, env=self.env, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        time.sleep(6)  # models load and the ports open
        if process.poll() is not None:
            raise RuntimeError(f'Meteor exited on restart; see {log_name}')
        return process

    def restart_with(self, extra):
        """Restarts with `extra` arguments, and as `binary` when given (a build
        with the frames file, e.g. meteor/target/release/nightfall-meteor)."""
        self._stop(self.pid)
        original = self.argv
        if self.binary:
            self.argv = [str(self.binary)] + original[1:]
        try:
            self.process = self._start(extra, 'meteor-test.log')
        finally:
            self.argv = original

    def restore(self):
        if self.process and self.process.poll() is None:
            self._stop(self.process.pid)
            self._start([], 'meteor-restored.log')
            self.check.notes.append(f"restarted Meteor as before: {' '.join(self.argv)}")


def headset_bridge(args):
    adb = quest.Adb(args.serial)
    adb.shell('am broadcast -a com.oculus.vrpowermanager.prox_close')
    adb.shell('setprop debug.oculus.guardian_pause 0')
    quest.launch(adb, quest.PACKAGE, fresh=False)
    adb.run('forward', f'tcp:{nf.PORT}', f'tcp:{nf.PORT}')
    time.sleep(2)
    return adb


def check_e2e(check, args):
    """Draws test/stream_pattern.gd on the streamed monitor while the headset
    streams it through Meteor, then reads the pattern back from Meteor's
    copy of the stream: frames the host never sent, repeats, and the time
    from drawing to arrival at Meteor."""
    sys.path.insert(0, str(ROOT / 'test'))
    import analyze_stream_pattern as pattern
    dump = check.dir / 'dump'
    meteor = RunningMeteor(check, args.meteor_binary)
    headset_bridge(args)
    if nf.request({'cmd': 'eval', 'expr': 'is_streaming'}).get('value'):
        nf.request({'cmd': 'eval', 'expr': 'disconnect_stream()'})
        nf.request({'cmd': 'wait', 'expr': 'not is_streaming', 'timeout': 15}, timeout=30)
    meteor.restart_with(['--dump-video', str(dump)])
    samples = []
    try:
        reply = connect(args)
        if not check.expect(reply.get('ok'), f'no Connect button (is the headset paired?): {reply}'):
            return
        reply = nf.request({'cmd': 'wait', 'expr': 'is_streaming', 'timeout': 40}, timeout=60)
        if not check.expect(reply.get('ok'), f"the stream didn't start: {reply.get('error')}"):
            return
        time.sleep(4)
        block = args.block
        window = f'{(pattern.BLOCKS) * block}x{2 * block}'
        log = open(check.artifact(check.dir / 'pattern.log'), 'w')
        drawer = subprocess.Popen([GODOT, '--xr-mode', 'off', '--resolution', window,
                                   '--position', f'{args.pattern_x},{args.pattern_y}', '--path', str(ROOT),
                                   '--script', 'test/stream_pattern.gd', '--',
                                   f'--x={args.pattern_x}', f'--y={args.pattern_y}', f'--block={block}',
                                   f'--seconds={args.seconds}'], stdout=log, stderr=subprocess.STDOUT)
        end = time.monotonic() + args.seconds
        while time.monotonic() < end:
            time.sleep(min(5, max(0.5, end - time.monotonic())))
            state = nf.request({'cmd': 'state'})['state']
            samples.append(parse_status(state.get('status_line', '')))
        drawer.wait(timeout=30)
    finally:
        try:
            nf.request({'cmd': 'eval', 'expr': 'disconnect_stream()'})
            time.sleep(3)  # the tap ends and the dump is flushed
        finally:
            meteor.restore()
    (check.dir / 'headset.json').write_text(json.dumps(samples, indent=2))
    videos = sorted((v for v in dump.glob('meteor-*') if v.suffix in ('.hevc', '.h264')),
                    key=lambda v: v.stat().st_mtime)
    if not check.expect(videos, 'Meteor dumped no video: did the stream go through Meteor?'):
        return
    video = videos[-1]
    rows = pattern.decode(video, args.pattern_x, args.pattern_y, args.block)
    stream_fps = next((s['stream_fps'] for s in reversed(samples) if 'stream_fps' in s), None)
    result = pattern.analyze(rows, pattern.arrivals(Path(str(video) + '.frames.tsv')), stream_fps)
    (check.dir / 'pattern.json').write_text(json.dumps(result, indent=2))
    check.metrics.update({k: v for k, v in result.items() if k != 'frames'})
    if samples:
        last = samples[-1]
        for key in ('resolution', 'stream_fps', 'net_ms', 'app_fps', 'depth_source', 'depth_hz'):
            if key in last:
                check.metrics[f'headset_{key}'] = last[key]
    if not check.expect(result.get('readable', 0) >= 30, f"only {result.get('readable', 0)} frames carried the pattern "
                        f'(is it at {args.pattern_x},{args.pattern_y} on the streamed monitor?)'):
        return
    lost = result.get('arrival_lost_pct', result['missing_pct'])
    check.expect(lost <= args.max_missing_pct, f'{lost}% of frames never reached Meteor')
    if 'latency_ms_p95' in result:
        check.expect(result['latency_ms_p95'] <= args.max_latency_ms,
                     f"p95 draw-to-Meteor latency {result['latency_ms_p95']} ms (limit {args.max_latency_ms})")


CHECKS = {'unit': check_unit, 'depth': check_depth, 'ui': check_ui, 'quest': check_quest,
          'stream': check_stream, 'pcvr': check_pcvr, 'xr': check_xr, 'e2e': check_e2e}


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
    ui.add_argument('--settle', type=float, default=10.0, help='stream: seconds before sampling')
    ui.add_argument('--server', help='stream/e2e: the server to choose first, as the server list shows it')
    e2e = parser.add_argument_group('e2e')
    e2e.add_argument('--pattern-x', type=int, default=64, help='desktop = stream pixels on a 1:1 stream')
    e2e.add_argument('--pattern-y', type=int, default=64)
    e2e.add_argument('--block', type=int, default=48)
    e2e.add_argument('--seconds', type=float, default=15.0)
    e2e.add_argument('--max-missing-pct', type=float, default=1.0)
    e2e.add_argument('--max-latency-ms', type=float, default=60.0)
    e2e.add_argument('--meteor-binary', type=Path, default=ROOT / 'meteor/target/release/nightfall-meteor',
                     help='run this Meteor during the test (it must write the frames file)')
    pcvr = parser.add_argument_group('pcvr')
    pcvr.add_argument('--runtime', help='installed XR runtime: a version prefix or a path (default: the current one)')
    pcvr.add_argument('--encoders', default='nvenc,vaapi')
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
