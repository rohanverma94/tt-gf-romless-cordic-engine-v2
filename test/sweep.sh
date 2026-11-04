#!/usr/bin/env bash
# sweep.sh — SPI speed sweep at a 50 MHz core clock: original ttsky25a design
# vs tt_um_xcordic, both SPI modes, real-time master on its own timeline.
#   test/sweep.sh            (iverilog)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
NEW="src/project.v src/xc_spi_slave.v src/xc_spi_slave_sclk.v src/xc_meta.v src/xc_frame.v src/xc_bist.v src/xc_exact.v src/xcordic_core.v src/xcordic_engine.v src/xcordic_atan.v"
ORIG="third_party/ttsky_orig/project.v third_party/ttsky_orig/spi_slave.v third_party/ttsky_orig/top_fsm.v
      third_party/ttsky_orig/top_CORDIC_Engine_v1.v third_party/ttsky_orig/CORDIC_Engine_v1.v
      third_party/ttsky_orig/dynamic_atan.v src/xc_exact.v src/xcordic_core.v src/xcordic_engine.v src/xcordic_atan.v"
iverilog -g2012 -DG=4 -o build/tb_new test/tb_spi.v $NEW
iverilog -g2012 -DORIG -o build/tb_orig test/tb_spi.v $ORIG
N=${N:-50}
printf '%-26s %-6s %-22s %-22s\n' "SCLK high/low (MHz)" mode "original ttsky25a" "tt_um_xcordic"
for t in 100:100 80:87 60:70 60:60 50:50 40:43 30:33 25:25 20:22; do
    IFS=: read -r th tl <<< "$t"
    for m in 0 1; do
        o=$(vvp -n build/tb_orig +TH=$th +TL=$tl +CPHA=$m +N=$N | grep -o 'legacy: [0-9]* / [0-9]*' | sed 's/legacy: //')
        n=$(vvp -n build/tb_new  +TH=$th +TL=$tl +CPHA=$m +N=$N | grep -o 'legacy: [0-9]* / [0-9]*' | sed 's/legacy: //')
        printf '%-26s %-6s %-22s %-22s\n' "$th/$tl ns ($(awk "BEGIN{printf \"%.1f\", 1000/($th+$tl)}"))" $m "${o:-error} exact" "${n:-error} exact"
    done
done
