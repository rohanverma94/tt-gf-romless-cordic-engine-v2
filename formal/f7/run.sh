#!/usr/bin/env bash
# f7/run.sh — F7 combinational equivalence by SAT (yosys `sat -prove`, every input).
#   F7a: xc_add (Kogge-Stone) == a + b + ci, for every width the design uses
#   F7b: the two-stage angle generator (aterms + asum) == xcordic_aval, every mode/shift
# Usage: formal/f7/run.sh   (needs yosys on PATH). Log: formal/build/f7.log
set -uo pipefail
cd "$(dirname "$0")"; here=.; src=../../src; log=../build/f7.log   # relative paths: some yosys builds mis-read long absolute ones
: > "$log"; rc=0
chk() {  # <label> <yosys script>
  if yosys -q -p "$2" >> "$log.raw" 2>&1; then echo "$1: PASS" | tee -a "$log"; else echo "$1: FAIL" | tee -a "$log"; rc=1; fi
}
: > "$log.raw"
for W in 2 3 5 16 17 19 20 21 24 46; do
  chk "F7a xc_add W=$W" "read_verilog $src/xc_add.v $here/add_eq.v; chparam -set W $W add_eq; prep -top add_eq; flatten; sat -prove ok 1 -verify -show-ports"
done
for p in "16 0" "20 4"; do set -- $p
  chk "F7b angle generator W=$1 GUARD=$2" "read_verilog $src/xcordic_atan.v $src/xc_add.v $here/aval_eq.v; chparam -set DATA_WIDTH $1 -set GUARD $2 aval_eq; prep -top aval_eq; flatten; sat -prove ok 1 -verify"
done
exit $rc
