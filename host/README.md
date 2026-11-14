# tt_um_xcordic test harness (Raspberry Pi Pico / Pico 2)

C++ firmware for an RP2040 or RP2350 wired to the Tiny Tapeout demo board's PMODs. It tests a tt_um_xcordic chip against a **bit-exact golden model** of the formally verified RTL. It also measures accuracy against libm, the old ttsky25a harness metric, protocol behaviour and the SPI timing window.

## Files

| | |
|---|---|
| `pico_harness/xc_model.hpp` | Golden model: a header-only C++ port of `<source_root>/formal/spec/xcordic_spec.vh`, GUARD 0 and 4 |
| `pico_harness/src/pio_spi_prog.hpp` | Generates the PIO SPI master program for an SCLK, a mode and a MISO sample delay |
| `pico_harnesssrc/hal.hpp`, `pico_harnesssrc/pico_hal.*` | Board layer: PIO or SPI-block master, CS/PROTO/CPHA/DATA_READY/BUSY pins |
| `pico_harness/src/xc_dut.hpp` | The chip's protocols (command frames, legacy frames, cfg, GUARD detection) |
| `pico_harness/src/suites.*` | The tests (portable: they run on the Pico and in `sim/`) |
| `pico_harness/src/main.cpp` | USB-serial console |
| `pico_harness/src/board.hpp` | Pin assignment |
| `pico_harness/check/` | Golden model vs the RTL (Verilator) |
| `pico_harness/sim/` | Firmware suites vs the RTL: Verilated `tt_um_xcordic` + PIO emulator + I/O delays |
| `pico_harness/tools/xch.cpp` | PC tool: sends commands, saves the `CSV,` lines |
| `pico_harness/build.sh`, `pico_harness/CMakeLists.txt` | Firmware build (pico-sdk 2.x) |

## Wiring

| Pico | Tiny Tapeout | |
|---|---|---|
| GP2 | ui[0] SCLK | input PMOD |
| GP3 | ui[1] MOSI | |
| GP5 | ui[2] CS_N | |
| GP6 | ui[3] PROTO | |
| GP7 | ui[4] CPHA | |
| GP4 | uo[0] MISO | output PMOD |
| GP8 | uo[1] DATA_READY | |
| GP9 | uo[2] BUSY | |
| GND | GND | at both PMODs |

- **ui[5..7]:** leave low (DIP switches off).
- **Pins:** change them with `-DXC_PIN_...=` (see `CMakeLists.txt`). SCLK/MOSI/MISO default to SPI0's pins so `link hw` works. If you move them, keep them on one SPI block's pins.
- **Wiring:** keep the wires short (≤ 15 cm) and run a ground next to SCLK and MISO. Above ~20 MHz a 33 Ω series resistor at the Pico end of SCLK helps.

### Demo board

The demo board's RP2040 selects the project and supplies its clock. It must leave `ui_in` to the PMOD. With the Tiny Tapeout MicroPython SDK ([tt-micropython-firmware](https://github.com/TinyTapeout/tt-micropython-firmware)):

```python
tt.shuttle.tt_um_xcordic.enable()
tt.mode = RPMode.ASIC_MANUAL_INPUTS     # the RP2040 does not drive ui_in
tt.clock_project_PWM(25_000_000)
print(tt.auto_clocking_freq)            # the real clock: give it to the harness as `fclk`
```

Check these names against your SDK version (also `config.ini`: `project`, `mode`, `clock_frequency`). The DIP switches must be off: they share `ui_in`.

## Build and flash

```sh
PICO_SDK_PATH=~/pico-sdk ./build.sh          # build-pico/ and build-pico2/xcordic_harness.uf2
```

Hold BOOTSEL, plug the Pico in, copy the `.uf2`. Prebuilt files for the default pins: `pico_harness/prebuilt/xcordic_harness_pico.uf2` (RP2040) and `pico_harness/prebuilt/xcordic_harness_pico2.uf2` (RP2350).

## Use

Open the USB serial port with any terminal. Or use the PC tool, which also appends every `CSV,` line to a file:

```sh
g++ -O2 -std=c++17 -o xch tools/xch.cpp
./xch /dev/ttyACM0 -o run1.csv "fclk 25" id regression "sclk 6" calibrate "shmoo 1 8 1"
./xch /dev/ttyACM0                 # interactive
```

### Typical session

