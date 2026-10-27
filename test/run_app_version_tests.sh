#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../tools/build_support/app_version.sh"
[[ "$(nightfall_version_code 0.8.1)" == 801 ]]
[[ "$(nightfall_version_code 0.8.2-preview.1)" == 802 ]]
[[ "$(nightfall_version_code 0.8.2)" == 802 ]]
[[ "$(nightfall_version_code 1.0.0-rc.2)" == 10000 ]]
for invalid in 0.8.2- 0.8.2-preview..1 0.100.0 0.8.100 abc; do
  if nightfall_version_code "$invalid" >/dev/null 2>&1; then
    echo "Invalid version accepted: $invalid" >&2
    exit 1
  fi
done
NIGHTFALL_VERSION=0.8.2-preview.1
nightfall_resolve_version release .
[[ "$NIGHTFALL_VERSION_NAME" == 0.8.2-preview.1 && "$NIGHTFALL_VERSION_CODE" == 802 ]]
echo "App version tests passed"
