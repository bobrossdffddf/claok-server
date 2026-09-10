#!/bin/bash
# The one place the version number is written down.
#
# The installer, the app bundle and the iOS build all used to carry their own
# copy of it, which is how a release ends up with three different answers.
# Everything that stamps a version sources this instead. Edit VERSION at the
# repository root and nothing else.

CLOAK_VERSION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLOAK_VERSION="$(tr -d ' \t\r\n' < "$CLOAK_VERSION_ROOT/VERSION" 2>/dev/null || true)"

if [ -z "$CLOAK_VERSION" ]; then
  echo "No version in $CLOAK_VERSION_ROOT/VERSION. Put one there, for example: 1.2"
  exit 1
fi

case "$CLOAK_VERSION" in
  *[!0-9.]*|.*|*.) echo "VERSION should be digits and dots, like 1.2. It says: $CLOAK_VERSION"; exit 1 ;;
esac

# iOS and the update check compare build numbers as plain integers, so the
# version has to collapse into one number that only ever goes up. 1.2 becomes
# 10200, 1.2.1 becomes 10201, 2.0 becomes 20000.
IFS=. read -r CLOAK_MAJOR CLOAK_MINOR CLOAK_PATCH <<< "$CLOAK_VERSION"
CLOAK_BUILD=$(( 10#${CLOAK_MAJOR:-0} * 10000 + 10#${CLOAK_MINOR:-0} * 100 + 10#${CLOAK_PATCH:-0} ))

export CLOAK_VERSION CLOAK_BUILD
