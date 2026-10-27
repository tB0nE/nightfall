"""Opt-in /proc wait-state samples. No debugger, signals, memory, argv or env."""
import json
import os
from pathlib import Path
import time


def stat_record(path):
    text=path.read_text()
    name,separator,tail=text.rpartition(") ")
    if not separator: raise ValueError("Invalid process stat")
    pid,separator,name=name.partition(" (")
    if not separator: raise ValueError("Invalid process name")
    fields=tail.split()
    return {"pid":int(pid),"name":name,"state":fields[0],"ppid":int(fields[1]),
            "cpu_ticks":int(fields[11])+int(fields[12]),"start_ticks":int(fields[19])}


class ProcessDiagnostics:
    def __init__(self, output, app_pid, runtime_pid=None, proc=Path("/proc")):
        self.output=output
        self.proc=proc
        self.known={}
        self.previous={}
        self.next_sample=0.0
        for pid in (app_pid,runtime_pid):
            if pid is not None:
                try: self.known[pid]=stat_record(proc/str(pid)/"stat")["start_ticks"]
                except (OSError,ValueError,IndexError): pass

    def sample(self, force=False):
        now=time.monotonic()
        if not force and now<self.next_sample: return
        self.next_sample=now+3.0
        try:
            all_processes={}
            for entry in self.proc.iterdir():
                if not entry.name.isdecimal(): continue
                try: all_processes[int(entry.name)]=stat_record(entry/"stat")
                except (OSError,ValueError,IndexError): continue
            owned={pid for pid,start in self.known.items()
                   if pid in all_processes and all_processes[pid]["start_ticks"]==start}
            while True:
                children={pid for pid,value in all_processes.items() if value["ppid"] in owned}
                if children<=owned: break
                owned|=children
            records=[]
            for pid in sorted(owned)[:64]:
                process=all_processes[pid].copy()
                self.known[pid]=process["start_ticks"]
                process["threads"]=[]
                try:
                    threads=sorted((self.proc/str(pid)/"task").iterdir(),key=lambda p:int(p.name))
                    for thread in threads[:512]:
                        try:
                            value=stat_record(thread/"stat")
                            value["wait"]= (thread/"wchan").read_text().strip()
                            key=(pid,value["pid"],value["start_ticks"])
                            old=self.previous.get(key)
                            value["cpu_delta_ticks"]=None if old is None else max(0,value["cpu_ticks"]-old)
                            self.previous[key]=value["cpu_ticks"]
                            process["threads"].append(value)
                        except (OSError,ValueError,IndexError): continue
                    process["thread_count"]=len(threads)
                    process["threads_truncated"]=len(threads)>512
                except OSError: process["threads_unavailable"]=True
                records.append(process)
            self._write({"monotonic_ns":time.monotonic_ns(),"wall_time":time.time(),
                         "processes":records,"processes_truncated":len(owned)>64})
        except (OSError,ValueError,IndexError) as error:
            # Diagnostics must never change game lifecycle or request its exit.
            try: self._write({"diagnostic_error":type(error).__name__})
            except OSError: pass

    def _write(self,value):
        descriptor=os.open(self.output,os.O_WRONLY|os.O_CREAT|os.O_APPEND|os.O_NOFOLLOW,0o600)
        with os.fdopen(descriptor,"w") as output:
            output.write(json.dumps(value)+"\n")
