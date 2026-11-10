# test.py — Tiny Tapeout CI test (cocotb 2.x, as the ttgf26c template runs).
# Both protocols over SPI mode 0 at 5 MHz with a 25 MHz core clock (the GF26c
# build's clock; the slave needs SCLK <= clk/4); every
# result is checked against math within 2 LSB of S3.12 (the GUARD = 4 core is
# within ~1.2). The exhaustive and bit-exact tests are test/tb_spi.v (iverilog)
# and the proofs in formal/.
import math

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer

T_HALF = 100  # ns: 5 MHz SCLK

# cordic.bist signature from the golden model (formal/exhaustive/xc_model.hpp,
# GUARD = 4, cfg registers at reset): xc::Model<4>().exec(20, 1000, 0xC0FFEE01)
BIST_1000 = 0xEEE2B8D2


def q12(f):
    return int(round(f * 4096)) & 0xFFFF


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


UI = 0b00000100  # shadow of ui_in (a write lands only at the end of the timestep)


def set_pin(dut, bit, val):
    global UI
    UI = (UI & ~(1 << bit)) | ((val & 1) << bit)
    dut.ui_in.value = UI


CPHA = 0  # SPI mode of the master (and the CPHA pin)


async def frame(dut, tx, proto_at_end=None):
    """One CS frame, MSB first, in SPI mode CPHA. Returns the bytes read.
    proto_at_end: drive the PROTO pin to this value in the same instant CS rises."""
    global UI
    rx = []
    set_pin(dut, 2, 0)
    for b in tx:
        r = 0
        for i in range(7, -1, -1):
            if CPHA == 0:                       # drive on the falling edge, sample on the rising edge
                set_pin(dut, 1, (b >> i) & 1)
                await Timer(T_HALF, unit="ns")
                set_pin(dut, 0, 1)
                r = (r << 1) | (dut.uo_out.value.to_unsigned() & 1)
                await Timer(T_HALF, unit="ns")
                set_pin(dut, 0, 0)
            else:                               # drive on the rising edge, sample on the falling edge
                await Timer(T_HALF, unit="ns")
                UI = (UI & ~0b11) | 0b01 | (((b >> i) & 1) << 1)
                dut.ui_in.value = UI
                await Timer(T_HALF, unit="ns")
                r = (r << 1) | (dut.uo_out.value.to_unsigned() & 1)
                set_pin(dut, 0, 0)
        rx.append(r)
    await Timer(T_HALF, unit="ns")
    if proto_at_end is None:
        set_pin(dut, 2, 1)
    else:
        UI = (UI & ~0b1100) | 0b0100 | (proto_at_end << 3)
        dut.ui_in.value = UI
    await Timer(4 * T_HALF, unit="ns")
    return rx


async def wait_ready(dut):
    for _ in range(80000):
        await ClockCycles(dut.clk, 1)
        if (dut.uo_out.value.to_unsigned() >> 1) & 1:
            return
    assert False, "DATA_READY never rose"


def close(got, want, what, tol=2):
    err = abs(s16(got) - want * 4096)
    assert err <= tol, f"{what}: got {s16(got) / 4096:+.5f}, want {want:+.5f} ({err:.2f} LSB)"


