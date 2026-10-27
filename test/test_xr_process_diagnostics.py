import json
from pathlib import Path
import tempfile
import unittest
from xr_process_diagnostics import ProcessDiagnostics, stat_record


class ProcessDiagnosticsTests(unittest.TestCase):
    def process(self,proc,pid,ppid=1,start=10,name="test process",cpu=5):
        path=proc/str(pid)
        (path/"task"/str(pid)).mkdir(parents=True,exist_ok=True)
        fields=["0"]*20
        fields[0]="S"; fields[1]=str(ppid); fields[11]=str(cpu); fields[12]="2"; fields[19]=str(start)
        text=f"{pid} ({name}) "+" ".join(fields)
        (path/"stat").write_text(text)
        (path/"task"/str(pid)/"stat").write_text(text)
        (path/"task"/str(pid)/"wchan").write_text("futex_wait_queue\n")
        return path

    def test_parser_handles_spaces_and_parentheses_in_thread_name(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.process(Path(directory),101,name="thread (render) worker")
            value=stat_record(path/"stat")
            self.assertEqual(value["name"],"thread (render) worker")
            self.assertEqual((value["pid"],value["ppid"],value["cpu_ticks"],value["start_ticks"]),(101,1,7,10))

    def test_only_owned_descendants_and_runtime_are_recorded(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); proc=root/"proc"; proc.mkdir()
            self.process(proc,101); self.process(proc,102,ppid=101,name="VRChat.exe")
            self.process(proc,103,ppid=102); self.process(proc,201,name="monado-service")
            self.process(proc,999,name="unrelated")
            output=root/"waits.jsonl"
            sampler=ProcessDiagnostics(output,101,201,proc=proc)
            sampler.sample()
            record=json.loads(output.read_text())
            self.assertEqual({p["pid"] for p in record["processes"]},{101,102,103,201})
            self.assertEqual(record["processes"][0]["threads"][0]["wait"],"futex_wait_queue")
            self.assertIsNone(record["processes"][0]["threads"][0]["cpu_delta_ticks"])
            self.assertEqual(output.stat().st_mode&0o777,0o600)
            sampler.sample(); self.assertEqual(len(output.read_text().splitlines()),1)
            self.process(proc,102,ppid=1,name="VRChat.exe",cpu=9)
            sampler.sample(force=True)
            second=json.loads(output.read_text().splitlines()[-1])
            child=next(p for p in second["processes"] if p["pid"]==102)
            self.assertEqual(child["threads"][0]["cpu_delta_ticks"],4)

    def test_reused_root_pid_does_not_include_another_application(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); proc=root/"proc"; proc.mkdir()
            self.process(proc,101,start=1)
            output=root/"waits.jsonl"; sampler=ProcessDiagnostics(output,101,proc=proc)
            self.process(proc,101,start=2,name="replacement")
            self.process(proc,102,ppid=101)
            sampler.sample()
            self.assertEqual(json.loads(output.read_text())["processes"],[])

    def test_missing_proc_does_not_abort_the_application(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); output=root/"waits.jsonl"
            sampler=ProcessDiagnostics(output,101,proc=root/"missing")
            sampler.sample()
            self.assertEqual(json.loads(output.read_text())["diagnostic_error"],"FileNotFoundError")


if __name__=="__main__": unittest.main()
