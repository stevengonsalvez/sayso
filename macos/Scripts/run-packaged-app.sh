#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
cd "$root_dir"

app_binary="$root_dir/.artifacts/Sayso Notch.app/Contents/MacOS/SaysoNotch"
if [[ ! -x "$app_binary" ]]; then
  echo "Error: $app_binary not found or not executable. Run ./Scripts/package-app.sh first." >&2
  exit 1
fi

"$app_binary" --automation-server 2>&1 | tee "$root_dir/dev-sayso-app.log"
