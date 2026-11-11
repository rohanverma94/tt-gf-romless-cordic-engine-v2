# Xcordic on the KU5P board

`tt_um_xcordic` on the XCKU5P-2FFVB676I board, for bring-up with the Pico harness. It is the same project as `../ulx3s`: the RTL in `src/` is unchanged, the wrapper only adds the clock, the reset and the pins.

## Before the first build

- **Check VADJ is still 1.8 V.** The 50 MHz oscillator is on E18 in bank 67, which runs from VADJ; the constraint is `LVCMOS18`.

## Wiring (40-pin header J7, 3.3 V)

The board prints each header pin's FPGA ball beside it; wire by that printed name. Pin numbers assume pin 1 is at the PIN1 mark (5V0) with odd pins in that column.

| Signal | Direction | Printed ball | J7 pin | Pico harness pin | Idle level, nothing connected |
|---|---|---|---|---|---|
| SCLK | in | D11 | 35 | GP2 | low (pull-down) |
| MOSI | in | J12 | 33 | GP3 | low (pull-down) |
| CS_N | in | J14 | 31 | GP5 | high (pull-up) |
| PROTO | in | F13 | 29 | GP6 | low (pull-down) |
| CPHA | in | F14 | 27 | GP7 | low (pull-down) |
| MISO | out | H14 | 30 | GP4 | |
| DATA_READY | out | F12 | 28 | GP8 | |
| BUSY | out | H12 | 26 | GP9 | |
| GND | | GND | 37 or 38 | GND | |

Do not connect J7 pin 1 (5 V) or pins 39/40 (3.3 V) to the Pico. To move a signal, edit `pins.tcl`.

The whole header, as printed (PIN1 column first):

| J7 pins | PIN1 column (odd) | other column (even) |
|---|---|---|
| 1 / 2 | 5V0 | GND |
| 3 / 4 | D9 | C9 |
| 5 / 6 | B9 | A9 |
| 7 / 8 | D10 | A10 |
| 9 / 10 | B10 | B11 |
| 11 / 12 | A12 | B12 |
| 13 / 14 | A13 | C11 |
| 15 / 16 | A14 | B14 |
| 17 / 18 | C13 | D14 |
| 19 / 20 | J15 | D13 |
| 21 / 22 | C14 | G14 |
| 23 / 24 | J13 | H13 |
| 25 / 26 | E13 | H12 |
| 27 / 28 | F14 | F12 |
| 29 / 30 | F13 | H14 |
| 31 / 32 | J14 | G12 |
| 33 / 34 | J12 | E12 |
| 35 / 36 | D11 | C12 |
| 37 / 38 | GND | GND |
| 39 / 40 | 3V3 | 3V3 |

Fixed pins, already in `xcordic_ku5p.xdc`: clock E18, KEY1 AF14 (reset, active low), LEDs K10, K9, J11, J10, J9, H9.

LEDs: 0 DATA_READY, 1 BUSY, 2 CS active, 3 PROTO, 4 reset, 5 heartbeat (about 1.5 Hz at 25 MHz).

## Build

Needs Vivado on the PATH (the KU5P is in the free edition).

```
./build.sh                 # GUARD 4 (the GF26c build), 25 MHz
GUARD=0 ./build.sh         # the ttsky25a 16-bit datapath
CLK_MHZ=40 ./build.sh      # 40 MHz core clock
./build.sh all             # all four: GUARD 4 and 0, at 25 and 40 MHz
./build.sh prog            # load over the board's USB JTAG
```

Bitstreams land in `prebuilt/xcordic_ku5p_g<guard>_<mhz>mhz.bit`. The build stops if timing is not met.

The core clock comes from an MMCM: 50 MHz × 20 = 1000 MHz, divided by 40 (25 MHz) or 25 (40 MHz). Any `CLK_MHZ` works whose divider 1000 / `CLK_MHZ` is a multiple of 0.125 between 2 and 128.

## Test

Same as the ULX3S, with the harness's `fclk` set to the core clock:

```
./xch /dev/ttyACM0 -o ku5p_25_g4.csv "fclk 25" id regression
./xch /dev/ttyACM0 -o ku5p_40_g4.csv "fclk 40" "mode 1" id regression
```

## Files

| File | What |
|---|---|
| `xcordic_ku5p.v` | wrapper: MMCM, reset, the design, LEDs |
| `xcordic_ku5p.xdc` | clock, key, LEDs, timing exceptions, configuration settings |
| `pins.tcl` | the eight header balls |
| `build.tcl`, `build.sh` | non-project Vivado build |
| `program.tcl` | load a bitstream over JTAG |

## Notes

- The SPI pins are not timed against the core clock (`set_false_path`): the design samples them through its own synchronisers. What a host must respect is in `docs/info.md`; on this board the I/O delays are much shorter than the chip's pads, so those limits have more margin here.
- The configuration settings (SPI x4, compression) are the ones the GPU project's builds use on this board.
- `XC_NO_MMCM` bypasses the MMCM for a simulation without the Xilinx library (the core then runs on the 50 MHz input).
