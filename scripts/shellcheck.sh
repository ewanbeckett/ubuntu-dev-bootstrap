#!/usr/bin/env bash
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found. Install it with: sudo apt-get install -y shellcheck" >&2
  exit 1
fi

shellcheck installer.sh
