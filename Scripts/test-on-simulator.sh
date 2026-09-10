#!/bin/bash
# Runs Cloak on a simulator and checks it picks up the pairing record the
# installer puts inside the app. No phone involved.
#
# This is the whole sub iOS 27 mechanism apart from the connection itself: a
# record arrives inside the app, the app finds it, the app keeps it. If that
# works, a phone on 26 has everything it needs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OS="${1:-26.5}"
DEVICE_NAME="${2:-iPhone 17}"
BUILD="$HOME/.cloak-build/dd-sim"
APP="$BUILD/Build/Products/Debug-iphonesimulator/Cloak.app"
BUNDLE="app.cloak.ios"

cd "$ROOT"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

echo "Building for iOS $OS"
xcodebuild -project Cloak.xcodeproj -scheme CloakFree -configuration Debug \
  -destination "platform=iOS Simulator,OS=$OS,name=$DEVICE_NAME" \
  -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO build 2>&1 |
  grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -3

[ -d "$APP" ] || { echo "no app was built"; exit 1; }

echo "Putting a pairing record inside it, the way the installer does"
/usr/bin/python3 - "$APP/cloak-pairing.plist" <<'PY'
import plistlib, sys
plistlib.dump({
    "UDID": "00008130-000000000000001E",
    "HostID": "11111111-2222-3333-4444-555555555555",
    "SystemBUID": "AAAA-BBBB",
    "HostCertificate": b"cert",
    "HostPrivateKey": b"key",
    "DeviceCertificate": b"devcert",
    "WiFiMACAddress": "00:11:22:33:44:55",
}, open(sys.argv[1], "wb"))
PY

DEVICE=$(xcrun simctl list devices available |
  awk -v os="iOS $OS" '$0 ~ os {found=1; next} /^--/ {found=0} found' |
  grep -m1 -o "[0-9A-F-]\{36\}")
[ -n "$DEVICE" ] || { echo "no simulator for iOS $OS. Add one in Xcode, Settings, Components."; exit 1; }

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null 2>&1 || true
sleep 8

echo
RESULT=$(xcrun simctl spawn "$DEVICE" log show --last 60s \
  --predicate "subsystem == \"app.cloak.ios\"" --style compact 2>/dev/null |
  grep -i "pairing-handoff" | tail -1 || true)
echo "${RESULT:-nothing was logged}"

if printf '%s' "$RESULT" | grep -q "adopted the pairing record that came inside the app"; then
  echo
  echo "PASS. On iOS $OS the app found the record and kept it, which is everything"
  echo "a phone below iOS 27 needs from Cloak's side."
  exit 0
fi

echo
echo "FAIL. The record did not survive the trip. The line above says where it stopped."
exit 1
