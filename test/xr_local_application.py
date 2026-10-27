"""Host-local opt-in application selection; never accepts a remote command.

This is a bounded Linux DEV launcher, not discovery or SteamVR/OpenVR support.
The inherited environment already selects the private managed OpenXR runtime.
"""
import json
import os
import time
import secrets
import tempfile
from pathlib import Path

STEAM_ENVIRONMENT = frozenset((
    "SteamAppId", "SteamGameId", "STEAM_COMPAT_APP_ID", "STEAM_COMPAT_CLIENT_INSTALL_PATH",
    "STEAM_COMPAT_DATA_PATH", "STEAM_COMPAT_INSTALL_PATH", "STEAM_COMPAT_LIBRARY_PATHS",
    "STEAM_COMPAT_MOUNTS", "STEAM_COMPAT_TOOL_PATHS", "STEAM_COMPAT_SHADER_PATH",
    "STEAM_COMPAT_TRANSCODED_MEDIA_PATH", "STEAM_RUNTIME", "STEAM_RUNTIME_LIBRARY_PATH",
    "STEAM_LD_LIBRARY_PATH", "LD_LIBRARY_PATH", "LD_PRELOAD", "PATH", "PROTON_LOG",
    "PROTON_USE_WINED3D", "PROTON_NO_ESYNC", "PROTON_NO_FSYNC", "WINEDEBUG"))


def validate_command(argv, cwd):
    if not isinstance(argv,list) or not 1 <= len(argv) <= 64:
        raise ValueError("XR application argv must contain 1..64 strings")
    if any(not isinstance(arg,str) or "\0" in arg or len(arg)>4096 for arg in argv):
        raise ValueError("Invalid XR application argument")
    executable = Path(argv[0])
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable,os.X_OK):
        raise ValueError("XR application executable must be an absolute executable file")
    if not isinstance(cwd,str) or "\0" in cwd or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise ValueError("XR application cwd must be an existing absolute directory")


def valid_app_id(value):
    return isinstance(value,str) and value.isascii() and value.isdecimal() and 0<int(value)<2**32


def load_application(path):
    path = Path(path)
    if path.stat().st_size > 16384:
        raise ValueError("XR application configuration exceeds 16 KiB")
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or not {"argv", "cwd"} <= set(value) or set(value) - {"argv", "cwd", "launch", "openvr_compat", "steam_runtime", "steam_app_id"}:
        raise ValueError("XR application requires argv, cwd and optional launch mode")
    if value.get("launch", "immediate") not in ("immediate", "manual", "steam"):
        raise ValueError("XR application launch must be immediate, manual or steam")
    if value.get("launch") == "steam" and not valid_app_id(value.get("steam_app_id")):
        raise ValueError("Steam launch requires an explicit steam_app_id")
    if type(value.get("steam_runtime", False)) is not bool:
        raise ValueError("steam_runtime must be a boolean")
    if "openvr_compat" in value:
        validate_openvr_compat(value["openvr_compat"])
    argv, cwd = value["argv"], value["cwd"]
    validate_command(argv,cwd)
    return argv, cwd


def validate_openvr_compat(value):
    if not isinstance(value, str) or "\0" in value or not Path(value).is_absolute():
        raise ValueError("OpenVR compatibility directory must be absolute")
    directory = Path(value).resolve(strict=True)
    library = directory / "bin/linux64/vrclient.so"
    with library.open("rb") as file:
        header = file.read(20)
    if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or int.from_bytes(header[18:20],"little") != 62:
        raise ValueError("OpenVR compatibility requires an x86-64 Linux vrclient.so")
    return directory


