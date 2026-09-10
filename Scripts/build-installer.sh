#!/bin/bash
# Wraps the installer binary in a Mac app bundle with Cloak.ipa inside it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$ROOT/Desktop"

# shellcheck source=version.sh
. "$ROOT/Scripts/version.sh"
STAGE="$HOME/.cloak-build/installer"
APP="$STAGE/Cloak Installer.app"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/.build/cargo}"

# Without this the absolute path of every dependency's source, and therefore
# the username of whoever built it, is baked into the panic messages in the
# binary. A public build should not carry that.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/build --remap-path-prefix=$ROOT=/src"

# Cargo keeps its own copy of the version and it is what the binary reports at
# startup, so bring it into line rather than letting the two drift.
if ! grep -q "^version = \"$CLOAK_VERSION.0\"$" "$DESKTOP/Cargo.toml"; then
  /usr/bin/sed -i '' "s/^version = \".*\"$/version = \"$CLOAK_VERSION.0\"/" "$DESKTOP/Cargo.toml"
  echo "set Desktop/Cargo.toml version to $CLOAK_VERSION.0"
fi

cd "$DESKTOP"
cargo build --release

rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$CARGO_TARGET_DIR/release/cloak-installer" "$APP/Contents/MacOS/CloakInstaller"

if [ -f "$DESKTOP/payload/Cloak.ipa" ]; then
  cp "$DESKTOP/payload/Cloak.ipa" "$APP/Contents/Resources/Cloak.ipa"
else
  echo "warning: no Cloak.ipa in Desktop/payload, run Scripts/build-ipa.sh first"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Cloak Installer</string>
    <key>CFBundleDisplayName</key>
    <string>Cloak Installer</string>
    <key>CFBundleIdentifier</key>
    <string>app.cloak.installer</string>
    <key>CFBundleExecutable</key>
    <string>CloakInstaller</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$CLOAK_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$CLOAK_BUILD</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [ -f "$DESKTOP/icon.png" ]; then
  ICONSET="$STAGE/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z $size $size "$DESKTOP/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) "$DESKTOP/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# Ad-hoc signing is enough for a tool the user runs themselves, and it stops
# macOS refusing to launch an unsigned arm64 binary outright.
codesign --force --deep --sign - "$APP"

mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/Cloak Installer.app"
cp -R "$APP" "$ROOT/dist/"
echo "wrote $ROOT/dist/Cloak Installer.app"
