#!/usr/bin/env bash
# Build OpenSlide (meson) for Mayhem: instrumented fuzz build + clean test build.
# Idempotent and air-gapped: all network fetches (meson wrap for libdicom,
# openslide-testdata base slides) are cached on first run and skipped after.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${CXX:=clang++}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# --- 0) Cache the libdicom meson wrap (no system libdicom in Debian trixie) ---
if [ ! -d subprojects/libdicom-1.3.0 ]; then
  meson subprojects download libdicom
fi

# --- 1) Instrumented fuzz build of libopenslide -------------------------------
# ASan/UBSan + libFuzzer edge instrumentation + DWARF-3 debug info.
FUZZ_CFLAGS="-O1 $DEBUG_FLAGS $SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
if [ ! -f builddir-fuzz/build.ninja ]; then
  meson setup builddir-fuzz \
    --buildtype=plain \
    -Ddefault_library=shared \
    -Dtest=disabled \
    -Ddoc=disabled \
    -Db_lundef=false \
    -Dc_args="$FUZZ_CFLAGS" \
    -Dc_link_args="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link -Wl,-z,undefs"
fi
ninja -C builddir-fuzz -j "$MAYHEM_JOBS"

# --- 2) Fuzz harness: libFuzzer target + standalone reproducer ----------------
FUZZ_LIB="$SRC/builddir-fuzz/src/libopenslide.so"
$CC -O1 $DEBUG_FLAGS $SANITIZER_FLAGS $LIB_FUZZING_ENGINE \
  mayhem/fuzz_open.c -Isrc "$FUZZ_LIB" \
  -Wl,-rpath,"$SRC/builddir-fuzz/src" \
  -o "$SRC/openslide-fuzz"
$CC -O1 $DEBUG_FLAGS $SANITIZER_FLAGS \
  "$STANDALONE_FUZZ_MAIN" mayhem/fuzz_open.c -Isrc "$FUZZ_LIB" \
  -Wl,-rpath,"$SRC/builddir-fuzz/src" \
  -o "$SRC/openslide-fuzz-standalone"

# --- 3) Clean test build (normal flags: honest functional oracle) -------------
if [ ! -f builddir-tests/build.ninja ]; then
  meson setup builddir-tests \
    -Dtest=enabled \
    -Ddoc=disabled \
    -Dc_args="$COVERAGE_FLAGS"
fi
ninja -C builddir-tests -j "$MAYHEM_JOBS"

# --- 4) Pre-fetch + unpack upstream test data for the integrated subset -------
# Downloads the two Aperio base slides once (cached in the image); the
# offline re-run and mayhem/test.sh use the cache without network access.
export OPENSLIDE_TEST_CACHE="$SRC/_slidedata"
while read -r case_name; do
  [ -n "$case_name" ] || continue
  "$SRC/builddir-tests/test/driver" unpack "$case_name"
done < mayhem/tests.list

echo "build.sh: OK"
