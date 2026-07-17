#!/usr/bin/env bash
# Run OpenSlide's own upstream test suite (test/driver.py) over the subset of
# cases whose base slides are baked into the image, fully offline. These are
# real behavioral tests: they open real/malformed slides and assert vendor,
# properties (incl. quickhash), region contents and expected error messages,
# so neutering openslide_open (sabotage) makes them fail. Emits a CTRF report
# and exits non-zero on any failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

export OPENSLIDE_TEST_CACHE="$SRC/_slidedata"
DRIVER="$SRC/builddir-tests/test/driver"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$DRIVER" ]; then
  echo "test.sh: driver not built ($DRIVER)" >&2
  emit_ctrf "openslide-driver" 0 1 0
  exit 1
fi

passed=0
failed=0
while read -r case_name; do
  [ -n "$case_name" ] || continue
  out="$("$DRIVER" run "$case_name" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  # exit 0 alone is not proof the test ran: require the driver's own
  # behavioral verdict ("<case>: OK" and its "Failed: 0/N" tally) in the output
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q ": OK" \
     && printf '%s' "$out" | grep -q "Failed: 0/"; then
    echo "PASS: $case_name"
    passed=$(( passed + 1 ))
  else
    echo "FAIL: $case_name" >&2
    failed=$(( failed + 1 ))
  fi
done < mayhem/tests.list

echo "openslide test suite: passed=$passed failed=$failed"
emit_ctrf "openslide-driver" "$passed" "$failed" 0
