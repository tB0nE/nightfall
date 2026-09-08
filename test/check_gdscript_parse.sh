#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NIGHTFALL_TEST_DATA_ROOT="${NIGHTFALL_TEST_DATA_ROOT:-${TMPDIR:-/tmp}/nightfall-gdscript-tests}"

if [[ -n "${NIGHTFALL_GODOT_EDITOR:-}" ]]; then
  GODOT="$NIGHTFALL_GODOT_EDITOR"
elif command -v godot >/dev/null 2>&1; then
  GODOT="$(command -v godot)"
else
  GODOT="/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64"
fi

if [[ ! -x "$GODOT" ]]; then
  echo "Godot executable not found: $GODOT" >&2
  echo "Set NIGHTFALL_GODOT_EDITOR to a Godot 4.7 executable." >&2
  exit 1
fi

mkdir -p "$NIGHTFALL_TEST_DATA_ROOT/parse-user-data"
output_file="$NIGHTFALL_TEST_DATA_ROOT/project-parse.out"

echo "Scanning and parsing the Godot project"
if ! XDG_DATA_HOME="$NIGHTFALL_TEST_DATA_ROOT/parse-user-data" "$GODOT" \
  --headless \
  --editor \
  --quit \
  --xr-mode off \
  --log-file "$NIGHTFALL_TEST_DATA_ROOT/parse.log" \
  --path "$PROJECT_ROOT" >"$output_file" 2>&1; then
  cat "$output_file" >&2
  echo "Godot project scan exited unsuccessfully" >&2
  exit 1
fi
if rg -q "SCRIPT ERROR:|Parse Error:" "$output_file"; then
  cat "$output_file" >&2
  echo "The Godot project scan reported a script failure" >&2
  exit 1
fi

echo "Godot project scripts parsed successfully"
