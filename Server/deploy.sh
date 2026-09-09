#!/bin/bash
# Builds the server and copies it to a host over ssh.
set -euo pipefail

HOST="${1:-}"
[ -n "$HOST" ] || { echo "usage: ./deploy.sh user@host"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

cargo build --release
ssh "$HOST" 'sudo mkdir -p /var/lib/cloak /etc/cloak && sudo systemctl stop cloak-server || true'
scp target/release/cloak-server "$HOST:/tmp/cloak-server"
ssh "$HOST" 'sudo mv /tmp/cloak-server /usr/local/bin/cloak-server && sudo chmod 755 /usr/local/bin/cloak-server && sudo systemctl start cloak-server || true'
echo "done"
