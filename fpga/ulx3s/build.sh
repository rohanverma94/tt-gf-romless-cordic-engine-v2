#!/bin/sh
# build.sh — bitstream for xcordic_ulx3s on a ULX3S 85F (open toolchain:
# yosys, nextpnr-ecp5, ecppack from Project Trellis; ecppll for CLK_MHZ).
#
#   ./build.sh                  GUARD 4 (the GF26c build), 25 MHz from the oscillator
#   GUARD=0 ./build.sh          the ttsky25a 16-bit datapath
#   CLK_MHZ=50 ./build.sh       core clock from the PLL (then `fclk 50` in the harness)
#   ./build.sh prog             load into SRAM (openFPGALoader), lost at power-off
#   ./build.sh flash            write to the board's SPI flash
#
# Tools can be overridden: YOSYS=... NEXTPNR=... ECPPACK=... ECPPLL=... LOADER=...
# The OSS CAD Suite (github.com/YosysHQ/oss-cad-suite-build) has all of them.
set -eu
cd "$(dirname "$0")"

GUARD=${GUARD:-4}
CLK_MHZ=${CLK_MHZ:-25}
YOSYS=${YOSYS:-yosys}
NEXTPNR=${NEXTPNR:-nextpnr-ecp5}
ECPPACK=${ECPPACK:-ecppack}
ECPPLL=${ECPPLL:-ecppll}
LOADER=${LOADER:-openFPGALoader}
B=build
BIT=$B/xcordic_ulx3s.bit

case "${1:-build}" in
  prog)  exec $LOADER -b ulx3s "$BIT" ;;
  flash) exec $LOADER -b ulx3s -f "$BIT" ;;
  build) ;;
  *) echo "usage: $0 [build|prog|flash]" >&2; exit 2 ;;
esac

SRC=../../src
RTL="$SRC/project.v $SRC/xc_spi_slave.v $SRC/xc_spi_slave_sclk.v $SRC/xc_meta.v $SRC/xc_frame.v"
RTL="$RTL $SRC/xc_bist.v $SRC/xc_exact.v $SRC/xcordic_core.v $SRC/xcordic_engine.v $SRC/xcordic_atan.v $SRC/xc_add.v"
mkdir -p $B

DEFS="-DXC_GUARD=$GUARD"
EXTRA=""
if [ "$CLK_MHZ" != 25 ]; then
    $ECPPLL -i 25 -o "$CLK_MHZ" -n xc_pll -f $B/pll.v > $B/pll.log
    grep -i "output freq\|achieved" $B/pll.log || true
    DEFS="$DEFS -DUSE_PLL"
    EXTRA=$B/pll.v
fi

echo "== yosys (GUARD=$GUARD)"
$YOSYS -q -l $B/yosys.log -p "read_verilog $DEFS xcordic_ulx3s.v $EXTRA $RTL; synth_ecp5 -top xcordic_ulx3s -json $B/xcordic_ulx3s.json"
grep -A40 "Printing statistics" $B/yosys.log | grep -E "LUT4|TRELLIS_FF|CCU2C|MULT18|DP16KD" || true

echo "== nextpnr-ecp5 (LFE5U-85F, CABGA381, core clock $CLK_MHZ MHz)"
$NEXTPNR --85k --package CABGA381 --speed 6 --freq "$CLK_MHZ" --lpf ulx3s.lpf \
    --json $B/xcordic_ulx3s.json --textcfg $B/xcordic_ulx3s.config \
    --report $B/report.json --log $B/nextpnr.log -q
grep -E "Max frequency for clock|Info: +(TRELLIS_SLICE|TRELLIS_IO|MULT18X18D):" $B/nextpnr.log | tail -6 || true

echo "== ecppack"
$ECPPACK --compress $B/xcordic_ulx3s.config "$BIT"
echo "wrote $BIT  (load it with: ./build.sh prog)"
