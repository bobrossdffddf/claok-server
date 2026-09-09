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
. "$ENV_FILE"
[ -n "${CLOAK_ADMIN_TOKEN:-}" ] || { echo "CLOAK_ADMIN_TOKEN is empty in $ENV_FILE"; exit 1; }

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
