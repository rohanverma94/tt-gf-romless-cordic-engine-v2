# GF26c I/O timing and the G1 pad-level model

This note covers how `tt_um_xcordic` meets the Tiny Tapeout GF26c chip's I/O: where the delay figures come from, what the static timing says, and what the G1 formal proof establishes about the default (oversampled, `SPI_SCLK = 0`) SPI slave at the chip's pads.

## 1. Where the I/O delays come from

**Pad cells.** The GF26c chip (gf180mcuD) builds every user pin from the `gf180mcu_ocd_io` library. Tiny Tapeout configures them as follows (sources: `tt-multiplexer` `rtl/tt_gf_gpio.v` and `ol2/tt_top/tt_gf_wrapper.v`):

| Pin | Pad cell | Configuration |
|---|---|---|
| `clk`, `rst_n`, `ui_in[7:0]` | `gf180mcu_ocd_io__in_c` | CMOS input, no pull-up or pull-down |
| `uo_out[7:0]` | `gf180mcu_ocd_io__bi_24t` | 24 mA, fast slew, input disabled |
| `uio[7:0]` | `gf180mcu_ocd_io__bi_24t` | 24 mA, fast slew, input enabled |

**Pad delays.** Measured with OpenSTA on the wafer.space gf180mcu liberty (`formal/sta/gf_pads.tcl`), with a 2 ns input transition:

| Corner | in_c pad→core (rise / fall) | bi_24t core→pad, 5 pF | bi_24t core→pad, 30 pF |
|---|---|---|---|
| ff_n40C_3v63 | 0.91 / 1.48 ns | 1.88 / 2.41 ns | 2.42 / 2.93 ns |
| tt_025C_3v30 | 1.65 / 1.96 ns | 3.13 / 3.62 ns | 3.99 / 4.42 ns |
| ss_125C_2v97 | 3.15 / 3.05 ns | 5.96 / 6.27 ns | 7.51 / 7.67 ns |

**Chip signoff budget.** The pad cells are only part of the path: the multiplexer and the routing to the tile add more. The GF26c top level is signed off (`tt-multiplexer` branch `dev-gf180mcuD`, commit `a2ebb37`, `ol2/tt_top/signoff.sdc` lines 96–99; the same limits are in tag `ttgf0p2-release`) with a 2 ns input transition, 30 pF on every output, and these limits at all corners:

- pad → tile input: **≤ 5.0 ns**
- tile output → pad: **≤ 12.5 ns**

Adding the tile's own port buffers gives the windows used everywhere below:

| Direction | Minimum (pad cell, ff) | Maximum (signoff + port buffer) | Skew between two pins |
|---|---|---|---|
| inward (pad → `ui_in` port) | 0.9 ns | 5.3 ns | ≤ 4.4 ns |
| outward (`uo_out` port → pad) | 1.9 ns | 12.8 ns | ≤ 10.9 ns |

To measure the pad cells on your own PDK install:

```
LIB=$PDK_ROOT/gf180mcuD/libs.ref/gf180mcu_ocd_io/lib/gf180mcu_ocd_io__ff_n40C_3v63.lib \
TIN=2 CL=5 sta -no_splash -exit formal/sta/gf_pads.tcl
```

## 2. Static timing

The default build has no I/O timing paths: every pin goes through a 2-flop synchronizer, so its I/O timing is a protocol question, which is what G1 settles. The core clock's signoff timing after layout is in `docs/info.md`.

## 3. G1: the default slave at the pads

N1 proves the slave at its own ports, in core clocks. G1 moves the master out to the chip's pads and puts the GF26c I/O between them. It then proves the same theorem, unbounded (PDR, any number of frames), in real time.

### The model

- **Time.** Multiclock formal: one global step is one tick, and the core clock is 2^CPL ticks. At 25 MHz, CPL = 1 is a 20 ns tick and CPL = 2 a 10 ns tick.
- **Master** (`spi_master_model`, `STRETCH`). It drives SCLK, MOSI and CS_N at the pads and reads MISO at its pad, SD ticks after its own sample edge (SD = 0 is a plain master). Each SCLK phase is ≥ H / L ticks, CS setup ≥ S, CS high ≥ G. Any phase may last longer, freely. Bytes and `tx_data` / `tx_next` are free, and the slave-side values change only at clock edges.
- **I/O** (`fv_iodelay`, one per pin). Every transition reaches the other side after a delay chosen freely, per pin and per transition, within [D0, D1] ticks, without glitching. The three inputs therefore also skew against each other by up to the window width.
- **Windows.** The window is the GF26c budget rounded up to whole ticks: D0 = 0, D1 = ⌈max delay / tick⌉. That gives 0..1 inward and 0..1 outward at 20 ns, and 0..1 inward and 0..2 outward at 10 ns.
- **Soundness of the tick grid.** Round each real master edge down to the grid. A real input arriving at a ≤ t + 5.3 ns then reaches the synchronizer at the same clock edge as in some model run with delay 0 or 1 tick: the first edge at or after a. The same holds when the arrival meets an edge's setup/hold window, because the next edge is two ticks later and still in the window. Since 5.3 ns and 12.8 ns are both shorter than a tick, every real behaviour has a model behaviour that sees the same thing at every clock edge and at every master read. The grid only adds pessimism (up to one tick per crossing), never optimism.
- **Theorem.**
  - M: every bit the slave shifts in is the bit the master drove for that SCLK period, and each `rx_data` is the last 8 bits.
  - S: every bit the master reads at its pad is bit 7−k of the byte the slave took for that position. Byte 0's MSB is checked against the slave's single snapshot of `tx_data`.
  - F: each frame gives exactly FB `rx_valid` pulses.
  - D: the master never changes a pin faster than the windows allow.