def application_environment(path, inherited):
    """Scope compatibility to this owned child, never rewrite global runtime files."""
    load_application(path)
    spec = json.loads(Path(path).read_text())
    env = dict(inherited)
    steam_runtime = spec.get("steam_runtime",False) or spec.get("launch")=="steam"
    if steam_runtime:
        env["PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES"] = "1"
    if "openvr_compat" not in spec:
        return env
    directory = validate_openvr_compat(spec["openvr_compat"])
    env["VR_OVERRIDE"] = str(directory)
    # Keep the required OpenVR registry private to this launch. A fresh system
    # need not have SteamVR or WiVRN installed to provide a global registry.
    registry = Path(path).resolve().parent / 'openvrpaths.vrpath'
    if not registry.is_file():
        # Steam launches use a session-local copy of application.json; the
        # compatibility path intentionally retains the stable installation link.
        registry = Path(spec['openvr_compat']).parent.parent / '.build-cache/meteor-xr/openvrpaths.vrpath'
    private_registry = None
    if registry.is_file():
        registered = json.loads(registry.read_text())
        if registered.get('runtime') == [str(Path(spec['openvr_compat']))]:
            private_registry = str(registry)
            env['VR_PATHREG_OVERRIDE'] = private_registry
    if steam_runtime:
        if ":" in str(directory):
            raise ValueError("Steam compatibility paths must not contain colon separators")
        if str(directory).startswith("/usr/"):
            env["VR_OVERRIDE"] = "/run/host" + str(directory)
        else:
            # Import only this explicitly selected tool, not an entire drive.
            existing = env.get("PRESSURE_VESSEL_FILESYSTEMS_RO", "")
            env["PRESSURE_VESSEL_FILESYSTEMS_RO"] = ":".join(filter(None,[existing,str(directory)]))
        if private_registry:
            env['PRESSURE_VESSEL_FILESYSTEMS_RO'] = ':'.join(filter(None, [
                env.get('PRESSURE_VESSEL_FILESYSTEMS_RO', ''), private_registry]))
    return env


def armed_ticket(output):
    path = output / "application-ready.json"
    if path.stat().st_size > 4096:
        raise RuntimeError("Invalid armed application ticket size")
    record = json.loads(path.read_text())
    generation = record.get("generation", "")
    if (record.get("state") != "ready" or not isinstance(generation,str) or len(generation) != 32
            or any(c not in "0123456789abcdef" for c in generation)):
        raise RuntimeError("No valid armed application ticket")
    pid = record.get("pid")
    expiry = record.get("expires_at")
    if type(pid) is not int or pid <= 1 or type(expiry) not in (int,float) or not time.time() < expiry:
        raise RuntimeError("Expired or invalid armed runtime owner")
    os.kill(pid, 0)
    if (output / "application-launch.json").exists():
        raise RuntimeError("Application launch already requested")
    return record


def find_armed_session(sessions):
    found = []
    for ticket in Path(sessions).glob("*/application-ready.json"):
        try:
            armed_ticket(ticket.parent)
            found.append(ticket.parent)
        except (OSError,ValueError,RuntimeError,AttributeError):
            continue
    if len(found)>1:
        raise RuntimeError("Multiple armed sessions; specify --session explicitly")
    return found[0] if found else None


def wait_for_local_launch(output, env, *, timeout=30, cancelled=lambda: False, steam_app_id=None):
    """Armed runtime; only a generation-bound local request may launch the app."""
    generation = env.get("METEOR_XR_RUNTIME_GENERATION") or secrets.token_hex(16)
    ready, request = output / "application-ready.json", output / "application-launch.json"
    if ready.exists() or request.exists():
        raise RuntimeError("Refusing stale application launch files")
    record = {"generation": generation, "pid": os.getpid(), "state": "ready", "expires_at": time.time()+timeout}
    if env.get("METEOR_XR_LAUNCH_INTENT"):
        record["launch_intent"] = env["METEOR_XR_LAUNCH_INTENT"]
    if steam_app_id is not None:
        if not valid_app_id(steam_app_id): raise ValueError("Invalid Steam application ID")
        record["steam_app_id"] = steam_app_id
    with ready.open("x") as file:
        os.chmod(ready, 0o600)
        json.dump(record, file)
    deadline = time.monotonic() + timeout
    print(f"XR_ARMED waiting for PC-side launch: {output}", flush=True)
    try:
        while time.monotonic() < deadline:
            if cancelled() or (output / "client-disconnected").exists():
                raise RuntimeError("Application wait cancelled")
            if request.exists():
                if request.stat().st_size > 65536:
                    raise RuntimeError("Invalid local launch request")
                value = json.loads(request.read_text())
                if steam_app_id is not None:
                    validate_steam_request(value,generation,steam_app_id)
                    return value
                if value != {"generation": generation, "action": "launch"}:
                    raise RuntimeError("Stale or invalid local launch request")
                return value
            time.sleep(.025)
        raise TimeoutError("No local XR application launch within armed window")
    finally:
        ready.unlink(missing_ok=True)


