#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="${HAMMERSPOON_DIR:-"$HOME/.hammerspoon"}"
init_file="$target_dir/init.lua"
timestamp="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$target_dir"

cp "$repo_dir/hammerspoon/fn_music_pause.lua" "$target_dir"/
cp "$repo_dir/hammerspoon/fn_music_pause_core.lua" "$target_dir"/
cp "$repo_dir/hammerspoon/fn_music_pause_player.lua" "$target_dir"/

if [[ -f "$init_file" ]]; then
  if ! grep -Fq 'require("fn_music_pause")' "$init_file"; then
    cp "$init_file" "$init_file.fn-music-pause-backup-$timestamp"
    {
      printf '\n'
      printf 'require("fn_music_pause")\n'
    } >> "$init_file"
  fi
else
  cat > "$init_file" <<'EOF'
hs.ipc.cliInstall()

require("fn_music_pause")
EOF
fi

cat <<EOF
Installed fn-music-pause into:
  $target_dir

Next steps:
  1. Open or reload Hammerspoon.
  2. Grant Hammerspoon Accessibility permission in macOS System Settings.
  3. Start music, hold Fn, and release Fn to verify pause/resume.
EOF
