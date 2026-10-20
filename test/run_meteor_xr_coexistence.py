"""Process-level DEV proxy/XR coexistence smoke test; no headset or GPU needed.

Uses test-only fixed seeds, isolated XDG directories and a mock HTTP upstream.
This is not full GameStream video or runtime rendering coverage.
"""
import argparse
from contextlib import ExitStack
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request


class Upstream(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload = b"nightfall-proxy-fixture"
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass


def fetch(port, path):
    request = urllib.request.Request(f"http://127.0.0.1:{port}{path}")
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=1) as response:
        return response.read()


def reserve(stack, kind, port=0):
    peer = stack.enter_context(socket.socket(socket.AF_INET, kind))
    peer.bind(("127.0.0.1", port))
    return peer


def client_public_key():
    # PKCS#8 X25519 test seed, not a user's identity or secret.
    encoded = bytes.fromhex("302e020100300506032b656e04220420") + bytes([2]) * 32
    result = subprocess.run(["openssl", "pkey", "-inform", "DER", "-pubout", "-outform", "DER"],
                            input=encoded, capture_output=True, check=True)
    if len(result.stdout) != 44:
        raise RuntimeError("Unexpected OpenSSL X25519 public key encoding")
    return result.stdout[-32:].hex()


def run_case(binary, client, mode, stop_signal):
    # Reserve a compatible complete proxy layout before releasing it to Meteor.
    for _attempt in range(50):
        upstream = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
        base = upstream.server_port
        reservations = ExitStack()
        try:
            if not 10 < base < 64000:
                raise OSError("Out-of-range fixture port")
            for offset in (-5, 0, 21):
                reserve(reservations, socket.SOCK_STREAM, base + 1000 + offset)
            for offset in (9, 10, 11, 13):
                reserve(reservations, socket.SOCK_DGRAM, base + 1000 + offset)
            discovery = reserve(reservations, socket.SOCK_STREAM)
            discovery_port = discovery.getsockname()[1]
            xr = reserve(reservations, socket.SOCK_STREAM)
            xr_port = xr.getsockname()[1]
            break
        except OSError:
            reservations.close()
            upstream.server_close()
    else:
        raise RuntimeError("Unable to reserve isolated proxy fixture ports")
    thread = threading.Thread(target=upstream.serve_forever, daemon=True)
    thread.start()
    try:
        with reservations, tempfile.TemporaryDirectory(prefix="nf-coexist-") as directory:
            root = Path(directory)
            env = dict(os.environ)
            env.pop("APPIMAGE", None)
            for kind in ("CONFIG", "DATA", "CACHE", "STATE"):
                env[f"XDG_{kind}_HOME"] = str(root / kind.lower())
            config = root / "config/nightfall-meteor"
            config.mkdir(parents=True)
            (config / "meteor.toml").write_text(
                f'sunshine_host="127.0.0.1"\nsunshine_port={base}\nport_offset=1000\ndiscovery_port={discovery_port}\n')
            data = root / "data/nightfall-meteor"
            data.mkdir(parents=True)
            key = data / "meteor.key"
            key.write_bytes(bytes([1]) * 32)
            key.chmod(0o600)
            command = [str(binary), "--no-tray", "--no-depth", "--no-mic"]
            if mode != "disabled":
                command += ["--xr-service-dev", f"127.0.0.1:{xr_port}",
                            "--xr-client-key", client_public_key()]
            # In the bind-failure case only the XR socket remains occupied.
            if mode == "bind_failure":
                xr.listen()
                occupied = xr.dup()
            else:
                occupied = None
            # All proxy/discovery reservations transfer to the child now; only
            # the deliberate XR bind-conflict duplicate stays open.
            reservations.close()
            with (root / "process.log").open("w") as log:
                child = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 10
                    while True:
                        try:
                            info = json.loads(fetch(discovery_port, "/meteor"))
                            break
                        except (OSError, ValueError):
                            if child.poll() is not None or time.monotonic() >= deadline:
                                raise RuntimeError((root / "process.log").read_text())
                            time.sleep(.05)
                    assert "xr" not in info, "DEV XR must not advertise production capability"
                    assert fetch(base + 1000, "/fixture") == b"nightfall-proxy-fixture"
                    if mode == "enabled":
                        # Native OpenSSL client authenticates, offers, accepts,
                        # and stops against the NORMAL Meteor process.
                        subprocess.run([str(client), str(xr_port)], check=True, timeout=10)
                    assert fetch(base + 1000, "/fixture-after-xr") == b"nightfall-proxy-fixture"
                    if mode == "bind_failure":
                        assert "DEV XR service disabled:" in (root / "process.log").read_text()
                    child.send_signal(stop_signal)
                    assert child.wait(timeout=30) == 0
                    assert "Shutting down" in (root / "process.log").read_text()
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait(timeout=5)
                    if occupied is not None:
                        occupied.close()
            print(f"PASS normal Meteor: XR={mode}, proxy forwarding, clean {stop_signal.name} shutdown")
    finally:
        upstream.shutdown()
        upstream.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("control_client", type=Path)
    args = parser.parse_args()
    for mode, stop_signal in [("enabled", signal.SIGTERM), ("bind_failure", signal.SIGINT), ("disabled", signal.SIGTERM)]:
        run_case(args.binary.resolve(), args.control_client.resolve(), mode, stop_signal)
