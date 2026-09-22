#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
cd "$root_dir"
swift build -c release --product SaysoNotch
bin_dir=$(swift build -c release --show-bin-path)
app_dir="$root_dir/.artifacts/Sayso Notch.app"

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/SaysoNotch" "$app_dir/Contents/MacOS/SaysoNotch"
cp "$root_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

signing_identity=${SAYSO_CODESIGN_IDENTITY:--}
codesign --force --options runtime --timestamp --sign "$signing_identity" "$app_dir"

if [[ -n "${SAYSO_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$app_dir" "$root_dir/.artifacts/Sayso-Notch.zip"
  xcrun notarytool submit "$root_dir/.artifacts/Sayso-Notch.zip" --keychain-profile "$SAYSO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$app_dir"
fi

codesign --verify --deep --strict --verbose=2 "$app_dir"
spctl --assess --type execute --verbose=4 "$app_dir" 2>&1 || true
print -- "$app_dir"
