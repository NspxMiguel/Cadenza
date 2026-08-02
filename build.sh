#!/bin/bash
# Builds Cadenza.app — no Xcode required, Command Line Tools are enough.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/Cadenza.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Cadenza" "$APP/Contents/MacOS/Cadenza"
cp Resources/Cadenza.icns "$APP/Contents/Resources/Cadenza.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Cadenza</string>
    <key>CFBundleIdentifier</key><string>com.miguel.cadenza</string>
    <key>CFBundleName</key><string>Cadenza</string>
    <key>CFBundleIconFile</key><string>Cadenza</string>
    <key>CFBundleDisplayName</key><string>Cadenza</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- Window restoration is what produced the "quit unexpectedly while
         reopening windows" loop after an unclean exit. The app has no document
         state worth restoring. -->
    <key>NSQuitAlwaysKeepsWindows</key><false/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <!-- Required: MusicAuthorization.request() runs at launch to decide whether
         lossless is reachable. Without this string TCC kills the process
         outright, which reads as a crash on every launch. -->
    <key>NSAppleMusicUsageDescription</key>
    <string>O Cadenza usa o Apple Music para tocar o catálogo de música clássica.</string>
</dict>
</plist>
PLIST

# Lossless needs the MusicKit entitlement, which needs a paid team. Without
# CADENZA_TEAM the build is ad-hoc signed and runs on the WebKit engine — see
# docs/lossless.md.
if [ -n "${CADENZA_TEAM:-}" ]; then
    ENT="$(mktemp -t cadenza-entitlements).plist"
    cat > "$ENT" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.musickit</key><true/>
</dict>
</plist>
ENTITLEMENTS

    IDENTITY=$(security find-identity -v -p codesigning \
        | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
    if [ -z "$IDENTITY" ]; then
        echo "CADENZA_TEAM definido, mas nenhuma identidade 'Apple Development' na keychain." >&2
        echo "Entre com seu Apple ID no Xcode (Settings ▸ Accounts) e tente de novo." >&2
        exit 1
    fi

    echo "assinando para lossless com: $IDENTITY (time $CADENZA_TEAM)"
    codesign --force --deep --options runtime \
        --entitlements "$ENT" --sign "$IDENTITY" "$APP"
    rm -f "$ENT"
else
    codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true
fi

echo "→ $APP"
