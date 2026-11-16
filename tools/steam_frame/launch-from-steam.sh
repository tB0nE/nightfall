#!/bin/sh
# Start Nightfall from Steam on a Steam Frame (or any SteamOS headset).
#
# Put this script next to the `nightfall` binary and add the script to Steam
# as a non-Steam game. Without it, Steam treats Nightfall's 2D desktop window
# as a flat game (any window from a game's launch process tree counts): it
# mirrors the window as a "desktopgame" overlay and opens its Now Playing
# panel over the VR view a couple of seconds after launch.
#
# Nightfall therefore runs as its own systemd user unit, outside Steam's
# launch tree. The Steam ids are passed on, so SteamVR keeps using the app's
# per-application settings (refresh rate, render size). This script waits for
# Nightfall, so Steam shows the game as running, and stops it when the script
# goes away (Steam stopping the game).
#
# Optional environment (e.g. Steam launch options `VAR=value %command%`):
#   NIGHTFALL_DIR        folder with the nightfall binary (default: this script's)
#   NIGHTFALL_LOG        log file (default: $NIGHTFALL_DIR/nightfall.log)
#   NF_MULTIPATH_REMOTE  passed on when set (see docs/plans/active/multipath.md)

DIR="${NIGHTFALL_DIR:-$(cd "$(dirname "$0")" && pwd)}"
LOG="${NIGHTFALL_LOG:-$DIR/nightfall.log}"
UNIT="nightfall-steam"
LAUNCHER=$$

[ -x "$DIR/nightfall" ] || { echo "No nightfall binary in $DIR" >&2; exit 1; }
[ -f "$LOG" ] && mv "$LOG" "$LOG.prev"

set -- -E DISPLAY="${DISPLAY:-:1}" -E XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
for var in SteamAppId SteamGameId SteamOverlayGameId NF_MULTIPATH_REMOTE; do
    eval "value=\${$var:-}"
    [ -n "$value" ] && set -- "$@" -E "$var=$value"
done

systemctl --user stop "$UNIT" 2>/dev/null
systemctl --user reset-failed "$UNIT" 2>/dev/null
trap 'systemctl --user stop "$UNIT" 2>/dev/null' INT TERM HUP EXIT
systemd-run --user --unit="$UNIT" --collect --wait --quiet -p WorkingDirectory="$DIR" "$@" \
    sh -c "./nightfall > \"$LOG\" 2>&1 & N=\$!
           while kill -0 \$N 2>/dev/null; do
               kill -0 $LAUNCHER 2>/dev/null || kill \$N
               sleep 1
           done
           wait \$N"
