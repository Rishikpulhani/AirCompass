#!/bin/zsh
# Builds AirCompassCompanion, signs it with your Apple Development team, and
# installs + launches it on the iPhone and iPad.
#
#   Scripts/install-ios.sh                 # both devices
#   DEVICES="<udid> <udid>" Scripts/install-ios.sh
#
# Without DEVICES, UDIDs are read from Scripts/devices.local (one per line,
# git-ignored). `xcrun devicectl list devices` shows them.
#
# Free Apple accounts: provisioning profiles expire after 7 days — rerun this
# script to refresh. First install on each device also needs
# Settings › General › VPN & Device Management › trust your developer certificate.
set -euo pipefail
cd "${0:A:h}/.."

if [[ -z "${DEVICES:-}" && -f Scripts/devices.local ]]; then
  DEVICES=$(grep -v '^#' Scripts/devices.local | tr '\n' ' ')
fi
DEVICE_LIST=${DEVICES:-}
[[ -n "${DEVICE_LIST// /}" ]] || { echo "Set DEVICES=… or list UDIDs in Scripts/devices.local" >&2; exit 1; }
DEVICES=(${=DEVICE_LIST})
BUNDLE_ID=com.rishikpulhani.AirCompassCompanion
PROJECT=AirCompassCompanion/AirCompassCompanion.xcodeproj
DERIVED=build/ios

if [[ -z "${TEAM_ID:-}" ]]; then
  TEAM_ID=$(security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject \
    | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')
fi
[[ -n "$TEAM_ID" ]] || { echo "Could not determine Team ID; set TEAM_ID=…" >&2; exit 1; }
echo "Team ID: $TEAM_ID"

# Building against each connected device registers it with the team (free
# accounts need that before the profile covers it). The last build's profile
# then includes every device.
for UDID in $DEVICES; do
  echo "→ Building for $UDID"
  xcodebuild -project "$PROJECT" -scheme AirCompassCompanion -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    build > "$DERIVED-build.log" 2>&1 || {
      grep -E "error:" "$DERIVED-build.log" | head -5
      echo "Build for $UDID failed. Is the device unlocked, and connected by cable or on the same Wi-Fi with" >&2
      echo "'Connect via network' enabled (Xcode › Window › Devices and Simulators)?" >&2
      exit 1
    }
  echo "   BUILD SUCCEEDED"
done

APP="$DERIVED/Build/Products/Debug-iphoneos/AirCompassCompanion.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep -E "Authority=Apple Development|TeamIdentifier" || true

for UDID in $DEVICES; do
  echo "→ Installing on $UDID"
  xcrun devicectl device install app --device "$UDID" "$APP"
  echo "→ Launching on $UDID"
  xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID" \
    || echo "   Launch failed — if this is the first install, trust the developer certificate on the device (Settings › General › VPN & Device Management) and rerun."
done
