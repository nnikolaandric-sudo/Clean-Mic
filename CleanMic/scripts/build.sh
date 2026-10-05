#!/bin/bash
# CleanMic build — universal (arm64 + x86_64), macOS 13+.
# Radi samo sa Command Line Tools (bez punog Xcode): flat-copy + swiftc umjesto
# SwiftPM-a, jer SwiftPM bez Xcode-a ne zna napraviti universal binarku.
#
#   ./scripts/build.sh                      -> bin/        (razvoj)
#   OUT_DIR=dist ./scripts/build.sh         -> dist/       (za DMG, vidi make-dmg.sh)
#   ARCHS=arm64 ./scripts/build.sh          -> samo Apple Silicon (brže)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$PROJECT_DIR/bin}"
case "$OUT_DIR" in /*) ;; *) OUT_DIR="$PROJECT_DIR/$OUT_DIR" ;; esac
export ARCHS="${ARCHS:-arm64 x86_64}"
export MIN_OS="${MIN_OS:-13.0}"

RNNOISE_INCLUDE="$PROJECT_DIR/Vendor/rnnoise/include"
RNNOISE_LIB_DIR="$PROJECT_DIR/Vendor/rnnoise"
CORE="$PROJECT_DIR/Sources/CleanMicCore"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cleanmic-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "🔨 CleanMic build — $ARCHS, macOS $MIN_OS+ → $OUT_DIR"

"$SCRIPT_DIR/build-rnnoise.sh"

# Core + target u jedan modul; `import CleanMicCore` tada ne treba.
mkdir -p "$OUT_DIR" "$WORK/cli" "$WORK/app"
cp "$CORE/"*.swift "$WORK/cli/"
cp "$CORE/"*.swift "$WORK/app/"
sed 's/^import CleanMicCore$//' "$PROJECT_DIR/Sources/CleanMicCLI/main.swift" > "$WORK/cli/main.swift"
for f in "$PROJECT_DIR/Sources/CleanMicApp/"*.swift; do
  sed 's/^import CleanMicCore$//' "$f" > "$WORK/app/$(basename "$f")"
done

CLI_SLICES=()
APP_SLICES=()
for ARCH in $ARCHS; do
  TARGET="$ARCH-apple-macos$MIN_OS"
  echo "🔨 [$ARCH] RNNoiseBridge.c"
  clang -O3 -fPIC -target "$TARGET" \
    -I "$RNNOISE_INCLUDE" -I "$CORE/include" \
    -c "$CORE/RNNoiseBridge.c" -o "$WORK/bridge-$ARCH.o"

  echo "🔨 [$ARCH] cleanmic-cli"
  swiftc -O -target "$TARGET" -o "$WORK/cleanmic-cli-$ARCH" \
    "$WORK/cli/"*.swift "$WORK/bridge-$ARCH.o" \
    -framework AVFoundation -framework CoreAudio \
    -L "$RNNOISE_LIB_DIR" -lrnnoise
  CLI_SLICES+=("$WORK/cleanmic-cli-$ARCH")

  echo "🔨 [$ARCH] CleanMicApp"
  swiftc -O -target "$TARGET" -o "$WORK/CleanMicApp-$ARCH" \
    "$WORK/app/"*.swift "$WORK/bridge-$ARCH.o" \
    -framework AVFoundation -framework CoreAudio -framework SwiftUI -framework AppKit \
    -framework ServiceManagement \
    -L "$RNNOISE_LIB_DIR" -lrnnoise
  APP_SLICES+=("$WORK/CleanMicApp-$ARCH")
done

lipo -create "${CLI_SLICES[@]}" -output "$OUT_DIR/cleanmic-cli"
lipo -create "${APP_SLICES[@]}" -output "$OUT_DIR/CleanMicApp"
echo "✅ $OUT_DIR/cleanmic-cli ($(lipo -archs "$OUT_DIR/cleanmic-cli"))"
echo "✅ $OUT_DIR/CleanMicApp ($(lipo -archs "$OUT_DIR/CleanMicApp"))"

# C++ demo (mock, nije dio aplikacije) — samo za razvoj, ne ide u dist.
if [ "$OUT_DIR" = "$PROJECT_DIR/bin" ]; then
  clang++ -std=c++17 -o "$OUT_DIR/cleanmic-demo" "$PROJECT_DIR/Sources/CleanMicClangDemo/main.cpp" \
    -framework CoreAudio -framework CoreFoundation
  echo "✅ $OUT_DIR/cleanmic-demo"
fi

# Zapakuj u .app bundle — bez Info.plist TCC nikad ne prikaze mic popup
OUT_DIR="$OUT_DIR" "$SCRIPT_DIR/make-app-bundle.sh"

echo ""
echo "🎉 Build gotov"
echo "  $OUT_DIR/CleanMic.app   <- GUI (menu bar)"
echo "  $OUT_DIR/cleanmic-cli   <- CLI: selftest | check-key | record-processed | transcribe | report"
echo ""
echo "Provjera:  $OUT_DIR/cleanmic-cli selftest"
echo "DMG:       ./scripts/make-dmg.sh"
