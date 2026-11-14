// equiv.cpp — the current RTL (src/) against the reference (equiv/ref/), instruction by instruction (rd and flags).
// Both units get the same instruction stream; each instruction starts when both
// are idle, and the results are compared when each one's done pulses (the two
// may take a different number of cycles: retiming adds cycles, never changes values).
//   ./equiv [random_count] [seed]
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cinttypes>
#include "Vref.h"
#include "Vnew.h"
#include <map>
#include <string>
static std::map<std::string, std::pair<uint64_t,uint64_t>> g_max;   // op -> (ref, new) max cycles

static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint32_t r32() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return uint32_t(rng >> 11); }

struct Pair {
    Vref r; Vnew n;
    uint64_t cyc = 0, cyc_r = 0, cyc_n = 0, mism = 0, count = 0;
    void tick() {
        r.clk = 0; n.clk = 0; r.eval(); n.eval();
        r.clk = 1; n.clk = 1; r.eval(); n.eval();
        ++cyc;
    }
    void reset() {
        r.rst_n = 0; n.rst_n = 0; r.start = 0; n.start = 0;
        for (int i = 0; i < 4; ++i) tick();
        r.rst_n = 1; n.rst_n = 1; tick();
    }
    // one instruction on both; returns false on a mismatch
    bool run(int f7, int f3, uint32_t a, uint32_t b, const char *what) {
        r.funct7 = n.funct7 = f7; r.funct3 = n.funct3 = f3;
        r.rs1 = n.rs1 = a; r.rs2 = n.rs2 = b;
        r.start = n.start = 1;
        tick();
        r.start = n.start = 0;
        bool dr = false, dn = false; uint32_t rr = 0, rn = 0; int fr = 0, fn = 0;
        uint64_t t0 = cyc, tr = 0, tn = 0;
        // a cfg op answers in the accepting cycle (done with the start)
        if (r.done) { dr = true; rr = r.rd; fr = r.flags; tr = 1; }
        if (n.done) { dn = true; rn = n.rd; fn = n.flags; tn = 1; }
        while (!(dr && dn)) {
            tick();
            if (!dr && r.done) { dr = true; rr = r.rd; fr = r.flags; tr = cyc - t0 + 1; }
            if (!dn && n.done) { dn = true; rn = n.rd; fn = n.flags; tn = cyc - t0 + 1; }
            if (cyc - t0 > 20000000) { std::printf("TIMEOUT %s f7=%d f3=%d a=%08x b=%08x\n", what, f7, f3, a, b); std::exit(2); }
        }
        // both idle before the next start
        while (r.busy || n.busy) tick();
        cyc_r += tr; cyc_n += tn; ++count;
        { auto &m = g_max[what]; if (tr > m.first) m.first = tr; if (tn > m.second) m.second = tn; }
        if (rr != rn || fr != fn) {
            if (mism < 20) std::printf("MISMATCH %s f7=%d f3=%d rs1=%08x rs2=%08x: ref %08x/%d  new %08x/%d\n", what, f7, f3, a, b, rr, fr, rn, fn);
            ++mism; return false;
        }
        return true;
    }
};

int main(int argc, char **argv) {
    const long nrand = argc > 1 ? std::atol(argv[1]) : 200000;
    if (argc > 2) rng ^= std::strtoull(argv[2], nullptr, 0) * 0x2545F4914F6CDD1Dull;
    Pair p; p.reset();
    struct Op { int f7, f3; const char *name; int nops; };     // nops: 1 = rs1[15:0] only matters
    const Op ops[] = {
        {0,0,"rot",2},{0,1,"sincos",1},{0,2,"vec",2},{0,3,"mac",2},{0,4,"ldiv",2},{0,5,"hsincos",1},{0,6,"hvec",2},
        {1,0,"sin",1},{1,1,"cos",1},{1,2,"tan",1},{1,3,"atan2",2},{1,4,"hypot",2},{1,5,"exp",1},{1,6,"ln",1},{1,7,"sqrt",1},
        {2,0,"mul",2},{2,1,"div",2},{2,2,"tanh",1},{2,3,"rotc",2},
    };
    // 1) every 16-bit input of the one-operand ops (reset cfg)
    uint64_t c0 = p.count;
    for (const Op &o : ops) if (o.nops == 1)
        for (uint32_t v = 0; v < 65536; ++v) p.run(o.f7, o.f3, v | (r32() & 0xffff0000u), r32(), o.name);
    std::printf("exhaustive one-operand: %" PRIu64 " instructions, %" PRIu64 " mismatches\n", p.count - c0, p.mism);
    // 2) random instructions of every op, including cfg writes that change the constants for what follows
    c0 = p.count; uint64_t m0 = p.mism;
    for (long i = 0; i < nrand; ++i) {
        uint32_t k = r32() % 64;
        if (k == 0) {                                   // cfg: write (or read-only) a random selector 0..7
            uint32_t v = r32();
            // keep the angle constants near their values most of the time, so results stay meaningful
            if (r32() & 1) v = (r32() & 1) ? 0x0c910 + (r32() & 0xff) - 0x80 : r32() & 0xfffff;
            p.run(0, 7, v, r32() & 0xf, "cfg");
        } else {
            const Op &o = ops[r32() % (sizeof ops / sizeof ops[0])];
            uint32_t a = r32(), b = r32();
            // small magnitudes now and then (the interesting ranges)
            if ((r32() & 3) == 0) a = (a & 0x8000ffffu) ^ ((a & 0x7fff) >> (r32() % 12));
            if ((r32() & 3) == 0) b = (b & 0x8000ffffu) ^ ((b & 0x7fff) >> (r32() % 12));
            p.run(o.f7, o.f3, a, b, o.name);
        }
        if (i % 50000 == 0 && r32() % 4 == 0) p.reset();   // cfg back to reset values now and then
    }
    std::printf("random (all ops, cfg writes): %" PRIu64 " instructions, %" PRIu64 " mismatches\n", p.count - c0, p.mism - m0);
    // 3) self-test runs
    c0 = p.count; m0 = p.mism; p.reset();
    for (int i = 0; i < 40; ++i) p.run(2, 4, r32() % (i < 4 ? 2000 : 300), r32(), "bist");
    std::printf("bist: %" PRIu64 " runs, %" PRIu64 " mismatches\n", p.count - c0, p.mism - m0);
    std::printf("cycles per instruction (incl. issue): ref %.2f, new %.2f\n", double(p.cyc_r) / p.count, double(p.cyc_n) / p.count);
    for (auto &kv : g_max) std::printf("  max cycles %-8s ref %4" PRIu64 "  new %4" PRIu64 "\n", kv.first.c_str(), kv.second.first, kv.second.second);
    std::printf("%s: %" PRIu64 " instructions, %" PRIu64 " mismatches\n", p.mism ? "FAIL" : "PASS", p.count, p.mism);
    return p.mism ? 1 : 0;
}
