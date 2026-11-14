#!/usr/bin/env bash
# run_pairs.sh — exhaustive two-operand run (pairs.cpp): all 2^32 pairs of
# atan2, hypot, mul, div on the RTL, against exact values and the Pico
# harness's golden model. Resumable; one state file per GUARD.
#
#   ./run_pairs.sh                    build, run GUARD 4 then 0 with all cores, report
#   ./run_pairs.sh 4                  only GUARD 4
#   J=8 HOURS=6 ./run_pairs.sh 4      8 threads, stop after 6 h (rerun to resume)
#   PART=0/2 ./run_pairs.sh 4         half the blocks (other machine: PART=1/2);
#                                     then cat the state files and --report them
#   ./run_pairs.sh report             report what the state files hold
#   ./run_pairs.sh unary              the one-operand functions (all inputs, ~1 min)
#   FN=atan2,hypot ./run_pairs.sh 4   only these functions
#   ADD=plus ./run_pairs.sh 4         with src/xc_add.v replaced by a + b + ci
#                                     (xc_add_plus.v; equal by F7), about 5 times
#                                     faster; own build and state files (pairs_plus_*)
#
# Needs verilator 5.x and g++. Runtime for GUARD 4, 1.7e10 instructions, on 2
# cores: about 30 h as is, about 6 h with ADD=plus.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../src"
B="$here/build"
mkdir -p "$B"
build() {
    local g=$1 d="$B/${TAG}_g$1"
    if [ ! -x "$d/pairs" ] || [ -n "$(find "$src" "$here/pairs.cpp" "$here/xc_model.hpp" -newer "$d/pairs" | head -1)" ]; then
        verilator --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-lint -Wno-style \
            --top-module xcordic_core -GGUARD=$g -GFUNCS=1 \
            -CFLAGS "-O3 -march=native -std=c++17 -DXC_GUARD=$g" -LDFLAGS -pthread -Mdir "$d" -o pairs \
            "$src/xc_exact.v" "$src/xcordic_core.v" "$src/xcordic_engine.v" "$src/xcordic_atan.v" "${ADDER[@]}" "$here/pairs.cpp" \
            > "$d.log" 2>&1 || { tail -30 "$d.log"; exit 1; }
    fi
}
J=${J:-$(nproc)}
if [ "${ADD:-}" = plus ]; then TAG=pairs_plus; ADDER=("$here/xc_add_plus.v"); else TAG=pairs; ADDER=("$here/xc_add.vlt" "$src/xc_add.v"); fi
PFX=${STATE_PREFIX:-$TAG}
case "${1:-all}" in
    report) shift; "$B/${TAG}_g4/pairs" --report "$B"/${PFX}_g*.state ${@:+"$@"}; exit $? ;;
    unary)  for g in 4 0; do build $g; "$B/${TAG}_g$g/pairs" --unary; done; exit 0 ;;
    all)    guards="4 0" ;;
    *)      guards="$1" ;;
esac
for g in $guards; do
    build "$g"
    args=(-j"$J" --state "$B/${PFX}_g$g.state")
    [ -n "${FN:-}" ] && args+=(--fn "$FN")
    [ -n "${PART:-}" ] && args+=(--part "$PART")
    [ -n "${HOURS:-}" ] && args+=(--hours "$HOURS")
    "$B/${TAG}_g$g/pairs" "${args[@]}"
done
build 4
"$B/${TAG}_g4/pairs" --report "$B"/${PFX}_g*.state
