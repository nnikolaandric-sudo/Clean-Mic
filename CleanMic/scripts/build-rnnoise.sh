#!/bin/bash
# CleanMic RNNoise build
# Kompajlira xiph/rnnoise (git submodule) u staticku biblioteku — universal
# (arm64 + x86_64), da ista aplikacija radi i na Apple Silicon i na Intel Macu.
# Koristi se umjesto autotools jer CLT nema autoreconf/autoconf.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/Vendor/rnnoise"
OUTPUT_LIB="$VENDOR_DIR/librnnoise.a"

# Uskladi sa scripts/build.sh — isti min macOS i iste arhitekture, da nema ld warninga.
ARCHS="${ARCHS:-arm64 x86_64}"
MIN_OS="${MIN_OS:-13.0}"

if [ ! -d "$VENDOR_DIR/src" ]; then
  echo "❌ RNNoise submodule nije initovan. Pokreni:"
  echo "   git submodule update --init --recursive"
  exit 1
fi

# rnnoise_data.h je generisan iz training modela (58MB tarball).
# Preuzmi ga ako ne postoji.
DATA_HEADER="$VENDOR_DIR/src/rnnoise_data.h"
if [ ! -f "$DATA_HEADER" ]; then
  if [ ! -f "$VENDOR_DIR/model_version" ]; then
    echo "❌ model_version fajl nedostaje u RNNoise vendor diru"
    exit 1
  fi
  MODEL_HASH=$(tr -d '[:space:]' < "$VENDOR_DIR/model_version")
  MODEL_URL="https://media.xiph.org/rnnoise/models/rnnoise_data-${MODEL_HASH}.tar.gz"
  echo "📦 Preuzimam RNNoise model (~60MB) sa $MODEL_URL"
  if ! command -v curl >/dev/null 2>&1; then
    echo "❌ curl nije dostupan — instaliraj ga ili ručno preuzmi model."
    exit 1
  fi
  (
    cd "$VENDOR_DIR"
    curl -sL -o rnnoise_data.tar.gz "$MODEL_URL"
    if [ ! -s rnnoise_data.tar.gz ]; then
      echo "❌ Download fajla neuspešan (prazan fajl)"
      rm -f rnnoise_data.tar.gz
      exit 1
    fi
    tar -xzf rnnoise_data.tar.gz
    rm rnnoise_data.tar.gz
  )
  if [ ! -f "$DATA_HEADER" ]; then
    echo "❌ rnnoise_data.h se nije pojavio nakon extrakta"
    exit 1
  fi
  echo "✅ Model preuzet i raspakovan"
fi

# Izvori — vidi vendor/rnnoise/Makefile.am RNNOISE_SOURCES (bez x86 RTCD).
# dump_features*, dump_rnnoise_tables, write_weights su trening alati i nisu
# dio librnnoise.a, ali parse_lpcnet_weights.c JESTE (koristi ga denoise.c
# preko extern const WeightArray).
SOURCES=(denoise rnn pitch kiss_fft celt_lpc nnet nnet_default parse_lpcnet_weights rnnoise_data rnnoise_tables)

SLICES=()
for ARCH in $ARCHS; do
  BUILD_DIR="$VENDOR_DIR/build/$ARCH-macos$MIN_OS"
  SLICE="$BUILD_DIR/librnnoise.a"
  mkdir -p "$BUILD_DIR"
  OBJECTS=()
  REBUILT=0
  for name in "${SOURCES[@]}"; do
    src="$VENDOR_DIR/src/$name.c"
    obj="$BUILD_DIR/$name.o"
    OBJECTS+=("$obj")
    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
      echo "  cc [$ARCH] $name.c"
      #   -fvisibility se ne dira: RNNOISE_BUILD aktivira RNNOISE_EXPORT.
      #   -O3: RNNoise je compute-heavy. NEON (arm64) i SSE2 (x86_64) su baseline.
      clang -O3 -fPIC -target "$ARCH-apple-macos$MIN_OS" -DRNNOISE_BUILD \
        -I"$VENDOR_DIR/include" -I"$VENDOR_DIR/src" -c "$src" -o "$obj"
      REBUILT=1
    fi
  done
  if [ "$REBUILT" = 1 ] || [ ! -f "$SLICE" ]; then
    rm -f "$SLICE"
    ar rcs "$SLICE" "${OBJECTS[@]}"
  fi
  SLICES+=("$SLICE")
done

rm -f "$OUTPUT_LIB"
if [ "${#SLICES[@]}" -gt 1 ]; then
  lipo -create "${SLICES[@]}" -output "$OUTPUT_LIB"
else
  cp "${SLICES[0]}" "$OUTPUT_LIB"
fi

echo "✅ RNNoise built: $OUTPUT_LIB ($(lipo -archs "$OUTPUT_LIB"), macOS $MIN_OS+)"
