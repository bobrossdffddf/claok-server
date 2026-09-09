#!/bin/bash
# Points the app at your licence server.
#
# Asks the server for its public key and writes both settings into
# Licensing.swift, so nobody has to copy base64 out of a log by hand.
#
#   Scripts/configure.sh https://cloak.yourdomain.com
#
# Run it with no arguments to switch licensing back off for development.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/Packages/CloakKit/Sources/CloakKit/Licensing/Licensing.swift"
URL="${1:-}"

[ -f "$FILE" ] || { echo "Cannot find $FILE"; exit 1; }

if [ -z "$URL" ]; then
  echo "Switching licensing off. The app will run unlocked."
  KEY=""
  URL="https://cloak.example.com"
else
  URL="${URL%/}"
  echo "Asking $URL for its public key"
  KEY="$(curl -fsS --max-time 15 "$URL/v1/pubkey" | python3 -c 'import json,sys; print(json.load(sys.stdin)["public_key"])')" || {
    echo
    echo "Could not reach $URL/v1/pubkey."
    echo "Check the server is up and the address is right, then try again."
    exit 1
  }
  echo "Got it: ${KEY:0:16}..."
fi

python3 - "$FILE" "$URL" "$KEY" <<'PY'
import re, sys
path, url, key = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()

text = re.sub(
    r'return URL\(string: "[^"]*"\)!',
    f'return URL(string: "{url}")!',
    text, count=1)

text = re.sub(
    r'public static let serverPublicKey = "[^"]*"',
    f'public static let serverPublicKey = "{key}"',
    text, count=1)

open(path, "w").write(text)
PY

echo
echo "Licensing.swift updated:"
grep -E 'return URL\(string:|serverPublicKey =' "$FILE" | sed 's/^ */  /'
echo
echo "Now rebuild:  Scripts/build-ipa.sh && Scripts/build-installer.sh && Scripts/build-dmg.sh"
