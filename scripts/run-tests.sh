#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hs_bin="${HS_BIN:-}"

if [[ -z "$hs_bin" ]]; then
  if command -v hs >/dev/null 2>&1; then
    hs_bin="$(command -v hs)"
  elif [[ -x /opt/homebrew/bin/hs ]]; then
    hs_bin="/opt/homebrew/bin/hs"
  else
    echo "error: Hammerspoon hs CLI not found. Install Hammerspoon and run hs.ipc.cliInstall()." >&2
    exit 1
  fi
fi

for test_file in "$repo_dir"/hammerspoon/*_test.lua; do
  lua_test_file="${test_file//\\/\\\\}"
  lua_test_file="${lua_test_file//\"/\\\"}"

  "$hs_bin" -c "return dofile(\"$lua_test_file\")"
done
