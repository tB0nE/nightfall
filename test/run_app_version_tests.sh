#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../tools/build_support/app_version.sh"
[[ "$(nightfall_version_code 0.8.1)" == 80100 ]]
[[ "$(nightfall_version_code 0.8.2-preview.1)" == 80200 ]]
[[ "$(nightfall_version_code 0.8.2)" == 80200 ]]
[[ "$(nightfall_version_code 0.9.1 3)" == 90103 ]]
[[ "$(nightfall_version_code 1.0.0-rc.2)" == 1000000 ]]
# Every new code must be above the old scheme's last one (0.9.1 -> 901).
(( $(nightfall_version_code 0.9.1) > 901 ))
for invalid in 0.8.2- 0.8.2-preview..1 0.100.0 0.8.100 abc; do
  if nightfall_version_code "$invalid" >/dev/null 2>&1; then
    echo "Invalid version accepted: $invalid" >&2
    exit 1
  fi
done
for invalid_build in 100 -1 x; do
  if nightfall_version_code 0.9.1 "$invalid_build" >/dev/null 2>&1; then
    echo "Invalid build number accepted: $invalid_build" >&2
    exit 1
  fi
done
NIGHTFALL_VERSION=0.8.2-preview.1
nightfall_resolve_version release .
[[ "$NIGHTFALL_VERSION_NAME" == 0.8.2-preview.1 && "$NIGHTFALL_VERSION_CODE" == 80200 ]]
NIGHTFALL_BUILD_NUMBER=2
nightfall_resolve_version release .
[[ "$NIGHTFALL_VERSION_CODE" == 80202 ]]
nightfall_resolve_version dev .
[[ "$NIGHTFALL_VERSION_CODE" == "$(nightfall_version_code "${NIGHTFALL_VERSION_NAME%%-dev+*}")" ]]
NIGHTFALL_DEV_BUILD_NUMBER=5
nightfall_resolve_version dev .
[[ "$NIGHTFALL_VERSION_CODE" == "$(nightfall_version_code "${NIGHTFALL_VERSION_NAME%%-dev+*}" 5)" ]]
echo "App version tests passed"
