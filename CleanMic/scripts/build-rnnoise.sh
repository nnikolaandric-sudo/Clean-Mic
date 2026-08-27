#!/bin/bash
# CleanMic RNNoise build — Faza 0.5
# Kompajlira xiph/rnnoise (git submodule) u staticku biblioteku.
# Koristi se umjesto autotools jer CLT nema autoreconf/autoconf.
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_DIR="$PROJECT_DIR/Vendor/rnnoise"
BUILD_DIR="$VENDOR_DIR/build"
OUTPUT_LIB="$VENDOR_DIR/librnnoise.a"

# Detekcija arhitekture — uskladi sa scripts/build.sh targetom da nema ld warninga.
if [ "$(uname -m)" = "x86_64" ]; then
  ARCH_FLAGS="-target x86_64-apple-macosx15.0"
else
  ARCH_FLAGS="-target arm64-apple-macosx15.0"
fi

# Hardverski SIMD: ARM64 Apple Clang automatski ukljucuje NEON, x86_64
# ne treba posebne flagove (SSE2 je baseline za macOS x86_64).
SIMD_FLAGS=""

# Common RNNoise compile flags:
#   -DHAVE_CONFIG_H je sigurno preskociti (koristimo config.h samo za autotools
#    stvari koje necemo koristiti, kao INSTALL). Ali pitch.c i rnn.c ocekuju
#    neke makroe. Probaj bez; ako link fail, dodaj minimalan config.h.
#   -fvisibility=hidden: sakrij sve osim RNNOISE_EXPORT-ovanih simbola.
#   -O3: RNNoise je compute-heavy.
COMMON_FLAGS=(
  "-O3" "-fPIC" $ARCH_FLAGS
  "-DRNNOISE_BUILD"  # activate RNNOISE_EXPORT __attribute__((visibility("default"))) on GNU
  "-I$VENDOR_DIR/include"
  "-I$VENDOR_DIR/src"
)

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
  MODEL_HASH=$(cat "$VENDOR_DIR/model_version" | tr -d '[:space:]')
  MODEL_URL="https://media.xiph.org/rnnoise/models/rnnoise_data-${MODEL_HASH}.tar.gz"
  echo "📦 Preuzimam RNNoise model (~$60MB) sa $MODEL_URL"
  if ! command -v curl >/dev/null 2>&1; then
    echo "❌ curl nije dostupan — instaliraj ga ili ručno preuzmi model."
    exit 1
  fi
  cd "$VENDOR_DIR"
  curl -sL -o rnnoise_data.tar.gz "$MODEL_URL"
  if [ ! -s rnnoise_data.tar.gz ]; then
    echo "❌ Download fajla neuspešan (prazan fajl)"
    rm -f rnnoise_data.tar.gz
    exit 1
  fi
  tar -xzf rnnoise_data.tar.gz
  rm rnnoise_data.tar.gz
  cd "$SCRIPT_DIR"
  if [ ! -f "$DATA_HEADER" ]; then
    echo "❌ rnnoise_data.h se nije pojavio nakon extrakta"
    exit 1
  fi
  echo "✅ Model preuzet i raspakovan"
fi

mkdir -p "$BUILD_DIR"

# Izvori — vidi vendor/rnnoise/Makefile.am RNNOISE_SOURCES (bez x86 RTCD).
# dump_features*, dump_rnnoise_tables, write_weights su trening alati i nisu
# dio librnnoise.a, ali parse_lpcnet_weights.c JESTE (koristi ga denoise.c
# preko extern const WeightArray).
SOURCES=(
  "$VENDOR_DIR/src/denoise.c"
  "$VENDOR_DIR/src/rnn.c"
  "$VENDOR_DIR/src/pitch.c"
  "$VENDOR_DIR/src/kiss_fft.c"
  "$VENDOR_DIR/src/celt_lpc.c"
  "$VENDOR_DIR/src/nnet.c"
  "$VENDOR_DIR/src/nnet_default.c"
  "$VENDOR_DIR/src/parse_lpcnet_weights.c"
  "$VENDOR_DIR/src/rnnoise_data.c"
  "$VENDOR_DIR/src/rnnoise_tables.c"
)

OBJECTS=()
for src in "${SOURCES[@]}"; do
  obj="$BUILD_DIR/$(basename "${src%.c}.o")"
  OBJECTS+=("$obj")
  if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
    echo "  cc $(basename "$src")"
    clang "${COMMON_FLAGS[@]}" -c "$src" -o "$obj"
  fi
done

echo "  ar librnnoise.a"
# Kreiraj arhivu (ili osvjezi ako postoji)
rm -f "$OUTPUT_LIB"
ar rcs "$OUTPUT_LIB" "${OBJECTS[@]}"
ranlib "$OUTPUT_LIB"

echo "✅ RNNoise built: $OUTPUT_LIB"
ls -lh "$OUTPUT_LIB"
