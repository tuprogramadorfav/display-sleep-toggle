#!/usr/bin/env bash
# Installs DisplaySleepToggle for the current user without Nix: builds it with Xcode's swiftc,
# puts the app in ~/Applications, adds a launch agent that starts it at login, and adds a
# sudoers rule that lets it run its two pmset commands without a password.
# Run it again to update. Asks for your password once, for the sudoers rule.
set -euo pipefail

cd "$(dirname "$0")"
label=io.github.tuprogramadorfav.DisplaySleepToggle
app="$HOME/Applications/DisplaySleepToggle.app"
agent="$HOME/Library/LaunchAgents/$label.plist"
sudoers=/etc/sudoers.d/display-sleep-toggle

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

echo "Building..."
bundle="$build/DisplaySleepToggle.app"
mkdir -p "$bundle/Contents/MacOS"
cp Info.plist "$bundle/Contents/"
swiftc -O main.swift -o "$bundle/Contents/MacOS/DisplaySleepToggle"
# Hardened runtime, so no other process can load its code into the app and borrow its
# Accessibility permission (see package.nix).
codesign --force --sign - --options runtime "$bundle"

echo "Adding the sudoers rule (asks for your password)..."
echo "$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a displaysleep 0, /usr/bin/pmset -a displaysleep 10" > "$build/sudoers"
visudo -cqf "$build/sudoers"
sudo install -m 0440 -o root -g wheel "$build/sudoers" "$sudoers"

echo "Installing $app..."
# Stop the running copy before replacing it.
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -rf "$app"
mkdir -p "$(dirname "$app")"
cp -R "$bundle" "$app"

echo "Starting it at login..."
mkdir -p "$(dirname "$agent")"
cat > "$agent" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/DisplaySleepToggle</string></array>
  <key>RunAtLoad</key><true/>
  <!-- Restart after a crash, but stay closed after Quit. -->
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$agent"

echo
echo "Done. Allow DisplaySleepToggle in System Settings > Privacy & Security > Accessibility"
echo "for the brightness key shortcuts. After an update, remove it there with - and add it"
echo "again with + from ~/Applications (see the README)."
