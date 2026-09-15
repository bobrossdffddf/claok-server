#!/bin/bash
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd /Users/wacko/Downloads/Cloak
Scripts/build-windows.sh 2>&1 | grep -vE "^\s+(Compiling|Downloaded|Downloading)" | tail -60
echo WIN_DONE
