#!/bin/bash
# CleanMic Build Script — Faza 0.5
# Radi sa Command Line Tools (bez punog Xcode) koristeci patched SDK + VFS overlay workaround
# za SwiftBridging duplikat, i flat-copy + swiftc umjesto SPM (zbudje radi sa CLT).
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$PROJECT_DIR/bin"
PATCHED_SDK="/tmp/patched-sdk/MacOSX15.2.sdk"
VFS_JSON="$SCRIPT_DIR/vfs.json"
RNNOISE_INCLUDE="$PROJECT_DIR/Vendor/rnnoise/include"
RNNOISE_LIB_DIR="$PROJECT_DIR/Vendor/rnnoise"
RNNOISE_BRIDGE_H="$PROJECT_DIR/Sources/CleanMicCore/include/RNNoiseBridge.h"

echo "🔨 CleanMic Build — Faza 0.5 (real RNNoise)"

# 0. Build RNNoise C lib (ako vec nije)
if [ ! -f "$RNNOISE_LIB_DIR/librnnoise.a" ] || [ ! -f "$PROJECT_DIR/Vendor/rnnoise/src/rnnoise_data.h" ]; then
  "$SCRIPT_DIR/build-rnnoise.sh"
else
  echo "✅ librnnoise.a vec postoji"
fi

# 1. Patch SDK ako je potrebno
if [ ! -d "$PATCHED_SDK" ]; then
  echo "📦 Patching SDK (1.5 -> 1.10)..."
  mkdir -p /tmp/patched-sdk
  if [ ! -d "/tmp/patched-sdk/MacOSX15.2.sdk" ]; then
    cp -R "/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk" /tmp/patched-sdk/ 2>/dev/null || \
    cp -R "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" /tmp/patched-sdk/MacOSX15.2.sdk
  fi
  find /tmp/patched-sdk/MacOSX15.2.sdk -name "*.swiftinterface" -exec sed -i '' 's/swiftlang-6.0.3.1.5/swiftlang-6.0.3.1.10/g' {} \; 2>/dev/null || true
  echo "✅ SDK patched at $PATCHED_SDK"
else
  echo "✅ Patched SDK vec postoji"
fi

# ensure VFS overlay exists
if [ ! -f "$VFS_JSON" ]; then
  echo "" > "$SCRIPT_DIR/empty.modulemap"
  cat > "$VFS_JSON" << 'EOF'
{
  "version": 0,
  "roots": [
    {
      "type": "directory",
      "name": "/Library/Developer/CommandLineTools/usr/include/swift",
      "contents": [
        {
          "type": "file",
          "name": "module.modulemap",
          "external-contents": "/tmp/empty.modulemap"
        }
      ]
    }
  ]
}
EOF
  touch /tmp/empty.modulemap
fi

mkdir -p "$BIN_DIR"

# Common flags za ObjC++ kompilaciju (RNNoise bridge) i Swift linking
ARCH_FLAG="-target arm64-apple-macosx15.0"
if [ "$(uname -m)" = "x86_64" ]; then
  ARCH_FLAG="-target x86_64-apple-macosx15.0"
fi
SWIFT_FRAMEWORKS="-framework AVFoundation -framework CoreAudio"

# Helper: compile RNNoiseBridge.c once, reuse across targets
BRIDGE_OBJ="/tmp/rnnoise_bridge.o"
RNNOISE_BRIDGE_C="$PROJECT_DIR/Sources/CleanMicCore/RNNoiseBridge.c"
# NAPOMENA: ranije se provjeravao samo .h, pa su izmjene u .c-u tiho ignorisane
# i linkovao se ustajali /tmp/rnnoise_bridge.o. Sada se prati i .c fajl.
if [ ! -f "$BRIDGE_OBJ" ] || [ "$RNNOISE_BRIDGE_H" -nt "$BRIDGE_OBJ" ] || [ "$RNNOISE_BRIDGE_C" -nt "$BRIDGE_OBJ" ]; then
  echo "🔨 Compiling RNNoiseBridge.c..."
  clang -O3 -fPIC $ARCH_FLAG \
    -I "$RNNOISE_INCLUDE" \
    -I "$PROJECT_DIR/Sources/CleanMicCore/include" \
    -c "$PROJECT_DIR/Sources/CleanMicCore/RNNoiseBridge.c" \
    -o "$BRIDGE_OBJ"
  echo "✅ $BRIDGE_OBJ"
