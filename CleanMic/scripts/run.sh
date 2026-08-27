#!/bin/bash
# Quick run helper
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin"

echo "CleanMic — Lokalno pokretanje (Faza 0 Spike)"
echo "============================================="
echo ""
echo "1) C++ demo (radi bez Xcode):"
echo "   $BIN/cleanmic-demo list"
echo ""
echo "2) Swift CLI (patchovan build):"
echo "   $BIN/cleanmic-cli list"
echo "   $BIN/cleanmic-cli test-rings"
echo "   $BIN/cleanmic-cli process in.wav out.wav"
echo "   $BIN/cleanmic-cli record 5 /tmp/raw.wav"
echo "   $BIN/cleanmic-cli record-processed 5 /tmp/clean.wav --mode balanced"
echo ""
echo "3) SwiftUI App (menu-bar, zahteva GUI):"
echo "   open $BIN/CleanMicApp  # ili dvoklik"
echo "   (Mora se pokrenuti kao app, ne iz terminala headless)"
echo ""
echo "--- Pokrećem C++ demo list + test ---"
"$BIN/cleanmic-demo" list
echo ""
"$BIN/cleanmic-demo" test-rings
echo ""
echo "--- Swift CLI list ---"
"$BIN/cleanmic-cli" list
