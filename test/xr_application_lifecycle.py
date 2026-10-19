"""Bounded, child-local shutdown for the USB XR diagnostic (not a LAN policy)."""
import subprocess
import time


def run_application(command, *, env, timeout, service_log, stop_file,
                    watch_disconnect=False, stop_timeout=3):
    stop_file.unlink(missing_ok=True)
    interrupted = False
    forced = False
    deadline = time.monotonic() + timeout
    application = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
    try:
        with service_log.open() as log:
            pending = ""
            while True:
                try:
                    stdout, stderr = application.communicate(timeout=.1)
                    break
                except subprocess.TimeoutExpired:
                    pass
                if watch_disconnect and not interrupted:
                    pending += log.read()
                    lines = pending.split("\n")
                    pending = lines.pop()
                    if any(line.startswith("METEOR_TRACKING_DISCONNECTED ") for line in lines):
                        interrupted = True
                        # Only the patched sample consumes this run-local request.
                        stop_file.write_text("tracking disconnected\n")
                        deadline = time.monotonic() + stop_timeout
                if time.monotonic() >= deadline:
                    if not interrupted:
                        raise subprocess.TimeoutExpired(command, timeout)
                    forced = True
                    application.terminate()
                    try:
                        stdout, stderr = application.communicate(timeout=2)
                    except subprocess.TimeoutExpired:
                        application.kill()
                        stdout, stderr = application.communicate(timeout=2)
                    break
        result = subprocess.CompletedProcess(command, application.returncode, stdout, stderr)
        return result, interrupted, forced
    except BaseException as failure:
        if application.poll() is None:
            application.kill()
        stdout, stderr = application.communicate(timeout=2)
        if isinstance(failure, subprocess.TimeoutExpired):
            failure.output, failure.stderr = stdout, stderr
        raise