1. `fclk 25`: tell it the project clock (25 MHz is the GF26c build's target, and the firmware's default).
2. `id`: link check, GUARD detection (cfg atan0 reads 0x0c91 or 0xc910), cfg reset values, and a sin and a mul.
3. `regression`: identify + bitexact + protocol + legacy + accuracy, exhaustive. It takes a few minutes, mostly libm on the Pico.
4. `sclk 10` then `calibrate`: measures the MISO sample window at this speed and centers the PIO sample delay in it.
5. `shmoo 2 20 2`: pass map of SCLK × sample delay, both SPI modes, plus the SPI block.

### Commands

| command | |
|---|---|
| `status`, `pins`, `help` | |
| `fclk <MHz>` | the chip's clock. It sets the CS timing and the legacy-timeout wait. The timeout is 2²⁸ clocks, so the `protocol` suite pauses about 12 s at 25 MHz. |
| `sclk <MHz>` | SPI clock; the achieved value is printed (whole PIO cycles) |
| `mode <0\|1>` | SPI mode; also drives ui[4] CPHA |
| `sample <ns\|auto>` | PIO MISO sample delay after the slave's sample edge, up to 2 bits |
| `link <pio\|hw>` | PIO master (with sample delay), or the SPI block (samples on its edge, like a plain master) |
| `cs <setup> <hold> <gap>` | CS timing in chip clocks (default 4 3 6; the chip needs ≥ 3, 2, 5) |
| `sysclk <MHz>` | Pico clock = PIO resolution: 150 MHz is a 6.7 ns tick. RP2350 to 300 (3.3 ns), RP2040 to 250. Raises the core voltage; overclocking is at your own risk. |
| `seed <n>`, `dump <0\|1>` | random seed; `dump 1` prints every accuracy/legacy input as CSV |
| `id` | see above |
| `calibrate` | sample-window search at the current SCLK/mode; sets `sample` to its middle |
| `bitexact [n]` | all 20 ops × n operands (half uniform, half edge values), STATUS/SEQ and the FLAGS byte checked on every frame. Then every op again with random cfg constants, and the cfg reset values restored. |
| `accuracy [fn\|all] [pairs]` | sin cos tan exp ln sqrt tanh over all 65536 inputs; atan2 hypot mul div over random pairs. Prints max/mean/RMS abs and rel error in LSB, and checks every result against the model. |
| `legacy [n] [cs\|frame]` | ttsky25a protocol, n angles: one CS per byte, or 8- and 6-byte frames. Prints the old harness's metric for the legacy frame and for the sincos instruction. |
| `protocol` | read-only frames, DATA_READY/BUSY right after EXEC, STATUS/SEQ, illegal ops (21, 22, 25, 31), short frames, 16-byte reads (STATUS, RD, FLAGS, zeros), exact mul/div/sqrt with SAT and INV, the 4-deep queues, a 300-instruction bist against the model, pipelined read+exec, 5- vs 9-byte frames, cfg read-only and unused selectors, legacy framings, the legacy timeout recovery, PROTO switching |
| `shmoo [min max step] [ops]` | see above |
| `perf [n]` | pipelined ops/s per instruction, EXEC + DATA_READY wait time |
| `exec <op> <rs1> [rs2]` | one instruction in hex, next to the model's answer |
| `raw <hex bytes>` | one CS frame; prints MISO |
| `proto <0\|1>` | PROTO pin |

**Pass criterion:** every result must equal the golden model bit for bit. Because the model is the RTL's proven specification, a pass means the silicon computes what was verified. The accuracy numbers are reported, not judged.

### Output

Human-readable lines, plus machine-readable ones:

```
CSV,identify,PASS,<guard>
CSV,bitexact,<op>,<n>,<mismatches>,<status errors/timeouts>
CSV,accuracy,<fn>,<inputs>,<max>,<mean>,<rms>,<relmax>,<relmean>,<model mismatches>,<status errors>
CSV,legacy,<n>,<byte_per_cs>,<legacy mean>,<legacy peak>,<sincos mean>,<sincos peak>,<mismatches>,<timeouts>,<third word bad>
CSV,protocol,<check>,<PASS|FAIL>
CSV,calibrate,<sclk>,<mode>,<tick ns>,<first tick>,<ticks>,<sample ns>,<map>
CSV,shmoo,<mode>,<sclk>,<map by delay>,<SPI block>
CSV,perf,<op>,<ops/s>
CSV,regression,<PASS|FAIL>
```

## SPI speed and the MISO sample delay

MISO reaches the Pico 20–25 ns after the edge that launched it (pads + Tiny Tapeout I/O). In the default build it also waits 2–3 chip clocks for the oversampled slave's synchronizer.

