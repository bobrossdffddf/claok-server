#!/bin/bash
# Builds the sideloadable Cloak.ipa: the free-account variant, with no network
# extension, unsigned. The installer re-signs it with the user's own Apple ID,
# so signing it here would only be thrown away.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$HOME/.cloak-build"
OUT="$ROOT/Desktop/payload"

export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$ROOT"

bash Scripts/build-bridge.sh
xcodegen generate

rm -rf "$BUILD/ipa"
mkdir -p "$BUILD/ipa"

# Xcode leaves behind files a copy phase used to produce, so the product from a
# previous build still carries the developer disk image even after the phase is
# gone. It is delivered by the licence server now and must not ship in the app.
rm -rf "$BUILD/dd-free/Build/Products/Release-iphoneos/Cloak.app"

# Swift and clang record the path of every source file and object file they
# compile, and the symbol table keeps them. That put the builder's home
# directory into the shipped binaries. Map the two roots that appear to
# neutral names, and strip what is left: this app is re-signed on the way to
# the phone, so nothing here depends on the symbol table surviving.
xcodebuild -project Cloak.xcodeproj -scheme CloakFree -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD/dd-free" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  DEBUG_INFORMATION_FORMAT=dwarf \
  GCC_GENERATE_DEBUGGING_SYMBOLS=NO \
  SWIFT_DEBUG_INFORMATION_FORMAT=none \
  DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  STRIP_STYLE=debugging \
  OTHER_SWIFT_FLAGS="-debug-prefix-map $ROOT=/src -debug-prefix-map $HOME=/build" \
  OTHER_CFLAGS="-fdebug-prefix-map=$ROOT=/src -fdebug-prefix-map=$HOME=/build" \
  build

APP="$BUILD/dd-free/Build/Products/Release-iphoneos/Cloak.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

mkdir -p "$BUILD/ipa/Payload"
cp -R "$APP" "$BUILD/ipa/Payload/"
rm -rf "$BUILD/ipa/Payload/Cloak.app/DeveloperImage"

mkdir -p "$OUT"
# zip adds to an archive that already exists rather than replacing it, so a
# stale ipa keeps every file a previous build put there no matter what this
# one produces.
rm -f "$OUT/Cloak.ipa"
cd "$BUILD/ipa"
zip -qry "$OUT/Cloak.ipa" Payload
echo "wrote $OUT/Cloak.ipa"
ls -lh "$OUT/Cloak.ipa"

# This build gets handed to strangers, so prove the builder is not in it
# rather than assuming the flags above did their job.
/usr/bin/python3 - "$OUT/Cloak.ipa" "$(id -un)" "$HOME" "$ROOT" <<'CHECK'
import re, sys, zipfile

ipa, user, home, root = sys.argv[1:5]

# The licence server address belongs in the app, and its domain may contain
# the builder's name. Blank it out before looking for anything else, so the
# one string that is supposed to be there does not read as a leak.
allowed = []
try:
    source = open(root + "/Packages/CloakKit/Sources/CloakKit/Licensing/Licensing.swift").read()
    allowed = [m.group(1) for m in re.finditer(r'"(https?://[^"]+)"', source)]
except OSError:
    pass

needles = ["/Users/", home.rstrip("/"), user]
findings = []

for info in zipfile.ZipFile(ipa).infolist():
    if info.is_dir():
        continue
    data = zipfile.ZipFile(ipa).read(info)
    for url in allowed:
        data = data.replace(url.encode(), b"")
        host = url.split("//", 1)[-1].split("/", 1)[0]
        data = data.replace(host.encode(), b"")
    for needle in needles:
        hits = data.count(needle.encode())
        if hits:
            spot = data.find(needle.encode())
            window = data[max(0, spot - 90):spot + 90]
            context = "".join(chr(c) if 32 <= c < 127 else "." for c in window)
            findings.append((info.filename, needle, hits, context))

if findings:
    for name, needle, hits, context in findings:
        print('LEAK: "%s" x%d in %s' % (needle, hits, name))
        print("      %s" % context)
    print()
    print("Refusing to call this shippable. Fix the leak before distributing.")
    sys.exit(1)

print("identity check: clean")
CHECK
