#!/bin/zsh

set -euo pipefail

echo "Stopping SportWork processes..."
pkill -f 'SportWork' 2>/dev/null || true
sleep 1

echo "Removing installed app..."
rm -rf /Applications/SportWork.app

echo "Removing local build artifacts..."
rm -rf "$(cd "$(dirname "$0")/.." && pwd)/build/SportWork.app"
rm -f "$(cd "$(dirname "$0")/.." && pwd)/build/SportWork.dmg"
rm -rf "$(cd "$(dirname "$0")/.." && pwd)/build/dmg-root"

echo "Removing saved app state..."
rm -rf "$HOME/Library/Application Support/SportWork"

echo "Removing launch-at-login registration..."
rm -f "$HOME/Library/LaunchAgents/com.lucas.sportwork.launcher.plist"
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.lucas.sportwork.launcher.plist" 2>/dev/null || true

echo
echo "Cleanup complete."
