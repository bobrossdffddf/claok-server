#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Cloak Installer.app"
STAGE="$ROOT/.build/dmg"
OUT="$ROOT/dist/CloakInstaller-macos.dmg"

[ -d "$APP" ] || { echo "build the app first: Scripts/build-installer.sh"; exit 1; }

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "$ROOT/Desktop/README.md" "$STAGE/Read me first.txt"

hdiutil create -volname "Cloak Installer" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGE"
echo "wrote $OUT"
ls -lh "$OUT"
