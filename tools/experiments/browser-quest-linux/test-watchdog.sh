#!/system/bin/sh
# Test-only shell watchdog. It survives host/USB loss; no production app timeout.
set -eu
root=${NIGHTFALL_WATCHDOG_ROOT:-/data/local/tmp}
lease="$root/nightfall-browser-test.lease"
mode=${1:-}
seconds=${2:-}
token=${3:-}
case "$token" in ''|*[!a-f0-9]*) exit 2 ;; esac
[ "${#token}" -eq 32 ] || exit 2
case "$mode" in
  wait)
    case "$seconds" in ''|*[!0-9]*) exit 2 ;; esac
    [ "$seconds" -ge 1 ] && [ "$seconds" -le 150 ] || exit 2
    sleep "$seconds"
    ;;
  cleanup) ;;
  *) exit 2 ;;
esac
[ -f "$lease" ] || exit 0
[ "$(cat "$lease")" = "$token" ] || exit 0
# Fixed packages only. force-stop retains all data and accounts.
am force-stop app.nightfall.browserlab || true
am force-stop app.nightfall.quest || true
am broadcast -a com.oculus.vrpowermanager.automation_disable || true
setprop debug.oculus.guardian_pause '' || true
if [ -f "$lease" ] && [ "$(cat "$lease")" = "$token" ]; then rm -f "$lease"; fi
