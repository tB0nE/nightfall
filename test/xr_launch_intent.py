"""Private, host-local pre-launch intent. Never contains game argv or secrets."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import secrets
import tempfile
import time
from xr_local_application import valid_app_id


def process_birth(pid):
    return int((Path("/proc")/str(pid)/"stat").read_text().rsplit(") ",1)[1].split()[19])


def alive(value):
    try:
        return value["expires_at"]>time.time() and process_birth(value["pid"])==value["start_ticks"]
    except (OSError,ValueError,KeyError,TypeError):
        return False


@contextlib.contextmanager
def publish_intent(root, app_id, timeout):
    cache=Path(root)/".build-cache/meteor-xr"
    spec=json.loads((cache/"application.json").read_text())
    if not valid_app_id(app_id) or spec.get("launch")!="steam" or spec.get("steam_app_id") not in (app_id,"*"):
        raise ValueError("Automatic XR launch requires the host-configured Steam application")
    directory=cache/"auto-launch"
    directory.mkdir(mode=0o700,parents=True,exist_ok=True)
    if directory.is_symlink() or directory.stat().st_uid!=os.getuid() or directory.stat().st_mode&0o077:
        raise ValueError("Automatic XR intent directory must be private and owned by this user")
    path=directory/"intent.json"
    value={"generation":secrets.token_hex(16),"app_id":app_id,"pid":os.getpid(),
           "start_ticks":process_birth(os.getpid()),"expires_at":time.time()+min(timeout,120),"state":"pending"}
    with (directory/".lock").open("a") as lock:
        os.chmod(directory/".lock",0o600)
        fcntl.flock(lock,fcntl.LOCK_EX)
        if path.exists():
            try: old=json.loads(path.read_text())
            except (OSError,ValueError): old={}
            if alive(old): raise RuntimeError("Another XR launch is already pending")
            path.unlink()
        descriptor, temporary=tempfile.mkstemp(prefix="intent-",dir=directory)
        try:
            with os.fdopen(descriptor,"w") as file: json.dump(value,file)
            os.link(temporary,path)
        finally: os.unlink(temporary)
    try:
        yield value["generation"]
    finally:
        try:
            if json.loads(path.read_text()).get("generation")==value["generation"]: path.unlink()
        except (OSError,ValueError): pass


def desktop_mode(command):
    return any(arg.lower() in ("--no-vr","--novr","-novr") for arg in command)
