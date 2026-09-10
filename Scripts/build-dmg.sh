#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=version.sh
. "$ROOT/Scripts/version.sh"

APP="$ROOT/dist/Cloak Installer.app"
STAGE="$ROOT/.build/dmg"
OUT="$ROOT/dist/CloakInstaller-macos.dmg"

[ -d "$APP" ] || { echo "build the app first: Scripts/build-installer.sh"; exit 1; }

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Desktop/README.md" "$STAGE/Read me first.txt"

# The file name stays put so a download link never has to change. The volume
# name carries the version, so it is obvious which one is mounted.
hdiutil create -volname "Cloak Installer $CLOAK_VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "wrote $OUT  (version $CLOAK_VERSION, build $CLOAK_BUILD)"
ls -lh "$OUT"

BUNDLED="$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
if [ "$BUNDLED" != "$CLOAK_VERSION" ]; then
  echo
  echo "warning: the app inside says $BUNDLED, not $CLOAK_VERSION."
  echo "Run Scripts/build-installer.sh again so the two agree."
fi
