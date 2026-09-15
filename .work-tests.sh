#!/bin/bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/wacko/Downloads/Cloak
echo "=== swift test CloakKit ==="; (cd Packages/CloakKit && swift test 2>&1 | tail -25); echo "SWIFT_EXIT=${PIPESTATUS[0]}"
echo "=== cargo test installer + isideload ==="; (cd Desktop && CARGO_TARGET_DIR=.build/cargo cargo test --release 2>&1 | grep -E "^test result|FAILED|panicked|error(\[|:)" | head -30)
echo "=== cargo test bridge (host) ==="; (cd Bridge/cloak-bridge && cargo test --release 2>&1 | grep -E "^test result|FAILED|panicked|error(\[|:)" | head -20)
echo "=== cargo check bridge ios ==="; (cd Bridge/cloak-bridge && cargo check --release --target aarch64-apple-ios 2>&1 | tail -2)
echo ALL_DONE
