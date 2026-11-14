// exact.cpp — exhaustive check of src/xc_exact.v against exact integer arithmetic.
//
//   exact mul [i n]   all 2^32 (a, b) pairs, a range split into n parts, part i
//   exact div [i n]   the same for div
//   exact sqrt        all 65536 a
//   exact smoke       corners and 1M random pairs of each op (seconds)
//
// The reference below is written from the definition (round to nearest, ties
// up, then saturate to [-8, 8); flags {INV, SAT}), not from the RTL's
// algorithm: products and quotients are formed in 64-bit integers and
// rounded with a floor division; the square root is found by search and
// checked with exact squares. Results are compared bit for bit, flags too.
// Prints the number of mismatches and the first few; exit status 1 on any.
#include "Vxc_exact.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <random>

struct Res { uint16_t rd; unsigned flags; };   // flags = {INV, SAT}

static int64_t floordiv(int64_t n, int64_t d) {      // d != 0
    if (d < 0) { n = -n; d = -d; }
    int64_t q = n / d;
    if ((n % d) != 0 && n < 0) --q;
    return q;
}
static Res sat(int64_t v) {
    if (v > 32767)  return {0x7fff, 1};
    if (v < -32768) return {0x8000, 1};
    return {uint16_t(int16_t(v)), 0};
}
static Res ref_mul(int16_t a, int16_t b) {
    // x = a b / 4096; round half up: floor(x + 1/2) = floor((2 a b + 4096) / 8192)
    return sat(floordiv(2 * int64_t(a) * b + 4096, 8192));
}
static Res ref_div(int16_t a, int16_t b) {
    if (b == 0) return {uint16_t(a == 0 ? 0x0000 : a < 0 ? 0x8000 : 0x7fff), 2};
    // x = 4096 a / b; floor(x + 1/2) = floor((8192 a + b) / (2 b))
    return sat(floordiv(8192 * int64_t(a) + b, 2 * int64_t(b)));
}
static Res ref_sqrt(int16_t a) {
    if (a < 0) return {0x8000, 2};
    // r = floor(sqrt(4096 a) + 1/2): the r with (2r - 1)^2 <= 16384 a < (2r + 1)^2
    const int64_t n = 16384 * int64_t(a);
    int64_t r = int64_t(std::floor(std::sqrt(4096.0 * a) + 0.5));
    while ((2 * r + 1) * (2 * r + 1) <= n) ++r;
    while (r > 0 && (2 * r - 1) * (2 * r - 1) > n) --r;
    return sat(r);
}

static Vxc_exact *dut;
static uint64_t cycles = 0;
static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
    ++cycles;
}
static Res run(unsigned op, uint16_t a, uint16_t b, unsigned *lat) {
    dut->start = 1; dut->op = op; dut->a = a; dut->b = b;
    tick();
    dut->start = 0;
    unsigned n = 0;
    while (!dut->done) {
        tick();
        if (++n > 64) { std::fprintf(stderr, "no done: op %u a %04x b %04x\n", op, a, b); std::exit(2); }
    }
    if (lat) *lat = n;
    return {uint16_t(dut->rd), unsigned(dut->flags)};
}

static uint64_t bad = 0, checked = 0;
static void check(unsigned op, uint16_t a, uint16_t b) {
    const Res got = run(op, a, b, nullptr);
    const Res exp = op == 0 ? ref_mul(int16_t(a), int16_t(b)) :
                    op == 1 ? ref_div(int16_t(a), int16_t(b)) : ref_sqrt(int16_t(a));
    ++checked;
    if (got.rd != exp.rd || got.flags != exp.flags) {
        if (bad < 10)
            std::printf("MISMATCH %s a=%04x b=%04x: rtl %04x/%u, ref %04x/%u\n",
                        op == 0 ? "mul" : op == 1 ? "div" : "sqrt", a, b,
                        got.rd, got.flags, exp.rd, exp.flags);
        ++bad;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vxc_exact;
    dut->rstn = 0; dut->start = 0;
    tick(); tick();
    dut->rstn = 1;
    tick();
    const char *mode = argc > 1 ? argv[1] : "smoke";
    if (!std::strcmp(mode, "mul") || !std::strcmp(mode, "div")) {
        const unsigned op = !std::strcmp(mode, "mul") ? 0 : 1;
        const unsigned part = argc > 3 ? std::atoi(argv[2]) : 0, parts = argc > 3 ? std::atoi(argv[3]) : 1;
        const uint32_t lo = uint32_t((uint64_t(65536) * part) / parts), hi = uint32_t((uint64_t(65536) * (part + 1)) / parts);
        for (uint32_t a = lo; a < hi; ++a) {
            for (uint32_t b = 0; b < 65536; ++b) check(op, uint16_t(a), uint16_t(b));
            if ((a & 0x3ff) == 0x3ff) { std::printf("  a=%04x done, %llu mismatches\n", a, (unsigned long long)bad); std::fflush(stdout); }
        }
    } else if (!std::strcmp(mode, "sqrt")) {
        for (uint32_t a = 0; a < 65536; ++a) check(2, uint16_t(a), 0);
    } else {                                                    // smoke
        const uint16_t corner[] = {0x0000, 0x0001, 0x0002, 0x0800, 0x0fff, 0x1000, 0x1001, 0x2000, 0x7ffe, 0x7fff,
                                   0x8000, 0x8001, 0x8002, 0xf000, 0xefff, 0xffff, 0xfffe, 0x0010, 0xfff0, 0x00ff};
        for (uint16_t a : corner) for (uint16_t b : corner) { check(0, a, b); check(1, a, b); }
        for (uint32_t a = 0; a < 65536; ++a) check(2, uint16_t(a), 0);
        std::mt19937 rng(1);
        for (int i = 0; i < 1000000; ++i) { check(0, rng(), rng()); check(1, rng(), rng()); }
        unsigned l0, l1, l2, l3, l4;
        run(0, 0x1234, 0x5678, &l0); run(1, 0x1234, 0x5678, &l1); run(2, 0x1234, 0, &l2);
        run(1, 0x7fff, 0x0001, &l3); run(1, 0x1234, 0, &l4);
        std::printf("latency (cycles after the start cycle until done): mul %u, div %u, sqrt %u, div overflow %u, div by 0 %u\n",
                    l0, l1, l2, l3, l4);
    }
    std::printf("%s: %llu checked, %llu mismatches, %llu cycles\n", mode,
                (unsigned long long)checked, (unsigned long long)bad, (unsigned long long)cycles);
    delete dut;
    return bad ? 1 : 0;
}
