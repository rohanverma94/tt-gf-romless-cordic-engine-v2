#!/usr/bin/env bash
# run.sh — check the golden model (xc_model.hpp) against the RTL with Verilator.
#   ./run.sh [N]     N random rounds per two-operand op (default 200000)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../../src"
for g in 0 4; do
    d="$here/build/g$g"; mkdir -p "$d"
    verilator --cc --exe --build -j 0 -O3 -Wno-fatal -Wno-lint -Wno-style \
        --top-module xcordic_core -GGUARD=$g -GFUNCS=1 \
        -CFLAGS "-O2 -std=c++17 -DXC_GUARD=$g" -Mdir "$d" -o model_check \
        "$src/xc_exact.v" "$src/xcordic_core.v" "$src/xcordic_engine.v" "$src/xcordic_atan.v" "$src/xc_add.v" \
        "$here/model_check.cpp" > "$d/build.log" 2>&1 || { tail -30 "$d/build.log"; exit 1; }
    "$d/model_check" "${1:-200000}"
done
