#!/usr/bin/env bash
# run_exact.sh — exhaustive check of src/xc_exact.v: every operand of
# mul and div (2^32 pairs each) and sqrt (2^16), RTL (Verilator) against exact
# integer arithmetic (exact.cpp). About 85 min per op on one core.
#   ./run_exact.sh            smoke (seconds), then sqrt, mul and div in parallel
#   ./run_exact.sh smoke      corners, every sqrt input, 2M random pairs
#   PARTS=4 ./run_exact.sh    split mul and div into 4 parts each (more cores)
# Results: formal/build/exact_{smoke,sqrt,mul,div}*.txt; exit 1 on any mismatch.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
B="$here/build/exact"; out="$here/../build"
mkdir -p "$B" "$out"
verilator --cc --exe --build -O3 --Mdir "$B" -CFLAGS "-O2 -march=native" \
    "$root/src/xc_exact.v" "$here/exact.cpp" -o exact > "$B/build.log" 2>&1 ||
    { tail -20 "$B/build.log"; exit 1; }
"$B/exact" smoke | tee "$out/exact_smoke.txt" | tail -2 || exit 1
[ "${1:-}" = smoke ] && exit 0
"$B/exact" sqrt > "$out/exact_sqrt.txt"; tail -1 "$out/exact_sqrt.txt"
P=${PARTS:-1}; pids=()
for op in mul div; do
    for ((i = 0; i < P; i++)); do
        f="$out/exact_$op.txt"; [ "$P" -gt 1 ] && f="$out/exact_${op}_$i.txt"
        "$B/exact" "$op" "$i" "$P" > "$f" 2>&1 & pids+=($!)
    done
done
bad=0; for p in "${pids[@]}"; do wait "$p" || bad=1; done
tail -qn1 "$out"/exact_mul*.txt "$out"/exact_div*.txt
[ $bad = 0 ] && echo "EXACT UNIT: every operand bit-exact" || { echo "EXACT UNIT: MISMATCHES"; exit 1; }
