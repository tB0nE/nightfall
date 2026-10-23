"""Bounded, child-local shutdown for the USB XR diagnostic (not a LAN policy)."""
import subprocess
import time
import json
import os


def valid_completion(path, token, target):
    if path is None or not token: return False
    try:
        record=json.loads(path.read_text())
        return (record.get("run_id")==token and record.get("state")=="completion_requested"
            and type(record.get("target")) is int and record["target"]==target and target>0
            and type(record.get("encoded_at_request")) is int and record["encoded_at_request"]>=target)
    except (OSError,ValueError,AttributeError):
        return False


def run_application(command, *, env, timeout, service_log, stop_file,
                    watch_disconnect=False, stop_timeout=3,
                    completion_file=None, completion_token=None, completion_target=0,
                    cwd=None, terminate_on_stop=False, owner_alive=None, output_path=None,
                    diagnostics_path=None, runtime_pid=None):
    stop_file.unlink(missing_ok=True)
    if completion_file is not None: completion_file.unlink(missing_ok=True)
    interrupted = False
    forced = False
    deadline = time.monotonic() + timeout
    # A background app must not consume the host terminal or see an immediate
    # EOF as "press any key to quit". Keep a private pipe's writer alive without
    # passing it to the app; communicate() must not own/close that writer.
    stdin_read, stdin_write = os.pipe() if terminate_on_stop else (None, None)
    # External Steam/xrizer output must survive supervisor termination. Pipes
    # otherwise keep the useful panic message only in this process's memory.
    output = output_path.open("w") if output_path is not None else None
    try:
        application = subprocess.Popen(command, env=env, cwd=cwd, stdin=stdin_read,
                                       stdout=output if output else subprocess.PIPE,
                                       stderr=subprocess.STDOUT if output else subprocess.PIPE, text=True)
    except BaseException:
        if output: output.close()
        if stdin_read is not None:
            os.close(stdin_read)
            os.close(stdin_write)
        raise
    try:
        diagnostics=None
        if diagnostics_path is not None:
            from xr_process_diagnostics import ProcessDiagnostics
            diagnostics=ProcessDiagnostics(diagnostics_path,application.pid,runtime_pid)
            diagnostics.sample(force=True)
        with service_log.open() as log:
            pending = ""
            while True:
                try:
                    stdout, stderr = application.communicate(timeout=.1)
                    break
                except subprocess.TimeoutExpired:
                    pass
                if diagnostics: diagnostics.sample()
                if owner_alive is not None and not owner_alive() and not interrupted:
                    stop_file.write_text("Local launch owner ended\n")
                if terminate_on_stop and stop_file.exists() and not interrupted:
                    interrupted = True
                    application.terminate()
                    deadline = time.monotonic() + stop_timeout
                if watch_disconnect and not interrupted:
                    pending += log.read()
                    lines = pending.split("\n")
                    pending = lines.pop()
                    if any(line.startswith("METEOR_TRACKING_DISCONNECTED ") for line in lines):
                        if not valid_completion(completion_file,completion_token,completion_target):
                            interrupted = True
                            # Only the patched sample consumes this run-local request.
                            stop_file.write_text("tracking disconnected\n")
                            if terminate_on_stop: application.terminate()
                        # A valid completion request permits normal validation, NOT a
                        # success verdict. Caller must still prove byte counts/drain.
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
        if output:
            output.flush()
            stdout, stderr = output_path.read_text(errors="replace"), ""
        result = subprocess.CompletedProcess(command, application.returncode, stdout, stderr)
        return result, interrupted, forced
    except BaseException as failure:
        if application.poll() is None:
            application.kill()
        stdout, stderr = application.communicate(timeout=2)
        if isinstance(failure, subprocess.TimeoutExpired):
            if output:
                output.flush()
                stdout, stderr = output_path.read_text(errors="replace"), ""
            failure.output, failure.stderr = stdout, stderr
        raise
    finally:
        if output: output.close()
        if stdin_read is not None:
            os.close(stdin_read)
            os.close(stdin_write)