**Oversampled slave (default build):**
- It shifts MISO on its sample edge.
- MISO bit b is valid at the master from about (sample edge b−1) + delay to (sample edge b) + delay.
- The SCLK limit is clk/4 at the chip's pins: 6.25 MHz at the GF26c build's 25 MHz.

**SCLK-domain slave (`SPI_SCLK = 1`):**
- It shifts MISO on the other edge, half a bit earlier.
- The SCLK limit is about 66 MHz (Tiny Tapeout inputs).

A master that samples on its own edge (`link hw`) works only while the delay fits in the slave's window. Past that the sample has to move later. The PIO master does that: `sample` places the sample on any PIO cycle up to two bits after the edge.

`sample auto` uses the window estimate in `pio_spi_prog.hpp`. `calibrate` measures the real window.

The sample point is one PIO tick (6.7 ns at 150 MHz). At high SCLK two ticks per bit cannot be used: the MOSI change and the loop jump occupy them. They show as `-` in the maps.

### Simulated windows 

 At the sky130 build's 50 and 100 MHz clocks: Pico + Tiny Tapeout I/O modelled as 12 ns out + 12 ns back. At the GF build's 25 MHz the oversampled slave's window shifts by its synchronizer delay (2–3 clocks, 80–120 ns); better run `calibrate` from `xch` utility.

| build, chip clk | SCLK | mode | passing sample delay |
|---|---|---|---|
| oversampled, 50 MHz | 4–8 MHz | 0, 1 | 0 – 56 ns |
| oversampled, 50 MHz | 12.5 MHz | 1 | 7 – 60 ns |
| oversampled, 100 MHz | 24 MHz | 0, 1 | 12 – 44 ns |
| SCLK domain, 50 MHz | 20 MHz | 0, 1 | 0 – 44 ns |
| SCLK domain, 50 MHz | 50 MHz | 0 | 20 – 33 ns |
| SCLK domain, 66.5 MHz | 60 MHz | 1 | 17 – 27 ns |

## How To Run Simulation Against RTL

**`pico_harness/check/run.sh`** checks the golden model against the RTL (`xcordic_core.v`, Verilator), GUARD 0 and 4:
- the one-operand ops over all 65536 inputs;
- the others over 200 000 random operand pairs each;
- random cfg constants.

- Run `<source_root>/formal/exhaustive/run_pairs.sh` this runs atan2, hypot, mul and div over all 2³² pairs on the RTL against the model: 0 mismatches in either GUARD. So the model is checked on every input of every value function.
- `<source_root>/formal/exhaustive/run_exact.sh` checks the RTL unit on every operand against integer arithmetic, and `pico_harness/check/run.sh` covers every sqrt input and random mul/div pairs against the model.)

**`pico_harness/sim/run.sh`** runs the firmware's suites unchanged against the Verilated `tt_um_xcordic` (TIMEOUT_LOG2 = 16, so the legacy-timeout test is short).
- The Pico is replaced by a PIO emulator that executes the generated program cycle by cycle.
- The pins pass through 12 ns delays each way.
- The matrix covers:
  - both slave builds × GUARD 0/4;
  - 50 and 100 MHz chip clocks;
  - modes 0 and 1;
  - the PIO master from 4 to 60 MHz, with fixed and calibrated sample delays;
  - the SPI-block master;
  - shmoos.
- All configurations pass. Accuracy is sampled (every 64th input) to keep the run short.

**Firmware:** compiles for `pico` (RP2040) and `pico2` (RP2350) with pico-sdk 2.1.1.


### Other limits

- **EXEC while busy:** the chip rejects an EXEC that arrives while an instruction is running. That cannot be observed here, because a frame always takes longer than an instruction (72 chip clocks), so the check reports SKIP.

## Reference values (RTL)

**ttsky25a harness metric** (250 angles, |error| of sin and cos against the exact angle, mean/peak in LSB):

| | legacy frame | sincos instruction |
|---|---|---|
| ttsky25a | 12.7 / 24.0 (1.71 / 5.54 with its per-half atan0 calibration) | — |
| GUARD 0 | 1.74 / 5.54 | 1.74 / 5.54 |
| GUARD 4 | 0.46 / 1.34 | 0.31 / 1.11 |

The legacy frame's x = 0x09B7 is 1/K rounded to S3.12. With 4 guard bits that rounding dominates. The sincos instruction uses the full-precision gain register.
