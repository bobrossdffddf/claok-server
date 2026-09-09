#!/bin/bash
# Pulls the two typefaces the installer draws with. Both are freely licensed
# and neither is redrawn by hand: Inter (SIL Open Font License) for text, and
# Phosphor Icons (MIT) for the glyphs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Desktop/assets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT"

echo "Phosphor Icons"
curl -sL -o "$OUT/Phosphor.ttf" \
  "https://raw.githubusercontent.com/phosphor-icons/web/master/src/regular/Phosphor.ttf"
curl -sL -o "$OUT/Phosphor-Fill.ttf" \
  "https://raw.githubusercontent.com/phosphor-icons/web/master/src/fill/Phosphor-Fill.ttf"

echo "Inter"
curl -sL -o "$TMP/inter.zip" \
  "https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
unzip -o -q "$TMP/inter.zip" -d "$TMP/inter"
for face in Inter-Regular Inter-Medium Inter-SemiBold InterDisplay-SemiBold; do
  cp "$TMP/inter/extras/ttf/$face.ttf" "$OUT/$face.ttf"
done

cat > "$OUT/LICENSES.txt" <<'TXT'
Inter, by Rasmus Andersson. SIL Open Font License 1.1.
https://github.com/rsms/inter

Phosphor Icons, by Phosphor Icons. MIT.
https://github.com/phosphor-icons/web
TXT

ls -lh "$OUT"
