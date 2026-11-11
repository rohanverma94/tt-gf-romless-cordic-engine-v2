#!/bin/sh
# build.sh — bitstreams for xcordic_ku5p on the KU5P board (Vivado; the KU5P is
# in the free edition). Header pins: pins.tcl.
#
#   ./build.sh                  GUARD 4 (the GF26c build), 25 MHz
#   GUARD=0 ./build.sh          the ttsky25a 16-bit datapath
#   CLK_MHZ=40 ./build.sh       40 MHz core clock (then `fclk 40` in the harness)
#   ./build.sh all              the four of the ULX3S set: GUARD 4 and 0, 25 and 40 MHz
#   ./build.sh prog [file.bit]  load over USB JTAG (default: the GUARD/CLK_MHZ build)
#   LED_ACTIVE_LOW=1 ./build.sh if the LEDs come out inverted
#
# Results: prebuilt/xcordic_ku5p_g<guard>_<mhz>mhz.bit, reports in build/<name>/.
set -eu
cd "$(dirname "$0")"
VIVADO=${VIVADO:-vivado}
GUARD=${GUARD:-4}
CLK_MHZ=${CLK_MHZ:-25}
LEDN=${LED_ACTIVE_LOW:-0}
one() { $VIVADO -mode batch -nojournal -log "build/vivado_g$1_$2.log" -source build.tcl -tclargs "$1" "$2" "$LEDN"; }
mkdir -p build
case "${1:-build}" in
  build) one "$GUARD" "$CLK_MHZ" ;;
  all)   for g in 4 0; do for f in 25 40; do one $g $f; done; done ;;
  prog)  exec $VIVADO -mode batch -nojournal -nolog -source program.tcl \
              -tclargs "${2:-prebuilt/xcordic_ku5p_g${GUARD}_${CLK_MHZ}mhz.bit}" ;;
  *) echo "usage: $0 [build|all|prog [file.bit]]" >&2; exit 2 ;;
esac
