#!/bin/bash
# Answers "will this work on iOS N" for every N, with no phone attached.
#
# The version-dependent behaviour is one function taking a version number, so
# every version can be asked here rather than found out from somebody's phone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/Scripts/version.sh"

echo "Cloak $CLOAK_VERSION"
echo

cd "$ROOT/Packages/CloakKit"
swift test --filter PairingPlanTests 2>&1 | sed -n '/iOS support matrix/,/^-\{10,\}$/p'

echo
cd "$ROOT/Packages/CloakKit"
if swift test --filter PairingPlanTests >/dev/null 2>&1; then
  echo "All versions have a working route."
else
  echo "FAILED. A version has no route, or a route is offered where it cannot work."
  exit 1
fi

echo
echo "What cannot be answered here:"
echo "  Whether iOS accepts the lockdown pairing request itself. That needs a phone."
echo "  A record from the installer does not depend on it, which is why that is the"
echo "  route every install takes."
echo
echo "To run the app itself without a phone:"
xcrun simctl list runtimes 2>/dev/null | grep -i "^iOS" | sed 's/^/  /' || true
echo "  Add older ones with: Xcode, Settings, Components."
