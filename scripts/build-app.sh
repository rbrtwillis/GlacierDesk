#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
bin_dir="$(swift build -c release --show-bin-path "$@")"
app="dist/GlacierDesk.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/GlacierDesk" "$app/Contents/MacOS/GlacierDesk"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GlacierDesk</string>
<key>CFBundleIdentifier</key><string>ai.willislabs.GlacierDesk</string>
<key>CFBundleName</key><string>GlacierDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 WillisLabs.ai</string>
</dict></plist>
PLIST
echo "Built $app"
