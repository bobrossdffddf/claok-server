#!/usr/bin/env bash
# Builds the portable Linux / ChromeOS installer: a single self-contained
# binary that needs no admin rights. It is a terminal program, so it works
# inside a Chromebook's Linux container with no GUI, and usbmuxd is bundled
# when a Linux copy is present so a Chromebook without one still works.
#
# The only supported, no-surprises way to build it is ON Linux: run this from a
# Linux machine, or from the Chromebook's own Crostini container. Cross-building
# from macOS is possible but only if a real Linux C toolchain is installed,
# because the installer links C libraries (aws-lc-sys, ring): a bare
# `cargo build --target ...-linux-...` on a stock Mac fails at the linker with a
# confusing error. This script refuses to pretend otherwise: it detects the
# case, uses a cross toolchain when one is present, and otherwise stops with
# instructions instead of writing a half-built or macOS binary into dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$ROOT/Desktop"
. "$ROOT/Scripts/version.sh"

HOST_OS="$(uname -s)"     # Linux, Darwin, ...
HOST_ARCH="$(uname -m)"   # x86_64, aarch64/arm64, ...

# The Linux triple to produce. Defaults to the host architecture; override with
# CLOAK_LINUX_TARGET to build the other one (e.g. an x86_64 build on an ARM Mac).
case "$HOST_ARCH" in
  x86_64|amd64)   DEFAULT_TARGET="x86_64-unknown-linux-gnu" ;;
  aarch64|arm64)  DEFAULT_TARGET="aarch64-unknown-linux-gnu" ;;
  *) DEFAULT_TARGET="x86_64-unknown-linux-gnu" ;;
esac
TARGET="${CLOAK_LINUX_TARGET:-$DEFAULT_TARGET}"
TARGET_ARCH="${TARGET%%-*}"   # x86_64 or aarch64, for the artifact name

STAGE="$ROOT/.build/linux/CloakInstaller"
OUT="$ROOT/dist/CloakInstaller-linux-$TARGET_ARCH.tar.gz"

export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/.build/cargo}"
# Keep absolute build paths out of the shipped binary.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$HOME=/build --remap-path-prefix=$ROOT=/src"

BUILT="$CARGO_TARGET_DIR/$TARGET/release/cloak-installer"
# Whether the host can also run a Linux usbmuxd we might bundle. Only a native
# Linux build produces a usbmuxd that matches the binary we just built; a macOS
# usbmuxd is a Mach-O and would be useless (and misleading) inside a Linux tar.
BUNDLE_USBMUXD=0

# No GUI: the CLI feature only, so there is no dependency on X11, Wayland or GL,
# which a Chromebook's container does not have.
CARGO_ARGS=(build --release --target "$TARGET" --no-default-features --features cli)

if [ "$HOST_OS" = "Linux" ]; then
  # The supported path: a native Linux build. rustup target add is a no-op when
  # the target is the host's own, and harmless otherwise.
  command -v rustup >/dev/null && rustup target add "$TARGET" >/dev/null 2>&1 || true
  echo "Building natively on Linux for $TARGET ..."
  ( cd "$DESKTOP" && cargo "${CARGO_ARGS[@]}" )
  # A same-arch native build is the common case; bundle the host usbmuxd then.
  case "$HOST_ARCH:$TARGET_ARCH" in
    x86_64:x86_64|amd64:x86_64|aarch64:aarch64|arm64:aarch64) BUNDLE_USBMUXD=1 ;;
    *) BUNDLE_USBMUXD=0 ;;
  esac
elif command -v cargo-zigbuild >/dev/null 2>&1 && command -v zig >/dev/null 2>&1; then
  # Cross-build from a non-Linux host using Zig as the cross C compiler and
  # linker. This actually links the C dependencies, unlike a bare cargo build.
  command -v rustup >/dev/null && rustup target add "$TARGET" >/dev/null 2>&1 || true
  echo "Cross-compiling from $HOST_OS with cargo-zigbuild for $TARGET ..."
  ( cd "$DESKTOP" && cargo zigbuild --release --target "$TARGET" --no-default-features --features cli )
elif command -v cross >/dev/null 2>&1 && { command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1; }; then
  # Cross-build inside a Linux container. The whole toolchain lives in the
  # image, so the host needs only cross + a container runtime.
  echo "Cross-compiling from $HOST_OS with cross (container) for $TARGET ..."
  ( cd "$DESKTOP" && cross "${CARGO_ARGS[@]}" )
