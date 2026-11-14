#!/usr/bin/env bash
# run.sh — build the RTL simulator of the harness and run its matrix.
#   ./run.sh                 the matrix below (both slave builds, both GUARDs,
#                            50 and 100 MHz chip clocks, PIO and hardware SPI)
#   ./run.sh build           only build
#   B=<dir>/sim_main <args>  run one configuration (see sim_main.cpp)
# Needs verilator (5.x) and a C++17 compiler.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../../src"
build() {   # <GUARD> <SPI_SCLK>
    local d="$here/build/g$1_s$2"
    mkdir -p "$d"
    if [ ! -x "$d/sim_main" ] || [ -n "$(find "$here/../src" "$here/../xc_model.hpp" "$here/sim_main.cpp" "$src" -newer "$d/sim_main" 2>/dev/null | head -1)" ]; then
        verilator --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-lint -Wno-style -Wno-MULTIDRIVEN \
            --top-module tt_um_xcordic -GGUARD=$1 -GSPI_SCLK=$2 -GTIMEOUT_LOG2=16 -GFUNCS=1 \
            -CFLAGS "-O2 -std=c++17 -DXC_SPI_SCLK=$2 -DXC_TIMEOUT_LOG2=16" -Mdir "$d" -o sim_main \
            "$src"/project.v "$src"/xc_spi_slave.v "$src"/xc_spi_slave_sclk.v "$src"/xc_meta.v \
            "$src"/xc_frame.v "$src"/xc_bist.v "$src"/xc_exact.v "$src"/xcordic_core.v "$src"/xcordic_engine.v "$src"/xcordic_atan.v "$src"/xc_add.v \
            "$here/sim_main.cpp" "$here/../src/suites.cpp" > "$d/build.log" 2>&1 || { tail -40 "$d/build.log"; exit 1; }
    fi
    echo "$d/sim_main"
}
for g in 4 0; do for s in 0 1; do build $g $s > /dev/null; done; done
[ "${1:-}" = build ] && exit 0

fail=0
run() {     # <name> <GUARD> <SPI_SCLK> <args...>
    local name=$1 g=$2 s=$3; shift 3
    local log="$here/build/$name.log"
    if "$here/build/g${g}_s${s}/sim_main" "$@" > "$log" 2>&1; then r=PASS; else r=FAIL; fail=1; fi
    printf '%-44s %s   %s\n' "$name" "$r" "$(grep -E '^(CSV,legacy|  ttsky25a harness metric)' "$log" | head -1 | sed 's/^ *//')"
}
# full regression (stride-sampled accuracy) on each build
# GF26c: 25 MHz, 6.25 MHz SCLK, I/O at the GF26c signoff limits plus ~4 ns of board
# (pad->port 5 ns + 4, port->pad 12.5 ns + 4.5), plain master (MISO read on the edge)
run reg_g4_s0_25MHz_6MHz_m0_gf      4 0 --fclk 25  --sclk 6.25 --din 9 --dout 17 --mode 0 regression
run gf_g4_s0_25MHz_6MHz_m1_edge     4 0 --fclk 25  --sclk 6.25 --din 9 --dout 17 --sample 0 --mode 1 identify bitexact protocol
run gf_g4_s0_25MHz_6MHz_m0_cal      4 0 --fclk 25  --sclk 6.25 --din 9 --dout 17 --mode 0 identify calibrate bitexact
run reg_g4_s0_50MHz_10MHz_m0        4 0 --fclk 50  --sclk 10 --mode 0 regression perf
run reg_g4_s0_50MHz_10MHz_m1        4 0 --fclk 50  --sclk 10 --mode 1 regression
run reg_g0_s0_50MHz_10MHz_m0        0 0 --fclk 50  --sclk 10 --mode 0 regression
run reg_g4_s1_50MHz_10MHz_m0        4 1 --fclk 50  --sclk 10 --mode 0 regression
run reg_g0_s1_50MHz_10MHz_m1        0 1 --fclk 50  --sclk 10 --mode 1 regression
# fast links
run fast_g4_s0_100MHz_25MHz_m0      4 0 --fclk 100 --sclk 25 --fsys 300 --mode 0 --sample 20 identify bitexact protocol
run fast_g4_s1_66MHz_66MHz_m0       4 1 --fclk 66.5 --sclk 66.7 --fsys 300 --mode 0 --sample 18 identify bitexact protocol
run fast_g4_s1_66MHz_66MHz_m1_cal   4 1 --fclk 66.5 --sclk 66.7 --fsys 300 --mode 1 identify calibrate bitexact
run fast_g0_s1_50MHz_50MHz_m0_cal   0 1 --fclk 50 --sclk 50 --fsys 300 --mode 0 identify calibrate bitexact legacy
run fast_g4_s0_50MHz_12MHz_m1_cal   4 0 --fclk 50 --sclk 12.5 --mode 1 identify calibrate bitexact
run shmoo_g4_s0_50MHz               4 0 --fclk 50 --sclk 4 identify shmoo
run shmoo_g4_s0_100MHz              4 0 --fclk 100 --sclk 16 --fsys 300 identify shmoo
run shmoo_g4_s1_50MHz               4 1 --fclk 50 --sclk 10 --fsys 300 identify shmoo
run hwspi_g4_s0_50MHz_8MHz_m1       4 0 --fclk 50  --sclk 8  --hw --mode 1 identify bitexact legacy
run hwspi_g4_s1_50MHz_16MHz_m0      4 1 --fclk 50  --sclk 16 --hw --mode 0 identify bitexact
run legacy8_g0_s0                   0 0 --fclk 50  --sclk 10 identify legacy8
exit $fail
