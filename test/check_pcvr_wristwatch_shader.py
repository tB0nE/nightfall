"""Compile the actual embedded GLES watch/video shader without a headset."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "extensions/nightfall-xr/src/pcvr_projection_test.cpp").read_text()
shader = re.search(r'const char \*METEOR_FRAGMENT = R"GLSL\((.*?)\)GLSL";', source, re.S).group(1)
command = sys.argv[1:] or ["glslangValidator", "--stdin", "-S", "frag"]
subprocess.run(command, input=shader, text=True, check=True)
print("PASS: embedded Meteor wristwatch GLES fragment shader compiled")
