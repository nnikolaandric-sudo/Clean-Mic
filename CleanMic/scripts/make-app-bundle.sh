#!/bin/bash
# Pakuje bin/CleanMicApp u pravi .app bundle sa Info.plist,
# da bi macOS TCC uopšte mogao da prikaže popup za mikrofon.
# Goli Mach-O bez Info.plist => NIKAD nema popupa (tihi deny).
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin"
APP="$BIN/CleanMic.app"
BUNDLE_ID="com.cleanmic.app"

if [ ! -x "$BIN/CleanMicApp" ]; then
  echo "❌ Nema $BIN/CleanMicApp — prvo pokreni ./scripts/build.sh"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CleanMicApp" "$APP/Contents/MacOS/CleanMicApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>CleanMic</string>
    <key>CFBundleDisplayName</key>       <string>CleanMic</string>
    <key>CFBundleIdentifier</key>        <string>com.cleanmic.app</string>
    <key>CFBundleExecutable</key>        <string>CleanMicApp</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSUIElement</key>               <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>CleanMic koristi mikrofon da u realnom vremenu uklanja šum iz tvog glasa.</string>
</dict>
</plist>
PLIST

# Ad-hoc potpis nad CELIM bundle-om — TCC vezuje dozvolu za bundle ID + cdhash.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "✅ $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Info.plist"
