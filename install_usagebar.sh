#!/bin/bash
set -x
DST="$HOME/Library/Application Support/UsageBar"
APP="/Applications/UsageBar.app"
PL="$HOME/Library/LaunchAgents/com.sudipta.usagebar.plist"
launchctl unload "$PL" 2>/dev/null
killall UsageBar 2>/dev/null
sleep 1
mkdir -p "$APP/Contents/MacOS"
cp "$DST/UsageBar" "$APP/Contents/MacOS/UsageBar"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.sudipta.usagebar</string>
<key>CFBundleName</key><string>UsageBar</string>
<key>CFBundleExecutable</key><string>UsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --deep --sign - "$APP"
cat > "$PL" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.sudipta.usagebar</string>
<key>ProgramArguments</key><array><string>/Applications/UsageBar.app/Contents/MacOS/UsageBar</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
</dict></plist>
EOF
launchctl load "$PL"
sleep 3
pgrep -x UsageBar && echo RUNNING || echo NOT_RUNNING
