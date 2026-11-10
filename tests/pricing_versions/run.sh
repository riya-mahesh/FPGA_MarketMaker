#!/bin/sh
# Checks every pricing version. Run from the repository root:
#   sh tests/pricing_versions/run.sh
# 1. rtl/pricing.sv matches pricing_v3_precompute.sv
# 2. make test-holes
# 3. make verify with each version in place of rtl/pricing.sv
# 4. each version matches the original on random inputs; a broken V3 is caught
set -u
cd "$(dirname "$0")/../.."
export PATH="$(pwd)/tools/oss-cad-suite/bin:$PATH"

VERSIONS=rtl/pricing_versions
WORK=build/pricing_versions
mkdir -p "$WORK"
status=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; status=1; }

# The design's source list, as the Makefile defines it.
RTL_SOURCES=$(printf 'print-rtl:\n\t@echo $(RTL_SOURCES)\n' | make -s -f Makefile -f - print-rtl)

echo "== 1. rtl/pricing.sv is version 3"
if cmp -s rtl/pricing.sv "$VERSIONS/pricing_v3_precompute.sv"; then
    pass "rtl/pricing.sv matches pricing_v3_precompute.sv"
else
    fail "rtl/pricing.sv differs from pricing_v3_precompute.sv"
fi

echo "== 2. Module unit tests"
if make -s test-holes > "$WORK/test-holes.log" 2>&1; then
    pass "make test-holes ($(grep -c '^PASS' "$WORK/test-holes.log") tests)"
else
    grep '^FAIL' "$WORK/test-holes.log"
    fail "make test-holes (see $WORK/test-holes.log)"
fi

echo "== 3. Whole design with each pricing version (make verify)"
for file in "$VERSIONS"/pricing_v*.sv; do
    name=$(basename "$file" .sv)
    # Verilator wants the file named after its module.
    mkdir -p "$WORK/$name"
    cp "$file" "$WORK/$name/pricing.sv"
    sources=$(echo "$RTL_SOURCES" | sed "s|rtl/pricing.sv|$WORK/$name/pricing.sv|")
    log="$WORK/$name.verify.log"
    if make -s BUILD="build/$name" RTL_SOURCES="$sources" verify > "$log" 2>&1; then
        pass "$name: make verify ($(grep -c '^PASS' "$log") fixtures)"
    else
        grep '^FAIL' "$log"
        fail "$name: make verify (see $log)"
    fi
done

echo "== 4. Equivalence with the original on random inputs"
# The original, renamed to sit beside the version under test.
sed 's/^module pricing$/module pricing_ref/' "$VERSIONS/pricing_v0_original.sv" > "$WORK/pricing_ref.sv"
# A broken V3 (ask on the wrong tick) that must be caught.
sed 's/exact\[j\] ? mid_ask\[j\] : mid_ask\[j + 1\]/exact[j] ? mid_ask[j + 1] : mid_ask[j]/' \
    "$VERSIONS/pricing_v3_precompute.sv" > "$WORK/pricing_v3_broken.sv"

# build <name> <file> <latency>
build() {
    verilator --cc --exe --build -j 0 -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL \
        -GLATENCY="$3" -CFLAGS "-std=c++20 -O2" --top-module pricing_equiv \
        -Mdir "$WORK/$1" -o equiv \
        rtl/config_pkg.sv rtl/messages_pkg.sv rtl/pipeline_pkg.sv \
        "$WORK/pricing_ref.sv" "$2" tests/pricing_versions/pricing_equiv.sv \
        "$(pwd)/tests/pricing_versions/equiv_main.cpp" > "$WORK/$1.build.log" 2>&1 \
        || { fail "$1: build (see $WORK/$1.build.log)"; return 1; }
}
# check <name> <mode> <expect: match|mismatch>
check() {
    if "$WORK/$1/equiv" "$2"; then result=match; else result=mismatch; fi
    if [ "$result" = "$3" ]; then pass "$1, credit $2: $result, as expected"
    else fail "$1, credit $2: $result, expected $3"; fi
}

# V0 against itself: harness sanity check.
build v0 "$VERSIONS/pricing_v0_original.sv" 1 && check v0 every-cycle match
# V1 reads credit a cycle late, so only steady credit applies (as in the real system).
build v1 "$VERSIONS/pricing_v1_pipelined.sv" 2 && check v1 between-items match
# V2 and V3 sample credit with the item, so either mode must match.
build v2 "$VERSIONS/pricing_v2_onehot.sv" 2 && {
    check v2 between-items match; check v2 every-cycle match; }
build v3 "$VERSIONS/pricing_v3_precompute.sv" 2 && {
    check v3 between-items match; check v3 every-cycle match; }
build v3_broken "$WORK/pricing_v3_broken.sv" 2 && check v3_broken between-items mismatch

echo
[ $status -eq 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $status
