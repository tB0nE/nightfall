#!/usr/bin/env python3
"""Bounded native Steam sandbox visibility check; no game, GPU render or headset.

Uses an isolated installed runtime, configuration and socket. Does not restart
Steam, edit its launchers/options, or select the real user's OpenXR runtime.
"""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'tools'),str(ROOT/'test')]
from meteor_steam_environment import environment
from meteor_xr_install import install
from xr_socket_activation import ActivationListener


def run(bundle,steam,out):
    out.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='fixture-',dir=out) as temporary:
        fixture=Path(temporary)
        installed=install(bundle,fixture/'installed')
        config=fixture/'config';config.mkdir()
        base=dict(os.environ,XDG_CONFIG_HOME=str(config))
        for key in ('XR_RUNTIME_JSON','XR_RUNTIME_JSON_64','XR_RUNTIME_JSON_32',
                    'LD_LIBRARY_PATH','LD_PRELOAD','SteamAppId','SteamGameId','STEAM_COMPAT_APP_ID'):
            base.pop(key,None)
        runtime_parent=Path(os.environ['XDG_RUNTIME_DIR'])
        with tempfile.TemporaryDirectory(prefix='nf-steam-check-',dir=runtime_parent) as runtime:
            runtime=Path(runtime)
            with ActivationListener(runtime/'nightfall-meteor') as listener:
                helper=subprocess.Popen(['/usr/bin/python3',str(installed/'tools/meteor_xr_register.py'),
                                          '--root',str(installed)],env=base,stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                try:
                    if not select.select([helper.stdout],[],[],10)[0]:
                        raise TimeoutError('Isolated runtime registration did not acknowledge readiness')
                    if not json.loads(helper.stdout.readline())['ready']:
                        raise RuntimeError('Isolated registration was not ready')
                    env=environment(installed,runtime,dict(base,XDG_RUNTIME_DIR=str(runtime)))
                    # Real user config normally lives in the shared home. This
                    # fixture is outside it, so explicitly expose its config.
                    env['PRESSURE_VESSEL_FILESYSTEMS_RO']+=':'+str(config)
                    command=[str(steam/'run'),'--batch','--share-home','--no-copy-runtime',
                             '--no-generate-locales','--no-gc-runtimes','--graphics-provider=/',
                             '--variable-dir='+str(fixture/'pressure-var'), '--','/bin/sh','-c',
                             '''set -eux
printf 'STEAM_PROBE_ENTERED\n'
test -S "$1"
test -r "$2"
test -r "$3"
test -r "$4"
imported=0
if [ -n "${XR_RUNTIME_JSON-}" ]; then
    test -r "$XR_RUNTIME_JSON"
    grep -F -q "$6" "$XR_RUNTIME_JSON"
    imported=1
else
    IFS=:
    for directory in ${XDG_CONFIG_DIRS:-/etc/xdg}; do
        for name in active_runtime.x86_64.json active_runtime.json; do
            candidate="$directory/openxr/1/$name"
            if [ -r "$candidate" ] && grep -F -q "$6" "$candidate"; then
                imported=1
            fi
        done
    done
fi
[ "$imported" = 1 ]
printf 'STEAM_OPENXR_MANIFEST_IMPORTED\n'
printf 'STEAM_XR_NAMESPACE_VISIBLE\n'
''', 'xr-sandbox-probe',str(listener.path),
                             str(installed/'.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/openxr/libopenxr_monado.so'),
                             str(installed/'xr-runtime/lib/libcjson.so.1'),
                             str(installed/'xr-runtime/xrizer/bin/linux64/vrclient.so'),
                             str(config/'openxr/1/active_runtime.json'),str(installed)]
                    with (out/'pressure-vessel.log').open('w') as log:
                        process=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
                        try:
                            code=process.wait(timeout=45)
                        finally:
                            if process.poll() is None:
                                os.killpg(process.pid,signal.SIGKILL)
                                process.wait(timeout=3)
                    text=(out/'pressure-vessel.log').read_text(errors='replace')
                    if code or 'STEAM_XR_NAMESPACE_VISIBLE' not in text:
                        raise RuntimeError(f'Steam sandbox visibility check failed (exit {code}); see pressure-vessel.log')
                    result=dict(passed=True,native_steam=True,socket_visible=True,
                                runtime_libraries_visible=True,wrapper_environment=False,
                                imported_manifest='STEAM_OPENXR_MANIFEST_IMPORTED' in text,
                                game_launched=False,headset_used=False,gpu_rendered=False)
                finally:
                    helper.stdin.close();helper.stdin=None
                    try:
                        _,error=helper.communicate(timeout=5)
                    except subprocess.TimeoutExpired:
                        helper.kill();helper.communicate()
                        raise
                    if helper.returncode:
                        raise RuntimeError('Isolated registration cleanup failed: '+error)
                if (config/'openxr/1/active_runtime.json').exists():
                    raise RuntimeError('Isolated runtime registration was not removed')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle',type=Path,required=True)
    parser.add_argument('--steam-runtime',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    summary=args.output/'summary.json'
    summary.unlink(missing_ok=True)
    try:
        result=run(args.bundle.resolve(),args.steam_runtime.resolve(),args.output.resolve())
    except BaseException as error:
        summary.write_text(json.dumps(dict(passed=False,error=str(error)),indent=2)+'\n')
        raise
    summary.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
