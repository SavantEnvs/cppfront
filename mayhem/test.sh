#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# cppfront's own functional suite is regression-tests/: run-tests.sh compiles every *.cpp2 with
# cppfront and diffs the generated Cpp1 (test-results/<t>.cpp) and the compiler's messages
# (test-results/<t>.cpp2.output) against golden files tracked in git. This runs the same
# translation step with the cppfront that mayhem/build.sh built with NORMAL flags (not the
# sanitized fuzz build) and compares against the same goldens. (The later steps of run-tests.sh
# compile and run the generated code per host compiler; they test the C++ compiler, not cppfront.)
CF="$SRC/build-fuzz/cppfront"
[ -x "$CF" ] || { echo "missing $CF - mayhem/build.sh must build it" >&2; emit_ctrf "cppfront-regression-tests" 0 1 0; exit 1; }

cd "$SRC/regression-tests"
gold=test-results
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0 failed=0
for src in *.cpp2; do
  t="${src%.cpp2}"
  opt=""
  case "$t" in pure2*) opt="-p -include-std" ;; esac

  "$CF" "$src" -o "$work/$t.cpp" $opt > "$work/$t.cpp2.output" 2>&1

  ok=1
  [ -s "$gold/$t.cpp2.output" ] && cmp -s "$work/$t.cpp2.output" "$gold/$t.cpp2.output" || ok=0
  if [ -f "$gold/$t.cpp" ]; then
    cmp -s "$work/$t.cpp" "$gold/$t.cpp" || ok=0
  else
    # a test with no golden Cpp1 must be rejected: no output file and an "error" message
    { [ ! -e "$work/$t.cpp" ] && grep -q error "$work/$t.cpp2.output"; } || ok=0
  fi

  if [ "$ok" = 1 ]; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL: $src" >&2; fi
done

# Known answers on top of the golden diffs, from the checked-in goldens: the compiler must emit
# the Cpp1 that upstream recorded for hello-world, not just exit 0.
"$CF" mixed-hello.cpp2 -o "$work/hello.cpp" > /dev/null 2>&1
if grep -q 'std::cout << "Hello "' "$work/hello.cpp" 2>/dev/null; then passed=$((passed+1)); else failed=$((failed+1)); echo "FAIL: hello-world KAT" >&2; fi

emit_ctrf "cppfront-regression-tests" "$passed" "$failed" 0
