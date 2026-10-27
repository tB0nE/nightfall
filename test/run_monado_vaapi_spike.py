"""Isolated HEVC Monado/AMD regression; never selects the installed XR runtime."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from run_meteor_vaapi_probe import OUTPUT, ROOT, recovery_check, require_current_build, require_healthy_boot


def main():
    require_healthy_boot(OUTPUT/'failed-boot.json')
    require_current_build()
    output=OUTPUT/('monado-'+str(time.time_ns()))
    output.mkdir(parents=True)
    env=dict(os.environ,NIGHTFALL_XR_ENCODER_BACKEND='vaapi',NIGHTFALL_XR_CODEC='h265',
             NIGHTFALL_XR_FOVEATED_ENCODING='0',NIGHTFALL_XR_PROBE_OUTPUT=str(output),
             NIGHTFALL_PROBE_PYTHON=sys.executable)
    env.setdefault('NIGHTFALL_XR_PROBE_FRAMES','16')
    try:
        with (output/'probe.log').open('w') as log:
            process=subprocess.Popen(['bash',str(ROOT/'tools/build_support/probe_monado_nvenc.sh')],
                                     env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
            try:
                result=process.wait(timeout=120)
            except BaseException:
                # Only the process group created for this diagnostic is owned.
                os.killpg(process.pid,signal.SIGTERM)
                try: process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid,signal.SIGKILL)
                raise
        if result:
            raise RuntimeError(f'Monado AMD probe failed: {output}/probe.log')
    finally:
        recovery_check(output)
    print((output/'probe.log').read_text()[-2200:])
    print('Monado AMD evidence:',output)


if __name__=='__main__':
    main()
