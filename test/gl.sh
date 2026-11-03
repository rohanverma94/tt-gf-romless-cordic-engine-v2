#!/usr/bin/env bash
# gl.sh — gate-level cocotb test (test.py) on gf180mcuD netlists, locally,
# before the GDS flow. The Tiny Tapeout GDS action runs the same test.py on the
# hardened netlist (`make GATES=yes`, see .github/workflows); this one needs no
# layout.
#
#   test/gl.sh                synthesize both builds (tools/sta.sh, SYNTH_ONLY)
#                             and run test.py on each netlist
#   SPI_SCLK_LIST=0 test/gl.sh   only the default build
#   NETLIST=<file> test/gl.sh    run one given Yosys netlist (no power pins)
#
# Needs yosys, iverilog, cocotb and the gf180mcuD cell models:
# $PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog/{primitives.v,
# gf180mcu_fd_sc_mcu7t5v0.v} (PDK_ROOT defaults to ~/.volare, as tools/sta.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
root=$PWD
cells=${PDK_ROOT:-$HOME/.volare}/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog
for f in primitives.v gf180mcu_fd_sc_mcu7t5v0.v; do
    [ -f "$cells/$f" ] || { echo "cell model not found: $cells/$f (set PDK_ROOT)"; exit 1; }
done
CELLS="$cells/primitives.v $cells/gf180mcu_fd_sc_mcu7t5v0.v"

if [ -n "${NETLIST:-}" ]; then
    runs="x:$(realpath "$NETLIST")"
else
    runs=""
    for s in ${SPI_SCLK_LIST:-0 1}; do
        SYNTH_ONLY=1 SPI_SCLK_LIST=$s tools/sta.sh > /dev/null
        runs="$runs $s:$root/build/sta/xcordic_sclk$s.v"
    done
fi

fail=0
for r in $runs; do
    s=${r%%:*}; nl=${r#*:}
    log=$root/build/gl_sclk$s.log
    ( cd test && make -s -B GATES=pre CELLS="$CELLS" NETLIST="$nl" SIM_BUILD=sim_build/gl_pre_$s ) > "$log" 2>&1 || true
    res=$(grep -E "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+" "$log" | tail -1 | grep -oE "TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+" || echo "no result")
    echo "gate level, $( [ "$s" = x ] && basename "$nl" || echo "SPI_SCLK=$s" ): $res   ($log)"
    echo "$res" | grep -q " FAIL=0" || fail=1
done
[ $fail = 0 ] && echo "GATE-LEVEL TESTS PASS" || { echo "GATE-LEVEL TEST FAILURES"; exit 1; }
