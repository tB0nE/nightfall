#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

mapfile -d '' scripts < <(git ls-files --cached --others --exclude-standard -z -- '*.sh')
for script in "${scripts[@]}"; do
  echo "Checking $script"
  bash -n "$script"
done

echo "All tracked shell scripts passed bash syntax checks"
