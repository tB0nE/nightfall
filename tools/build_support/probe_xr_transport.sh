#!/usr/bin/env bash
# Loopback-only diagnostic transport; no product server/discovery registration.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
OUT="$ROOT/.build-cache/meteor-xr/transport-spike"
mkdir -p "$OUT"
cc -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror \
    "$ROOT/test/monado_direct_transport_test.c" -o "$OUT/direct-transport-tests"
timeout 10s "$OUT/direct-transport-tests"
rustc --edition=2024 --test "$ROOT/meteor/src/xr_wire.rs" -o "$OUT/wire-tests"
"$OUT/wire-tests"
rustc --edition=2024 -O "$ROOT/meteor/tools/xr_transport_receiver.rs" -o "$OUT/receiver"
NIGHTFALL_XR_TRANSPORT_RECEIVER="$OUT/receiver" bash "$TOOL_DIR/probe_monado_nvenc.sh"
