#!/bin/zsh
# Builds AirCompass.app into ./build and signs it with the hardened runtime.
#
#   Scripts/bundle.sh                    # release build, auto-detected signing identity
#   SIGN_IDENTITY="Apple Development: …" Scripts/bundle.sh
#   CONFIG=debug Scripts/bundle.sh
#
# macOS ties privacy grants (Accessibility, Automation, Microphone) to the code
# signature. Signing with a stable "Apple Development" identity keeps them
# across rebuilds; the ad-hoc fallback ("-") changes every build.
set -euo pipefail
cd "${0:A:h}/.."

CONFIG=${CONFIG:-release}
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
APP=build/AirCompass.app

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AirCompass"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirCompass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --options runtime --timestamp=none \
  --entitlements Resources/AirCompass.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP (signed with: $SIGN_IDENTITY)"
