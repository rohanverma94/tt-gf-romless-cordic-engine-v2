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


async def frame(dut, tx):
    """One CS frame, mode 0, MSB first. Returns the bytes read."""
    rx = []
    set_pin(dut, 2, 0)
    for b in tx:
        r = 0
        for i in range(7, -1, -1):
            set_pin(dut, 1, (b >> i) & 1)
            await Timer(T_HALF, unit="ns")
            set_pin(dut, 0, 1)
            r = (r << 1) | (dut.uo_out.value.to_unsigned() & 1)
            await Timer(T_HALF, unit="ns")
            set_pin(dut, 0, 0)
        rx.append(r)
    await Timer(T_HALF, unit="ns")
    set_pin(dut, 2, 1)
    await Timer(4 * T_HALF, unit="ns")
    return rx


async def wait_ready(dut):
    for _ in range(5000):
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

    flags = [0]                         # FLAGS byte of the last result (v1.0): bit 0 SAT, bit 1 INV

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
    close(await run((1, 7), q12(5.0)), math.sqrt(5.0), "sqrt", tol=0.5)          # v1.0: exact
    close(await run((1, 3), q12(0.6), q12(-0.8)), math.atan2(0.6, -0.8), "atan2")
    close(await run((2, 0), q12(1.25), q12(-2.5)), 1.25 * -2.5, "mul", tol=0)    # v0.9: exact
    close(await run((2, 1), q12(1.0), q12(3.0)), 1 / 3, "div", tol=0.5)       # v1.0: exact
    assert flags[0] == 0, f"div flags {flags[0]}"
    # v1.0 flags: SAT when a result is clipped, INV for an invalid argument
    assert await run((2, 0), q12(7.0), q12(2.0)) == 0x7FFF and flags[0] == 1, "mul 7 * 2: SAT"
    assert await run((2, 1), q12(1.0), 0) == 0x7FFF and flags[0] == 2, "div by 0: INV"
    assert await run((1, 7), 0xFFFF) == 0xFFFF8000 and flags[0] == 2, "sqrt of < 0: INV"
    assert await run((2, 1), q12(-4.0) & 0xFFFF, q12(0.5)) == 0xFFFF8000 and flags[0] == 0, "-4 / 0.5 = -8: not clipped"
    close(await run((2, 2), q12(-0.75)), math.tanh(-0.75), "tanh")
    # cordic.bist: 25 instructions from seed 0x12345678; the signature is the
    # golden model's (host/pico_harness/xc_model.hpp, GUARD = 4, cfg at reset)
    sig = await run((2, 4), 25, 0x12345678)
    assert sig == 0x1BA9615E, f"bist signature {sig:08x}"     # v1.0 (flags in the signature)
    dut._log.info("legacy and command protocol: all results within tolerance, bist signature OK")
