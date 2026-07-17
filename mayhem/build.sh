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
# The meson source tarballs and the python wheels for the test driver live in an
# in-image cache OUTSIDE the tree (created by the Dockerfile), so they survive
# `git clean -ffdX` and nothing here needs the network after the image build.
MAYHEM_CACHE="${MAYHEM_CACHE:-/opt/openslide-cache}"
# The nested uthash wrap that meson promotes into subprojects/ is untracked but not
# gitignored, so it survives the clean as a redirect into the now-deleted libdicom
# dir (which makes meson abort) — drop that stale pair whenever libdicom is missing.
export MESON_PACKAGE_CACHE_DIR="$MAYHEM_CACHE/packagecache"
mkdir -p "$MESON_PACKAGE_CACHE_DIR"
if [ ! -d subprojects/libdicom-1.3.0 ]; then
  rm -rf subprojects/uthash.wrap subprojects/uthash-*
  meson subprojects download libdicom
fi

# The test build pip-installs driver.py's requirements into builddir-tests/test/env,
# which the clean removes: always install from the wheel cache, filled on first run.
WHEELS="$MAYHEM_CACHE/wheels"
if ! ls "$WHEELS"/*.whl >/dev/null 2>&1; then
  python3 -m pip download -q --disable-pip-version-check -r test/requirements.txt -d "$WHEELS"
fi
export PIP_NO_INDEX=1 PIP_FIND_LINKS="$WHEELS"
chmod -R a+rX "$MAYHEM_CACHE"

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
