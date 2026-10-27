"""Owned runtime service lifecycle, independent of any XR application launcher.

IPC readiness is NOT an OpenXR application/session event. The caller owns
application launch/observation and must reap its app before leaving this scope.
"""
from contextlib import contextmanager
import json
import subprocess
import time


@contextmanager
def managed_runtime(command, *, env, ready_path, log_path, state_path,
                    startup_timeout=10, stop_timeout=5, cancel_path=None):
    if ready_path.exists():
        raise RuntimeError("Refusing pre-existing runtime IPC endpoint")
    # No inherited/stale state may be interpreted as readiness for this attempt.
    state_path.unlink(missing_ok=True)

    def record(state, child):
        temporary = state_path.with_suffix(".tmp")
        temporary.write_text(json.dumps({"state": state, "pid": child.pid,
                                         "application_session_observed": False}))
        temporary.replace(state_path)

    with log_path.open("w") as log:
        child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            record("starting", child)
            deadline = time.monotonic() + startup_timeout
            while True:
                if child.poll() is not None:
                    raise RuntimeError(f"Runtime exited before readiness; see {log_path}")
                if cancel_path is not None and cancel_path.exists():
                    raise RuntimeError("Runtime startup cancelled")
                if ready_path.is_socket():
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"Runtime startup timed out; see {log_path}")
                time.sleep(.05)
            record("runtime_ready", child)
            yield child
            if child.poll() is not None:
                raise RuntimeError(f"Runtime exited unexpectedly; see {log_path}")
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=stop_timeout)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            record("stopped", child)
