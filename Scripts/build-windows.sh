#!/bin/bash
# Cross-builds the Windows installer from a Mac and zips it with Cloak.ipa.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$ROOT/Desktop"

# shellcheck source=version.sh
. "$ROOT/Scripts/version.sh"

TARGET="${CLOAK_WINDOWS_TARGET:-x86_64-pc-windows-gnu}"
STAGE="$ROOT/.build/windows/CloakInstaller"
OUT="$ROOT/dist/CloakInstaller-windows.zip"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/.build/cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/build --remap-path-prefix=$ROOT=/src"

if ! rustup target list --installed | grep -q "^$TARGET$"; then
  rustup target add "$TARGET"
fi
if [ "$TARGET" = "x86_64-pc-windows-gnu" ] && ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
  echo "mingw-w64 is missing: brew install mingw-w64"; exit 1
fi

if ! grep -q "^version = \"$CLOAK_CARGO_VERSION\"$" "$DESKTOP/Cargo.toml"; then
  /usr/bin/sed -i '' "s/^version = \".*\"$/version = \"$CLOAK_CARGO_VERSION\"/" "$DESKTOP/Cargo.toml"
fi

cd "$DESKTOP"
cargo build --release --target "$TARGET"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE" "$ROOT/dist"
cp "$CARGO_TARGET_DIR/$TARGET/release/cloak-installer.exe" "$STAGE/CloakInstaller.exe"
if [ -f "$DESKTOP/payload/Cloak.ipa" ]; then
  cp "$DESKTOP/payload/Cloak.ipa" "$STAGE/Cloak.ipa"
else
  echo "warning: no Cloak.ipa in Desktop/payload, run Scripts/build-ipa.sh first"
fi
cp "$DESKTOP/README.md" "$STAGE/Read me first.txt"

(cd "$ROOT/.build/windows" && zip -qr "$OUT" CloakInstaller)
echo "wrote $OUT  (version $CLOAK_VERSION, build $CLOAK_BUILD)"
ls -lh "$OUT"
