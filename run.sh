#!/bin/zsh
# Make executable: chmod +x run.sh
#
# Dev mode: build debug and run directly
#   ./run.sh
#
# App mode: build .app bundle and open it
#   ./run.sh app

if [[ "${1:-}" == "app" ]]; then
    ./build-app.sh
    echo "🚀 Launching MouseHelper.app..."
    open build/MouseHelper.app
else
    swift package clean
    swift build && .build/debug/MouseHelper
fi
