#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/.build/cargo}"
cd "$ROOT"

TEAM_ARGS=()
if [ -f "$ROOT/Scripts/team.env" ]; then
  . "$ROOT/Scripts/team.env"
  TEAM_ARGS=(DEVELOPMENT_TEAM="$CLOAK_TEAM_ID")
fi

bash Scripts/build-bridge.sh
xcodegen generate
xcodebuild -project Cloak.xcodeproj -scheme "${1:-CloakFree}" -configuration Debug \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates \
  -derivedDataPath "$ROOT/.build/dd" "${TEAM_ARGS[@]}" build
