#!/usr/bin/env bash
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck not found. Install it with: sudo apt-get install -y shellcheck" >&2
  exit 1
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
installer_path="$script_dir/../installer.sh"

shellcheck "$installer_path"
