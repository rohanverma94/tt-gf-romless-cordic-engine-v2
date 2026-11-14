#!/usr/bin/env bash
# run.sh — build both units with Verilator and compare them (GUARD 4 and 0)
#   ./run.sh [random_count] [seed]   (reference: equiv/ref/, current: src/)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
FILES="xc_bist.v xcordic_core.v xcordic_engine.v xcordic_atan.v xc_exact.v"
for G in ${GLIST:-4 0}; do
    b=$here/build_g$G; mkdir -p $b
    ref=""; new=""
    for f in $FILES; do ref="$ref $here/ref/$f"; new="$new $root/src/$f"; done
    [ -f $here/ref/xc_add.v ] && ref="$ref $here/ref/xc_add.v"
    [ -f $root/src/xc_add.v ] && new="$new $root/src/xc_add.v"
    verilator -O3 --cc --prefix Vref --top-module eq_unit -GGUARD=$G -Wno-fatal -Wno-lint -Wno-style --Mdir $b/ref $here/eq_unit.v $ref > $b/vl_ref.log 2>&1
    verilator -O3 --cc --prefix Vnew --top-module eq_unit -GGUARD=$G -Wno-fatal -Wno-lint -Wno-style --Mdir $b/new $here/eq_unit.v $new > $b/vl_new.log 2>&1
    make -s -C $b/ref -f Vref.mk OPT_FAST=-O2 > /dev/null
    make -s -C $b/new -f Vnew.mk OPT_FAST=-O2 > /dev/null
    VI=$(dirname $(dirname $(command -v verilator)))/share/verilator/include
    [ -d $VI ] || VI=/usr/share/verilator/include
    g++ -O2 -std=c++17 -I$b/ref -I$b/new -I$VI -I$VI/vltstd $here/equiv.cpp $b/ref/Vref__ALL.a $b/new/Vnew__ALL.a \
        $VI/verilated.cpp $VI/verilated_threads.cpp -o $b/equiv -pthread
    echo "== GUARD $G"
    $b/equiv "$@"
done
