#!/usr/bin/env python3
"""Isolated real Monado activation check; intended for the offline build image.

Uses software Vulkan only, changes no user runtime registration or Steam files,
and stops owned processes on timeout. /out is a separate diagnostic build cache.
"""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys

from xr_socket_activation import ActivationListener
from xr_runtime_registration import acquire, release


async def check(root):
    service = root / 'capture-build/src/xrt/targets/service/monado-service'
    probe = root / 'runtime-probe'
    icds = (Path('/usr/share/vulkan/icd.d/lvp_icd.json'),
            Path('/usr/share/vulkan/icd.d/lvp_icd.x86_64.json'))
    icd = next(path for path in icds if path.exists())
    environment = dict(os.environ, SIMULATED_ENABLE='1', XRT_COMPOSITOR_NULL='1',
                       XRT_NO_STDIN='1', VK_ICD_FILENAMES=str(icd))
    for name in ('XR_RUNTIME_JSON', 'XR_RUNTIME_JSON_64', 'XR_RUNTIME_JSON_32'):
        environment.pop(name, None)
    rounds = []
    for index in range(2):
        directory = root / f'activation-{index}'
        directory.mkdir(mode=0o700, exist_ok=True)
        private = directory / 'private-service'
        private.mkdir(mode=0o700, exist_ok=True)
        config = directory / 'config'
        destination = config / 'openxr/1/active_runtime.json'
        journal = directory / 'registration.json'
        acquire(destination, root / 'capture-build/openxr_monado-dev.json', journal)
        try:
            await check_round(service, probe, directory, private, environment, config, rounds, index)
        finally:
            if not release(journal):
                raise RuntimeError('Isolated runtime registration cleanup conflicted')
        if destination.exists() or destination.is_symlink():
            raise RuntimeError('Isolated runtime registration was not restored')
    return dict(passed=True, software_vulkan=True, rounds=rounds,
                note='Real OpenXR default discovery; no headset or Steam acceptance')


async def check_round(service, probe, directory, private, environment, config, rounds, index):
    environment = dict(environment, XDG_CONFIG_HOME=str(config))
    name = (Path('/out/ipc-socket-name').read_text().strip()
            if Path('/out/ipc-socket-name').is_file() else 'monado_comp_ipc')
    if name not in ('monado_comp_ipc','nightfall-meteor/monado_comp_ipc'):
        raise ValueError('Unsupported diagnostic socket namespace')
    client_runtime = directory / 'client'
    with ActivationListener((client_runtime / name).parent) as broker:
        log = directory / 'probe.log'
        # The app starts first. It waits in real OpenXR IPC while the
        # broker prepares the runtime; no game wrapper or byte proxy.
        with log.open('w') as output:
            child = subprocess.Popen([str(probe)],
                                     env=dict(environment, XDG_RUNTIME_DIR=str(client_runtime)),
                                     stdout=output, stderr=subprocess.STDOUT)
            try:
                async def prepare():
                    await asyncio.sleep(0.05)
                    # A different XDG dir proves the service adopted the
                    # listener, rather than silently creating a new socket.
                    return [sys.executable, str(Path(__file__)), '--runtime-fixture', str(directory)], dict(
                        environment, XDG_RUNTIME_DIR=str(private), METEOR_XR_RUNTIME_GENERATION='a'*32)
                await broker.activate(prepare, timeout=10)
                code = await asyncio.to_thread(child.wait, 15)
                if code != 0:
                    raise RuntimeError(f'OpenXR probe failed ({code}); see {log}')
                if 'two pixel-verified eye images' not in log.read_text():
                    raise RuntimeError(f'Probe did not verify rendered frames; see {log}')
                if (private / name).exists():
                    raise RuntimeError('Service bound its own IPC instead of adopting listener')
                if broker.process.wait(timeout=5) != 0:
                    raise RuntimeError('External runtime observer failed')
                observed = json.loads((directory / 'external-session.json').read_text())
                if not observed.get('finished') or observed.get('game_process_owned'):
                    raise RuntimeError('External XR session ownership/lifecycle failed')
                rounds.append(dict(round=index, probe_exit=code, inherited_listener=True,
                                   default_runtime_discovery=True))
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait(timeout=2)


def runtime_fixture(directory):
    from xr_runtime_lifecycle import managed_runtime
    from xr_external_runtime import wait_for_sessions
    with managed_runtime(['/out/capture-build/src/xrt/targets/service/monado-service'],
                         env=dict(os.environ), ready_path=directory/'private-service/monado_comp_ipc',
                         log_path=directory/'service.log', state_path=directory/'runtime-state.json',
                         inherited_fd=int(os.environ['METEOR_XR_LISTEN_FD'])) as child:
        events, interrupted = wait_for_sessions(child,directory/'service.log',
            directory/'stop',directory/'failure',os.environ['METEOR_XR_RUNTIME_GENERATION'])
        (directory/'external-session.json').write_text(json.dumps(dict(
            finished=events.finished, interrupted=interrupted, game_process_owned=False)))


if __name__ == '__main__' and '--runtime-fixture' in sys.argv:
    runtime_fixture(Path(sys.argv[-1]))
    raise SystemExit(0)


if __name__ == '__main__':
    summary = Path('/out/socket-activation-summary.json')
    summary.unlink(missing_ok=True)
    try:
        result = asyncio.run(check(Path('/out')))
    except BaseException as error:
        summary.write_text(json.dumps(dict(passed=False, error=str(error)), indent=2) + '\n')
        raise
    summary.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
