#!/bin/bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/wacko/Downloads/Cloak
echo "=== bridge ==="; Scripts/build-bridge.sh > /tmp/cloak_bridge.log 2>&1; echo BRIDGE_EXIT=$?; grep -E "^error|error\[|xcframework|Finished" /tmp/cloak_bridge.log | tail -6
./.work-chain.sh
