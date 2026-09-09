#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/Bridge/cloak-bridge"
OUT="$ROOT/Frameworks"

if [ -f "$HOME/.cargo/env" ]; then
  source "$HOME/.cargo/env"
fi

if ! command -v rustup >/dev/null 2>&1; then
  echo "rustup is not installed."
  echo
  echo "Homebrew's rust formula ships cargo without rustup, and rustup is what adds"
  echo "the iOS cross-compile targets. Install it with:"
  echo
  echo "  brew uninstall rust"
  echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
  echo "  source \"\$HOME/.cargo/env\""
  echo
  exit 1
fi

if command -v brew >/dev/null 2>&1 && brew list --formula 2>/dev/null | grep -qx rust; then
  echo "Homebrew's rust formula is installed alongside rustup."
  echo "Its cargo will shadow rustup's and the iOS targets will not be found."
  echo "Run: brew uninstall rust"
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild not found. Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

if [ ! -f "$CRATE/Cargo.toml" ]; then
  echo "Cannot find the bridge crate at $CRATE"
  exit 1
fi

# The connected folder does not allow deletes, so build and assemble in scratch
# space and copy the finished xcframework over the top.
SCRATCH="${CLOAK_SCRATCH:-$HOME/.cloak-build}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$SCRATCH/cargo}"
mkdir -p "$SCRATCH"

HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" = "arm64" ]; then
  SIM_TARGET="aarch64-apple-ios-sim"
else
  SIM_TARGET="x86_64-apple-ios"
fi

echo "Adding targets"
rustup target add aarch64-apple-ios "$SIM_TARGET"

echo "Building device slice"
cargo build --release --lib --manifest-path "$CRATE/Cargo.toml" --target aarch64-apple-ios

echo "Building simulator slice"
cargo build --release --lib --manifest-path "$CRATE/Cargo.toml" --target "$SIM_TARGET"

DEVICE_LIB="$CARGO_TARGET_DIR/aarch64-apple-ios/release/libcloak_bridge.a"
SIM_LIB="$CARGO_TARGET_DIR/$SIM_TARGET/release/libcloak_bridge.a"

for LIB in "$DEVICE_LIB" "$SIM_LIB"; do
  if [ ! -f "$LIB" ]; then
    echo "Expected static library missing: $LIB"
    exit 1
  fi
done

STAGE="$SCRATCH/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT"

xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$CRATE/include" \
  -library "$SIM_LIB" -headers "$CRATE/include" \
  -output "$STAGE/CloakBridge.xcframework"

mkdir -p "$OUT/CloakBridge.xcframework"
cp -R "$STAGE/CloakBridge.xcframework/." "$OUT/CloakBridge.xcframework/"

echo
echo "Built $OUT/CloakBridge.xcframework"
echo "Next: xcodegen generate && open Cloak.xcodeproj"