@cocotb.test()
async def test_xcordic(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.ena.value = 1
    dut.ui_in.value = UI                  # CS high, legacy protocol, SPI mode 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)

    # ---- legacy: the ttsky25a frame, one byte per CS, as the original harness ----
    for ang in (0.5236, 2.0, 4.0, 6.0):
        words = [0x09B7, 0x0000, q12(ang), 0x0C91]            # x = 1/K, y, alpha, atan0
        for w in words:
            await frame(dut, [w & 0xFF])
            await frame(dut, [w >> 8])
        await wait_ready(dut)
        rx = [(await frame(dut, [0]))[0] for _ in range(6)]
        a = s16(q12(ang)) / 4096
        close(rx[0] | rx[1] << 8, math.sin(a), f"legacy sin({a:.4f})")
        close(rx[2] | rx[3] << 8, math.cos(a), f"legacy cos({a:.4f})")

    # ---- command protocol ----
    set_pin(dut, 3, 1)
    await ClockCycles(dut.clk, 10)

    flags = [0]                         # FLAGS byte of the last result: bit 0 SAT, bit 1 INV

    async def run(op, a, b=None):
        f7, f3 = op
        cmd = 0x80 | (f7 << 3) | f3
        tx = [cmd] + list(a.to_bytes(4, "little")) + ([] if b is None else list(b.to_bytes(4, "little")))
        await frame(dut, tx)
        await wait_ready(dut)
        rx = await frame(dut, [0] * 6)     # STATUS, RD, FLAGS
        status = rx[0]
        assert status & 0b111 == 0b010, f"status {status:02x}"
        flags[0] = rx[5]
        return rx[1] | rx[2] << 8 | rx[3] << 16 | rx[4] << 24

    x = 0.7
    close(await run((1, 0), q12(x)), math.sin(x), "sin")
    close(await run((1, 1), q12(x)), math.cos(x), "cos")
    close(await run((1, 5), q12(1.5)), math.exp(1.5), "exp", tol=6)   # rel <= 1.1 LSB at 4.48
    close(await run((1, 6), q12(3.0)), math.log(3.0), "ln")
    close(await run((1, 7), q12(5.0)), math.sqrt(5.0), "sqrt", tol=0.5)          # exact
    close(await run((1, 3), q12(0.6), q12(-0.8)), math.atan2(0.6, -0.8), "atan2")
    close(await run((2, 0), q12(1.25), q12(-2.5)), 1.25 * -2.5, "mul", tol=0)    # exact
    close(await run((2, 1), q12(1.0), q12(3.0)), 1 / 3, "div", tol=0.5)       # exact
    assert flags[0] == 0, f"div flags {flags[0]}"
    # flags: SAT when a result is clipped, INV for an invalid argument
    assert await run((2, 0), q12(7.0), q12(2.0)) == 0x7FFF and flags[0] == 1, "mul 7 * 2: SAT"
    assert await run((2, 1), q12(1.0), 0) == 0x7FFF and flags[0] == 2, "div by 0: INV"
    assert await run((1, 7), 0xFFFF) == 0xFFFF8000 and flags[0] == 2, "sqrt of < 0: INV"
    assert await run((2, 1), q12(-4.0) & 0xFFFF, q12(0.5)) == 0xFFFF8000 and flags[0] == 0, "-4 / 0.5 = -8: not clipped"
    close(await run((2, 2), q12(-0.75)), math.tanh(-0.75), "tanh")
    # cordic.bist: 25 instructions from seed 0x12345678; the signature is the
    # golden model's (host/pico_harness/xc_model.hpp, GUARD = 4, cfg at reset)
    sig = await run((2, 4), 25, 0x12345678)
    assert sig == 0x1BA9615E, f"bist signature {sig:08x}"

    # ---- the other instructions (the base passes carry the CORDIC gain K) ----
    def pair(rd):
        return s16(rd >> 16), s16(rd)

    def close2(rd, hi, lo, what, tol=3):
        h, l = pair(rd)
        assert abs(h - hi * 4096) <= tol and abs(l - lo * 4096) <= tol, \
            f"{what}: got {h / 4096:+.5f}, {l / 4096:+.5f}, want {hi:+.5f}, {lo:+.5f}"

    K, KH = 1.646760, 0.828160
    close2(await run((0, 0), 0x09B7, q12(0.5)), math.sin(0.5), math.cos(0.5), "rot")           # x = 1/K, y = 0
    close2(await run((0, 1), q12(0.7)), math.sin(0.7), math.cos(0.7), "sincos")
    close2(await run((0, 2), q12(1.0) << 16 | q12(1.0)), math.pi / 4, K * math.sqrt(2), "vec")
    close(await run((0, 3), q12(0.5) << 16 | q12(1.5), q12(1.25)), 0.5 + 1.5 * 1.25, "mac")
    close(await run((0, 4), q12(1.5) << 16 | q12(2.0)), 0.75, "ldiv")
    close2(await run((0, 5), q12(0.5)), math.sinh(0.5), math.cosh(0.5), "hsincos")
    close2(await run((0, 6), q12(0.5) << 16 | q12(1.0)), math.atanh(0.5), KH * math.sqrt(0.75), "hvec")
    assert await run((0, 7), 0, 8) == 0x0C91 << 4, "cfg: atan0 read back (read-only access)"
    close(await run((1, 2), q12(0.7)), math.tan(0.7), "tan", tol=3)
    close(await run((1, 4), q12(3.0), q12(4.0)), 5.0, "hypot", tol=3)
    close2(await run((2, 3), q12(1.0) << 16 | q12(2.0), q12(0.5)),
           2 * math.sin(0.5) + math.cos(0.5), 2 * math.cos(0.5) - math.sin(0.5), "rotc", tol=4)
    assert await run((1, 4), q12(7.9), q12(7.9)) == 0x7FFF and flags[0] == 1, "hypot(7.9, 7.9): SAT"
    assert await run((1, 6), 0) == 0xFFFF8000 and flags[0] == 2, "ln 0: INV"

    # ---- DATA_READY stays high once everything has finished, read or not ----
    assert (dut.uo_out.value.to_unsigned() >> 1) & 0b11 == 0b01, "DATA_READY high, BUSY low after a read"

    # ---- queues: 5 instructions back to back, results in order ----
    async def wait_not_busy():
        for _ in range(5000):
            await ClockCycles(dut.clk, 1)
            if not (dut.uo_out.value.to_unsigned() >> 2) & 1:
                return
        assert False, "BUSY never fell"

    async def drain(first=()):
        got = list(first)
        for _ in range(8):
            rx = await frame(dut, [0] * 6)
            if not rx[0] & 0b010:
                return got, rx[0]
            got.append((rx[0] >> 4, s16(rx[1] | rx[2] << 8)))
        assert False, "results never ran out"

    args = [0.25 * (i + 1) for i in range(5)]
    early = []
    for a in args:
        rx = await frame(dut, [0x88] + list(q12(a).to_bytes(4, "little")))      # sin, 5-byte frame
        if rx[0] & 0b010:                                                       # it also read a result
            early.append((rx[0] >> 4, s16(rx[1] | rx[2] << 8)))
    await wait_not_busy()
    got, status = await drain(early)
    assert len(got) == 5, f"queue: {len(got)} results of 5"
    for i, (seq, v) in enumerate(got):
        assert abs(v - math.sin(args[i]) * 4096) <= 2, f"queued sin #{i}: {v / 4096:+.5f}"
        assert seq == (got[0][0] + i) & 15, f"queued result #{i} has number {seq}"
    assert status & 0b111 == 0, f"status after reading all: {status:02x}"

    # ---- protocol switch: an unread EXEC, a legacy transaction, PROTO back to 1
    #      in the instant the last legacy frame's CS rises. The legacy frame must
    #      not move the queues: one result, then none. ----
    await frame(dut, [0x88] + list(q12(0.3).to_bytes(4, "little")))
    await wait_not_busy()
    set_pin(dut, 3, 0)
    await ClockCycles(dut.clk, 10)
    for w in (0x09B7, 0x0000, q12(1.0), 0x0C91):
        await frame(dut, [w & 0xFF])
        await frame(dut, [w >> 8])
    await wait_ready(dut)
    rx = [(await frame(dut, [0], proto_at_end=(1 if k == 5 else None)))[0] for k in range(6)]
    close(rx[0] | rx[1] << 8, math.sin(1.0), "legacy sin after a command session")
    await ClockCycles(dut.clk, 10)
    got, status = await drain()
    assert len(got) == 1 and abs(got[0][1] - math.sin(0.3) * 4096) <= 2, f"after the switch: {got}"
    assert status & 0b111 == 0, f"status after the switch: {status:02x}"

    # ---- SPI mode 1 ----
    global CPHA
    CPHA = 1
    set_pin(dut, 4, 1)
    await ClockCycles(dut.clk, 10)
    close(await run((1, 0), q12(-1.2)), math.sin(-1.2), "sin, mode 1")
    close(await run((2, 0), q12(-3.0), q12(1.5)), -4.5, "mul, mode 1", tol=0)
    CPHA = 0
    set_pin(dut, 4, 0)
    await ClockCycles(dut.clk, 10)

    # ---- a long self-test: 1000 instructions, every op but cfg about 53 times ----
    sig = await run((2, 4), 1000, 0xC0FFEE01)
    assert sig == BIST_1000, f"bist signature (N = 1000) {sig:08x}"
    dut._log.info("legacy and command protocols, both SPI modes, queues, protocol switch, bist: all OK")
