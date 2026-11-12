#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release "$@"
bin_dir="$(swift build -c release --show-bin-path "$@")"
app="dist/GlacierDesk.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/GlacierDesk" "$app/Contents/MacOS/GlacierDesk"
cp Assets/GlacierDesk.png "$app/Contents/Resources/GlacierDesk.png"
iconset="$(mktemp -d "${TMPDIR:-/tmp}/glacierdesk-icon.XXXXXX")/GlacierDesk.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/GlacierDesk.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" Assets/GlacierDesk.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 - "$iconset" "$app/Contents/Resources/GlacierDesk.icns" <<'PY'
import pathlib, struct, sys
iconset, destination = map(pathlib.Path, sys.argv[1:])
sizes = [('icp4', 16), ('icp5', 32), ('icp6', 64), ('ic07', 128),
         ('ic08', 256), ('ic09', 512), ('ic10', 1024)]
chunks = []
for kind, size in sizes:
    name = f'icon_{size}x{size}.png' if size <= 512 and size != 64 else ('icon_32x32@2x.png' if size == 64 else 'icon_512x512@2x.png')
    png = (iconset / name).read_bytes()
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(png) + 8) + png)
data = b''.join(chunks)
destination.write_bytes(b'icns' + struct.pack('>I', len(data) + 8) + data)
PY
rm -rf "$(dirname "$iconset")"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GlacierDesk</string>
<key>CFBundleIdentifier</key><string>ai.willislabs.GlacierDesk</string>
<key>CFBundleName</key><string>GlacierDesk</string>
<key>CFBundleIconFile</key><string>GlacierDesk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 WillisLabs.ai</string>
</dict></plist>
PLIST
# Finder displays the bundle directory's modification time, which does not
# automatically change when only files inside an existing bundle are replaced.
touch "$app"
echo "Built $app"
