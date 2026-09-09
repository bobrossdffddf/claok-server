#!/bin/bash
# Builds the sideloadable Cloak.ipa: the free-account variant, with no network
# extension, unsigned. The installer re-signs it with the user's own Apple ID,
# so signing it here would only be thrown away.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$HOME/.cloak-build"
OUT="$ROOT/Desktop/payload"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$ROOT"

bash Scripts/build-bridge.sh
xcodegen generate

rm -rf "$BUILD/ipa"
mkdir -p "$BUILD/ipa"

# Xcode leaves behind files a copy phase used to produce, so the product from a
# previous build still carries the developer disk image even after the phase is
# gone. It is delivered by the licence server now and must not ship in the app.
rm -rf "$BUILD/dd-free/Build/Products/Release-iphoneos/Cloak.app"

xcodebuild -project Cloak.xcodeproj -scheme CloakFree -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD/dd-free" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="$BUILD/dd-free/Build/Products/Release-iphoneos/Cloak.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

mkdir -p "$BUILD/ipa/Payload"
cp -R "$APP" "$BUILD/ipa/Payload/"
rm -rf "$BUILD/ipa/Payload/Cloak.app/DeveloperImage"

mkdir -p "$OUT"
# zip adds to an archive that already exists rather than replacing it, so a
# stale ipa keeps every file a previous build put there no matter what this
# one produces.
rm -f "$OUT/Cloak.ipa"
cd "$BUILD/ipa"
zip -qry "$OUT/Cloak.ipa" Payload
echo "wrote $OUT/Cloak.ipa"
ls -lh "$OUT/Cloak.ipa"
