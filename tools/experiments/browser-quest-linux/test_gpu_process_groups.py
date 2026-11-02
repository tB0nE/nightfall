#!/usr/bin/python3
"""Exercise real descendant cleanup and isolation without a GPU or headset."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
HELPER=Path(__file__).with_name('gpu-process-groups.sh').resolve()
class ProcessGroups(unittest.TestCase):
    def test_kills_owned_descendants_but_not_unrelated_process(self):
        sentinel=subprocess.Popen(['sleep','30'])
        owned=[]
        try:
            with tempfile.TemporaryDirectory() as tmp:
                pidfile=Path(tmp)/'child'
                script='''source "$1"
setsid bash -c 'trap "" TERM; sleep 30 & echo $! > "$1"; wait' group-test "$2" &
leader=$!
nf_gpu_register_group "$leader"
for ((i=0;i<100;i++)); do [[ -s "$2" ]] && break; sleep .01; done
printf '%s %s\n' "$leader" "$(cat "$2")"
nf_gpu_stop_groups
wait "$leader" 2>/dev/null || true
'''
                run=subprocess.run(['bash','-c',script,'test',str(HELPER),str(pidfile)],capture_output=True,text=True,timeout=3,check=True)
                owned=[int(p) for p in run.stdout.split()]
                self.assertEqual(len(owned),2)
                for pid in owned:
                    status=Path(f'/proc/{pid}/stat')
                    self.assertTrue(not status.exists() or status.read_text().rsplit(')',1)[1].split()[0]=='Z')
                self.assertIsNone(sentinel.poll())
        finally:
            for pid in owned:
                try:os.kill(pid,signal.SIGKILL)
                except ProcessLookupError:pass
            sentinel.terminate();sentinel.wait(timeout=2)
    def test_refuses_unsafe_group_ids(self):
        run=subprocess.run(['bash','-c','source "$1"; for value in 0 1 -1 abc $$; do if nf_gpu_register_group "$value"; then exit 1; fi; done','test',str(HELPER)],timeout=2)
        self.assertEqual(run.returncode,0)
if __name__=='__main__':unittest.main()
