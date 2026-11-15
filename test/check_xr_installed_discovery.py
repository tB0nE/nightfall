#!/usr/bin/env python3
"""Relocated bundle registration/activation test, offline and software Vulkan.

Run inside the build image with /bundle read-only, /tests read-only, /out writable.
No Steam/headset or host GPU devices. Owns only its temporary helper/runtime/app.
"""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from xr_socket_activation import ActivationListener


def runtime_fixture(installed, work):
    # Exercise the installed supervisor modules, not the checkout copies.
    sys.path.insert(0,str(installed/'test'))
    from xr_runtime_lifecycle import managed_runtime
    from xr_external_runtime import wait_for_sessions
    service=installed/'.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/service/monado-service'
    with managed_runtime([str(service)],env=dict(os.environ),
            ready_path=work/'private-service/nightfall-meteor/monado_comp_ipc',
            inherited_fd=int(os.environ['METEOR_XR_LISTEN_FD']),
            log_path=work/'service.log',state_path=work/'runtime-state.json') as child:
        observed,interrupted=wait_for_sessions(child,work/'service.log',work/'stop',work/'failure',
                                             os.environ['METEOR_XR_RUNTIME_GENERATION'])
        if not observed.finished or interrupted:
            raise RuntimeError('Installed observer did not see normal session completion')


async def check(work):
    sys.path.insert(0,'/bundle/tools')
    from meteor_xr_install import install
    installed=install(Path('/bundle'),work/'installed')
    config=work/'user-config'
    selection=config/'openxr/1/active_runtime.json'
    selection.parent.mkdir(parents=True)
    selection.write_text('previous runtime selection')
    registry=config/'openvr/openvrpaths.vrpath'
    registry.parent.mkdir(parents=True)
    registry.write_text('{"runtime":["/previous-runtime"],"external_drivers":["/kept-driver"]}')
    original_registry=registry.read_bytes()
    icd=next(path for path in (Path('/usr/share/vulkan/icd.d/lvp_icd.json'),
                              Path('/usr/share/vulkan/icd.d/lvp_icd.x86_64.json')) if path.exists())
    env=dict(os.environ,XDG_CONFIG_HOME=str(config),SIMULATED_ENABLE='1',
             XRT_COMPOSITOR_NULL='1',XRT_NO_STDIN='1',VK_ICD_FILENAMES=str(icd))
    for name in ('XR_RUNTIME_JSON','XR_RUNTIME_JSON_64','XR_RUNTIME_JSON_32','LD_LIBRARY_PATH'):
        env.pop(name,None)
    registration=subprocess.Popen([sys.executable,str(installed/'tools/meteor_xr_register.py'),
                                    '--root',str(installed)],env=env,stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    rounds=[]
    try:
        import select
        if not select.select([registration.stdout],[],[],10)[0]:
            raise TimeoutError('Installed registration did not acknowledge readiness')
        if not json.loads(registration.stdout.readline())['ready']:
            raise RuntimeError('Installed registration was rejected')
        if json.loads(registry.read_text())['external_drivers']!=['/kept-driver']:
            raise RuntimeError('Registration changed unrelated OpenVR drivers')
        with tempfile.TemporaryDirectory(prefix='nf-installed-') as temporary:
            runtime=Path(temporary)
            for index in range(2):
                out=work/f'round-{index}';out.mkdir()
                private=out/'private-service';private.mkdir(mode=0o700)
                with ActivationListener(runtime/'nightfall-meteor') as broker:
                    with (out/'probe.log').open('w') as log:
                        app=subprocess.Popen(['/out/installed-probe'],env=dict(env,XDG_RUNTIME_DIR=str(runtime)),
                                             stdout=log,stderr=subprocess.STDOUT)
                        try:
                            async def prepare():
                                return [sys.executable,str(Path(__file__)),'--runtime-fixture',str(installed),str(out)],dict(
                                    env,XDG_RUNTIME_DIR=str(private),METEOR_XR_RUNTIME_GENERATION='a'*32)
                            await broker.activate(prepare,timeout=10)
                            code=await asyncio.to_thread(app.wait,15)
                            if code or 'two pixel-verified eye images' not in (out/'probe.log').read_text():
                                raise RuntimeError(f'Installed OpenXR probe failed; see {out}')
                            if await asyncio.to_thread(broker.process.wait,5):
                                raise RuntimeError(f'Installed runtime observer failed; see {out}')
                            rounds.append(dict(round=index,verified_pixels=True))
                        finally:
                            if app.poll() is None:
                                app.kill();app.wait(timeout=2)
    finally:
        registration.stdin.close();registration.stdin=None
        try:
            _,error=registration.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            registration.kill();registration.communicate()
            raise
        if registration.returncode:
            raise RuntimeError('Installed registration helper failed: '+error)
    if selection.read_text()!='previous runtime selection' or registry.read_bytes()!=original_registry:
        raise RuntimeError('Original runtime registration was not restored exactly')
    return dict(passed=True,rounds=rounds,registration_restored=True,private_dependencies_relocated=True,
                wrapper_environment_used=False,hardware_gpu_used=False,steam_tested=False)


if __name__=='__main__' and '--runtime-fixture' in sys.argv:
    runtime_fixture(Path(sys.argv[-2]),Path(sys.argv[-1]))
    raise SystemExit(0)

if __name__=='__main__':
    work=Path(tempfile.mkdtemp(prefix='installed-check-',dir='/out'))
    summary=Path('/out/installed-discovery-summary.json')
    summary.unlink(missing_ok=True)
    try:
        result=asyncio.run(check(work))
    except BaseException as error:
        summary.write_text(json.dumps(dict(passed=False,error=str(error),work=str(work)),indent=2)+'\n')
        raise
    summary.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
