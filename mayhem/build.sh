#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# cppfront is a header-only compiler (source/cppfront.cpp #includes everything), so the "project
# build" is compiling the harness translation unit, which pulls in the whole front end:
# lexer, parser, sema and the Cpp1 generator. Nothing is fetched.
CXXSTD="-std=c++20"
OUT=/mayhem
BUILD="$SRC/build-fuzz"            # gitignored by upstream's `build*/`
mkdir -p "$BUILD"

# Per-input state: cppfront keeps two more pieces of cross-input state in FUNCTION-LOCAL
# statics (lex.h labelized_position's `labels`/`ordinal`, parse.h's `last_parent_type`), which the
# harness cannot reach. Compile the harness against a copy of source/ + include/ in which those
# statics are hoisted to namespace scope, so the harness can reset them. The edits keep every line
# number, so backtraces still match upstream's files (-ffile-prefix-map points paths at $SRC);
# upstream's tree is untouched and the copy lives in the gitignored build dir. Each edit must hit
# exactly once, so an upstream change to these lines fails the build loudly.
rm -rf "$BUILD/source" "$BUILD/include"
cp -r "$SRC/source" "$SRC/include" "$BUILD/"
patch_once() {  # file, exact old text (one line fragment), new text
  [ "$(grep -cF -- "$2" "$1")" = 1 ] || { echo "mayhem/build.sh: expected exactly one '$2' in $1" >&2; exit 1; }
  OLD="$2" NEW="$3" awk '{ i = index($0, ENVIRON["OLD"]);
    if (i) $0 = substr($0, 1, i-1) ENVIRON["NEW"] substr($0, i + length(ENVIRON["OLD"])); print }' "$1" > "$1.new"
  mv "$1.new" "$1"
}
patch_once "$BUILD/source/lex.h" \
  'auto labelized_position(token const* t)' \
  'inline int fuzz_label_ordinal = 0; struct fuzz_label { std::string text; fuzz_label() { text = std::to_string(++fuzz_label_ordinal); } }; inline auto fuzz_labels = std::unordered_map<token const*, fuzz_label const>{}; auto labelized_position(token const* t)'
patch_once "$BUILD/source/lex.h" \
  'static auto labels = std::unordered_map<token const*, label const>{};' \
  'auto& labels = fuzz_labels;'
patch_once "$BUILD/source/parse.h" \
  'static declaration_node const* last_parent_type = {};' \
  'auto& last_parent_type = fuzz_last_parent_type;'
patch_once "$BUILD/source/parse.h" \
  'inline static int         indent_spaces  = 2;' \
  'inline declaration_node const* fuzz_last_parent_type = {}; inline static int         indent_spaces  = 2;'

INC="-I$BUILD/source -I$BUILD/include -ffile-prefix-map=$BUILD/source=$SRC/source -ffile-prefix-map=$BUILD/include=$SRC/include"

# 1) fuzz harness + standalone reproducer, in mixed (default) and -pure-cpp2 modes.
#    -fsanitize=fuzzer-no-link puts SanCov on the library code regardless of $SANITIZER_FLAGS.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

pids=()
for mode in mixed pure; do
  if [ "$mode" = pure ]; then name=fuzz_cppfront_pure; def=-DPURE_CPP2; else name=fuzz_cppfront; def=; fi
  ( $CXX $CXXSTD -O1 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $INC $def \
        -c "$SRC/mayhem/fuzz_cppfront.cpp" -o "$BUILD/$name.o" \
    && $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$BUILD/$name.o" "$BUILD/lsan_off.o" -o "$OUT/$name" ) &
  pids+=($!)
  ( $CXX $CXXSTD -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $INC $def \
        -c "$SRC/mayhem/fuzz_cppfront.cpp" -o "$BUILD/$name-standalone.o" \
    && $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$BUILD/$name-standalone.o" "$BUILD/standalone_main.o" "$BUILD/lsan_off.o" \
        -o "$OUT/$name-standalone" ) &
  pids+=($!)
done

# 2) the test oracle: upstream's real compiler, NORMAL flags (no sanitizer, no -gdwarf-3, as the
#    project's own regression-tests/run-tests.sh builds it), for mayhem/test.sh to run.
( $CXX $CXXSTD $COVERAGE_FLAGS "$SRC/source/cppfront.cpp" -o "$BUILD/cppfront" ) &
pids+=($!)

rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
exit $rc