fi

# Compile cleanmic-cli (Swift + RNNoise bridge C obj)
echo "🔨 Building cleanmic-cli (Swift + RNNoise)..."
mkdir -p /tmp/build-cli
cp "$PROJECT_DIR/Sources/CleanMicCore/"*.swift /tmp/build-cli/
cp "$PROJECT_DIR/Sources/CleanMicCLI/main.swift" /tmp/build-cli/main.swift
sed -i '' 's/import CleanMicCore//g' /tmp/build-cli/main.swift 2>/dev/null || sed -i 's/import CleanMicCore//g' /tmp/build-cli/main.swift

swiftc -o "$BIN_DIR/cleanmic-cli" /tmp/build-cli/*.swift "$BRIDGE_OBJ" \
  -sdk "$PATCHED_SDK" $SWIFT_FRAMEWORKS $ARCH_FLAG \
  -no-verify-emitted-module-interface -vfsoverlay "$VFS_JSON" \
  -Xcc "-I$RNNOISE_INCLUDE" \
  -Xcc "-I$PROJECT_DIR/Sources/CleanMicCore/include" \
  -L "$RNNOISE_LIB_DIR" -lrnnoise
echo "✅ $BIN_DIR/cleanmic-cli"

# C++ demo (nije dirnut, ostaje isti)
echo "🔨 Building cleanmic-demo (C++)..."
clang++ -std=c++17 -o "$BIN_DIR/cleanmic-demo" "$PROJECT_DIR/Sources/CleanMicClangDemo/main.cpp" \
  -framework CoreAudio -framework CoreFoundation
echo "✅ $BIN_DIR/cleanmic-demo"

# SwiftUI App
echo "🔨 Building CleanMicApp (SwiftUI)..."
mkdir -p /tmp/build-app
cp "$PROJECT_DIR/Sources/CleanMicCore/"*.swift /tmp/build-app/
cp "$PROJECT_DIR/Sources/CleanMicApp/main.swift" /tmp/build-app/main-app.swift
sed -i '' 's/import CleanMicCore//g' /tmp/build-app/main-app.swift 2>/dev/null || sed -i 's/import CleanMicCore//g' /tmp/build-app/main-app.swift
rm -f /tmp/build-app/main.swift 2>/dev/null || true
swiftc -o "$BIN_DIR/CleanMicApp" /tmp/build-app/*.swift "$BRIDGE_OBJ" \
  -sdk "$PATCHED_SDK" $SWIFT_FRAMEWORKS -framework SwiftUI -framework AppKit $ARCH_FLAG \
  -no-verify-emitted-module-interface -vfsoverlay "$VFS_JSON" \
  -Xcc "-I$RNNOISE_INCLUDE" \
  -Xcc "-I$PROJECT_DIR/Sources/CleanMicCore/include" \
  -L "$RNNOISE_LIB_DIR" -lrnnoise
echo "✅ $BIN_DIR/CleanMicApp"

# Zapakuj u .app bundle — bez Info.plist TCC nikad ne prikaze mic popup
"$PROJECT_DIR/scripts/make-app-bundle.sh"


echo ""
echo "🎉 Build gotov! (Faza 0.5 — pravi RNNoise)"
echo "  bin/cleanmic-cli"
echo "  bin/cleanmic-demo"
echo "  bin/CleanMicApp"
echo "  bin/CleanMic.app   <- OVO pokreni za GUI (ima mic dozvolu)"
echo ""
echo "Probaj:"
echo "  ./bin/cleanmic-cli list"
echo "  ./bin/cleanmic-cli process /tmp/cleanmic_synthetic_in.wav /tmp/out.wav --mode balanced"
echo "  ./bin/cleanmic-cli record-processed 3 /tmp/clean.wav --mode balanced"
