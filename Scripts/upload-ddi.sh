#!/bin/bash
# Copies the developer disk image to the licence server. It is no longer
# shipped inside the app, so the server needs it before anybody can finish
# setting Cloak up.
set -euo pipefail

HOST="${1:-}"
[ -n "$HOST" ] || { echo "usage: ./upload-ddi.sh user@host [remote-dir]"; exit 1; }
DIR="${2:-/opt/cloak/data/ddi}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/ServerPayload/DeveloperImage"

for name in Image.dmg Image.dmg.trustcache BuildManifest.plist; do
  [ -f "$SRC/$name" ] || { echo "missing $SRC/$name"; exit 1; }
done

ssh "$HOST" "sudo mkdir -p '$DIR' && sudo chown -R \$(id -u):\$(id -g) '$DIR'"
scp "$SRC"/Image.dmg "$SRC"/Image.dmg.trustcache "$SRC"/BuildManifest.plist "$HOST:$DIR/"
ssh "$HOST" "ls -lh '$DIR'"
echo "done"
