#!/bin/bash
set -euo pipefail
launcher_dir="$(cd "$(dirname "$0")/.." && pwd)"
preview_app="$launcher_dir/build/Sakura.app"
if [[ ! -x "$preview_app/Contents/MacOS/GardenBoot" ]]; then
  bash "$launcher_dir/scripts/build.sh"
fi
preview_root="$HOME/Library/Caches/GardenBoot/settings-preview"
open -n "$preview_app" --args --test-root "$preview_root" --test-target local.gardenboot.settings-preview --settings
