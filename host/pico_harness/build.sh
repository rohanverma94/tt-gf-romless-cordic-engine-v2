#!/usr/bin/env bash
# build.sh — firmware for the Pico (RP2040) and Pico 2 (RP2350).
#   PICO_SDK_PATH=<pico-sdk 2.x> ./build.sh [pico|pico2 ...]   (default: both)
# Output: build-<board>/xcordic_harness.uf2 (hold BOOTSEL, plug in, copy it over).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${PICO_SDK_PATH:?set PICO_SDK_PATH to a pico-sdk 2.x checkout (with submodules: tinyusb)}"
boards=("$@"); [ ${#boards[@]} -eq 0 ] && boards=(pico pico2)
for b in "${boards[@]}"; do
    cmake -S "$here" -B "$here/build-$b" -DPICO_BOARD="$b" -DPICO_SDK_PATH="$PICO_SDK_PATH" ${XC_CMAKE_ARGS:-} > /dev/null
    cmake --build "$here/build-$b" -j"$(nproc 2>/dev/null || echo 4)"
    echo "$b: $here/build-$b/xcordic_harness.uf2"
done
