# formal/

Formal verification of `tt_um_xcordic` (`src/`) and of the original ttsky25a design it replaces (`third_party/ttsky_orig/`).

Unzip `formal/results.zip`. That should place the results in `formal/results`.

The full timing tables, the list of bugs found and the mutation table are in [`docs/FORMAL.md`](../docs/FORMAL.md). The pad-level I/O model is in [`docs/GF26C_IO.md`](../docs/GF26C_IO.md).

## Result Summary

185 SymbiYosys tasks: **155 PASS, 30 FAIL, all 30 expected**. Every proof of `tt_um_xcordic` inside the datasheet's operating conditions passes. The 30 failures are deliberate: 29 are timings outside the datasheet in the SPI timing sweeps (a FAIL there is a counterexample that marks where the limit is), and 1 is the original design's lock-up, which this design fixes. Outside SymbiYosys: 12/12 SAT equivalences, 789,864 instructions equal to the reference core, every operand of mul, div and sqrt against exact arithmetic, all 2³² operand pairs of atan2, hypot, mul and div against the golden model, and 52 of 52 planted bugs caught.

## Contents

1. [How the design is covered](#1-how-the-design-is-covered)
2. [How a proof is built](#2-how-a-proof-is-built)
3. [The proofs of tt_um_xcordic](#3-the-proofs-of-tt_um_xcordic): N1, N1c, N1S, G1, N2, F2, F3, F5, F6, F7
4. [The proofs of the original design](#4-the-proofs-of-the-original-design): O1, O2, F4
5. [Checks that are not proofs](#5-checks-that-are-not-proofs): equivalence, exhaustive simulation, mutation testing
6. [Results](#6-results)
7. [What is not proved](#7-what-is-not-proved)
8. [Folder layout](#8-folder-layout) and [running](#9-running)

## 1. How the design is covered

No single proof covers the whole chip: a solver cannot handle SPI timing, two 4-deep queues and a 20-bit CORDIC datapath in one model. The design is cut at its module boundaries. Each block is proved on its own, with its neighbours replaced by a **contract** (a small model that allows every behaviour the real neighbour can show). Each contract is then proved for the real neighbour by that neighbour's own proof.

| RTL block | What it does | Proved by | Neighbours replaced by |
|---|---|---|---|
| `xc_spi_slave.v` | default SPI slave, oversampled on the core clock | **N1** (bits and bytes vs. a timed master), **N1c** (byte contract), **G1** (same theorem at the chip's pads) | the frame logic: `tx_data`/`tx_next` are free inputs |
| `xc_spi_slave_sclk.v`, `xc_meta.v` | optional slave clocked by SCLK (`SPI_SCLK = 1`) | **N1S** (bits, bytes, clock-domain crossing) | the frame logic: assumptions A1/A2, proved by N2 |
| `xc_frame.v` | both protocols, the two queues, STATUS, the pins | **N2** (legacy, recover, command, switch) | SPI slave: the N1c contract. Core: `xcordic_core_abstract.v` |
| `xc_bist.v` | self-test instruction, sits between frame and core | **F5** | core: `xcordic_core_abstract.v` |
| `xcordic_core.v` | sequencer: turns an instruction into engine passes | **F3** (one task per instruction) | engine: `xcordic_engine_abstract.v`. Exact unit: `xc_exact_abstract.v` |
| `xcordic_engine.v`, `xcordic_atan.v` | the CORDIC iteration and the ROM-less angle generator | **F2**, **F7b** | none |
| `xc_add.v` | prefix adder | **F7a** | none |
| `xc_exact.v` | exact mul, div, sqrt | **F6** (contract, operands-only), exhaustive simulation (values) | none |
| `project.v` | wiring, two flops on `rst_n` and PROTO | no proof of its own (section 7) | |

How the pieces add up to the chip:

```
 SPI pins ── N1 / N1S / G1 ──► bytes ── N2 ──► instructions ── F5 ──► core ── F3 ──► engine passes ── F2 ──► values
                  │                      │                             │                        └ F7: adder, angle generator
                  └ N1c: byte contract ──┘                             └ F6 + exhaustive: mul, div, sqrt
```

Reading it as one sentence: for any master inside the proven timings, every byte arrives (N1), every frame becomes exactly the right instruction and every result goes back in the right frame (N2), every instruction launches exactly the engine passes the specification prescribes and returns its result (F3), and every engine pass computes the specified micro-rotations (F2).

The original design is covered the same way: **O1** (SPI bytes) + **O2** (frames) + **F4** (CORDIC).

## 2. How a proof is built

### Where the properties live

Properties are plain Verilog `assert`, `assume` and `cover` statements in `props/*.vh`, one file per proved module. They are written inside the module, so they can see its internal registers. They get there in one of two ways:

- **Compiled in by a define.** `xc_frame.v`, `xc_bist.v`, `xcordic_core.v`, `xcordic_engine.v` and `xc_exact.v` each end with an `` `ifdef XC_FV_... `` / `` `include "..._props.vh" `` pair. Synthesis and simulation never define it, so the chip's RTL is the file as it stands.
- **Injected into a build copy.** The two SPI slaves take several different property sets (N1, N1c, G1 all apply to `xc_spi_slave.v`), and the third-party RTL must not be edited at all. `tools/inject.sh` copies the source and adds one `` `include `` line before `endmodule`. It fails unless the copy differs from the source by exactly that line.

### The specification

`spec/xcordic_spec.vh` is an executable specification made of functions only, with no state. It was written from the specification document, not from the RTL, and it is coded differently (integer arithmetic, tables, an explicit rotation direction). Its layers:

- `sp_angle`, `sp_shift`, `sp_step`: one CORDIC micro-rotation.
- `sp_quad`, `sp_unquad`: the quadrant mapping for rotations.
- `sp_norm`, `sp_shl`, `sp_scale`: normalisation and exponent handling.
- `sp_alg`: for each instruction, which engine pass to launch next, or the final result and flags.

`XC_GUARD` selects the datapath: 0 is the 16-bit ttsky25a datapath, 4 is the 20-bit one the chip is built with. `spec/xcordic_isa_spec.vh` holds the instruction encoding.

### Contracts

`models/` holds the stand-ins for submodules. A contract is a module with the same ports that may do anything the real module could do, and usually more:

| Contract | Says | Proved for the real module by |
|---|---|---|
| `xcordic_engine_abstract.v` | start accepted only when idle; busy from the next cycle; done pulses as busy falls; outputs arbitrary | F2 |
| `xc_exact_abstract.v` | the same handshake; result and flags arbitrary | F6 |
| `xcordic_core_abstract.v` | the same handshake; cfg finishes in one cycle; result arbitrary | F3a |
| the byte contract (assumptions in `xc_frame_props.vh`) | when `rx_valid`, `frame_start` and `frame_end` may occur | N1c, and N1S part C |
| `spi_slave_contract.v`, `cordic_top_contract.v` | the original design's SPI slave and CORDIC top | O1, F4 |

Because the contract's results are arbitrary, a proof against it holds for **every** result the real module could return. What the result actually is belongs to the real module's own proof.

### Environments for the SPI proofs

SPI is asynchronous to the core clock, so the SPI proofs need a model of time:

- **`tb/spi_master_model.v`: a timed master.** CPOL 0, mode 0 or 1. SCLK high lasts at least H, low at least L, CS setup at least S. Every phase may also last longer, chosen freely each time. That covers every alignment between the master and the core clock and every slower master, so a PASS at one timing is a PASS at every slower one. The data bytes are free.
- **Tick models (N1S, G1).** SymbiYosys `multiclock` mode with a global time step. N1S uses 4 ticks per core clock; G1 uses 2 or 4. The master moves on any tick.
- **`src/xc_meta.v` with `XC_FV_META`.** A synchroniser's first flop may resolve an input that just changed either way.
- **`tb/fv_iodelay.v`.** A glitch-free wire whose delay is chosen freely, per transition and per pin, inside a window. It models the pad and port-buffer delays in G1.

The SPI theorems are stated **per bit** ("this sample took the right bit at the right index"), not per frame. That keeps them local in time, which is what makes them provable with free phase lengths.

### Solvers

| Engine | Used for | What a PASS means |
|---|---|---|
| ABC PDR (`abc pdr`) | N1, N1S, G1, N2, O1, O2 | unbounded: holds for any number of frames and transactions |
| k-induction (`smtbmc yices`, `mode prove`) | N1c, F2, F3a, F5, F6, F4a | unbounded: holds in every reachable state |
| BMC (`mode bmc`) | F3b, F4b, one F5 task | holds for every trace up to the depth; complete where the run is known to finish inside it |
| cover (`mode cover`) | every group | a trace that reaches the target exists, so the assumptions are not contradictory |
| SAT (`yosys sat -prove`) | F7 | combinational equality for every input |

Every unbounded theorem has a cover task next to it. Without one, a proof could pass only because its assumptions rule out every trace.

### Shortened constants

Three constants are smaller in the proofs than on the chip, so the counters stay small: the legacy timeout is 2⁴ cycles instead of 2²⁸ (`TIMEOUT_LOG2 = 4` in `tb/fv_n2_top.sv`), the core's latency is at most 6 cycles in the legacy and recover tasks, and the original CORDIC's latency is at most 20 in O2. The state machines depend on these values only through counters that are the same RTL at any width. The command tasks of N2 allow any core latency.

## 3. The proofs of tt_um_xcordic

Each entry has the same four parts: **purpose**, **design under proof**, **construction**, **result**. Times are solver time on the last full run.

### N1: the default SPI slave carries every bit

**Purpose.** Show that `xc_spi_slave` moves every bit of every byte both ways, in one-byte and multi-byte frames and in both SPI modes, and find the slowest timing at which it stops doing so.

**Design under proof.** `src/xc_spi_slave.v`, real RTL, with `props/n1_slave_props.vh` injected. Top: `tb/fv_spi_top.sv`. The frame logic is not present: `tx_data` and `tx_next` are free inputs.

**Construction.**
- The injected properties instantiate the timed master and tie the slave's `sclk`, `mosi`, `cs_n` and reset to it.
- The master side keeps a record of which byte it sent at each byte position; the slave side keeps a record of which byte it took from `tx_data`/`tx_next`.
- Three assertions:
  - **M**: the cycle after each sample, the bit just shifted into `rx_sh` is the bit the master drove for that SCLK period; at `rx_valid`, the byte handed over is the shift register.
  - **S**: every bit the master samples from MISO is bit 7−k of the byte the slave took for that position. Byte 0 must be one consistent snapshot, even when a mode-0 master samples the MSB before the slave has seen CS fall.
  - **F**: each frame gives exactly the expected number of `rx_valid` pulses.
- `sby/gen_o1.sh new` writes one task per timing: `m<mode>_h<high>_l<low>_s<setup>`, with `_fb3` for 3 bytes per frame and `_t1` for a short CS hold. Units are core clocks.
- Engine: PDR, unbounded. Two cover tasks show that two complete frames are reachable.

**Result.** 26 tasks: 18 timings PASS, 6 FAIL, 2 covers PASS. 11 minutes.
- Both modes work down to SCLK high + low = 4 core clocks with any split down to 1 (the original needs 9 in mode 0).
- CS setup must be at least 3 clocks in mode 0 and 1 in mode 1.
- The 6 failures are high + low = 3 (four tasks) and mode-0 CS setup of 1 and 2. All are outside the datasheet.

### N1c: the default slave keeps the byte contract

**Purpose.** N2 does not contain the SPI slave. It assumes a few facts about when bytes and frame marks can occur. N1c proves those facts for the real slave, so N2's assumptions are discharged.

**Design under proof.** `src/xc_spi_slave.v` with `props/n1c_contract_props.vh` injected. It is its own top; there is no master model.

**Construction.** Every input is free: any SCLK, MOSI and CS waveform at all. The assertions are the contract: `rx_valid` only if `cs_on` was high in the previous cycle, at least 2 cycles after `frame_start` and after the previous `rx_valid`; `frame_start` is `cs_on` rising; `frame_end` comes one cycle after `cs_on` falls, so never together with `rx_valid`. A few helper invariants make it inductive. Engine: k-induction, depth 6.

**Result.** 1 task, PASS, under a second. Because the inputs are unconstrained, the contract holds even for a master far outside the SPI timing.

### N1S: the SCLK-domain slave

**Purpose.** With `SPI_SCLK = 1` the slave shifts bits on SCLK itself and passes whole bytes to the core clock. The oversampling argument of N1 does not apply, and there is a real clock-domain crossing to check. (The chip is built with `SPI_SCLK = 0`; this proof covers the option.)

**Design under proof.** `src/xc_spi_slave_sclk.v` and `src/xc_meta.v`, with `props/n1s_slave_props.vh` injected. Top: `tb/fv_n1s_top.sv`.

**Construction.**
- Time is modelled in ticks of a quarter core clock (`multiclock on`). The core clock is 2 ticks high, 2 low. The master runs on every tick, so SCLK takes every alignment to the core clock at that resolution.
- `XC_FV_META` lets each synchroniser's first flop catch a just-changed input old or new.
- The frame logic is replaced by two assumptions about its outputs: **A1** `tx_data` does not change from the last cycle before `frame_start` until the frame's first byte; **A2** `tx_next` changes only right after a byte or after `frame_start`. N2 proves both for `xc_frame`.
- Assertions: **M** and **S** (bytes both ways), **F** (bytes per frame), **C** (the same byte contract N1c proves for the default slave), and **X**: every value crossing between the two clock domains has been stable for at least 2 ticks before the edge that captures it, and the MSB a mode-0 master reads straight from `tx_data` has been stable for at least 4.
- `sby/gen_n1s.sh` writes one task per timing: `m<mode>_h_l_s_t_g` in ticks, `g` being CS high between frames, `_fb2` two bytes per frame with any pause between them.
- Engine: `abc scorr; dc2; pdr`, unbounded.

**Result.** 20 tasks: 14 timings PASS, 4 FAIL, 2 covers PASS. 90 minutes.
- SCLK periods down to 3 ticks (¾ of a core clock) carry multi-byte frames; one-byte frames go down to 2 ticks.
- CS setup must be at least 3 core clocks in mode 0 and 2 in mode 1; CS high at least 4 core clocks.
- The 4 failures are a CS setup or CS high time one step below those limits: byte 0 would be taken before it is frozen.

### G1: the default slave at the chip's pads

**Purpose.** N1 is stated at the slave's ports in core clocks. A host sees the chip's pads, with the GF26c I/O cells and the Tiny Tapeout multiplexer in between. G1 proves the N1 theorem again with the master at the pads, to turn "core clocks at the port" into "nanoseconds at the pin".

**Design under proof.** `src/xc_spi_slave.v` with `props/g1_slave_props.vh` injected. Top: `tb/fv_g1_top.sv`.

**Construction.**
- Real-time tick model at 25 MHz: 20 ns ticks (`k1`, 2 per clock) or 10 ns ticks (`k2`, 4 per clock).
- Between each pad and the slave's port sits a `fv_iodelay` instance. Every transition of every pin takes a freely chosen delay inside a window, so the pins also skew against each other. The windows contain the chip's signoff budget: pad to tile at most 5.0 ns, tile to pad at most 12.5 ns into 30 pF, plus the tile's port buffers. `sta/gf_pads.tcl` measures the pad cells.
- The master may read MISO some ticks after its sample edge (`d0` = on the edge, a plain master).
- Assertions: **M**, **S** and **F** as in N1, measured at the pads, plus **D**: the master never changes a pin faster than the delay window allows (otherwise the delay model would be unsound).
- `sby/gen_g1.sh` writes the tasks; names carry the tick size, mode, phases, setup, hold, CS high, delay windows and the MISO read delay. Tasks ending in `_x` are expected to fail: each sits one step past a limit.
- Engine: `abc scorr; dc2; pdr`, unbounded.

**Result.** 20 tasks: 12 proofs PASS, 2 covers PASS, 6 `_x` tasks FAIL as intended. 74 minutes.
- A plain master at 6.25 MHz passes in both modes.
- Each SCLK phase must be at least 60 ns at the pads; CS setup at least 120 ns in mode 0.
- For a plain master, an outward delay up to 20 ns is proved and 30 ns fails.

### N2: the frame logic

**Purpose.** Show that `xc_frame` turns frames into exactly the right instructions and returns exactly the right bytes, in both protocols, for any number of frames, and that it recovers from a confused host. This is where the original design locked up.

**Design under proof.** `src/xc_frame.v`, real RTL, compiled with `XC_FV_FRAME` so that `props/xc_frame_props.vh` is included. Top: `tb/fv_n2_top.sv`, which connects the core contract `xcordic_core_abstract.v` and leaves the SPI-side inputs free.

**Construction, common to all tasks.**
- The SPI slave is replaced by the byte contract as assumptions: `cs_on` is any sequence, `rx_valid` obeys the spacing N1c proves, `rx_data` is any byte.
- Bookkeeping registers reconstruct what the master reads: byte 0 of a frame is `tx_data` in the last cycle before `frame_start`; byte n+1 is `tx_next` in the cycle before the `rx_valid` of byte n.
- Defines select the task: `N2_LEGACY`, `N2_FREE`, `N2_CMD`, `N2_SWITCH`, and `N2_GUARD` = 0 or 4.
- Engine: PDR, unbounded. Covers use BMC.

**The tasks.**

| Task | What the environment may do | What is asserted | Result |
|---|---|---|---|
| `legacy_g0`, `legacy_g4` | PROTO = 0. The master follows the legacy protocol with any framing, repeatedly: 8 bytes written, wait for DATA_READY, 6 bytes read. It never pauses for the timeout inside a transaction. | Each transaction issues exactly `cfg(atan0 << GUARD)` and then `rot({y, x}, alpha)` with the bytes written, and the 6 bytes read are {sin, cos, 0} of that result. | PASS, 60 s and 50 s |
| `recover_g4` | First anything at all (lost bytes, early reads, aborted transactions), then quiet for the timeout, then the protocol. | The same theorem for every transaction after the quiet period. | PASS, 72 s |
| `cmd_g0`, `cmd_g4` | PROTO = 1. Any frames at all, any core latency. | Checked against a shadow model of both 4-deep queues: an instruction is queued exactly for an accepted EXEC frame with that frame's op and operands; ERR is set exactly for a rejected frame; instructions start in order, one at a time, only when a result slot is free; a result is removed exactly by a frame of at least 5 bytes whose snapshot showed VALID; every MISO byte is STATUS, RD or FLAGS as of the frame start, then zeros; DATA_READY and BUSY show not-ready from the EXEC command byte on. | PASS, 191 s and 192 s |
| `switch_g4` | The PROTO pin is any sequence, with any frames. | **S1** only a frame that began in command mode moves the queues. **S2** the protocol changes only with CS high, the last frame's end seen and nothing open. **S3** no legacy transaction is open in command mode and no command state is held in legacy mode. | PASS, 1 s |
| every task | | **A1** and **A2**, the two facts N1S assumes about `tx_data` and `tx_next`. | PASS |
| `cov_legacy`, `cov_cmd`, `cov_switch` | | A legacy transaction completes; the instruction queue fills and results wait during a frame; command, then a legacy transaction, then command again with an accepted EXEC. | PASS |

**Result.** 9 tasks, all PASS, 13 minutes. N2 found the byte-position wrap, the stale read byte and the timeout bug listed in `docs/FORMAL.md`, and the `switch` task was added after a review found a frame could be acted on by the other protocol.

### F2: the CORDIC engine

**Purpose.** Show that `xcordic_engine` computes the specified micro-rotation at every iteration, for every mode, direction and operand, including its lookahead registers, which were added to shorten the critical path and are easy to get wrong by one iteration.

**Design under proof.** `src/xcordic_engine.v`, `src/xcordic_atan.v` and `src/xc_add.v`, all real RTL, compiled with `XC_FV_ENGINE` (`props/xcordic_engine_props.vh`). The engine is its own top.

**Construction.**
- A shadow copy of the recurrence, written with the specification's `sp_step`, runs in lockstep with the RTL. The assertion that the RTL's `o_x`, `o_y`, `o_z` equal the shadow in every cycle is the inductive invariant.
- Further assertions: a run takes exactly `sp_niter(mode)` iterations and `o_done` pulses as `o_busy` falls; outputs hold while idle; a start while busy is ignored; the registered shift and angle for this iteration, the shift and series terms for the next, and the shift (with 3× and 5× of it) for the one after, each equal the reference generator's value for their iteration.
- Assumptions: only the commands the core can issue (direction 3 only in linear mode), and the angle constants held during a run.
- `XC_GUARD` picks the specification's datapath and `chparam` picks the RTL's: `g0` is 16 bits with 13 iterations, `g4` is 20 bits with 15 circular and 17 linear and hyperbolic.
- Engine: k-induction, depth 18 (`g0`) and 21 (`g4`), one more than the longest run.

**Result.** 4 tasks, all PASS, 24 minutes (`prove_g4` 18 min, `prove_g0` 5 min, two covers).

### F3: the core sequencer

**Purpose.** Show that for every instruction, operand and configuration value, `xcordic_core` launches exactly the engine passes the specification prescribes and returns exactly the specified result and flags.

**Design under proof.** `src/xcordic_core.v` and `src/xc_add.v`, real RTL, compiled with `XC_FV_CORE` (`props/xcordic_core_props.vh`). The engine and the exact unit are replaced by their contracts, so their results are arbitrary values.

**Construction.** Two layers:

- **F3a (`a_*` tasks, k-induction from reset, unbounded).** Control invariants: the state is legal; one engine run at a time; every reachable idle state is "clean" (no run, no pending launch); the one-hot decode equals `1 << op` while an instruction runs; the exact unit is started only from idle. **Stutter lemma**: while the core waits for the engine, or idles, no instruction state changes. Also the start/busy/done contract that N2 and F5 rely on, and that cfg registers change only on cfg.
- **F3b (`b_*` tasks, BMC, one instruction per task).** The trace starts from **any** clean idle state: every operand, every cfg value, any leftover scratch state. One instruction is accepted in cycle 0. The assertions compare every engine launch (mode, direction, x, y, z) and the final `rd` and flags with `sp_alg`, and require completion within 34 cycles. The opcode is a literal define, so each task elaborates only one instruction's branch of the specification.

Why the two layers together give the full theorem: F3a shows every reachable idle state is clean, so F3b's arbitrary clean start covers every real one. F3b runs with engine passes of 1 cycle; the stutter lemma shows a longer pass changes nothing. So every instruction in every reachable execution meets `sp_alg`.

For sqrt, mul and div (ops 15, 16, 17) the assertions are different: the core must start the exact unit in the accepting cycle with the right op and operands, run no engine pass, and return the unit's result sign-extended with its flags.

Task names: `b_op<n>_g<guard>` for FUNCS = 1, `b0_op<n>_g<guard>` for the FUNCS = 0 subset (ops 0–7), `cov_op<n>` for the longest pass sequence of each multi-pass instruction.

**Result.** 70 tasks, all PASS, 12 minutes. 4 invariant tasks, 56 instruction tasks (20 + 8 per datapath) and 10 covers.

### F5: the self-test unit

**Purpose.** `xc_bist` sits in the path of every instruction. Show that it is invisible outside a self-test, and that a self-test does exactly what the datasheet says, so its signature means something.

**Design under proof.** `src/xc_bist.v` compiled with `XC_FV_BIST` (`props/xc_bist_props.vh`). Top: `tb/fv_bist_top.sv`, with the core contract and free source inputs.

**Construction.**
- Assumption: the source starts an instruction only when busy is low, as `xc_frame` does.
- A specification copy of one self-test runs alongside: its instruction counter, LFSR and signature register.
- Assertions:
  - **T** outside a self-test the unit is a wire in both directions.
  - **B** a self-test with N and a seed issues exactly N core instructions, the k-th with the k-th op of the cycle (0–6, 8–19; FUNCS = 0: 0–6) and the next two LFSR values as operands; no other instruction reaches the core meanwhile; done pulses once with the signature of the N results, flags folded into bits 31:30.
  - **C** towards the source it keeps the core's own handshake contract.
  - **R** the registered output stage.
- Engine: k-induction, depth 12. `bmc_f1` runs the same properties bounded to 48 cycles: a bug several instructions deep then shows as a trace instead of as an inconclusive induction.

**Result.** 4 tasks, all PASS, 1.4 minutes (FUNCS 1 and 0 unbounded, one cover, one BMC).

### F6: the exact unit

**Purpose.** F3 treats `xc_exact` as a contract. F6 proves the real unit keeps that contract, and that its result depends only on the operands and not on what an earlier operation left behind.

**Design under proof.** `src/xc_exact.v` compiled with `XC_FV_EXACT` (`props/xc_exact_props.vh`). For the miter, `tb/fv_exact_miter.sv` holds two copies.

**Construction.**
- **F6a (`contract`, k-induction).** Busy rises the cycle after an accepted start; done pulses exactly as busy falls, once per start; a run takes 3 to 23 cycles from start to done; `rd` and flags change only while busy. A cycle counter since the start is the inductive invariant.
- **F6b (`miter`, k-induction).** Two copies start idle from arbitrary, different internal states and get the same op and operands. The assertion is that from the second cycle on, every register a run depends on is equal in both. (`XC_FV_EXACT_MITER` adds a formal-only port that exposes those registers.) Stated this way the property is inductive; comparing only the final results needed the solver to unroll two 17-step dividers and did not finish.
- **`cover`.** Each operation's normal path and each special case completes.

The arithmetic values are **not** proved here. A SAT solver does not handle 16-bit multiplication and division at this size, so the values are checked for every operand by simulation (section 5). F6b is what makes that simulation complete: the simulation runs the operations back to back from one history, and F6b shows the history cannot matter.

**Result.** 3 tasks, all PASS, 35 seconds.

### F7: the adder and the angle generator (SAT)

**Purpose.** Two blocks were rewritten for the slow corner: the adders became Kogge-Stone prefix adders (`xc_add`), and the angle generator was split into two stages. F7 shows both rewrites compute the same function as before.

**Design under proof.** `src/xc_add.v`; and `xcordic_aterms` + `xcordic_asum` against the reference `xcordic_aval`, all in `src/xcordic_atan.v`.

**Construction.** `f7/add_eq.v` and `f7/aval_eq.v` put the two forms side by side and output `ok = (a == b)`. `f7/run.sh` asks yosys `sat -prove ok 1` for every input.
- **F7a.** `xc_add` equals `a + b + ci` at widths 2, 3, 5, 16, 17, 19, 20, 21, 24 and 46.
- **F7b.** The two-stage generator equals `xcordic_aval` for every mode, shift and constant, at 16 bits / GUARD 0 and 20 bits / GUARD 4.

**Result.** 12 of 12 PASS, in seconds (`results/f7.log`). F7a is also what allows the exhaustive sweep to simulate the adder as `a + b + ci`.

## 4. The proofs of the original design

These run on the unmodified ttsky25a RTL in `third_party/ttsky_orig/`, with properties injected into build copies. They give the baseline and they found the faults this design fixes.

### O1: the original SPI slave

**Purpose.** The same question as N1, asked of the original `SPI_Slave`: at which timings does it carry every bit?

**Design under proof.** A build copy of `spi_slave.v` with `props/o1_slave_props.vh`. Top: `tb/fv_spi_top.sv` with `SLAVE_ORIG`.

**Construction.** The same timed master, one byte per CS frame (the original protocol). Assertions M, S and F as in N1, with F also requiring one `tx_req` per frame, before `rx_valid`, both while CS is low. `sby/gen_o1.sh orig` writes the sweep. Engine: PDR.

**Result.** 22 tasks: 7 timings PASS, 13 FAIL, 2 covers PASS. 23 minutes. Mode 0 needs SCLK high ≥ 4, low ≥ 5 and CS setup ≥ 4 core clocks, which is at most 5.5 MHz with a 50 MHz clock. The counterexamples show why: MOSI is sampled unsynchronised 3–4 clocks after the edge, and MISO changes 4–5 clocks after the falling edge.

### O2: the original frame FSM

**Purpose.** Does the original `cordic_fsm` implement its documented protocol, and does it recover after a protocol error?

**Design under proof.** A build copy of `top_fsm.v` with `props/o2_fsm_props.vh`. The SPI slave and the CORDIC are replaced by `spi_slave_contract.v` and `cordic_top_contract.v`.

**Construction.** A byte-level master drives CS.
- **`proto`**: the master follows the protocol forever. Asserted: each transaction launches the CORDIC once with exactly the 8 bytes written, the 6 bytes read are its outputs, and the FSM ends in its reset state.
- **`recover`** (`O2_FREE`): first any frames, then CS high for 16 cycles, then the protocol. The same assertions for the transactions that follow.
- Engine: PDR.

**Result.** `proto` PASS (unbounded, 23 min), `cover` PASS, **`recover` FAIL, as expected**: after one stray byte the next transaction launches with only 7 of its own bytes. The FSM counts bytes and never re-frames. This is the lock-up that N2 `recover` proves absent in the new design.

### F4: the original CORDIC datapath

**Purpose.** Pin down what the taped-out datapath computes, so the new design's `rot` can be shown to agree with silicon.

**Design under proof.** Build copies of `CORDIC_Engine_v1.v` and `top_CORDIC_Engine_v1.v` with `props/ttsky_engine_props.vh` and `props/ttsky_top_props.vh`, plus the unmodified `dynamic_atan.v`. Harness: `tb/fv_silicon.sv`.

**Construction.**
- **F4a (`engine`, k-induction).** Every run of the engine is the specification's circular rotation recurrence, step for step, with the angle input of each iteration.
- **F4b (`top`, BMC over one transaction from reset).** The top starts the engine on the quadrant-reduced angle, feeds iteration k the angle the specification gives (the input constant, then 1880, 1003, 510, 256, then powers of two), and un-maps the quadrant on the way out.

**Result.** 3 tasks, all PASS, 1.3 minutes. The proof also showed three pipeline flops in the original top have no reset.

## 5. Checks that are not proofs

### Equivalence with the reference core (`equiv/`)

**Purpose.** The core was retimed for the slow corner. Show the retimed core returns the same results as the one before the rework.

**Construction.** `equiv/ref/` holds the earlier RTL. `equiv/run.sh` builds both with Verilator and `equiv.cpp` feeds them the same instruction stream, comparing `rd` and flags whenever each one finishes (they may take different numbers of cycles). The stream is every input of every one-operand instruction, 200,000 random instructions with cfg writes, and 40 self-test runs, at GUARD 4 and 0.

**Result.** 789,864 instructions, 0 mismatches (`results/equivalence.log`).

### Exhaustive simulation (`exhaustive/`)

| Check | Construction | Result |
|---|---|---|
| Exact unit (`run_exact.sh`) | `xc_exact` in Verilator against exact integer arithmetic written from the definition, flags included: mul and div on all 2³² operand pairs, sqrt on all 2¹⁶ inputs. | 0 mismatches (`results/exact_*.txt`) |
| One-operand functions (`run_pairs.sh unary`) | The whole core, every input of sin, cos, tan, exp, ln, sqrt, tanh, against the golden model `xc_model.hpp`, with the error measured against long-double libm. | bit-exact; worst errors in `results/accuracy_unary.txt` |
| Two-operand functions (`run_pairs.sh 4`) | The whole core at GUARD 4, all 2³² pairs of atan2, hypot, mul and div, against the golden model. | 0 mismatches; worst errors 1.07 LSB (atan2), 0.81 LSB relative (hypot), 0.50 LSB (mul, div) (`results/accuracy_pairs.txt`) |

The two-operand run used `ADD=plus`: `xc_add.v` is swapped for `xc_add_plus.v` (`a + b + ci`), which Verilator simulates about five times faster. F7a proves the two are equal. An evenly spread 1.3 % sample with the real adder is also bit-exact. GUARD 0 was not re-run for the two-operand functions.

### Mutation testing (`mutate.sh`)

**Purpose.** A proof that passes might be passing because it checks too little. Mutation testing puts a known bug into a copy of the project and runs the proof that should catch it.

**Construction.** Each mutant is one `sed` edit to one source file, with the task that must then FAIL. Mutants in the exact unit's arithmetic are judged by `exhaustive/exact.cpp smoke`, since the proofs treat those values as arbitrary.

**Result.** 52 of 52 caught (`results/mutate.log`). The table of mutants is in `docs/FORMAL.md`.

## 6. Results

| Group | Subject | Tasks | PASS | FAIL | Time | About the failures |
|---|---|---|---|---|---|---|
| N1 | default SPI slave, timing sweep | 26 | 20 | 6 | 11 min | timings outside the datasheet |
| N1c | default slave, byte contract | 1 | 1 | 0 | 1 s | |
| N1S | SCLK-domain slave | 20 | 16 | 4 | 90 min | timings outside the datasheet |
| G1 | default slave at the pads | 20 | 14 | 6 | 74 min | the `_x` tasks: one step past each limit |
| N2 | frame logic | 9 | 9 | 0 | 13 min | |
| F2 | CORDIC engine | 4 | 4 | 0 | 24 min | |
| F3 | core, every instruction | 70 | 70 | 0 | 12 min | |
| F5 | self-test unit | 4 | 4 | 0 | 1.4 min | |
| F6 | exact unit | 3 | 3 | 0 | 0.6 min | |
| O1 | original SPI slave, timing sweep | 22 | 9 | 13 | 23 min | timings the original cannot do |
| O2 | original frame FSM | 3 | 2 | 1 | 24 min | the lock-up |
| F4 | original CORDIC datapath | 3 | 3 | 0 | 1.3 min | |
| | **Total** | **185** | **155** | **30** | **4.5 h** | |

A FAIL in a sweep is a result, not a defect: the counterexample trace shows exactly how that timing breaks, and the row above it in the table is the proven limit. The per-task list with times and failing assertions is `results/summary.md`; each task's log and traces are under `results/tasks/`.

## 7. What is not proved

- **The arithmetic of mul, div and sqrt** is checked by exhaustive simulation, not by a solver. F6b makes that simulation complete.
- **Accuracy** (how far a result is from the true value) is measured, not proved. The proofs show the RTL equals the specification; the exhaustive runs measure the specification's error.
- **`project.v`** has no proof of its own. It wires the blocks together and puts two flops on `rst_n` and PROTO. N2 `switch` holds for any PROTO sequence, every block's proof starts from a synchronous reset, and the simulations in `test/` run the whole chip, including a reset inside a frame.
- **Timing in nanoseconds** inside the chip is a static-timing question (`docs/info.md`). The proofs are in logical time; G1 carries the SPI proof to the pads through the signoff I/O budget.
- **Metastability lasting longer than a clock** is not modelled. N1 and G1 let a sampled input fall either side of an edge; N1S lets a synchroniser's first flop resolve either way.
- **The host's side of the legacy protocol.** N2 `legacy` assumes the master does not pause for the timeout (2²⁸ clocks, 10.7 s at 25 MHz) inside a transaction. The datasheet states that as a requirement.
- **The tools** are trusted: Yosys, SymbiYosys, yices, ABC, Verilator, g++.

## 8. Folder layout

| Path | What |
|---|---|
| `run.sh` | runs every proof group, or the ones named; writes `build/summary.txt` and `build/logs/` |
| `sby/*.sby` | the proof tasks, one file per group |
| `sby/gen_o1.sh`, `gen_n1s.sh`, `gen_g1.sh` | write the O1, N1, N1S and G1 timing sweeps |
| `props/` | properties, one file per proved module |
| `spec/` | the executable specification (`xcordic_spec.vh`) and the instruction encoding |
| `models/` | contracts that stand in for submodules |
| `tb/` | harnesses: the timed SPI master, the I/O delay model, tops and miters |
| `tools/inject.sh` | builds the property-injected copies and checks one `` `include `` is the only change |
| `tools/summary.sh` | rebuilds the summary table from the task folders, without solving |
| `f7/` | SAT equivalence of the adder and the angle generator |
| `equiv/` | Verilator equivalence of the core against `equiv/ref/` |
| `exhaustive/` | exhaustive simulation: `run_exact.sh`, `run_pairs.sh`, the golden model `xc_model.hpp` |
| `sta/gf_pads.tcl` | OpenSTA measurement of the GF26c pad cells, for G1's delay windows |
| `mutate.sh` | mutation testing |
| `results/` | outputs of the last full run |

`results/` holds `summary.md` and `summary.txt` (per-group and per-task results), `tasks/<task>/` (each task's status, log, and counterexample or cover traces as `.vcd` for GTKWave), `f7.log`, `equivalence.log`, `exact_*.txt`, `accuracy_unary.txt`, `accuracy_pairs.txt` and `mutate.log`.

## 9. Running

Needs the OSS CAD Suite (yosys, sby, yices-smt2 and yosys-abc from the same release). The equivalence and exhaustive checks also need Verilator 5 and g++.

```
cd formal
./run.sh                    # everything: about 4.5 h of solver time
JOBS=4 ./run.sh f3 f2 f5    # selected groups: o1 o2 f4 n1 n1c n1s g1 n2 f2 f3 f5 f6
./tools/summary.sh          # summary from the task folders
./f7/run.sh                 # seconds
./equiv/run.sh              # a few minutes
./exhaustive/run_exact.sh   # about 85 min per op
ADD=plus ./exhaustive/run_pairs.sh 4   # about 6 h on 2 cores (about 30 h without ADD=plus)
./mutate.sh                 # all 52 mutants; ./mutate.sh n03 n07 for selected ones
```

`run.sh` deletes and re-runs the task folders of the groups it runs, and keeps the summary lines of the groups it does not.

To look at a failure: open `results/tasks/<task>/trace.vcd` in GTKWave (cover tasks write `trace0.vcd`, `trace1.vcd`, ...). The failing assertion's file and line are in the task's `logfile.txt` and in the last column of `results/summary.md`.
