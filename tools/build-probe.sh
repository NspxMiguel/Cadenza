#!/bin/bash
# Bundles MusicKitProbe as a real .app — MusicKit needs a bundle identifier and
# NSAppleMusicUsageDescription before it will even show the consent prompt.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/MusicKitProbe.app"
swift build -c release --product MusicKitProbe

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/MusicKitProbe" "$APP/Contents/MacOS/MusicKitProbe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MusicKitProbe</string>
    <key>CFBundleIdentifier</key><string>com.miguel.cadenza.musickitprobe</string>
    <key>CFBundleName</key><string>MusicKitProbe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSAppleMusicUsageDescription</key>
    <string>Cadenza precisa acessar o Apple Music para tocar as gravações do seu catálogo.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "→ $APP"
