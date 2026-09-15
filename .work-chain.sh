#!/bin/bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/wacko/Downloads/Cloak
echo "=== swift test ==="; (cd Packages/CloakKit && swift test 2>&1 | grep -E "✘|Test run|error:" | head -12)
echo "=== ipa ==="; Scripts/build-ipa.sh > /tmp/cloak_ipa9.log 2>&1; echo IPA_EXIT=$?; grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/cloak_ipa9.log | head -6
echo "=== installer ==="; CARGO_TARGET_DIR=.build/cargo Scripts/build-installer.sh > /tmp/cloak_build17.log 2>&1; echo INST_EXIT=$?; grep -E "^error|warning: unused|Finished|dmg" /tmp/cloak_build17.log | tail -5
echo CHAIN_DONE
