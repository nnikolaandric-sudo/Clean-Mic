#!/bin/bash
# Pravi dist/CleanMic-<verzija>.dmg (universal, macOS 13+).
#   ./scripts/make-dmg.sh              build + DMG
#   ./scripts/make-dmg.sh --no-build   samo DMG od postojećeg dist/CleanMic.app
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$DIR/dist"
VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"
DMG="$DIST/CleanMic-$VERSION.dmg"

if [ "${1:-}" != "--no-build" ]; then
  OUT_DIR="$DIST" "$DIR/scripts/build.sh"
fi
if [ ! -d "$DIST/CleanMic.app" ]; then
  echo "❌ Nema $DIST/CleanMic.app — pokreni bez --no-build"
  exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cleanmic-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$DIST/CleanMic.app" "$STAGE/CleanMic.app"
ln -s /Applications "$STAGE/Applications"
cp "$DIR/scripts/dmg/PROCITAJ.txt" "$STAGE/PROČITAJ — instalacija.txt"

rm -f "$DMG"
hdiutil create -volname "CleanMic $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
  -imagekey zlib-level=9 "$DMG" >/dev/null

echo "✅ $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
shasum -a 256 "$DMG"

# Potpis za automatsko ažuriranje. Bez njega se izdanje instalira samo ručno.
SIG="$DMG.sig"
rm -f "$SIG"
if [ -f "$HOME/.config/cleanmic/update_signing_key" ] || [ -n "${CLEANMIC_UPDATE_SIGNING_KEY:-}" ]; then
  "$DIST/cleanmic-cli" sign-update "$DMG" --version "$VERSION"
  echo ""
  echo "Izdanje:  gh release create v$VERSION \"$DMG\" \"$SIG\" --title \"CleanMic $VERSION\" --notes-file <bilješke>"
else
  echo "⚠️  Nema ključa za potpis (cleanmic-cli update-keygen) — ovo izdanje se neće moći instalirati samo."
fi
