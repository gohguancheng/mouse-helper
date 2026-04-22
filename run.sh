#!/bin/zsh
# Make executable: chmod +x run.sh
# swift package clean
swift build && .build/debug/MouseHelper