else
  cat >&2 <<MSG
Cannot build the Linux installer on this host ($HOST_OS/$HOST_ARCH).

This machine is not Linux, and no Linux cross toolchain was found, so there is
no honest way to produce a working Linux binary here. The installer links C
libraries, so a plain "cargo build --target $TARGET" would fail at the linker.

Pick one:

  1. Build it on Linux (simplest, and what a Chromebook already has).
     Copy the repo to a Linux machine or the Chromebook's Linux (Crostini)
     container and run:

         bash Scripts/build-linux.sh

  2. Cross-compile from this Mac with Zig:

         brew install zig
         cargo install cargo-zigbuild
         rustup target add $TARGET
         bash Scripts/build-linux.sh

  3. Cross-compile from this Mac inside a container:

         brew install colima docker      # or Docker Desktop
         colima start
         cargo install cross
         bash Scripts/build-linux.sh

Nothing was written to dist/.
MSG
  exit 1
fi

# Do not claim success unless the binary is really there and is a Linux ELF.
if [ ! -f "$BUILT" ]; then
  echo "Build finished but $BUILT is missing. Not writing an artifact." >&2
  exit 1
fi
if command -v file >/dev/null 2>&1; then
  if ! file "$BUILT" | grep -qi 'ELF'; then
    echo "error: $BUILT is not a Linux ELF binary:" >&2
    file "$BUILT" >&2
    echo "Refusing to package a non-Linux binary as a Linux release." >&2
    exit 1
  fi
fi

rm -rf "$STAGE"; mkdir -p "$STAGE" "$ROOT/dist"
cp "$BUILT" "$STAGE/cloak-installer"
chmod +x "$STAGE/cloak-installer"

if [ -f "$DESKTOP/payload/Cloak.ipa" ]; then
  cp "$DESKTOP/payload/Cloak.ipa" "$STAGE/Cloak.ipa"
else
  echo "warning: no Cloak.ipa in Desktop/payload, run Scripts/build-ipa.sh first"
fi

# Bundle a usbmuxd only on a native Linux build, where the host copy is a Linux
# ELF that matches what we just built. Static is best; a dynamic one may still
# work, and if it does not the installer falls back to one on PATH. Never copy a
# macOS usbmuxd into a Linux bundle.
if [ "$BUNDLE_USBMUXD" = "1" ] && command -v usbmuxd >/dev/null 2>&1; then
  if command -v file >/dev/null 2>&1 && ! file "$(command -v usbmuxd)" | grep -qi 'ELF'; then
    echo "note: host usbmuxd is not a Linux ELF, not bundling it"
  else
    cp "$(command -v usbmuxd)" "$STAGE/usbmuxd" && echo "bundled usbmuxd from $(command -v usbmuxd)" || true
  fi
fi

cat > "$STAGE/install.sh" <<'INNER'
#!/usr/bin/env bash
# No root needed. Plug the iPhone into THIS machine (on a Chromebook, share it
# with Linux under Settings > Developers > Linux > Manage USB devices), unlock
# it, then run: ./cloak-installer --cli
cd "$(dirname "$0")"
exec ./cloak-installer --cli "$@"
INNER
chmod +x "$STAGE/install.sh"

cat > "$STAGE/Read me first.txt" <<INNER
Cloak Installer for Linux and ChromeOS
======================================

No administrator rights are needed.

1. Plug your iPhone into this computer with a cable and unlock it.
   On a Chromebook: open Settings > Developers > Linux development
   environment > Manage USB devices, and turn on your iPhone there, then
   run this quickly (ChromeOS lets go of the device after a moment).
2. In a terminal, run:  ./install.sh
   (or:  ./cloak-installer --cli )
3. Follow the prompts. Sign in with your Apple ID (a free one is fine).

If it cannot see the iPhone, install usbmuxd inside the Linux container
(for example: sudo apt install usbmuxd) and run it again. usbmuxd needs
no root once the phone is plugged into your own session; Cloak runs its
own copy on a socket in your \$XDG_RUNTIME_DIR.

Cloak then re-signs itself every seven days from the phone, so you do not
need this computer again.
INNER

rm -f "$OUT"
(cd "$ROOT/.build/linux" && tar -czf "$OUT" CloakInstaller)
echo "wrote $OUT  (version $CLOAK_VERSION, build $CLOAK_BUILD, target $TARGET)"
ls -lh "$OUT"
