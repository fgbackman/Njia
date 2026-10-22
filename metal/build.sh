#!/bin/bash
# Builds build/Njia.app next to this script. Pass "open" to launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Njia.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O src/*.swift -o "$APP/Contents/MacOS/Njia"
cp src/Shaders.metal "$APP/Contents/Resources/"
if [ -d data/stages ]; then cp -R data/stages "$APP/Contents/Resources/stages"; fi
if [ -d data/people ]; then cp -R data/people "$APP/Contents/Resources/people"; fi

printf 'APPL????' > "$APP/Contents/PkgInfo"
printf '%s\n' "$(cd .. && pwd)/diagnostics" > "$APP/Contents/Resources/diagnostics.path"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Njia</string>
    <key>CFBundleDisplayName</key><string>Njia</string>
    <key>CFBundleIdentifier</key><string>com.fbackman.njia</string>
    <key>CFBundleExecutable</key><string>Njia</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.adventure-games</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $(pwd)/$APP"
if [ "${1:-}" = "open" ]; then open "$APP"; fi