def publish_launch_request(output,value):
    path = output / "application-launch.json"
    descriptor, temporary = tempfile.mkstemp(prefix="launch-", dir=output)
    try:
        with os.fdopen(descriptor, "w") as file:
            json.dump(value, file)
        if Path(temporary).stat().st_size>65536: raise ValueError("Launch request exceeds 64 KiB")
        os.link(temporary, path)
    finally:
        os.unlink(temporary)


def request_local_launch(output):
    record = armed_ticket(output)
    if "steam_app_id" in record:
        raise RuntimeError("This session requires the per-game Steam launch wrapper")
    generation = record["generation"]
    publish_launch_request(output,{"generation":generation,"action":"launch"})


def validate_steam_request(value,generation,app_id):
    if (not isinstance(value,dict) or set(value)!={"generation","action","app_id","argv","cwd","environment","owner_pid"}
            or value["generation"]!=generation or value["action"]!="steam_launch" or value["app_id"]!=app_id):
        raise ValueError("Steam launch request does not match the armed application")
    validate_command(value["argv"],value["cwd"])
    if type(value["owner_pid"]) is not int or value["owner_pid"]<=1:
        raise ValueError("Invalid Steam wrapper owner")
    env=value["environment"]
    if not isinstance(env,dict) or set(env)-STEAM_ENVIRONMENT:
        raise ValueError("Forbidden Steam environment override")
    if any(not isinstance(v,str) or "\0" in v or len(v)>16384 for v in env.values()):
        raise ValueError("Invalid Steam environment value")
    # Steam can use AppId 0 for shortcuts, while SteamGameId identifies the
    # shortcut with a 64-bit non-Steam game ID. Keep the session bound to it.
    shortcut_identity=env.get("SteamGameId")==str((int(app_id)<<32)|0x02000000)
    for name in ("SteamAppId","STEAM_COMPAT_APP_ID"):
        if name in env and env[name]!=app_id and not (env[name]=="0" and shortcut_identity):
            raise ValueError("Steam app ID mismatch")


def request_steam_launch(output,app_id,argv,cwd,inherited):
    ticket=armed_ticket(output)
    if ticket.get("steam_app_id")!=app_id: raise ValueError("Headset is not armed for this Steam game")
    value={"generation":ticket["generation"],"action":"steam_launch","app_id":app_id,
           "argv":argv,"cwd":cwd,"owner_pid":os.getpid(),"environment":{k:v for k,v in inherited.items() if k in STEAM_ENVIRONMENT}}
    validate_steam_request(value,ticket["generation"],app_id)
    publish_launch_request(output,value)
    return ticket


def validate_capture(output, service_log):
    """Validate capture ownership/drain without requiring demo-only stdout."""
    records = [json.loads(line) for line in (output / "monado-stereo.jsonl").read_text().splitlines()]
    if not records:
        raise RuntimeError("External application produced no encoded XR frames")
    offset = previous_id = previous_time = 0
    for record in records:
        if (record["offset"] != offset or record["bytes"] <= 0
                or record["frame_id"] <= previous_id or record["display_time_ns"] <= previous_time):
            raise RuntimeError("Invalid external application frame accounting")
        offset += record["bytes"]
        previous_id, previous_time = record["frame_id"], record["display_time_ns"]
    if offset != (output / "monado-stereo.h264").stat().st_size:
        raise RuntimeError("Unaccounted external application bitstream bytes")
    retained = service_log.count("METEOR_IMAGE_LEASE retain=1 ")
    if (not retained or retained != service_log.count("METEOR_IMAGE_LEASE retain=0 ")
            or "METEOR_IMAGE_LEASE_FAILED" in service_log
            or f"METEOR_ENCODER_DRAIN frames={len(records)} " not in service_log
            or service_log.count("METEOR_ENCODER_RELEASED") != 1):
        raise RuntimeError("External application image leases/encoder did not drain")
    return len(records)
