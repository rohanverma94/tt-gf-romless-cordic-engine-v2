# Xcordic bring-up kit: ULX3S 85F + Raspberry Pi Pico

Everything to run tt_um_xcordic on a ULX3S (ECP5 LFE5U-85F) and test it with the Pico harness, the same way you will test the GF26c chip.

## 1. FPGA

Prebuilt bitstreams, for both datapaths, at two core clocks: the board's 25 MHz oscillator (the GF26c target), or 40 MHz from the ECP5 PLL:

| file | |
|---|---|
| `fpga/ulx3s/prebuilt/xcordic_ulx3s_g4_25mhz.bit` | GUARD 4, the GF26c build |
| `fpga/ulx3s/prebuilt/xcordic_ulx3s_g0_25mhz.bit` | GUARD 0, the ttsky25a 16-bit datapath |
| `fpga/ulx3s/prebuilt/xcordic_ulx3s_g4_40mhz.bit` | GUARD 4, 40 MHz from the PLL: tell the harness `fclk 40` |
| `fpga/ulx3s/prebuilt/xcordic_ulx3s_g0_40mhz.bit` | GUARD 0, 40 MHz from the PLL: `fclk 40` |

```sh
openFPGALoader -b ulx3s fpga/ulx3s/prebuilt/xcordic_ulx3s_g4_25mhz.bit      # SRAM, gone at power-off
openFPGALoader -b ulx3s -f fpga/ulx3s/prebuilt/xcordic_ulx3s_g4_25mhz.bit   # flash
```

To build it yourself, you need yosys, nextpnr-ecp5 and ecppack (all in the OSS CAD Suite):

```sh
cd fpga/ulx3s
./build.sh                 # GUARD 4, 25 MHz     -> build/xcordic_ulx3s.bit
GUARD=0 ./build.sh         # 16-bit datapath
CLK_MHZ=40 ./build.sh      # core clock from the PLL; tell the harness `fclk 40`
./build.sh prog            # load build/xcordic_ulx3s.bit into SRAM
```

The build runs in about a minute and a half. GUARD 4 uses 8,382 logic cells (10 % of the 85F), 1,869 FF and 4 MULT18X18D; GUARD 0 uses 8 % and 2 multipliers. After routing, the core clock reaches 51–54 MHz, so 25 MHz and 40 MHz both close. At 40 MHz SCLK may go up to 10 MHz (fclk / 4).

**LEDs:**

| LED | Meaning |
|---|---|
| 0 | DATA_READY |
| 1 | BUSY |
| 2 | CS active |
| 3 | PROTO |
| 4 | CPHA |
| 6 | in reset |
| 7 | heartbeat, about 0.7 Hz: the clock is running |

**Reset:** the design resets at power-up. **F1** (btn[1]) resets it again.

## 2. Wiring

These are the Pico harness's default pins to header J1 of the ULX3S. On the silkscreen, "n+" is gp[n] and "n−" is gn[n]. Everything is 3.3 V, so connect them directly.

| Pico | ULX3S J1 | FPGA site | signal |
|---|---|---|---|
| GP2 | 0+ (gp0) | B11 | SCLK → ui[0] |
| GP3 | 1+ (gp1) | A10 | MOSI → ui[1] |
| GP5 | **15+ (gp5)** | C8 | CS_N → ui[2] (moved off J1-9, which had a bad contact; 2+ is unused) |
| GP6 | 3+ (gp3) | B9 | PROTO → ui[3] |
| GP7 | 4+ (gp4) | A7 | CPHA → ui[4] |
| GP4 | 0− (gn0) | C11 | MISO ← uo[0] |
| GP8 | 1− (gn1) | A11 | DATA_READY ← uo[1] |
| GP9 | 2− (gn2) | B10 | BUSY ← uo[2] |
| (spare) | 3− (gn3) | C10 | BUSY again: wire GP9 here if 2− gives no signal |
| GND | GND | | at least one, next to SCLK/MISO if you can |

The pin sites come from the board's reference `ulx3s_v20.lpf`. Check `fpga/ulx3s/ulx3s.lpf` against your board revision before the first run.

Keep wires short (≤ 15 cm). The ULX3S drives MISO directly; there is no level shifter.

### Quick check without the Pico

Send `94 19 00 00 00 78 56 34 12` (self-test, N = 25, seed 0x12345678) over any SPI master, mode 0, PROTO high. Wait for DATA_READY, then read 5 bytes: STATUS, then RD = `5E 61 A9 1B` (0x1BA9615E) on the GUARD 4 bitstream, or 0x63C38BD6 on GUARD 0.
