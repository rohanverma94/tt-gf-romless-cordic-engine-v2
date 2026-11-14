// model_check.cpp — the harness's golden model (xc_model.hpp) against the RTL.
//
// Runs xcordic_core.v (Verilator) and xc::Model<GUARD> side by side:
//   * every one-operand instruction over all 65536 operands
//     (sincos sin cos tan exp ln sqrt tanh hsincos),
//   * every other instruction (rot vec mac ldiv hvec atan2 hypot mul div rotc)
//     over N random operand pairs, half of them small/edge-biased,
//   * cfg reads and writes, then the random mix again with random cfg values.
// Any mismatch is printed and the exit status is 1.
//   ./run.sh            (both GUARD 0 and GUARD 4)
#include "Vxcordic_core.h"
#include "verilated.h"
#include "../xc_model.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>

#ifndef XC_GUARD
#define XC_GUARD 4
#endif

class Core {
public:
    Core() : m_(&ctx_) {
        m_.clk = 0; m_.rstn = 0; m_.start = 0;
        for (int i = 0; i < 4; ++i) tick();
        m_.rstn = 1; tick();
    }
    unsigned flags() const { return m_.flags; }
    uint32_t exec(unsigned op, uint32_t rs1, uint32_t rs2) {
        m_.funct7 = op >> 3; m_.funct3 = op & 7; m_.rs1 = rs1; m_.rs2 = rs2;
        m_.start = 1; tick(); m_.start = 0;
        if (m_.done) return m_.rd;                     // cfg finishes in one cycle
        for (int n = 1; n <= 200; ++n) { tick(); if (m_.done) return m_.rd; }
        std::fprintf(stderr, "core hung: op %u\n", op); std::exit(2);
    }
private:
    void tick() { m_.clk = 0; m_.eval(); m_.clk = 1; m_.eval(); }
    VerilatedContext ctx_;
    Vxcordic_core m_;
};

static Core *core;
static xc::Model<XC_GUARD> model;
static uint64_t checked = 0, bad = 0;

static void check(unsigned op, uint32_t rs1, uint32_t rs2) {
    uint32_t want = model.exec(op, rs1, rs2);
    uint32_t got = core->exec(op, rs1, rs2);
    ++checked;
    // the flags {INV, SAT} as well
    if ((got != want || core->flags() != model.flags()) && ++bad <= 20)
        std::printf("MISMATCH %-7s rs1 %08x rs2 %08x  rtl %08x/%u model %08x/%u\n",
                    xc::op_name(op), rs1, rs2, got, core->flags(), want, model.flags());
}

int main(int argc, char **argv) {
    long n = argc > 1 ? std::atol(argv[1]) : 200000;
    core = new Core;
    std::mt19937_64 rng(12345);
    auto r16 = [&]() -> uint32_t {                     // half uniform, half edge-biased
        uint64_t v = rng();
        switch (v & 7) {
        case 0: return uint32_t(v >> 8) & 0x1f;                         // tiny
        case 1: return (0u - (uint32_t(v >> 8) & 0x1f)) & 0xffff;      // tiny negative
        case 2: { static const uint16_t e[] = {0, 1, 0xffff, 0x7fff, 0x8000, 0x8001, 0x1000, 0xf000, 0x4000, 0xc000};
                  return e[(v >> 8) % 10]; }
        case 3: return uint32_t(v >> 8) & 0x1fff;                       // |x| < 2
        default: return uint32_t(v >> 16) & 0xffff;
        }
    };
    // reset values of cfg must agree
    for (unsigned s = 0; s < 5; ++s) check(xc::CFG, 0, 8 | s);

    const unsigned unary[] = {xc::SINCOS, xc::SIN, xc::COS, xc::TAN, xc::EXP, xc::LN, xc::SQRT, xc::TANH, xc::HSINCOS};
    for (unsigned op : unary)
        for (uint32_t a = 0; a < 65536; ++a) check(op, a | (uint32_t(rng()) & 0xffff0000u), 0);
    std::printf("GUARD %d: exhaustive one-operand ops done (%llu checks, %llu bad)\n",
                XC_GUARD, (unsigned long long)checked, (unsigned long long)bad);

    const unsigned binary[] = {xc::ROT, xc::VEC, xc::MAC, xc::LDIV, xc::HVEC, xc::ATAN2, xc::HYPOT,
                               xc::MUL, xc::DIV, xc::ROTC};
    auto mix = [&](long count) {
        for (long i = 0; i < count; ++i)
            for (unsigned op : binary) check(op, r16() | r16() << 16, r16() | (uint32_t(rng()) & 0xffff0000u));
    };
    mix(n);
    std::printf("GUARD %d: random two-operand ops done (%llu checks, %llu bad)\n",
                XC_GUARD, (unsigned long long)checked, (unsigned long long)bad);

    // random cfg values (+-25 % around reset), every op, read back, restore
    const uint32_t wmask = (1u << (16 + XC_GUARD)) - 1;
    for (int round = 0; round < 50; ++round) {
        for (unsigned s = 0; s < 5; ++s) {
            uint32_t base = xc::Model<XC_GUARD>::RST[s];
            uint32_t v = (base + uint32_t(int32_t(rng() % (base / 2 + 1)) - int32_t(base / 4))) & wmask;
            check(xc::CFG, v | (uint32_t(rng()) & ~wmask), s);
        }
        for (unsigned s = 0; s < 8; ++s) check(xc::CFG, 0, 8 | s);
        for (long i = 0; i < n / 200 + 1; ++i)
            for (unsigned op = 0; op < xc::kNumOps; ++op)
                if (op != xc::CFG) check(op, r16() | r16() << 16, r16());
    }
    for (unsigned s = 0; s < 5; ++s) check(xc::CFG, xc::Model<XC_GUARD>::RST[s], s);
    std::printf("GUARD %d: %llu checks, %llu mismatches -> %s\n", XC_GUARD,
                (unsigned long long)checked, (unsigned long long)bad, bad ? "FAIL" : "PASS");
    delete core;
    return bad ? 1 : 0;
}
