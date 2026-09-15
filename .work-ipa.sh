#!/bin/bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/wacko/Downloads/Cloak
Scripts/build-ipa.sh > /tmp/cloak_ipa10.log 2>&1; echo IPA_EXIT=$?; grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/cloak_ipa10.log | head -8
echo IPA_DONE
