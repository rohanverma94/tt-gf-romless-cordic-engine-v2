# Formal verification

This project is verified formally, with SymbiYosys, against two designs:

- **`tt_um_xcordic`**, this project (`src/`).
- **The original ttsky25a CORDIC design** (`third_party/ttsky_orig/`). Its proofs give the baseline this design is compared with, and they found the bugs this design fixes.

Unzip `formal/results.zip`. That should place the results in `formal/results`.

`formal/run.sh` runs every proof, `formal/mutate.sh` shows the proofs catch bugs, and `formal/results/` holds the outputs of the last full run (`formal/results/summary.md`). Third-party RTL is never edited: properties reach its internals through a build copy with one added `` `include`` line, and `formal/tools/inject.sh` checks that this is the only change.

## Results
185 proof tasks: **155 PASS, 30 FAIL, all 30 expected**. Every proof of `tt_um_xcordic` inside the datasheet's operating conditions passes.

| Group | What | Tasks | Result | Solver time |
|---|---|---|---|---|
| O1 | original SPI slave, timing sweep + 2 covers | 22 | 9 PASS, 13 FAIL (the timing table below) | 23 min |
| O2 | original frame FSM: protocol, recovery, cover | 3 | proto **PASS** (unbounded), recover **FAIL** (the lock-up), cover PASS | 24 min |
| F4 | original CORDIC engine and quadrant top | 3 | PASS | 1 min |
| N1 | SPI slave, timing sweep + 2 covers | 26 | 20 PASS, 6 FAIL (all outside the datasheet timings) | 11 min |
| N1c | SPI slave keeps its byte contract | 1 | PASS | 1 s |
| N1S | SCLK-domain slave (`SPI_SCLK = 1`): bits, bytes, CDC, contract | 20 | 16 PASS, 4 FAIL (outside the datasheet), both covers | 90 min |
| G1 | default slave at the GF26c pads, through the I/O delays | 20 | 14 PASS (12 proofs, 2 covers), 6 FAIL (documented limits) | 74 min |
| N2 | frame FSM: legacy ×2, recover, command ×2, protocol switch, 3 covers | 9 | **all PASS** (unbounded) | 13 min |
| F2 | Xcordic engine, GUARD 0 and 4, prove + cover | 4 | PASS | 24 min |
| F3 | Xcordic core, every instruction, GUARD 0 and 4 | 70 | PASS | 12 min |
| F5 | `cordic.bist` self-test unit, FUNCS 1 and 0, cover, BMC | 4 | **all PASS** (unbounded) | 1.4 min |
| F6 | exact mul/div/sqrt unit: contract, cover, operands-only miter | 3 | **all PASS** (unbounded) | 0.6 min |

About 4.5 hours of solver time in all. The per-task list, with times and failing assertions, is `formal/results/summary.md`.

Besides the SymbiYosys proofs:

| Check | Result |
|---|---|
| F7: SAT equivalence (`formal/f7/run.sh`): the Kogge-Stone adder `xc_add` equals `a + b + ci` at every width the design uses (2–46 bits); the two-stage angle generator equals the reference `xcordic_aval` (W16/GUARD 0, W20/GUARD 4) | 12/12 PASS (`results/f7.log`) |
| Equivalence (`formal/equiv/run.sh`, Verilator): the core against the reference core in `formal/equiv/ref/` (the design before the slow-corner timing rework), instruction by instruction, rd and flags, GUARD 4 and 0: every one-operand input, 200,000 random instructions with cfg writes, 40 self-test runs | 789,864 instructions, 0 mismatches (`results/equivalence.log`) |
| Exhaustive exact unit (`formal/exhaustive/run_exact.sh`): mul and div on all 2³² operand pairs, sqrt on all 2¹⁶ inputs, against exact integer arithmetic, flags included | 0 mismatches (`results/exact_*.txt`) |
| Mutation testing (`formal/mutate.sh`) | 52/52 mutants killed (`results/mutate.log`) |

## Method

**Timed SPI master.** `formal/tb/spi_master_model.v` is an SPI master in core-clock cycles:
- CPOL = 0, mode 0 or mode 1.
- SCLK high ≥ H, low ≥ L, CS-to-first-edge ≥ S.
- Every phase lasts at least its minimum, and any longer, chosen freely each time. That covers any alignment between an asynchronous master and the core clock, and every slower master: a PASS at a timing is a PASS at every slower timing.
- Bytes are free choices.

**Local per-bit properties.** The SPI theorems are per bit: each sample takes the right bit at the right index. That keeps them local in time and tractable with jitter. The equivalent end-of-frame byte checks were intractable.

**Contracts.** The frame FSMs are proved with the SPI slave and the CORDIC replaced by their contracts. Each contract is discharged by its own proof (O1/N1 for the SPI slave, F4/F3a for the CORDIC).

**Composition.**
- Original design: O1 (bytes) + O2 (frames) + F4 (CORDIC) = the whole design.
- This design: N1 + N2 + F2/F3, with F5 and F6 for the self-test and the exact unit.

**Engines.**
- The SPI and frame theorems (O1, O2, N1, N1S, G1, N2) are proved **unbounded** with ABC's PDR (IC3), so they hold for any number of frames and transactions, not just to a depth. Counterexamples come from the same run.
- Every unbounded theorem has a cover task showing its environment reaches complete frames or transactions, so no assumption is vacuous.
- F2/F3 use k-induction and complete BMC; F5 and F6 use k-induction.

## The original design (ttsky25a)

| ID | Theorem | Result |
|---|---|---|
| **O1** | `SPI_Slave` carries every bit of every byte both ways, with one rx_valid and one tx_req per frame, for a given master timing | timing table below: PASS = proved for every byte and jitter, FAIL = counterexample |
| **O2a** | `cordic_fsm` with a master that follows the documented protocol: in every transaction the CORDIC gets exactly the 8 bytes written, the 6 bytes read are its outputs, and the FSM ends the transaction in its reset state | **PASS** (unbounded) |
| **O2b** | same, after any frames at all followed by a quiet period | **FAIL**: after one stray byte, the next transaction launches with only 7 of its own bytes |
| **F4** | the CORDIC engine runs the rotation recurrence; the quadrant top maps and unmaps as specified | PASS |

### O1: SPI timing of the original slave (core clocks; at 50 MHz, 1 clock = 20 ns)

Each row is one unbounded proof (PDR): it holds for every frame, every byte and every choice of phase lengths ≥ the minimums (in core clocks).

| Master | SCLK high ≥ | SCLK low ≥ | CS setup ≥ | Result | Failing property |
|---|---|---|---|---|---|
| mode 0 | 2 | 5 | 5 | FAIL | MOSI bit: slave samples after the master changed MOSI |
| mode 0 | 3 | 5 | 5 | FAIL | MOSI bit |
| mode 0 | **4** | 5 | 5 | **PASS** | |
| mode 0 | 5 | 2 | 5 | FAIL | MISO bit: new bit not yet on MISO at the master's sample |
| mode 0 | 5 | 3 | 5 | FAIL | MISO bit |
| mode 0 | 5 | 4 | 5 | FAIL | MISO bit |
| mode 0 | 5 | 5 | 1, 2, 3 | FAIL | CS seen: master samples the MSB before the slave latched it |
| mode 1 | 1 | 5 | 5 | PASS | |
| mode 1 | 2 | 5 | 5 | PASS | |
| mode 1 | 5 | 1 | 5 | PASS | |
| mode 1 | 5 | 2 | 5 | PASS | |
| mode 1 | 2 | 2 | 5 | FAIL | MISO bit |
| mode 1 | 2 | 1 | 5 | FAIL | MISO bit |
| mode 1 | 1 | 2 | 5 | FAIL | bit index |
| mode 1 | 3 | 1 | 5 | FAIL | MISO bit |
| mode 1 | 1 | 3 | 5 | FAIL | MISO bit |
| mode 1 | 5 | 5 | 1, 2 | PASS | |

**Mode 0** needs high ≥ 4 and low ≥ 5 (low = 4 fails), so the SCLK period is ≥ 9 clocks = 180 ns at 50 MHz: **≤ 5.5 MHz guaranteed**. It also needs CS setup ≥ 4. **Mode 1** passes with a period of 6 clocks (1+5, 5+1, 2+5, 5+2) and fails at 4 (2+2, 1+3, 3+1): **≤ 8.3 MHz guaranteed**, with any CS setup.

What the counterexamples show:

1. **MOSI race (mode 0).** MOSI is sampled raw, 3–4 clocks after the SCLK rising edge has passed through the 3-flop synchronizer. A mode-0 master changes MOSI on the falling edge, so SCLK high must last at least 4 clocks (80 ns). At 8.33 MHz (60 ns high) the slave reads the next bit.
2. **Late MISO (mode 0).** MISO changes 4–5 clocks after the falling edge, and the master samples on the next rising edge. So SCLK low must last at least 5 clocks (100 ns). With the high-time limit, mode 0 needs a 180 ns period, ≈ 5.5 MHz.
3. **CS setup (mode 0).** The MSB appears only when the synchronized CS falls, so the first edge must come at least 4 clocks after CS.
4. **Mode 1 works by accident.** The slave is mode 0, but with a mode-1 master it samples MOSI just after the bit was put out and drives MISO a full period ahead. It works for periods down to about 6 clocks and fails at 4.

### Further findings

5. **One byte per CS frame only.** The transmit shifter reloads only when CS falls. Holding CS low across bytes returns the first byte, then zeros (`test/tb_spi.v -DORIG +MULTI=1`).
6. **No resynchronization (O2b).** The FSM counts bytes and never re-frames. A lost byte, an extra byte, or a read before DATA_READY misaligns every later transaction until reset.
7. **Unsynchronized `cs_n`.** `S_DONE` reads the raw `cs_n` pin, an asynchronous input into an FSM (by inspection).
8. **Unreset pipeline flops** in `top_CORDIC_Engine_v1` (from F4): `diff_valid`, `quadrant_valid` and `r_quadrant_valid` power up arbitrary.
9. **Stage-1 angle 19 codes short**: Taylor 1880 vs atan(1/2) = 1899. A per-half `i_atan_0` calibration compensates on a 250-angle grid; exhaustively it leaves errors up to 32.5 LSB within ±0.25° of 45°, 135°, 225° and 315°.
10. **The original cocotb test checks nothing.** It logs the bytes it reads without asserting them. It also clocks SCLK at 25 MHz against a 100 MHz core, which leaves 2 clocks of SCLK high time: inside the MOSI race of finding 1.

## tt_um_xcordic

| ID | Theorem | Result |
|---|---|---|
| **N1** | `xc_spi_slave` carries every bit of every byte both ways, in one-byte and multi-byte frames, both SPI modes, for a given master timing; byte 0 is one consistent snapshot | timing table below (unbounded) |
| **N1c** | `xc_spi_slave` keeps the byte contract N2 assumes, for any inputs at all | **PASS** (unbounded) |
| **N1S** | `xc_spi_slave_sclk` (`SPI_SCLK = 1`): bits both ways, bytes, the N2 byte contract, and CDC safety, with metastable synchronizers, at quarter-clock time resolution | timing table below (unbounded) |
| **G1** | the default slave at the GF26c chip's pads, through the I/O delays | below and `docs/GF26C_IO.md` (unbounded) |
| **N2 legacy** | the legacy protocol, any framing, any number of transactions: each issues exactly `cfg(atan0 << GUARD)` then `rot({y,x}, alpha)` with the written bytes, and the 6 bytes read are {sin, cos, 0} of that rot. The master never pauses for the timeout inside a transaction. | **PASS** (unbounded, GUARD 0 and 4) |
| **N2 recover** | after anything at all, then a quiet period ≥ the timeout, the legacy protocol works again | **PASS** (unbounded) |
| **N2 cmd** | any frames at all: an instruction is queued exactly for an accepted EXEC frame, with the frame's op and operands; queued instructions start in order, one at a time, only when their result has a place; results are taken off exactly by frames of ≥ 5 bytes whose snapshot showed VALID; ERR is set exactly for rejected frames (incl. a full queue); every MISO byte is STATUS/RD/FLAGS as of the frame start. Checked against a shadow model of both 4-deep queues; each result carries its flags through the queue, and byte 5 is the FLAGS of the result shown. Any core latency. | **PASS** (unbounded, GUARD 0 and 4) |
| **N2 switch** | the PROTO pin is any sequence, with any frames: the protocol changes only with CS high, the last frame closed and nothing open in either protocol; a frame moves the queues (instruction accepted, result removed) only if it began in command mode; no legacy transaction is open in command mode and no command state is held in legacy mode | **PASS** (unbounded) |
| **N2 A1/A2** | what the SCLK-domain slave relies on: `tx_data` holds from the last idle cycle to the frame's first byte; `tx_next` changes only right after a byte or `frame_start` (command mode always; legacy read phase) | **PASS** (unbounded, in every N2 task) |
| **F2** | the Xcordic engine computes the specification's micro-rotations for every mode, direction and operand (GUARD 0 and 4), including the rounded linear product pass that holds at z = 0. Its lookahead registers (the shifts of the coming iterations, the next one's series terms, 3× and 5× the shift) equal the reference generator's values for their iteration. | **PASS** |
| **F3** | the Xcordic core computes the specification `sp_alg` for every instruction, operand and cfg value (GUARD 0 and 4), rd and flags (SAT = a 16-bit result, either half of a pair, was clipped; INV = invalid argument), with the engine replaced by its contract. One task per instruction, complete BMC up to 34 cycles. This covers the capture and timing registers (shifted lanes, quadrant-mapped sin/cos, the scaler, the zero flags for the early finishes) and the one-hot decode (equal to 1 << op while an instruction runs). sqrt, mul and div run on the exact unit, which F3 replaces by its contract (any result, any flags; F6 proves the real unit keeps it): F3 proves the core starts it in the accepting cycle with the right op and operands, runs no engine pass, and returns its result sign-extended with its flags. | **PASS** (70 tasks) |
| **F5** | `xc_bist`: outside a self-test it is a wire between the frame and the core; `cordic.bist` with N and a seed issues exactly N core instructions, the k-th with the k-th op of the cycle (0–6, 8–19; FUNCS = 0: 0–6) and the next two LFSR values as operands, accepts no other instruction meanwhile, and returns the MISR of the N results (flags in bits 31:30) once; to the frame it keeps the core's start/busy/done contract, through its registered output stage. The core is its F3a contract. | **PASS** (unbounded, k-induction, FUNCS 1 and 0) |
| **F6** | `xc_exact` (exact mul, div, sqrt). F6a: the contract F3 assumes: busy from the cycle after an accepted start, done exactly as busy falls, once per start, 3–23 cycles from start to done, rd and flags held while idle. F6b: two copies started from arbitrary, different idle states with the same operands have equal state from the second cycle on, so the result depends only on (op, a, b). The values are checked for every operand by `formal/exhaustive/exact.cpp`: a SAT solver cannot handle 16-bit multiplication and division at this size. | **PASS** (unbounded, k-induction) |
| **F7** | `xc_add` = `a + b + ci`; the two-stage angle generator = `xcordic_aval` (SAT, all inputs) | **PASS** |

### N1: SPI timing of the slave

Unbounded proofs (PDR), any number of frames. Same master model as O1. CS high between frames ≥ 5 clocks.

| Master | SCLK high ≥ | SCLK low ≥ | CS setup ≥ | other | Result | Failing property |
|---|---|---|---|---|---|---|
| mode 0 | 1 | 5 | 5 | | PASS | |
| mode 0 | 2 | 5 | 5 | | PASS | |
| mode 0 | 5 | 1 | 5 | | PASS | |
| mode 0 | 5 | 2 | 5 | | PASS | |
| mode 0 | 1 | 3 | 5 | | PASS | |
| mode 0 | **2** | **2** | 5 | | **PASS** | |
| mode 0 | 2 | 1 | 5 | | FAIL | MISO bit |
| mode 0 | 1 | 2 | 5 | | FAIL | MISO bit |
| mode 0 | 5 | 5 | 1, 2 | | FAIL | byte-0 snapshot: MSB sampled before the slave saw CS, from an older tx_data |
| mode 0 | 5 | 5 | **3** | | **PASS** | |
| mode 0 | 2 | 2 | 5 | 3 bytes per frame | PASS | |
| mode 0 | 5 | 1 | 5 | CS hold 2 after the last edge | PASS | |
| mode 1 | 1 | 5 | 5 | | PASS | |
| mode 1 | 2 | 5 | 5 | | PASS | |
| mode 1 | 5 | 1 | 5 | | PASS | |
| mode 1 | 5 | 2 | 5 | | PASS | |
| mode 1 | 1 | 3 | 5 | | PASS | |
| mode 1 | **2** | **2** | 5 | | **PASS** | |
| mode 1 | 2 | 1 | 5 | | FAIL | MISO bit |
| mode 1 | 1 | 2 | 5 | | FAIL | MISO bit |
| mode 1 | 5 | 5 | **1** | | **PASS** | |
| mode 1 | 2 | 2 | 5 | 3 bytes per frame | PASS | |
| mode 1 | 5 | 1 | 5 | CS hold 2 after the last edge | PASS | |

**Both modes:** SCLK high + low ≥ 4 clocks, with any split down to 1: a quarter of the core clock, where the original needs 9 clocks in mode 0. Multi-byte frames work, and CS may rise 2 clocks after the last edge.

**CS setup:** 3 clocks in mode 0 and 1 in mode 1. A mode-0 master samples the MSB on its first edge. With CS setup below 3, that edge comes before the slave's 2-flop synchronizer has seen CS, while it is still reloading `tx_data`. If the byte changes in that window, the master gets an MSB from one value and the other bits from the next. STATUS can change at any time, when an instruction completes. The original needs CS setup ≥ 4 for the same reason, but its MISO is not valid at all before then.

### N1S: the SCLK-domain slave (`SPI_SCLK = 1`)

`xc_spi_slave_sclk` shifts bits on SCLK and hands whole bytes across to the core clock, so the oversampling proof (N1) does not apply. N1S models time at a finer grain:
- **Time.** One tick is a quarter of the core clock. The core clock is 4 ticks, and the timed master runs on every tick.
- **Master.** Every phase lasts at least its minimum, and any longer, chosen freely. So a PASS holds for every slower master, at every alignment to the core clock.
- **Synchronizers.** The first flop of each synchronizer may resolve a just-changed input either way (`xc_meta`).

Theorems, all unbounded (PDR):
- **M:** every received byte equals the byte the master sent at that position.
- **S:** every byte the master reads is the one the N2 contract promises.
- **F:** each frame gives exactly its number of bytes.
- **C:** the byte contract N2 assumes holds at the clk side.
- **X (CDC safety):** each value crossing between the domains is stable for ≥ 2 ticks before the edge that captures it. The MSB a mode-0 master reads straight from `tx_data` is stable ≥ 4 ticks.

The environment assumptions about `tx_data`/`tx_next` (A1, A2) are proved for `xc_frame` by N2.

In ticks (a quarter core clock each):

| Master | SCLK high ≥ | low ≥ | CS setup ≥ | CS high ≥ | other | Result | Failing property |
|---|---|---|---|---|---|---|---|
| mode 0 | **3** | **3** | **12** | **16** | | **PASS** | |
| mode 0 | 3 | 1 | 12 | 24 | CS hold 2 ticks after the last edge | PASS | |
| mode 0 | 2 | 2 | 12 | 24 | | PASS | |
| mode 0 | 1 | 1 | 12 | 24 | | PASS | |
| mode 0 | 3 | 3 | 8 | 24 | | FAIL | MSB stability: first sample before byte 0 is frozen |
| mode 0 | 3 | 3 | 12 | 12 | | FAIL | MSB stability: the core never sees CS high, the next frame's byte 0 is not frozen |
| mode 0 | 3 | 3 | 12 | 24 | 2 bytes per frame, any pause between them | **PASS** | |
| mode 0 | 1 | 2 | 12 | 24 | 2 bytes per frame, any pause between them | **PASS** | |
| mode 1 | **3** | **3** | **8** | **16** | | **PASS** | |
| mode 1 | 3 | 1 | 8 | 24 | CS hold 2 ticks after the last edge | PASS | |
| mode 1 | 2 | 2 | 8 | 24 | | PASS | |
| mode 1 | 1 | 1 | 8 | 24 | | PASS | |
| mode 1 | 3 | 3 | 4 | 24 | | FAIL | CDC: byte 0 taken before it is frozen |
| mode 1 | 3 | 3 | 8 | 12 | | FAIL | CDC: as above, next frame |
| mode 1 | 3 | 3 | 8 | 24 | 2 bytes per frame, any pause between them | **PASS** | |
| mode 1 | 2 | 1 | 8 | 24 | 2 bytes per frame, any pause between them | **PASS** | |

Covers: two complete frames are reachable in both modes.

**Result:** SCLK periods down to 3 ticks (3/4 core clock) carry multi-byte frames with any pause between bytes, and one-byte frames go down to 2 ticks. CS setup must be ≥ 3 core clocks (mode 0) or ≥ 2 (mode 1), CS high ≥ 4 core clocks, and CS may rise half a core clock after the last edge. The bit logic itself has no core-clock limit; the I/O does (`docs/GF26C_IO.md`, `docs/info.md`).

### G1: the default slave at the GF26c pads

N1 is at the slave's ports, in core clocks. G1 puts the master at the chip's pads and the GF26c I/O between them. Every pin transition takes a freely chosen delay within the chip's signoff budget: pad → tile ≤ 5.0 ns, tile → pad ≤ 12.5 ns into 30 pF, plus the tile's port buffers. G1 proves the same theorem as N1 (bits, bytes, MISO, frame count), unbounded, in a multiclock real-time model with 20 ns and 10 ns ticks (2 and 4 per core clock at 25 MHz).

The model is `formal/tb/fv_iodelay.v` (a glitch-free wire with an unknown per-transition delay) and `formal/props/g1_slave_props.vh`. Where the delays come from, the soundness argument for the tick grid and the full table are in `docs/GF26C_IO.md`. Results at 25 MHz:

- A plain master (MISO read on its own edge) at 6.25 MHz, in mode 0 and mode 1, passes (10 ns model).
- Each SCLK phase must be ≥ 60 ns at the pads. A 40 ns phase fails: SCLK's rise and fall skew through the I/O, so the pulse can arrive shorter than one clock.
- CS setup must be ≥ 120 ns in mode 0. At 100 ns the byte-0 MSB fails, as at the ports.
- The MISO margin for a plain master is outward delay ≤ 20 ns proved, 30 ns failing: 7–17 ns beyond the budget.

There are 12 proofs, 2 covers and 6 documented limits (`_x`).

### Bugs the proofs and checks found in this design

All fixed. Each has a mutant in `formal/mutate.sh` that puts it back, and the named proof catches it.

- **Byte position wrap (N2).** In command mode the byte counter saturated at 15, but the next-byte index wrapped to 0, so a frame longer than 16 bytes resent STATUS instead of zeros. Mutant n08.
- **Stale read byte with a one-cycle CS gap (N2).** In legacy mode, with one byte per CS frame and CS high for about one core clock between read bytes, the slave preloaded the byte at the old read position. Reproduced in simulation (mode 1, SCLK 12 MHz, 16 ns CS gap: 2 of 20 transactions wrong). Fixed: the position used for the preload looks ahead in the cycle a read byte completes. Mutant n13.
- **Timeout counted the core's computing time (N2).** The legacy recovery timeout counted every cycle since the last byte, including the core's latency. A host that waited before reading could have its result dropped even though it was within the documented window. Fixed: the count is held while the core computes and restarts when DATA_READY rises. The default timeout is 2²⁴ clocks (0.67 s at 25 MHz), to give slow hosts such as MicroPython margin. Mutant n14.
- **Next byte taken too early after a pause (N1S).** The SCLK slave took the next byte from `tx_next` at that byte's first launch. If the master pauses between bytes (mode 1: any pause; mode 0: a long high phase after the last bit), the FSM has already counted the finished byte and moved `tx_next` on, so the master gets the byte after the right one. Fixed: the next byte is taken on the edge that samples the last bit of the current one. Mutant n20.
- **DATA_READY stale right after an EXEC (simulation).** DATA_READY and BUSY kept showing the previous instruction's state until the core clock had synchronized CS and processed the frame end, about 4 core clocks with the default slave and 7 with the SCLK slave. A host polling the pins right after raising CS saw "ready" and read the old result. Fixed: the pins go busy as soon as an EXEC command byte arrives, during the frame. N2 proves it. Mutant n21.
- **STATUS glitch in the `frame_start` cycle (simulation).** `xc_frame`'s `tx_data` indexed the snapshot with the previous frame's byte counter for one cycle, which the oversampled slave never sees but the SCLK slave can. Fixed; N2's lemma A1 covers it. Mutant n15.
- **DATA_READY fell after every read (simulation).** A first design of the queues raised DATA_READY only while an unread result waited. Since a read takes the result off, DATA_READY fell after every read, and a host that waits for DATA_READY before its next EXEC waited forever. Fixed: DATA_READY means every queued instruction has finished; VALID tells whether a result is waiting.
- **Unreset registers (gate-level simulation).** The self-test's counters and the queue entries had no reset. In RTL that is harmless, but in the gate-level netlist "load 0" into a counter that starts unknown stayed unknown, and synthesis wove the unknown queue contents into the frame's sequence counter: DATA_READY and BUSY went to X. Every register of `xc_bist` and every queue entry is now reset.
- **A frame acted on by the other protocol (review).** Every N2 task held the PROTO pin constant, so nothing covered a switch at run time. `xc_frame` kept the last command frame's registers through a legacy session and took the pin over before the last frame's end had been processed. With PROTO raised during the last legacy frame, or within two clocks of its CS rising, that legacy frame's end re-queued the last EXEC of the earlier command session (the instruction ran twice), or removed an unread result. The other way round, a read frame's result was not removed. Reproduced in simulation. Fixed: the pin is taken over only once the last frame is closed, and the command frame registers are held clear in legacy mode. The new task N2 switch proves it with the pin free. Mutants n51, n52; `test/tb_spi.v` and `test/test.py` switch at the critical instant.
- **A gap in the proof, found by a cover.** N2 once bounded the core's latency to 6 cycles. A 5-byte frame takes longer than that, so the core always drained the instruction queue before the next EXEC arrived: the queue never filled, and the FULL / reject path was never exercised. The cover "the instruction queue fills" was unreachable and exposed this. The command tasks now allow any core latency, and the queue fills. Mutant n35 (EXEC accepted with the queue full) is caught now and would have survived before.

Method notes:
- F6b first compared two copies' results as a bounded miter over a whole run. That asks the solver to show two unrolled 17-step dividers agree, and it had not finished after 12 minutes. Stated instead as "from the second cycle on, every register a run depends on is equal in both copies", the property is inductive and proves unbounded in under a minute.
- One planned mutant was equivalent: making the divide's overflow check `>` instead of `>=` changes nothing, because with |a| = 16 |b| the iteration produces an all-ones quotient that saturates to the same result. It was replaced (n36 drops a divide step).

## Exhaustive simulation (`formal/exhaustive/`)

- **Exact unit** (`run_exact.sh`): mul and div on all 2³² operand pairs, sqrt on all 2¹⁶ inputs, RTL (Verilator) against exact integer arithmetic written from the definition, not from the RTL's algorithm. Flags included. 0 mismatches; about 85 min per op on one core.
- **One-operand functions** (`run_pairs.sh unary`, about a minute): all 65,536 inputs of sin, cos, tan, exp, ln, sqrt and tanh on this RTL, bit-exact against the golden model, with the error measured against long-double libm (`formal/results/accuracy_unary.txt`). GUARD 4 worst errors: sin 1.18 LSB, cos 1.16, ln 1.18, tanh 0.80, sqrt 0.50, exp 1.10 relative; tan 5.63 relative, next to its poles.
- **Value functions** (`run_pairs.sh`): every operand pair of atan2, hypot, mul and div through the whole core, checked bit-exactly against the host harness's golden model (`formal/exhaustive/xc_model.hpp`), with the error measured against long-double libm. Run on this RTL at GUARD 4, all 2³² pairs of each function: 0 model mismatches, worst errors 1.07 LSB (atan2), 0.81 LSB relative (hypot), 0.50 LSB (mul, div) (`formal/results/accuracy_pairs.txt`). The full run used `ADD=plus`, which swaps the prefix adder `xc_add.v` for `a + b + ci` because the simulator runs that about five times faster (5.6 h on 2 cores instead of about 30 h); F7 proves the two equal at every adder width the design uses. An even 1.3 % sample (5.6·10⁷ pairs per function) with the real adder is also bit-exact. Resumable, and splittable across machines (`PART=i/n`). GUARD 0 was not re-run.

## Mutation testing

`formal/mutate.sh` copies the project, puts in one bug, and runs the proof that should catch it. All 52 are caught. A bug in the exact unit's arithmetic is judged by `formal/exhaustive/exact.cpp smoke` (corners, every sqrt input, 2 M random pairs; seconds), since the proofs abstract those values.

| Mutant | Bug put in | Caught by |
|---|---|---|
| n01 | MOSI sampled raw (the ttsky25a race) | N1 m0_h2_l2_s5 |
| n02 | slave on the wrong SCLK edge | N1 m0_h2_l2_s5 |
| n03 | no MSB preload while CS is high | N1 m0_h5_l5_s3 |
| n04 | multi-byte frames resend the same byte | N1 m0_h2_l2_s5_fb3 |
| n05 | MISO shifted one bit late | N1 m1_h2_l2_s5 |
| n06 | EXEC accepted from a frame without RS1 | N2 cmd_g4 |
| n07 | BUSY missing between EXEC and core start | N2 cmd_g4 |
| n08 | byte position wraps in long frames | N2 cmd_g4 |
| n09 | legacy atan0 not scaled to the GUARD datapath | N2 legacy_g4 |
| n10 | legacy sin and cos swapped | N2 legacy_g0 |
| n11 | no legacy timeout (the ttsky25a lock-up) | N2 recover_g4 |
| n12 | instruction decided at the wrong frame edge | N2 cmd_g4 |
| n13 | stale read byte with a one-cycle CS gap | N2 legacy_g0 |
| n14 | timeout counts the core's computing time | N2 legacy_g4 |
| n15 | STATUS glitch in the frame_start cycle | N2 cmd_g4 (A1) |
| n16 | SCLK slave: cs_on falls as fast as it rises, the last byte arrives after frame end | N1S m1_h3_l3_s8_t1_g24 |
| n17 | SCLK slave: MISO launched on the sample edge | N1S m0_h3_l3_s12_t1_g24 |
| n18 | SCLK slave: multi-byte frames resend byte 0 | N1S m0_h3_l3_s12_t1_g24_fb2 |
| n19 | SCLK slave: no MSB before the first launch (mode 0) | N1S m0_h3_l3_s12_t1_g24 |
| n20 | SCLK slave: next byte taken at its first launch, wrong after a pause | N1S m1_h3_l3_s8_t1_g24_fb2 |
| n21 | DATA_READY shows the previous instruction ready until CS is synchronized | N2 cmd_g4 |
| n22 | angle lookahead shift one iteration late | F2 prove_g4 |
| n23 | ln mantissa used before it is scaled (capture cycles skipped) | F3 b_op14_g4 |
| n24 | rotc returns the stale scaled x′ as y′ | F3 b_op19_g4 |
| n25 | the product pass truncates x >> s instead of rounding | F2 prove_g4 |
| n26 | the product pass keeps iterating once z = 0 | F2 prove_g4 |
| n27 | the rounded product pass leaks into GUARD 0, which must stay bit-exact with silicon | F2 prove_g0 |
| n28 | the exact unit rounds negative results like positive ones | exact smoke |
| n29 | a result taken off the queue by a frame too short to read it | N2 cmd_g4 |
| n30 | a result that arrived during a frame taken off unseen | N2 cmd_g4 |
| n31 | an instruction started while the result queue is full | N2 cmd_g4 |
| n32 | self-test rs2 = rs1 (LFSR stepped once) | F5 prove_f1 |
| n33 | the self-test issues cfg, which would change the cfg registers | F5 bmc_f1 (the unbounded proof only reports UNKNOWN: the bug is 7 instructions deep, beyond its 12-step base case) |
| n34 | the self-test stops one instruction early | F5 prove_f1 |
| n35 | EXEC accepted with the instruction queue full | N2 cmd_g4 |
| n36 | the divide runs one step short | exact smoke |
| n37 | the square root takes the wrong argument bits | exact smoke |
| n38 | division by zero not flagged INV | exact smoke |
| n39 | the core drops the exact unit's flags | F3 b_op17_g4 |
| n40 | an exact result not sign-extended | F3 b_op16_g4 |
| n41 | FLAGS byte of the last result, not of the one shown | N2 cmd_g4 |
| n42 | the result queue loses the flags | N2 cmd_g4 |
| n43 | SAT of one half of a pair missed | F3 b_op0_g4 |
| n44 | the self-test signature ignores the flags | F5 prove_f1 |
| n45 | the angle generator loses a term of the 1/3 series | F2 prove_g4 |
| n46 | the scaler drops its rounding increment | F3 b_op13_g4 |
| n47 | a normalization lane registered unshifted | F3 b_op11_g4 |
| n48 | sin captured before the engine pass | F3 b_op8_g4 |
| n49 | the one-hot decode taken from the previous instruction | F3 b_op8_g4 |
| n50 | the lookahead 3s formed as 2s | F2 prove_g4 |
| n51 | the protocol taken over before the last frame is closed | N2 switch_g4 |
| n52 | command frame state kept through a legacy session | N2 switch_g4 |

## Trusted base

- **Tools:** Yosys, SBY, yices, ABC; Verilator and g++ for the equivalence and exhaustive checks.
- **The cycle model of asynchronous SPI.** O1/N1: phases are counted in whole core clocks, any length ≥ the minimum; synchronizers resolve to the sampled value. N1S: phases in quarter core clocks, and a synchronizer's first flop may resolve a just-changed input either way. G1: real-time ticks with per-transition I/O delays. Metastability lasting longer than a clock is not modelled.
- **Timing at the pins.** Formal results are in logical time; path delays are a static-timing question (`docs/info.md` has the signoff timing). G1 carries the default slave's proof out to the pads through the chip's signoff I/O budget (`docs/GF26C_IO.md`).
- **Unbounded and bounded results:**
  - O1, O2, N1, N1S, G1 and N2 are unbounded (PDR): they hold for any number of frames and transactions.
  - F3's per-instruction tasks are complete BMC: an instruction finishes within the depth.
  - sqrt, mul, div: F3 proves the core against the exact unit's contract (any result); F6 proves the unit keeps that contract and that its result depends only on the operands. The values themselves rest on the exhaustive simulation of the unit (every operand) against exact integer arithmetic.
  - F5 is unbounded (k-induction); the core is replaced by its F3a contract with any result.
  - The model's timeouts and latencies are shortened: TIMEOUT_LOG2 = 4 and core latency ≤ 6 in N2 legacy and recover (the command tasks allow any latency), CORDIC latency ≤ 20 in O2. The FSMs do not depend on those values except through the counters, which are the same RTL at any width.
- **Master pacing in N2 legacy:** the theorem assumes the master never stays quiet for the timeout inside a transaction. The datasheet states this as a host requirement: 2²⁸ clocks, 10.7 s at 25 MHz.
- **The core contract** used by N2 is proved by F3a.
- **The top level.** `project.v` only wires the blocks together and puts two flops on `rst_n` and PROTO. It has no proof of its own: N2 switch holds for any PROTO sequence, every block's proof starts from a synchronous reset, and the simulations (`test/tb_spi.v`, `test/test.py`) run the whole chip, including a reset inside a frame.
