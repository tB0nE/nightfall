#!/usr/bin/env python3
"""Linux DEV launcher for the current checkout's explicitly armed XR session."""
import argparse
import json
from pathlib import Path
import sys
import time
import os
import shlex
import contextlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "test"))
from xr_local_application import armed_ticket, find_armed_session, request_local_launch, validate_openvr_compat, request_steam_launch, valid_app_id
from xr_launch_intent import publish_intent, desktop_mode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action",required=True)
    for action in ("status", "launch"):
        command = sub.add_parser(action)
        command.add_argument("--session", type=Path, help="Explicit session directory; otherwise discover the sole live armed session")
        if action == "launch":
            command.add_argument("--wait", type=float, default=0, help="Wait up to 120 seconds for the headset to arm")
    compatibility = sub.add_parser("compat-check")
    compatibility.add_argument("directory",type=Path)
    options = sub.add_parser("steam-options",help="Print per-game launch options; never modifies Steam")
    options.add_argument("--app-id",required=True)
    steam = sub.add_parser("steam-run",help="Receive Steam's actual command and wait for its game result")
    steam.add_argument("--app-id",required=True)
    steam.add_argument("--session",type=Path)
    steam.add_argument("--wait",type=float,default=120)
    steam.add_argument("command",nargs=argparse.REMAINDER)
    args = parser.parse_args()
    try:
        if args.action in ("steam-run","steam-options") and not valid_app_id(args.app_id):
            raise ValueError("Invalid Steam application ID")
        if args.action == "steam-options":
            print(shlex.join([sys.executable,str(Path(__file__).resolve()),"steam-run","--app-id",args.app_id,"--wait","120","--"])+" %command%")
            return 0
        if args.action == "compat-check":
            directory = validate_openvr_compat(str(args.directory))
            print(f"Found x86-64 OpenVR compatibility library: {directory / 'bin/linux64/vrclient.so'}")
            print("File-layout/ELF check only; loading, dependencies and game compatibility are not verified.")
            return 0
        wait = getattr(args,"wait",0)
        if not 0 <= wait <= 120:
            raise ValueError("--wait must be between 0 and 120 seconds")
        command=(args.command[1:] if args.command[:1]==["--"] else args.command) if args.action=="steam-run" else []
        if args.action=="steam-run" and desktop_mode(command):
            from xr_local_application import validate_command
            validate_command(command,str(Path.cwd()))
            os.execvpe(command[0],command,os.environ)
        session = args.session or find_armed_session(ROOT / ".build-cache/meteor-xr/lan-sessions")
        automatic=args.action=="steam-run" and session is None and args.session is None and wait>0
        intent=publish_intent(ROOT,args.app_id,wait) if automatic else contextlib.nullcontext(None)
        with intent as generation:
            deadline = time.monotonic()+wait
            while session is None:
                candidate=find_armed_session(ROOT / ".build-cache/meteor-xr/lan-sessions")
                if candidate is not None and (generation is None or armed_ticket(candidate).get("launch_intent")==generation):
                    session=candidate
                    break
                if time.monotonic() >= deadline:
                    print("XR launch timed out waiting for the connected headset.")
                    return 1
                time.sleep(.1)
            if args.action=="steam-run":
                ticket=request_steam_launch(session,args.app_id,command,str(Path.cwd()),os.environ)
        if args.action!="steam-run": ticket = armed_ticket(session)
        if args.action == "status":
            print(json.dumps({"state":"armed","session":str(session),"seconds_remaining":max(0,round(ticket["expires_at"]-time.time(),1))},indent=2))
        elif args.action == "launch":
            request_local_launch(session)
            print("Requested the host-configured XR application. Handover still waits for its session and video.")
        else:
            print("Steam command handed to the owned XR runtime; waiting for game exit.",flush=True)
            while True:
                outcome=session/"steam-outcome.json"
                if outcome.exists():
                    value=json.loads(outcome.read_text())
                    if value.get("generation")!=ticket["generation"] or value.get("app_id")!=args.app_id:
                        raise RuntimeError("Mismatched Steam game outcome")
                    code=value.get("returncode")
                    if type(code) is not int: raise RuntimeError("Invalid Steam exit code")
                    return 130 if value.get("interrupted") else (code if 0<=code<=255 else 1)
                os.kill(ticket["pid"],0)
                state=session/"runtime-state.json"
                if state.exists() and json.loads(state.read_text()).get("state")=="stopped":
                    raise RuntimeError("XR runtime stopped before game outcome")
                time.sleep(.1)
        return 0
    except (OSError,ValueError,RuntimeError,AttributeError) as error:
        print(f"XR launcher: {error}",file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
