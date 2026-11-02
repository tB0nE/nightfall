#!/usr/bin/python3
"""Independent kernel-log abort for bounded generated GPU tests."""
import subprocess
import threading

class GpuHangMonitor:
    def __init__(self,guard,since,output):
        self.guard=guard;self.since=since;self.output=output
        self.hang=threading.Event();self.error=None;self.process=None;self.worker=None

    def start(self):
        self.process=subprocess.Popen([self.guard.adb,'-s',self.guard.serial,'logcat','-b','kernel','-v','threadtime','-T',self.since],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
        self.worker=threading.Thread(target=self._read,name='GpuHangMonitor',daemon=True)
        self.worker.start()
        return self

    def _line(self,line):
        if 'GPU hang detected' not in line or self.hang.is_set():return
        self.hang.set()
        # Runs independently of dev-bridge socket reads and runtime callbacks.
        for package in ('app.nightfall.browserlab','app.nightfall.quest'):
            try:self.guard.shell('am force-stop '+package)
            except Exception as error:self.error=type(error).__name__

    def _read(self):
        try:
            with self.output.open('w') as output:
                for line in self.process.stdout:
                    output.write(line);output.flush();self._line(line)
        except Exception as error:self.error=type(error).__name__

    def check(self):
        if self.hang.is_set():raise RuntimeError('GPU hang detected; test aborted')
        if self.error:raise RuntimeError('Kernel monitor failed: '+self.error)
        if self.process.poll() is not None:raise RuntimeError('Kernel monitor exited unexpectedly')

    def stop(self):
        if self.process is not None:
            self.process.terminate()
            try:self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:self.process.kill();self.process.wait(timeout=2)
        if self.worker is not None:self.worker.join(timeout=2)
        if self.process is not None and self.process.stdout is not None:self.process.stdout.close()