Files: `formal/props/g1_slave_props.vh`, `formal/tb/fv_iodelay.v`, `formal/tb/fv_g1_top.sv`, `formal/sby/gen_g1.sh` (`formal/run.sh g1`).

### Results

All at a 25 MHz core clock (40 ns). Windows: "GF" is the signoff budget above (20 ns model: in 0–20, out 0–20 ns; 10 ns model: in 0–10, out 0–20 ns). The CS high time is 240 ns in every case. Times are solver wall-clock times from the last run (`formal/results/summary.md`).

| Model | Mode | SCLK high / low | CS setup | Windows | MISO read | Bytes | Result | Time |
|---|---|---|---|---|---|---|---|---|
| 10 ns | 0 | 80 / 80 ns (6.25 MHz) | 120 ns | GF | on the edge | 1 | **PASS** | 11 min |
| 10 ns | 1 | 80 / 80 ns | 120 ns | GF | on the edge | 1 | **PASS** | 15 min |
| 20 ns | 0 | 80 / 80 ns | 140 ns | GF | +20 ns | 1 | PASS | 3 min |
| 20 ns | 1 | 80 / 80 ns | 140 ns | GF | +20 ns | 1 | PASS | 3 min |
| 20 ns | 0 | 80 / 80 ns | 140 ns | GF | +20 ns | 2 | PASS | 13 min |
| 20 ns | 1 | 80 / 80 ns | 140 ns | GF | +20 ns | 2 | PASS | 8 min |
| 20 ns | 0 | 80 / 100 ns | 140 ns | GF | on the edge | 1 | PASS | 5 min |
| 20 ns | 1 | 100 / 80 ns | 140 ns | GF | on the edge | 1 | PASS | 3 min |
| 20 ns | 0 | 60 / 100 ns | 140 ns | GF | +20 ns | 1 | PASS | 3 min |
| 20 ns | 1 | 100 / 60 ns | 140 ns | GF | +20 ns | 1 | PASS | 4 min |
| 20 ns | 0 | 80 / 80 ns | 120 ns | GF | +20 ns | 1 | PASS | 3 min |
| 20 ns | 1 | 80 / 80 ns | 60 ns | GF | +20 ns | 1 | PASS | 3 min |
| 20 ns | 0 | 80 / 80 ns | **100 ns** | GF | +20 ns | 1 | FAIL (S, step 21) | — |
| 20 ns | 0 | **40** / 120 ns | 140 ns | GF | +20 ns | 1 | FAIL (M, step 31) | — |
| 20 ns | 1 | 120 / **40** ns | 140 ns | GF | +20 ns | 1 | FAIL (M, step 37) | — |
| 20 ns | 0 | 80 / 80 ns | 140 ns | GF | **on the edge** | 1 | FAIL (S, step 31) | — |
| 20 ns | 0 | 80 / 80 ns | 140 ns | **0–40 / 0–40 ns** | +40 ns | 1 | FAIL (S, step 34) | — |
| 10 ns | 0 | 80 / 80 ns | 120 ns | in GF, **out 0–30 ns** | on the edge | 1 | FAIL (S, step 44) | — |
| cover (20 ns) | 0, 1 | 80 / 80 ns | 120 ns | GF | | 1 | first frame completes (step 93) | 20 s |

How to read the failures:

- **CS setup 100 ns.** Below 3 clocks, a mode-0 master takes byte 0's MSB before the slave has seen CS, as at the ports (N1).
- **40 ns SCLK phase.** This is the pad effect: rise and fall skew shortens the pulse below a clock.
- **20 ns model, read on the edge.** This is the model's own rounding (20 ns per crossing). The 10 ns model proves the same timing.
- **40 ns windows** and **30 ns outward with the read on the edge** mark the margin's limits.

### What it means for a GF26c host

At 25 MHz, the default slave works at the pads of the GF26c chip, through the full signoff I/O budget, with:

- **SCLK ≤ 6.25 MHz** (period ≥ 160 ns, 4 core clocks), with **each phase ≥ 60 ns**. At the ports one clock (40 ns) per phase would be enough, but at the pads SCLK's rise and fall reach the slave with different delays (up to 4.4 ns apart), so a 40 ns phase can arrive shorter than a clock and be missed. G1 shows that failure; 60 ns phases pass. The physical limit lies near 45 ns (one clock plus the skew), and 60 ns is what is proved. A 50 % duty cycle at 6.25 MHz (80 + 80 ns) is fine.
- **MISO read on the master's own sample edge** (a plain SPI master, no delay compensation). Proved in the 10 ns model in both modes. The coarser 20 ns model needs the read 20 ns late, or SCLK 180 ns, which is its own rounding showing.
- **CS setup ≥ 120 ns in mode 0** (3 clocks, as at the ports: the skew is absorbed) and ≥ 60 ns in mode 1.
- **CS high between frames ≥ 240 ns**, and any number of bytes per frame.

**Margin.** With a plain master, the 10 ns model passes with outward delays up to 20 ns and fails at 30 ns. That is 7–17 ns beyond the 12.8 ns budget, for board trace, the master's input buffer and its setup time, measured with the model's rounding pessimism still in. A master that reads MISO later gains that delay one-for-one, up to about 80 ns: MISO at the pad never changes earlier than about 83 ns after the master's sample edge (three clock edges, less one clock of synchronizer phase, plus the minimum pad delays). The Pico harness's PIO master does exactly that (`calibrate`).

The Pico host harness simulation runs the GF case on the real RTL with 9 ns inward and 17 ns outward (signoff plus about 4 ns of board): all checks pass with the master reading MISO on its edge. Its calibration finds a 0–107 ns window of valid sample delays at 6.25 MHz.
