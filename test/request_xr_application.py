"""Local DEV launch trigger; no executable or arguments accepted from the client."""
from pathlib import Path
import sys
from xr_local_application import request_local_launch

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: request_xr_application.py SESSION_DIRECTORY")
    request_local_launch(Path(sys.argv[1]).resolve())
    print("Requested configured XR application launch")
