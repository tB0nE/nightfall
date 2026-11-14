"""Observe externally launched OpenXR sessions without owning a game process."""
import json
import time


class SessionEvents:
    def __init__(self, generation):
        self.generation = generation
        self.sequence = 0
        self.sessions = {}
        self.saw_begin = False

    def consume(self, line):
        prefix = 'METEOR_XR_EVENT '
        if not line.startswith(prefix):
            return
        value = json.loads(line[len(prefix):])
        if (value.get('generation') != self.generation or
                type(value.get('sequence')) is not int or value['sequence'] != self.sequence + 1 or
                type(value.get('session')) is not int or value['session'] <= 0):
            raise ValueError('Stale or out-of-order external XR session event')
        session, event = value['session'], value.get('event')
        previous = self.sessions.get(session)
        valid = ((previous is None and event == 'created' and len(self.sessions) < 128) or
                 (previous in ('created', 'ended') and event == 'begun') or
                 (previous == 'begun' and event == 'ended') or
                 (previous in ('created', 'begun', 'ended') and event == 'destroyed'))
        if not valid:
            raise ValueError('Invalid external XR session transition')
        self.sequence = value['sequence']
        self.sessions[session] = event
        self.saw_begin |= event == 'begun'

    @property
    def finished(self):
        # xrEndSession alone can be transient (standby/restart). Wait until
        # every created session has actually been destroyed.
        return self.saw_begin and all(event == 'destroyed' for event in self.sessions.values())


def wait_for_sessions(child, log_path, stop_path, failure_path, generation,
                      startup_timeout=30, poll_seconds=0.05):
    events = SessionEvents(generation)
    deadline = time.monotonic() + startup_timeout
    pending = ''
    with log_path.open(errors='replace') as log:
        while True:
            if stop_path.exists():
                return events, True
            if failure_path.exists():
                raise RuntimeError('External XR capture failed; see service.log')
            if child.poll() is not None:
                raise RuntimeError('Runtime exited while observing external XR application')
            pending += log.read(65536)
            lines = pending.split('\n')
            pending = lines.pop()
            if len(pending) > 8192:
                raise ValueError('External XR log line exceeds bound')
            for line in lines:
                events.consume(line)
            # Proton's OpenVR discovery creates/destroys a session before its
            # OpenXR initialization and the actual game. Do not tear down the
            # runtime until a session has produced capture output.
            capture = log_path.parent / 'monado-stereo.jsonl'
            captured = capture.is_file() and capture.stat().st_size > 0
            if events.finished and captured:
                return events, False
            if not captured and time.monotonic() >= deadline:
                raise TimeoutError('External application did not produce XR frames')
            time.sleep(poll_seconds)


def run_activated_runtime(service, env, runtime, out, transport):
    import os
    from xr_runtime_lifecycle import managed_runtime
    from xr_local_application import validate_capture
    raw = env.get('METEOR_XR_LISTEN_FD', '')
    if not raw.isascii() or not raw.isdecimal() or int(raw) < 3:
        raise ValueError('External runtime requires an inherited activation listener')
    generation = env.get('METEOR_XR_RUNTIME_GENERATION')
    if not isinstance(generation, str) or len(generation) != 32 or any(c not in '0123456789abcdef' for c in generation):
        raise ValueError('External runtime requires a current session generation')
    fd = int(raw)
    try:
        with managed_runtime([str(service)], env=env, ready_path=runtime / 'monado_comp_ipc',
                             log_path=out / 'service.log', state_path=out / 'runtime-state.json',
                             inherited_fd=fd, cancel_path=out / 'client-disconnected') as child:
            events, interrupted = wait_for_sessions(child, out / 'service.log',
                out / 'client-disconnected', out / 'capture-failed', generation)
    finally:
        # This helper owns only its inherited listener duplicate, never the
        # broker's master listener and never an externally launched game.
        os.close(fd)
    (out / 'postrun-validation').write_text('runtime reaped; external game not owned\n')
    outcome = dict(outcome='interrupted' if interrupted else 'completed',
                   automatic_detection=True, application_session_observed=events.saw_begin,
                   event_sequence=events.sequence, game_process_owned=False)
    if not interrupted:
        outcome['encoded_frames'] = validate_capture(out, (out / 'service.log').read_text())
        transport.finish()
    (out / 'external-application-outcome.json').write_text(json.dumps(outcome, indent=2) + '\n')
