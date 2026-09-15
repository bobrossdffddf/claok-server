#!/bin/bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/wacko/Downloads/Cloak
DEV=6E52F421-5A86-4EC3-842C-6F3155CDF79F
LIC=Packages/CloakKit/Sources/CloakKit/Licensing/Licensing.swift
cp "$LIC" /tmp/Licensing.swift.bak
bash Scripts/configure.sh >/dev/null 2>&1
xcodegen generate >/dev/null 2>&1
echo "=== build ==="; xcodebuild -project Cloak.xcodeproj -scheme CloakFree -configuration Debug -destination "id=$DEV" -derivedDataPath /tmp/cloak-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -10
cp /tmp/Licensing.swift.bak "$LIC"
APP=$(find /tmp/cloak-dd/Build/Products -name "Cloak.app" -path "*iphonesimulator*" | head -1)
xcrun simctl boot "$DEV" 2>/dev/null; sleep 3
xcrun simctl location "$DEV" set 37.7749,-122.4194 2>/dev/null
xcrun simctl uninstall "$DEV" app.cloak.ios 2>/dev/null; xcrun simctl install "$DEV" "$APP" && echo installed; xcrun simctl privacy "$DEV" grant location-always app.cloak.ios >/dev/null 2>&1
rm -rf /tmp/cloak-shots; mkdir -p /tmp/cloak-shots
shot(){ # name tour step
  xcrun simctl terminate "$DEV" app.cloak.ios 2>/dev/null; sleep 1
  SIMCTL_CHILD_CLOAK_TOUR="$2" SIMCTL_CHILD_CLOAK_TOUR_STEP="$3" xcrun simctl launch "$DEV" app.cloak.ios >/dev/null 2>&1; sleep 5
  xcrun simctl io "$DEV" screenshot "/tmp/cloak-shots/$1.png" >/dev/null 2>&1 && echo "shot $1"
}
shot 10-license license 0
for i in 0 1 2 3 4 5 6; do shot "2$i-onboarding-$i" onboarding $i; done
shot 30-map map 0
for t in route drive trips; do xcrun simctl terminate "$DEV" app.cloak.ios 2>/dev/null; sleep 1; SIMCTL_CHILD_CLOAK_TOUR=map SIMCTL_CHILD_CLOAK_TOUR_TAB=$t xcrun simctl launch "$DEV" app.cloak.ios >/dev/null 2>&1; sleep 5; xcrun simctl io "$DEV" screenshot "/tmp/cloak-shots/3$t-map-$t.png" >/dev/null 2>&1 && echo "shot map-$t"; done
shot 40-settings settings 0
shot 50-pair pair 0
shot 60-diagnostics diagnostics 0
mkdir -p ~/Downloads/Cloak/.shots; for f in /tmp/cloak-shots/*.png; do sips -Z 800 "$f" --out ~/Downloads/Cloak/.shots/$(basename "$f") >/dev/null 2>&1; done
ls ~/Downloads/Cloak/.shots
echo TOUR_DONE
