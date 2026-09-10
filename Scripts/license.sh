#!/bin/bash
# Day to day licence admin, so you never have to write a curl by hand.
#
# First run creates Scripts/server.env for you to fill in. That file is
# ignored by git and holds your server address and admin token.
#
#   Scripts/license.sh new 5              five new licences
#   Scripts/license.sh list               who has what
#   Scripts/license.sh revoke CLOAK-...   kill one and free its phone
#   Scripts/license.sh release 14 1.2 https://.../CloakInstaller-macos.dmg "What changed"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="$ROOT/Scripts/server.env"

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<'EOF'
CLOAK_URL=https://cloak.yourdomain.com
CLOAK_ADMIN_TOKEN=
EOF
  chmod 600 "$ENV_FILE"
  echo "Made $ENV_FILE. Put your server address and admin token in it, then run this again."
  exit 1
fi

# shellcheck source=/dev/null
# Tolerant reader: ignores spaces around =, surrounding quotes, and Windows line endings.
read_env() {
  key="$1"
  v=$(tr -d '\r' < "$ENV_FILE" | sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" | sed "s/[[:space:]]*$//" | tail -n 1)
  case "$v" in
    \"*\") v=${v#\"}; v=${v%\"} ;;
  esac
  printf '%s' "$v"
}

CLOAK_URL="$(read_env CLOAK_URL)"
CLOAK_ADMIN_TOKEN="$(read_env CLOAK_ADMIN_TOKEN)"

if [ -z "$CLOAK_ADMIN_TOKEN" ]; then
  echo "No admin token found in $ENV_FILE"
  echo
  echo "That file currently holds:"
  sed "s/\r$/<CR>/" "$ENV_FILE" | sed "s/^/    /"
  echo
  echo "It needs a line shaped exactly like this, with no spaces around the = sign:"
  echo "    CLOAK_ADMIN_TOKEN=your-token-here"
  echo
  echo "Your admin token is the CLOAK_ADMIN_TOKEN value in Server/.env on the machine"
  echo "running the server. Open $ENV_FILE, paste it in, save, and run this again."
  exit 1
fi

if [ -z "$CLOAK_URL" ] || case "$CLOAK_URL" in *yourdomain.com*) true;; *) false;; esac; then
  echo "CLOAK_URL in $ENV_FILE is still the placeholder. Set it to your real address,"
  echo "for example: CLOAK_URL=https://claokkey.wackoxyz.org"
  exit 1
fi

URL="${CLOAK_URL%/}"
AUTH=(-H "x-admin-token: $CLOAK_ADMIN_TOKEN" -H 'content-type: application/json')

pretty() {
  if command -v jq >/dev/null 2>&1; then jq; else python3 -m json.tool; fi
}

case "${1:-}" in
  new)
    COUNT="${2:-1}"
    curl -fsS -X POST "$URL/v1/admin/licenses" "${AUTH[@]}" \
      -d "{\"count\":$COUNT,\"note\":\"${3:-}\"}" | pretty
    ;;

  list)
    curl -fsS "$URL/v1/admin/licenses" "${AUTH[@]}" | pretty
    ;;

  revoke)
    KEY="${2:?usage: license.sh revoke CLOAK-...}"
    curl -fsS -X POST "$URL/v1/admin/revoke" "${AUTH[@]}" \
      -d "{\"license\":\"$KEY\",\"revoked\":true,\"release_device\":true}" | pretty
    ;;

  free)
    KEY="${2:?usage: license.sh free CLOAK-...}"
    curl -fsS -X POST "$URL/v1/admin/revoke" "${AUTH[@]}" \
      -d "{\"license\":\"$KEY\",\"revoked\":false,\"release_device\":true}" | pretty
    echo "Freed. That licence can be activated on a new phone now."
    ;;

  release)
    BUILD="${2:?usage: license.sh release <build> <version> <url> [notes]}"
    VERSION="${3:?}"
    LINK="${4:?}"
    NOTES="${5:-}"
    curl -fsS -X POST "$URL/v1/admin/release" "${AUTH[@]}" \
      -d "{\"platform\":\"ios\",\"build\":$BUILD,\"version\":\"$VERSION\",\"url\":\"$LINK\",\"notes\":\"$NOTES\"}" | pretty
    echo "Every phone below build $BUILD will see the banner."
    ;;

  health)
    curl -fsS "$URL/v1/health" | pretty
    ;;

  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
