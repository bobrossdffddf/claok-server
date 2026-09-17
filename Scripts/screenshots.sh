#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OS="${OS:-26.5}"
DEVICE_NAME="${DEVICE_NAME:-iPhone 17}"
BUILD="${BUILD:-$HOME/.cloak-build/dd-shots}"
APP="$BUILD/Build/Products/Debug-iphonesimulator/Cloak.app"
BUNDLE="app.cloak.ios"
OUT="${OUT:-$ROOT/.build/shots}"
LABEL="${1:-now}"

cd "$ROOT"
if [ "${REGEN:-0}" = "1" ]; then
  command -v xcodegen >/dev/null && xcodegen generate >/dev/null
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  xcodebuild -project Cloak.xcodeproj -scheme CloakFree -configuration Debug \
    -destination "${DESTINATION:-platform=iOS Simulator,OS=$OS,name=$DEVICE_NAME}" \
    -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO build 2>&1 |
    grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -5
fi
[ -d "$APP" ] || { echo "no app was built"; exit 1; }

DEVICE="${DEVICE_UDID:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun simctl list devices available |
    awk -v os="iOS $OS" '$0 ~ os {found=1; next} /^--/ {found=0} found' |
    grep "$DEVICE_NAME (" | grep -m1 -o "[0-9A-F-]\{36\}")
fi
[ -n "$DEVICE" ] || { echo "no $DEVICE_NAME on iOS $OS"; exit 1; }

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl location "$DEVICE" set 32.7767,-96.7970 2>/dev/null || true
xcrun simctl uninstall "$DEVICE" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl privacy "$DEVICE" grant location "$BUNDLE" 2>/dev/null || true

mkdir -p "$OUT/$LABEL"
SMALL="${SMALL:-}"

shoot() {
  local name="$1"; shift
  xcrun simctl terminate "$DEVICE" "$BUNDLE" 2>/dev/null || true
  env "$@" xcrun simctl launch "$DEVICE" "$BUNDLE" >/dev/null
  sleep "${WAIT:-4}"
  xcrun simctl io "$DEVICE" screenshot "$OUT/$LABEL/$name.png" >/dev/null 2>&1
  echo "shot $name"
}

ONLY="${ONLY:-all}"
wants() { [ "$ONLY" = "all" ] || [[ ",$ONLY," == *",$1,"* ]]; }

if wants onboarding; then
  for step in 0 1 2 3 4 5 6; do
    shoot "onboarding-$step" SIMCTL_CHILD_CLOAK_TOUR=onboarding SIMCTL_CHILD_CLOAK_TOUR_STEP=$step
  done
fi
wants license && shoot license SIMCTL_CHILD_CLOAK_TOUR=license
if wants map; then
  for tab in places route drive trips; do
    shoot "map-$tab" SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=$tab
  done
fi
if wants populated; then
  STOPS="32.7767,-96.7970;32.7900,-96.8000;32.8100,-96.7700"
  shoot pin-places SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=places SIMCTL_CHILD_CLOAK_TOUR_PIN=32.7800,-96.8000
  shoot stops-route SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=route SIMCTL_CHILD_CLOAK_TOUR_STOPS=$STOPS
  shoot stops-route-large SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=route SIMCTL_CHILD_CLOAK_TOUR_STOPS=$STOPS SIMCTL_CHILD_CLOAK_TOUR_DETENT=large
  shoot running-drive SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=drive SIMCTL_CHILD_CLOAK_TOUR_RUNNING=route
  shoot running-route SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=route SIMCTL_CHILD_CLOAK_TOUR_RUNNING=route
  shoot running-peek SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=drive SIMCTL_CHILD_CLOAK_TOUR_RUNNING=route SIMCTL_CHILD_CLOAK_TOUR_DETENT=peek
  shoot trips-large SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=trips SIMCTL_CHILD_CLOAK_TOUR_DETENT=large
fi
wants settings && shoot settings SIMCTL_CHILD_CLOAK_TOUR=settings
wants pair && shoot pair SIMCTL_CHILD_CLOAK_TOUR=pair
wants diagnostics && shoot diagnostics SIMCTL_CHILD_CLOAK_TOUR=diagnostics

if [ -n "$SMALL" ]; then
  mkdir -p "$SMALL"
  for f in "$OUT/$LABEL"/*.png; do /usr/bin/sips -Z 900 "$f" --out "$SMALL/$(basename "$f")" >/dev/null; done
fi
ls "$OUT/$LABEL"
