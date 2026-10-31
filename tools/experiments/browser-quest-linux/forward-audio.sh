#!/bin/bash
set -euo pipefail
export XDG_RUNTIME_DIR=/home/browser/.cache/nightfall-runtime
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
exec /usr/bin/parec --raw --device=nightfall_lab.monitor \
  --format=s16le --rate=48000 --channels=2 --latency-msec=40
