#!/usr/bin/env bash
# Runs a second, isolated Meteor that runs its own bundled host, next to the
# Meteor and host you already use. For development and for testing the
# two-hosts-on-one-PC case.
#
# Everything Meteor writes (settings, host.toml, key, log, the host's own
# config) goes under METEOR_INSTANCE_DIR (default
# ~/.local/share/nightfall-meteor-dev2). Models and the TensorRT runtime
# are shared with the normal Meteor. The bundled host takes the first free
# base port: 49989 while another stack holds 47989, so this Meteor answers
# on 49900 and proxies on 50984-51010.
#
#   meteor/tools/run_second_meteor.sh <vibepollo binary> [meteor args]
#
# The settings file is written on the first run only. METEOR_NCNN_LIB sets
# ncnn_lib, and METEOR_HOST_LIBS adds LD_LIBRARY_PATH for the host, e.g.
#   METEOR_HOST_LIBS=~/.local/lib/vibepollo-libs \
#     run_second_meteor.sh ~/Development/Personal/Vibepollo/build-cuda/vibepollo-2.0.0
set -euo pipefail

host_binary="${1:?usage: run_second_meteor.sh <vibepollo binary> [meteor args]}"
shift
root="${METEOR_INSTANCE_DIR:-$HOME/.local/share/nightfall-meteor-dev2}"
meteor="${METEOR_BINARY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/target/release/nightfall-meteor}"
shared="$HOME/.local/share/nightfall-meteor"

[[ -x "$meteor" ]] || { echo "No Meteor build at $meteor (cargo build --release --no-default-features)" >&2; exit 1; }
[[ -x "$host_binary" ]] || { echo "Not an executable: $host_binary" >&2; exit 1; }

export XDG_CONFIG_HOME="$root/config"
export XDG_STATE_HOME="$root/state"
export XDG_DATA_HOME="$root/data"
config="$XDG_CONFIG_HOME/nightfall-meteor"
mkdir -p "$config"

if [[ ! -f "$config/meteor.toml" ]]; then
	tensorrt="$(find "$shared/runtime" -maxdepth 1 -type d -name 'tensorrt-*' 2>/dev/null | sort | tail -n1)"
	{
		echo "# Second Meteor instance (meteor/tools/run_second_meteor.sh)."
		echo "host_binary = \"$(readlink -f "$host_binary")\""
		echo "models_dir = \"$shared/models\""
		[[ -n "$tensorrt" ]] && echo "tensorrt_dir = \"$tensorrt\""
		[[ -n "${METEOR_NCNN_LIB:-}" ]] && echo "ncnn_lib = \"$METEOR_NCNN_LIB\""
		# A development host build linked against libraries outside the system's.
		[[ -n "${METEOR_HOST_LIBS:-}" ]] && printf '\n[host_env]\nLD_LIBRARY_PATH = "%s"\n' "$METEOR_HOST_LIBS"
	} >"$config/meteor.toml"
fi
if [[ ! -f "$config/host.toml" ]]; then
	echo 'choice = "bundled"' >"$config/host.toml"
	chmod 600 "$config/host.toml"
fi

echo "Second Meteor: settings in $config, log in $XDG_STATE_HOME/nightfall-meteor/meteor.log"
exec "$meteor" "$@"
