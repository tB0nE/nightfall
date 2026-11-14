import json
from pathlib import Path
import tempfile
import unittest
from xr_external_runtime import SessionEvents, wait_for_sessions


class ExternalRuntimeTests(unittest.TestCase):
    def event(self, sequence, state, session=1, generation='a'*32):
        return 'METEOR_XR_EVENT ' + json.dumps(dict(generation=generation,
            sequence=sequence, session=session, event=state))

    def test_standby_end_is_not_game_exit(self):
        observer = SessionEvents('a'*32)
        observer.consume(self.event(1, 'created'))
        observer.consume(self.event(2, 'begun'))
        observer.consume(self.event(3, 'ended'))
        self.assertFalse(observer.finished)
        observer.consume(self.event(4, 'begun'))
        observer.consume(self.event(5, 'destroyed'))
        self.assertTrue(observer.finished)

    def test_all_sessions_must_be_destroyed(self):
        observer = SessionEvents('a'*32)
        for seq, event, session in ((1,'created',1),(2,'begun',1),(3,'created',2),(4,'destroyed',1)):
            observer.consume(self.event(seq,event,session))
        self.assertFalse(observer.finished)
        observer.consume(self.event(5,'destroyed',2))
        self.assertTrue(observer.finished)

    def test_stale_and_replayed_events_fail(self):
        observer = SessionEvents('a'*32)
        with self.assertRaises(ValueError):
            observer.consume(self.event(1,'created',generation='b'*32))
        observer.consume(self.event(1,'created'))
        with self.assertRaises(ValueError):
            observer.consume(self.event(1,'created'))
        with self.assertRaises(ValueError):
            observer.consume(self.event(2,'ended'))

    def test_wait_never_signals_external_game_and_cancellation_is_bounded(self):
        class Child:
            def poll(self):
                return None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / 'log'
            log.write_text('ordinary service message\n')
            with self.assertRaises(TimeoutError):
                wait_for_sessions(Child(),log,root/'stop',root/'failure','a'*32,
                                  startup_timeout=0.01,poll_seconds=0.001)
            (root/'stop').touch()
            observer, interrupted = wait_for_sessions(Child(),log,root/'stop',root/'failure','a'*32)
            self.assertTrue(interrupted)
            self.assertFalse(observer.saw_begin)

    def test_completed_session_observed_without_launching_process(self):
        class Child:
            def poll(self):
                return None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / 'log'
            (root / 'monado-stereo.jsonl').write_text('{}\n')
            log.write_text('\n'.join(self.event(seq,event) for seq,event in
                                     ((1,'created'),(2,'begun'),(3,'destroyed'))) + '\n')
            observer, interrupted = wait_for_sessions(Child(),log,root/'stop',root/'failure','a'*32)
            self.assertTrue(observer.finished)
            self.assertFalse(interrupted)

    def test_proton_probe_does_not_complete_runtime_before_game_frames(self):
        class Child:
            def poll(self):
                return None
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / 'log'
            log.write_text('\n'.join(self.event(seq,event) for seq,event in
                                     ((1,'created'),(2,'begun'),(3,'destroyed'))) + '\n')
            with self.assertRaises(TimeoutError):
                wait_for_sessions(Child(),log,root/'stop',root/'failure','a'*32,
                                  startup_timeout=0.01,poll_seconds=0.001)


if __name__ == '__main__':
    unittest.main()
