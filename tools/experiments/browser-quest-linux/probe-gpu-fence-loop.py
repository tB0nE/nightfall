#!/usr/bin/python3
"""Generated persistent GPU clear -> Android read -> release-fence ownership."""
import importlib.util
import json
import os
import signal
import time
signal.alarm(5)
spec=importlib.util.spec_from_file_location('capture','/tmp/gpu-x11-capture.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
capture=None;result={'passed':False,'source':'generated-no-x11'}
try:
    capture=module.GpuCapture(dict(os.environ),mode='generated')
    started=time.monotonic()
    for frame in range(120):
        expected=[255 if frame%120<60 else 0,64,191,255]
        pixel=capture.frame()
        if any(abs(a-b)>2 for a,b in zip(pixel,expected)):raise RuntimeError('Android shared-buffer pixel mismatch')
        time.sleep(max(0,started+(frame+1)/60-time.monotonic()))
    result.update(passed=True,frames=capture.frames,release_fences=capture.release_fences,elapsed_s=round(time.monotonic()-started,3))
except Exception as error:result['error']=type(error).__name__+': '+str(error)
finally:
    if capture is not None:
        try:capture.close()
        except Exception as error:result.update(passed=False,cleanup_error=type(error).__name__)
print(json.dumps(result),flush=True)
raise SystemExit(0 if result['passed'] else 1)
