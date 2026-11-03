#!/usr/bin/env bash
# run.sh — simulation regression (iverilog, no Python): tt_um_xcordic for
# GUARD 0 and 4, both SPI modes, both SPI slaves (SPI_SCLK = 0/1), one-byte and multi-byte frames, the ttsky25a
# harness sweep and random instructions, all bit-exact against a reference
# xcordic_core; the original design at a speed it supports; then the SPI speed
# sweep (sweep.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
NEW="src/project.v src/xc_spi_slave.v src/xc_spi_slave_sclk.v src/xc_meta.v src/xc_frame.v src/xcordic_core.v src/xcordic_engine.v src/xcordic_atan.v"
ORIG="third_party/ttsky_orig/project.v third_party/ttsky_orig/spi_slave.v third_party/ttsky_orig/top_fsm.v
      third_party/ttsky_orig/top_CORDIC_Engine_v1.v third_party/ttsky_orig/CORDIC_Engine_v1.v
      third_party/ttsky_orig/dynamic_atan.v src/xcordic_core.v src/xcordic_engine.v src/xcordic_atan.v"
fail=0
for g in 0 4; do
    iverilog -g2012 -DG=$g -o build/tb_g$g test/tb_spi.v $NEW
    for m in 0 1; do for multi in 0 1; do
        out=$(vvp -n build/tb_g$g +TH=40 +TL=43 +CPHA=$m +MULTI=$multi +N=${N:-250} +CMD=${CMD:-1000})
        r=$(echo "$out" | grep RESULT)
        printf 'GUARD=%s mode %s %-14s 12 MHz: %s\n' $g $m "$([ $multi = 1 ] && echo multi-byte || echo byte-per-CS)" "$r"
        echo "$out" | grep -q "RESULT: .* 0 errors" || { fail=1; echo "$out" | grep -v RESULT | head; }
    done; done
done
# the corner N2 found: one byte per CS frame, CS raised right after the last
# edge and low again ~1 core clock later (failed 18/20 before the fix)
r=$(vvp -n build/tb_g4 +CPHA=1 +TH=40 +TL=43 +TT=18 +TG=16 +N=50 | grep RESULT)
echo "GUARD=4 mode 1 byte-per-CS, CS hold 18 ns, gap 16 ns: $r"
echo "$r" | grep -q " 0 errors" || fail=1
# SPI_SCLK = 1: SCLK-domain slave, 100 MHz core clock, 66.7 MHz SCLK (7/8 ns),
# CS setup 35 ns (>= 3 core clocks), CS gap 60 ns, CS hold 10 ns
iverilog -g2012 -DG=4 -DCLKP=10 -DSCLKDOM -o build/tb_sclk test/tb_spi.v $NEW
for m in 0 1; do for multi in 0 1; do
    out=$(vvp -n build/tb_sclk +TH=7 +TL=8 +TS=35 +TT=10 +TG=60 +CPHA=$m +MULTI=$multi +N=${N:-250} +CMD=${CMD:-1000})
    r=$(echo "$out" | grep RESULT)
    printf 'SPI_SCLK=1 mode %s %-14s 66.7 MHz SCLK, 100 MHz clk: %s\n' $m "$([ $multi = 1 ] && echo multi-byte || echo byte-per-CS)" "$r"
    echo "$out" | grep -q "RESULT: .* 0 errors" || { fail=1; echo "$out" | grep -v RESULT | head; }
done; done
# pauses between the bytes of a frame (the bug N1S found in the first version
# of xc_spi_slave_sclk: it took the next byte too late), both slaves
for m in 0 1; do
    r=$(vvp -n build/tb_sclk +TH=7 +TL=8 +TS=35 +TT=10 +TG=60 +TP=100 +CPHA=$m +MULTI=1 +N=50 +CMD=200 | grep RESULT)
    echo "SPI_SCLK=1 mode $m multi-byte, 100 ns pause between bytes: $r"; echo "$r" | grep -q " 0 errors" || fail=1
    r=$(vvp -n build/tb_g4 +TH=40 +TL=43 +TP=300 +CPHA=$m +MULTI=1 +N=50 +CMD=200 | grep RESULT)
    echo "SPI_SCLK=0 mode $m multi-byte, 300 ns pause between bytes: $r"; echo "$r" | grep -q " 0 errors" || fail=1
done
# default slave at a 100 MHz core clock, SCLK = clk/4 = 25 MHz, through a model
# of the Tiny Tapeout I/O (10 ns in, 10 ns out, 2 ns MOSI skew): the master must
# sample MISO late (+SD=20 ns); 10 core-clock phase alignments
iverilog -g2012 -DG=4 -DCLKP=10 -DIO_IN=10 -DIO_OUT=10 -DIO_SKEW=2 -o build/tb_io test/tb_spi.v $NEW
for m in 0 1; do
    e=0
    for ph in 0 1 2 3 4 5 6 7 8 9; do
        vvp -n build/tb_io +TH=20 +TL=20 +TS=40 +TT=20 +TG=60 +SD=20 +CPHA=$m +MULTI=1 +N=8 +CMD=30 +PH=$ph | grep -q "RESULT: .* 0 errors" || e=1
    done
    echo "SPI_SCLK=0 mode $m, 100 MHz clk, 25 MHz SCLK, TT I/O, 20 ns read delay, 10 phases: $([ $e = 0 ] && echo pass || echo FAIL)"
    [ $e = 0 ] || fail=1
done
# GF26c: 25 MHz core clock, 6.25 MHz SCLK (80/80 ns), CS setup 120 ns, CS high
# 240 ns, the GF26c I/O budget (in 5 ns, out 13 ns; and in 1 ns with MOSI 4 ns
# later), a plain master (MISO read on its edge), 20 phase alignments over a clock
for io in "5 13 0" "1 13 4"; do
    set -- $io
    iverilog -g2012 -DG=4 -DCLKP=40 -DIO_IN=$1 -DIO_OUT=$2 -DIO_SKEW=$3 -o build/tb_gf test/tb_spi.v $NEW
    for m in 0 1; do
        e=0
        for ph in $(seq 0 2 38); do
            vvp -n build/tb_gf +TH=80 +TL=80 +TS=120 +TT=80 +TG=240 +SD=0 +CPHA=$m +MULTI=1 +N=8 +CMD=30 +PH=$ph | grep -q "RESULT: .* 0 errors" || e=1
        done
        echo "GF26c: SPI_SCLK=0 mode $m, 25 MHz clk, 6.25 MHz SCLK, I/O in $1 ns (MOSI +$3) out $2 ns, read on the edge, 20 phases: $([ $e = 0 ] && echo pass || echo FAIL)"
        [ $e = 0 ] || fail=1
    done
done
iverilog -g2012 -DORIG -o build/tb_orig test/tb_spi.v $ORIG
r=$(vvp -n build/tb_orig +TH=100 +TL=100 +CPHA=0 +N=${N:-250} | grep RESULT)
echo "original ttsky25a, mode 0, 5 MHz (bit-exact vs the proven-equivalent xcordic_core): $r"
echo "$r" | grep -q " 0 errors" || fail=1
echo; N=40 test/sweep.sh
[ $fail = 0 ] && echo "ALL SIMULATIONS PASS" || { echo "SIMULATION FAILURES"; exit 1; }
