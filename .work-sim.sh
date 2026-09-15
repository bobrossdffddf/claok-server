#!/bin/bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/wacko/Downloads/Cloak
echo "=== swift test ==="; (cd Packages/CloakKit && swift test 2>&1 | grep -E "✘|Test run" | head -10)
echo "=== simulators ==="; xcrun simctl list devices available | grep -E "iPhone" | head -5
DEV=$(xcrun simctl list devices available | grep -E "iPhone 1[6-9]|iPhone 17|iPhone 16" | head -1 | sed -E 's/.*\(([A-F0-9-]{36})\).*/\1/')
echo "DEV=$DEV"
xcodegen generate >/dev/null 2>&1
echo "=== build sim ==="; xcodebuild -project Cloak.xcodeproj -scheme CloakFree -configuration Debug -destination "id=$DEV" -derivedDataPath /tmp/cloak-dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | head -8
APP=$(find /tmp/cloak-dd/Build/Products -name "Cloak.app" -path "*iphonesimulator*" | head -1); echo "APP=$APP"
xcrun simctl boot "$DEV" 2>/dev/null; sleep 5
xcrun simctl install "$DEV" "$APP" && echo installed
BID=$(defaults read "$APP/Info.plist" CFBundleIdentifier); echo "BID=$BID"
xcrun simctl launch "$DEV" "$BID" && sleep 6
mkdir -p /tmp/cloak-shots; xcrun simctl io "$DEV" screenshot /tmp/cloak-shots/01-first.png && echo shot1
echo SIM_DONE
