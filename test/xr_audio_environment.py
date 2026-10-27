"""Keep desktop audio reachable when Monado owns a private XDG runtime dir."""
from pathlib import Path


def host_audio_environment(host):
    result={key:host[key] for key in ("PULSE_SERVER","PULSE_RUNTIME_PATH","PIPEWIRE_RUNTIME_DIR") if host.get(key)}
    runtime=host.get("XDG_RUNTIME_DIR")
    if not runtime or not Path(runtime).is_absolute(): return result
    pulse=Path(host.get("PULSE_RUNTIME_PATH",str(Path(runtime)/"pulse")))/"native"
    if "PULSE_SERVER" not in result and pulse.is_socket():
        result["PULSE_SERVER"]="unix:"+str(pulse)
    # libpipewire otherwise looks in the private Monado XDG_RUNTIME_DIR too.
    if "PIPEWIRE_RUNTIME_DIR" not in result and (Path(runtime)/"pipewire-0").is_socket():
        result["PIPEWIRE_RUNTIME_DIR"]=runtime
    return result
