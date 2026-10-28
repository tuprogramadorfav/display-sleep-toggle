#!/usr/bin/env bash
# Removes everything install.sh added. Asks for your password once, for the sudoers rule.
set -euo pipefail

label=io.github.tuprogramadorfav.DisplaySleepToggle

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/DisplaySleepToggle.app"
sudo rm -f /etc/sudoers.d/display-sleep-toggle

echo "Done. Display sleep stays at its last setting; change it in System Settings > Lock Screen."
echo "Remove DisplaySleepToggle from System Settings > Privacy & Security > Accessibility too."
