#!/bin/bash
# Pakuje CleanMicApp u pravi .app bundle sa Info.plist,
# da bi macOS TCC uopšte mogao da prikaže popup za mikrofon.
# Goli Mach-O bez Info.plist => NIKAD nema popupa (tihi deny).
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$DIR/bin}"
APP="$OUT_DIR/CleanMic.app"
BUNDLE_ID="com.cleanmic.app"
VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"
BUILD="$(git -C "$DIR" rev-list --count HEAD 2>/dev/null || date +%Y%m%d)"
MIN_OS="${MIN_OS:-13.0}"

if [ ! -x "$OUT_DIR/CleanMicApp" ]; then
  echo "❌ Nema $OUT_DIR/CleanMicApp — prvo pokreni ./scripts/build.sh"
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$OUT_DIR/CleanMicApp" "$APP/Contents/MacOS/CleanMicApp"
cp "$DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>CleanMic</string>
    <key>CFBundleDisplayName</key>       <string>CleanMic</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>CleanMicApp</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>    <string>$MIN_OS</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSUIElement</key>               <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>CleanMic snima sa mikrofona i u realnom vremenu uklanja šum iz tvog glasa.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>CleanMic snima i zvuk iz računara (glasove ostalih na online sastanku) kad nosiš slušalice, da izvještaj ne ostane bez njih.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>CleanMic čuva snimke, transkripte i izvještaje u folderu Downloads/CleanMic.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>CleanMic čuva snimke, transkripte i izvještaje u folderu koji izabereš.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>CleanMic čuva snimke, transkripte i izvještaje u folderu koji izabereš.</string>
</dict>
</plist>
PLIST

# Ad-hoc potpis nad CELIM bundle-om — TCC vezuje dozvolu za bundle ID + cdhash.
# (Bez Apple Developer ID-a: na drugom Macu Gatekeeper traži "Open Anyway" pri
#  prvom pokretanju — vidi INSTALL.md.)
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "✅ $APP  (v$VERSION build $BUILD, $(lipo -archs "$APP/Contents/MacOS/CleanMicApp"), macOS $MIN_OS+)"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Info.plist"
