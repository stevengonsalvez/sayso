#!/bin/zsh
set -euo pipefail

root_dir=${0:A:h:h}
cd "$root_dir"
swift build -c release --product SaysoNotch
bin_dir=$(swift build -c release --show-bin-path)
app_dir="$root_dir/.artifacts/Sayso Notch.app"
iconset_root=$(mktemp -d)
iconset_dir="$iconset_root/AppIcon.iconset"
mkdir "$iconset_dir"
trap 'rm -rf "$iconset_root"' EXIT

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/SaysoNotch" "$app_dir/Contents/MacOS/SaysoNotch"
cp "$root_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$root_dir/../docs/logo.svg" > "$iconset_dir/icon_${size}x${size}.png"
  double_size=$((size * 2))
  rsvg-convert -w "$double_size" -h "$double_size" "$root_dir/../docs/logo.svg" > "$iconset_dir/icon_${size}x${size}@2x.png"
done
iconutil --convert icns "$iconset_dir" --output "$app_dir/Contents/Resources/AppIcon.icns"

if [[ -n "${SAYSO_CODESIGN_IDENTITY:-}" ]]; then
  signing_identity="$SAYSO_CODESIGN_IDENTITY"
elif [[ -n "${CI:-}" ]]; then
  signing_identity="-"
else
  signing_identity=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)
  signing_identity=${signing_identity:--}
fi
codesign --force --options runtime --timestamp --entitlements "$root_dir/Resources/SaysoNotch.entitlements" --sign "$signing_identity" "$app_dir"

if [[ -n "${SAYSO_NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$app_dir" "$root_dir/.artifacts/Sayso-Notch.zip"
  xcrun notarytool submit "$root_dir/.artifacts/Sayso-Notch.zip" --keychain-profile "$SAYSO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$app_dir"
fi

codesign --verify --deep --strict --verbose=2 "$app_dir"
spctl --assess --type execute --verbose=4 "$app_dir" 2>&1 || true
print -- "$app_dir"
