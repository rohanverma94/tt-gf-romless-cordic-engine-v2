#!/usr/bin/env bash
# formal/run.sh — proofs for the original ttsky25a standalone design (O*) and
# the corrected tt_um_xcordic (N*), plus the Xcordic core proofs (F2, F3).
#
#   ./run.sh                 everything
#   ./run.sh o1 n1           selected groups
#   JOBS=8 ./run.sh          parallel tasks (default nproc)
#
# o1  original SPI_Slave vs timed master: timing sweep (PASS/FAIL table)
# o2  original cordic_fsm protocol (contracts for SPI and CORDIC)
# n1  new xc_spi_slave vs timed master: timing sweep, multi-byte frames
# n1c new xc_spi_slave keeps the byte contract N2 assumes, for any inputs
# n1s SCLK-domain slave (SPI_SCLK = 1): bits, bytes, CDC safety at 66.7 MHz SCLK
#     with a 100 MHz core clock, multiclock time model
# g1  default slave at the Tiny Tapeout GF26c pads, through the GF I/O delays
#     (25 MHz core clock, 10 ns and 20 ns ticks), multiclock time model
# n2  new frame FSM (legacy + command protocols) with SPI and core contracts
# f2  Xcordic engine (GUARD 0 and 4), f3 Xcordic core (GUARD 0 and 4)
# f5  cordic.bist self-test unit (FUNCS 1 and 0)
# f6  exact mul/div/sqrt unit: contract, covers, result depends on the operands only
#     (its values: formal/exhaustive/exact.cpp, every operand)
# f4  original ttsky25a CORDIC engine and quadrant top
#
# Needs yosys, sby, yices-smt2, yosys-abc (OSS CAD Suite). The unbounded
# proofs use `abc pdr`; sby calls it as `pdr -v -l`, so sby and yosys-abc must
# come from the same release (the OSS CAD Suite bundles matching ones).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
B="$here/build"
SBY=${SBY:-sby}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$B/gen" "$B/logs"
summary="$B/summary.txt"
groups=("$@")
[ ${#groups[@]} -eq 0 ] && groups=(o1 o2 f4 n1 n1c n1s g1 n2 f2 f3 f5 f6)
want() { [[ " ${groups[*]} " =~ " $1 " ]]; }
# the summary keeps the results of groups not re-run now
touch "$summary"
awk -v g=" ${groups[*]} " 'NR > 1 && index(g, " " $1 " ") == 0' "$summary" > "$B/summary.keep"
: > "$summary"
note() { printf '%-4s %-40s %-8s %8s  %s\n' "$1" "$2" "$3" "$4" "$5" | tee -a "$summary"; }

prepare() {
    local I="$here/tools/inject.sh"
    "$I" "$root/third_party/ttsky_orig/spi_slave.v" SPI_Slave   o1_slave_props.vh "$B/gen/spi_slave_o1.v" &&
    "$I" "$root/third_party/ttsky_orig/top_fsm.v"   cordic_fsm  o2_fsm_props.vh   "$B/gen/top_fsm_o2.v" &&
    "$I" "$root/src/xc_spi_slave.v"                 xc_spi_slave n1_slave_props.vh "$B/gen/xc_spi_slave_n1.v" &&
    "$I" "$root/src/xc_spi_slave.v"                 xc_spi_slave n1c_contract_props.vh "$B/gen/xc_spi_slave_n1c.v" &&
    "$I" "$root/src/xc_spi_slave_sclk.v"            xc_spi_slave_sclk n1s_slave_props.vh "$B/gen/xc_spi_slave_sclk_n1s.v" &&
    "$I" "$root/src/xc_spi_slave.v"                 xc_spi_slave g1_slave_props.vh "$B/gen/xc_spi_slave_g1.v" &&
    "$I" "$root/third_party/ttsky_orig/CORDIC_Engine_v1.v"     CORDIC_Engine_v1     ttsky_engine_props.vh "$B/gen/CORDIC_Engine_v1_fv.v" &&
    "$I" "$root/third_party/ttsky_orig/top_CORDIC_Engine_v1.v" top_CORDIC_Engine_v1 ttsky_top_props.vh    "$B/gen/top_CORDIC_Engine_v1_fv.v" ||
    { echo "prepare failed"; exit 1; }
    (cd "$here/sby" && ./gen_o1.sh orig > o1_spi.sby && ./gen_o1.sh new > n1_spi.sby && ./gen_n1s.sh > n1s_spi.sby && ./gen_g1.sh > g1_spi.sby) || exit 1
}

tasks_of() { sed -n '/^\[tasks\]/,/^$/p' "$here/sby/$1.sby" | awk 'NR > 1 && NF { print $1 }'; }

run_sby() {   # <group> <sby-name> [expect-file]
    local g=$1 f=$2 t
    local ts; mapfile -t ts < <(tasks_of "$f")
    printf '%s\n' "${ts[@]}" | xargs -P "$JOBS" -I{} sh -c \
        "cd '$here/sby' && rm -rf '${f}_{}' && $SBY -f '$f.sby' '{}' > '$B/logs/${g}_{}.log' 2>&1" || true
    for t in "${ts[@]}"; do
        [ -f "$here/sby/${f}_$t/status" ] && continue
        (cd "$here/sby" && rm -rf "${f}_$t" && $SBY -f "$f.sby" "$t" > "$B/logs/${g}_$t.log" 2>&1) || true
    done
    for t in "${ts[@]}"; do
        local st="ERROR" secs="" where=""
        [ -f "$here/sby/${f}_$t/status" ] && st=$(awk '{print $1}' "$here/sby/${f}_$t/status")
        secs=$(grep -o 'Elapsed clock time \[H:MM:SS (secs)\]: [0-9:]* ([0-9]*)' "$here/sby/${f}_$t/logfile.txt" 2>/dev/null |
               grep -o '([0-9]*)' | tr -d '()' | tail -1)
        where=$(grep -o 'failed assertion.*' "$here/sby/${f}_$t/logfile.txt" 2>/dev/null | head -1 |
                sed 's/.*at \([^ ]*\) step \([0-9]*\)/\1 step \2/')
        note "$g" "$f:$t" "$st" "${secs:-?}s" "$where"
    done
}

prepare
printf '%-4s %-40s %-8s %8s  %s\n' grp proof result time note | tee -a "$summary"
cat "$B/summary.keep" >> "$summary"; rm -f "$B/summary.keep"
want o1 && run_sby o1 o1_spi
want o2 && run_sby o2 o2_fsm
want f4 && run_sby f4 f4_silicon
want n1 && run_sby n1 n1_spi
want n1c && run_sby n1c n1c_contract
want n1s && run_sby n1s n1s_spi
want g1 && run_sby g1 g1_spi
want n2 && run_sby n2 n2_top
want f2 && run_sby f2 f2_engine
want f3 && run_sby f3 f3_core
want f5 && run_sby f5 f5_bist
want f6 && run_sby f6 f6_exact
echo
echo "summary: $summary (O1/N1 sweeps are characterizations: FAIL marks a timing that does not work)"
