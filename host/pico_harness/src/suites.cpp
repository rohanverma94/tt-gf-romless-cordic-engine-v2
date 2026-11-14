// suites.cpp — the harness's tests (see suites.hpp). Portable: runs on the
// Pico against the chip, and in sim/ against the RTL.
#include "suites.hpp"
#include <cmath>
#include <cstdio>
#include <cstring>

using namespace xc;

namespace suites {
namespace {

// ---------------------------------------------------------------- helpers
struct Rng {
    uint64_t s;
    explicit Rng(uint64_t seed) : s(seed ? seed : 0x9e3779b97f4a7c15ull) {}
    uint64_t next() { s ^= s >> 12; s ^= s << 25; s ^= s >> 27; return s * 0x2545f4914f6cdd1dull; }
    // operand halves: half uniform, half small / edge values
    uint32_t r16() {
        uint64_t v = next();
        switch (v & 7) {
        case 0: return uint32_t(v >> 8) & 0x1f;
        case 1: return (0u - (uint32_t(v >> 8) & 0x1f)) & 0xffff;
        case 2: { static const uint16_t e[] = {0, 1, 0xffff, 0x7fff, 0x8000, 0x8001, 0x1000, 0xf000, 0x4000, 0xc000};
                  return e[(v >> 8) % 10]; }
        case 3: return uint32_t(v >> 8) & 0x1fff;
        default: return uint32_t(v >> 16) & 0xffff;
        }
    }
};

const char *pf(int fails) { return fails ? "FAIL" : "PASS"; }
double q2f(uint32_t v) { return double(int16_t(uint16_t(v))) / 4096.0; }

// Stream n instructions of one op through the pipelined frame: frame i+1
// returns the result of instruction i. gen(i, a, b) makes operands,
// sink(a, b, rd, status_ok) consumes results in order. Returns the number of
// instructions that timed out or came back with a wrong STATUS.
template <class Gen, class Sink>
uint32_t stream(Dut &d, unsigned op, uint32_t n, Gen gen, Sink sink) {
    uint32_t bad = 0, rd = 0, pa = 0, pb = 0;
    Status st = d.read(&rd);
    int seq = st.seq();
    bool have = false;
    for (uint32_t i = 0; i <= n; ++i) {
        uint32_t a = 0, b = 0;
        if (i < n) gen(i, a, b);
        if (!d.wait_ready()) { ++bad; have = false; d.read(&rd); seq = d.read(&rd).seq(); continue; }
        if (i < n) st = d.exec_frame(op, a, b, &rd);
        else       st = d.read(&rd);
        if (have) {
            seq = (seq + 1) & 15;
            bool ok = st.valid() && !st.busy() && !st.err() && st.seq() == seq;
            if (!ok) { ++bad; seq = st.seq(); }
            sink(pa, pb, rd, ok);
        }
        pa = a; pb = uses_rs2(op) ? b : 0; have = (i < n);
    }
    return bad;
}

}  // namespace

// ---------------------------------------------------------------- link
bool apply_link(Ctx &c, const LinkCfg &l, bool quiet) {
    LinkActual a;
    if (!c.dut.h.configure(l, a)) {
        if (!quiet) std::printf("link: cannot generate this timing: %s\n", a.note);
        return false;
    }
    c.dut.fclk_hz = l.fclk_hz;
    if (!quiet) {
        if (l.backend == Backend::PIO)
            std::printf("link: PIO SPI mode %d, SCLK %.3f MHz (high %d, low %d ticks of %.2f ns), "
                        "MISO sampled %.1f ns after the sample edge; chip clk %.3f MHz\n",
                        l.cpha, a.sclk_hz / 1e6, a.high, a.low, a.pio_tick_ns, a.sample_ns, l.fclk_hz / 1e6);
        else
            std::printf("link: hardware SPI mode %d, SCLK %.3f MHz; chip clk %.3f MHz\n",
                        l.cpha, a.sclk_hz / 1e6, l.fclk_hz / 1e6);
        if (a.note[0]) std::printf("      %s\n", a.note);
    }
    return true;
}

// ---------------------------------------------------------------- identify
int identify(Ctx &c) {
    Dut &d = c.dut;
    uint32_t atan0 = 0;
    std::printf("\n== identify ==\n");
    d.h.set_proto(1);
    uint32_t rd; Status s0 = d.read(&rd);
    std::printf("STATUS 0x%02x (seq %d err %d valid %d busy %d), RD 0x%08x\n",
                s0.raw, s0.seq(), s0.err(), s0.valid(), s0.busy(), (unsigned)rd);
    int g = d.identify(&atan0);
    if (g < 0) {
        std::printf("cfg atan0 reads 0x%08x: not a tt_um_xcordic reset value (0x0c91 / 0xc910).\n"
                    "Check wiring, the project selection on the demo board, the chip clock and SPI speed.\n"
                    "CSV,identify,FAIL,%08x\n", (unsigned)atan0, (unsigned)atan0);
        return 1;
    }
    int fails = 0;
    std::printf("GUARD %d datapath (atan0 0x%05x)\ncfg:", g, (unsigned)atan0);
    static const char *nm[5] = {"atan0", "atan1", "kc", "atanh1", "kh"};
    for (unsigned s = 0; s < 5; ++s) {
        uint32_t v = d.cfg_read(s);
        std::printf(" %s=0x%05x%s", nm[s], (unsigned)v, v == d.gold.rst(s) ? "" : "(!)");
        if (v != d.gold.rst(s) && s != 0) ++fails;
    }
    std::printf("\n");
    d.sync_cfg();
    // one instruction of each kind as a smoke test
    uint32_t r1, r2;
    d.exec(SIN, 0x0800, 0, &r1);
    d.exec(MUL, 0x1800, 0x2000, &r2);
    uint32_t e1 = d.gold.exec(SIN, 0x0800, 0), e2 = d.gold.exec(MUL, 0x1800, 0x2000);
    std::printf("sin(0.5) = 0x%04x (%.5f, model 0x%04x)   1.5*2 = 0x%04x (model 0x%04x)\n",
                (unsigned)(r1 & 0xffff), q2f(r1), (unsigned)(e1 & 0xffff), (unsigned)(r2 & 0xffff), (unsigned)(e2 & 0xffff));
    if (r1 != e1) ++fails;
    if (r2 != e2) ++fails;
    std::printf("identify: %s\nCSV,identify,%s,%d\n", pf(fails), pf(fails), g);
    return fails;
}

// ---------------------------------------------------------------- bitexact
int bitexact(Ctx &c, uint32_t n) {
    Dut &d = c.dut;
    std::printf("\n== bitexact: every op vs the golden model (GUARD %d), %u operands each ==\n",
                d.gold.guard, (unsigned)n);
    d.h.set_proto(1);
    d.sync_cfg();
    Rng rng(c.seed);
    int total_fail = 0;
    uint64_t t0 = d.h.now_us();
    for (unsigned op = 0; op < kNumOps; ++op) {
        uint32_t mism = 0, first_a = 0, first_b = 0, first_rd = 0, first_want = 0;
        auto gen = [&](uint32_t, uint32_t &a, uint32_t &b) {
            a = rng.r16() | rng.r16() << 16;
            b = rng.r16() | uint32_t(rng.next() & 0xffff0000u);
            if (op == CFG) b = 8 | (b & 7);          // read-only here; writes below
        };
        auto sink = [&](uint32_t a, uint32_t b, uint32_t rd, bool) {
            uint32_t want = d.gold.exec(op, a, b);
            const bool fl_ok = d.last_flags == d.gold.flags();     // FLAGS too
            if ((rd != want || !fl_ok) && mism++ == 0) { first_a = a; first_b = b; first_rd = rd; first_want = want; }
        };
        uint32_t bad = stream(d, op, n, gen, sink);
        int f = (mism || bad) ? 1 : 0;
        total_fail += f;
        std::printf("  %-7s %s  mismatches %u  status/timeouts %u", op_name(op), pf(f), (unsigned)mism, (unsigned)bad);
        if (mism) std::printf("  e.g. rs1 %08x rs2 %08x -> %08x, model %08x", (unsigned)first_a, (unsigned)first_b,
                              (unsigned)first_rd, (unsigned)first_want);
        std::printf("\nCSV,bitexact,%s,%u,%u,%u\n", op_name(op), (unsigned)n, (unsigned)mism, (unsigned)bad);
    }
    // random cfg values: every op again with altered constants, then restore
    uint32_t mism = 0, bad = 0;
    for (int round = 0; round < 8; ++round) {
        for (unsigned s = 0; s < 5; ++s) {
            uint32_t base = d.gold.rst(s);
            uint32_t v = (base + uint32_t(int32_t(rng.next() % (base / 2 + 1)) - int32_t(base / 4))) & d.gold.wmask();
            uint32_t old = d.cfg_write(s, v);
            (void)old;
        }
        for (unsigned op = 0; op < kNumOps; ++op) {
            if (op == CFG) continue;
            auto gen = [&](uint32_t, uint32_t &a, uint32_t &b) { a = rng.r16() | rng.r16() << 16; b = rng.r16(); };
            auto sink = [&](uint32_t a, uint32_t b, uint32_t rd, bool) {
                if (rd != d.gold.exec(op, a, b) || d.last_flags != d.gold.flags()) ++mism;
            };
            bad += stream(d, op, n / 16 + 1, gen, sink);
        }
    }
    d.sync_cfg();
    for (unsigned s = 0; s < 5; ++s) if (d.cfg_read(s) != d.gold.rst(s)) ++bad;
    int f = (mism || bad) ? 1 : 0;
    total_fail += f;
    std::printf("  cfg     %s  random constants, all ops: mismatches %u  status/timeouts %u\n", pf(f),
                (unsigned)mism, (unsigned)bad);
    std::printf("CSV,bitexact,cfg_random,%u,%u,%u\n", (unsigned)(8 * 19 * (n / 16 + 1)), (unsigned)mism, (unsigned)bad);
    double s = double(d.h.now_us() - t0) / 1e6;
    std::printf("bitexact: %s (%d of 21 groups failed) in %.1f s\n", pf(total_fail), total_fail, s);
    return total_fail;
}

// ---------------------------------------------------------------- accuracy
namespace {
struct Ref { bool special; uint16_t code; double v; };
struct Fn {
    const char *name; unsigned op; bool binary;
    Ref (*ref)(double a, double b);
    const char *domain;
};
Ref val(double v) { return {false, 0, v}; }
Ref spec(uint16_t c) { return {true, c, 0}; }
const Fn kFns[] = {
    {"sin",   SIN,   false, [](double a, double) { return val(std::sin(a)); }, "all"},
    {"cos",   COS,   false, [](double a, double) { return val(std::cos(a)); }, "all"},
    {"tan",   TAN,   false, [](double a, double) { return val(std::tan(a)); }, "all"},
    {"exp",   EXP,   false, [](double a, double) { return val(std::exp(a)); }, "all"},
    {"ln",    LN,    false, [](double a, double) { return a > 0 ? val(std::log(a)) : spec(0x8000); }, "a>0, else 0x8000"},
    {"sqrt",  SQRT,  false, [](double a, double) { return a >= 0 ? val(std::sqrt(a)) : spec(0x8000); }, "a>=0, else 0x8000"},
    {"tanh",  TANH,  false, [](double a, double) { return val(std::tanh(a)); }, "all"},
    {"atan2", ATAN2, true,  [](double a, double b) { return val(std::atan2(a, b)); }, "random pairs"},
    {"hypot", HYPOT, true,  [](double a, double b) { return val(std::hypot(a, b)); }, "random pairs"},
    {"mul",   MUL,   true,  [](double a, double b) { return val(a * b); }, "random pairs"},
    {"div",   DIV,   true,  [](double a, double b) {
        return b != 0 ? val(a / b) : a == 0 ? val(0) : spec(a < 0 ? 0x8000 : 0x7fff); }, "random pairs"},
};
constexpr double kMax = 32767.0 / 4096.0, kMin = -8.0;

struct Stats {
    uint32_t n = 0, sat = 0, sat_ok = 0, special = 0, special_bad = 0, sext_bad = 0, model_bad = 0, total = 0;
    double sum_abs = 0, max_abs = 0, sum_rel = 0, max_rel = 0, sum_sq = 0;
    uint32_t arg_max = 0;
    void add(uint32_t rd, const Ref &r, uint32_t arg) {
        ++total;
        uint16_t lo = rd & 0xffff;
        if ((rd >> 16) != ((lo & 0x8000) ? 0xffffu : 0u)) ++sext_bad;
        if (r.special) { ++special; if (lo != r.code) ++special_bad; return; }
        if (r.v > kMax || r.v < kMin) {
            ++sat;
            if (lo == (r.v > 0 ? 0x7fff : 0x8000)) ++sat_ok;
            return;
        }
        double e = std::fabs(q2f(lo) - r.v) * 4096.0;
        double rel = e / (std::fabs(r.v) > 1 ? std::fabs(r.v) : 1.0);
        ++n; sum_abs += e; sum_sq += e * e; sum_rel += rel;
        if (e > max_abs) { max_abs = e; arg_max = arg; }
        if (rel > max_rel) max_rel = rel;
    }
};
}  // namespace

int accuracy(Ctx &c, const char *which, uint32_t n_binary) {
    Dut &d = c.dut;
    std::printf("\n== accuracy vs libm (double), GUARD %d; errors in LSB of S3.12 ==\n", d.gold.guard);
    if (c.acc_stride > 1)
        std::printf("  one-operand functions: every %u-th of the 65536 inputs; two-operand: %u random pairs\n",
                    (unsigned)c.acc_stride, (unsigned)n_binary);
    else
        std::printf("  one-operand functions: all 65536 inputs; two-operand: %u random pairs\n", (unsigned)n_binary);
    std::printf("  %-6s %8s %8s %8s %8s %8s %8s  %-9s %s\n", "fn", "inputs", "max", "mean", "rms", "relmax",
                "relmean", "argmax", "bit-exact vs model");
    d.h.set_proto(1);
    d.sync_cfg();
    Rng rng(c.seed ^ 0xacc);
    int fails = 0, ran = 0;
    for (const Fn &f : kFns) {
        if (std::strcmp(which, "all") && std::strcmp(which, f.name)) continue;
        if (!std::strcmp(which, "all") && f.binary && n_binary == 0) continue;
        ++ran;
        Stats st;
        const uint32_t stride = c.acc_stride ? c.acc_stride : 1;
        uint32_t n = f.binary ? n_binary : 65536 / stride;
        auto gen = [&](uint32_t i, uint32_t &a, uint32_t &b) {
            if (f.binary) { a = uint32_t(rng.next() >> 48); b = uint32_t(rng.next() >> 48); }
            else { a = i * stride; b = 0; }
        };
        auto sink = [&](uint32_t a, uint32_t b, uint32_t rd, bool) {
            if (rd != d.gold.exec(f.op, a, b)) ++st.model_bad;
            Ref r = f.ref(q2f(a), q2f(b));
            st.add(rd, r, f.binary ? (a & 0xffff) | b << 16 : a);
            if (c.dump) std::printf("CSV,accdump,%s,%04x,%04x,%04x\n", f.name, (unsigned)(a & 0xffff),
                                    (unsigned)(b & 0xffff), (unsigned)(rd & 0xffff));
        };
        uint32_t bad = stream(d, f.op, n, gen, sink);
        int fl = (st.model_bad || bad || st.special_bad || st.sext_bad) ? 1 : 0;
        fails += fl;
        double mean = st.n ? st.sum_abs / st.n : 0, rms = st.n ? std::sqrt(st.sum_sq / st.n) : 0;
        double rmean = st.n ? st.sum_rel / st.n : 0;
        std::printf("  %-6s %8u %8.3f %8.3f %8.3f %8.3f %8.3f  %08x  %s (%u differ, %u status)", f.name,
                    (unsigned)st.total, st.max_abs, mean, rms, st.max_rel, rmean, (unsigned)st.arg_max,
                    pf(fl), (unsigned)st.model_bad, (unsigned)bad);
        if (st.sat) std::printf("  |exact|>=8: %u, saturated %u", (unsigned)st.sat, (unsigned)st.sat_ok);
        if (st.special) std::printf("  special %u (bad %u)", (unsigned)st.special, (unsigned)st.special_bad);
        std::printf("\nCSV,accuracy,%s,%u,%.4f,%.4f,%.4f,%.4f,%.4f,%u,%u\n", f.name, (unsigned)st.total, st.max_abs,
                    mean, rms, st.max_rel, rmean, (unsigned)st.model_bad, (unsigned)bad);
    }
    if (!ran) { std::printf("unknown function '%s'\n", which); return 1; }
    std::printf("accuracy: %s (pass = every result bit-exact with the proven RTL)\n", pf(fails));
    return fails;
}

// ---------------------------------------------------------------- legacy
int legacy(Ctx &c, int n, bool byte_per_cs) {
    Dut &d = c.dut;
    const uint16_t X = 0x09B7, ATAN0 = 0x0C91;
    std::printf("\n== legacy (ttsky25a) protocol: %d angles over [0, 2pi), x = 0x%04x, atan0 = 0x%04x, %s ==\n",
                n, X, ATAN0, byte_per_cs ? "one CS per byte" : "one CS per word group (8 + 6 bytes)");
    d.h.set_proto(1);
    d.sync_cfg();
    d.h.set_proto(0);
    uint32_t mism = 0, timeouts = 0, third_bad = 0;
    double sum = 0, peak = 0;
    for (int i = 0; i < n; ++i) {
        double th = 2.0 * M_PI * i / n;
        uint16_t alpha = uint16_t(int(std::lround(th * 4096.0)));
        uint16_t sn, cs, z;
        if (!d.legacy(X, 0, alpha, ATAN0, &sn, &cs, &z, byte_per_cs)) ++timeouts;
        uint32_t want = d.legacy_model(X, 0, alpha);
        if (sn != (want >> 16) || cs != (want & 0xffff)) {
            if (mism++ < 5) std::printf("  angle %d (%.4f rad): sin %04x cos %04x, model %04x %04x\n", i, th, sn, cs,
                                        (unsigned)(want >> 16), (unsigned)(want & 0xffff));
        }
        if (z) ++third_bad;
        double es = std::fabs(q2f(sn) - std::sin(th)) * 4096, ec = std::fabs(q2f(cs) - std::cos(th)) * 4096;
        sum += es + ec;
        if (es > peak) peak = es;
        if (ec > peak) peak = ec;
        if (c.dump) std::printf("CSV,legacydump,%d,%.6f,%04x,%04x\n", i, th, sn, cs);
    }
    d.h.set_proto(1);
    d.sync_cfg();
    // the same angles through the sincos instruction (full-precision gain constant)
    double sum2 = 0, peak2 = 0;
    uint32_t mism2 = 0;
    stream(d, SINCOS, uint32_t(n),
           [&](uint32_t i, uint32_t &a, uint32_t &b) { a = uint16_t(int(std::lround(2.0 * M_PI * i / n * 4096.0))); b = 0; },
           [&](uint32_t a, uint32_t, uint32_t rd, bool) {
               if (rd != d.gold.exec(SINCOS, a, 0)) ++mism2;
               double th = 0;
               for (int i = 0; i < n; ++i)                      // the exact angle this code came from
                   if (uint16_t(int(std::lround(2.0 * M_PI * i / n * 4096.0))) == a) { th = 2.0 * M_PI * i / n; break; }
               double es = std::fabs(q2f(rd >> 16) - std::sin(th)) * 4096, ec = std::fabs(q2f(rd) - std::cos(th)) * 4096;
               sum2 += es + ec;
               if (es > peak2) peak2 = es;
               if (ec > peak2) peak2 = ec;
           });
    if (mism2) ++mism;
    int f = (mism || timeouts || third_bad) ? 1 : 0;
    std::printf("  ttsky25a harness metric (|error| of sin and cos vs the exact angle, LSB):\n"
                "    legacy frame (x = 0x09B7): mean %.2f, peak %.2f\n"
                "    sincos instruction:        mean %.2f, peak %.2f\n", sum / (2 * n), peak, sum2 / (2 * n), peak2);
    std::printf("  RTL values for 250 angles: GUARD 0 1.74/5.54 (both); GUARD 4 0.46/1.34 legacy, 0.31/1.11 sincos\n"
                "  (the legacy x = 1/K is quantized to S3.12). ttsky25a: 12.7/24.0, 1.71/5.54 with its atan0 calibration.\n");
    std::printf("legacy: %s  (model mismatches %u, timeouts %u, third word non-zero %u)\n", pf(f), (unsigned)mism,
                (unsigned)timeouts, (unsigned)third_bad);
    std::printf("CSV,legacy,%d,%d,%.4f,%.4f,%.4f,%.4f,%u,%u,%u\n", n, byte_per_cs ? 1 : 0, sum / (2 * n), peak,
                sum2 / (2 * n), peak2, (unsigned)mism, (unsigned)timeouts, (unsigned)third_bad);
    return f;
}

// ---------------------------------------------------------------- protocol
int protocol(Ctx &c) {
    Dut &d = c.dut;
    Hal &h = d.h;
    int fails = 0;
    auto check = [&](const char *name, bool ok, const char *detail = "") {
        std::printf("  %-52s %s %s\n", name, ok ? "PASS" : "FAIL", detail);
        std::printf("CSV,protocol,%s,%s\n", name, ok ? "PASS" : "FAIL");
        if (!ok) ++fails;
    };
    char buf[96];
    std::printf("\n== protocol ==\n");
    h.set_proto(1);
    d.sync_cfg();
    uint32_t rd, rd2;

    // read-only frames do not execute (the first may take an unread
    // result off the queue, so compare SEQ, RD and BUSY, not VALID)
    Status s1 = d.read(&rd), s2 = d.read(&rd2);
    check("read-only frame does not execute", s1.seq() == s2.seq() && !s2.busy() && rd == rd2);

    // EXEC: the pins drop DATA_READY / raise BUSY from the command byte until
    // the instruction is done. Checked with a 64-instruction self-test (tens of
    // microseconds), so how quickly the host looks after CS rises cannot matter;
    // a single CORDIC instruction can finish before a slow host reads the pins.
    const uint32_t q = h.quiet_begin();
    d.exec_frame(BIST, 64, 0x12345678);
    const int r_now = h.ready();
    const int b_now = h.busy();
    h.quiet_end(q);
    bool came = d.wait_ready();
    int b_after = h.busy();
    uint32_t rdb = 0;
    Status sb = d.read(&rdb);
    std::snprintf(buf, sizeof buf, "(right after CS rise: READY %d BUSY %d; after: BUSY %d)", r_now, b_now, b_after);
    check("DATA_READY low and BUSY high right after an EXEC frame", r_now == 0 && b_now == 1, buf);
    check("DATA_READY returns, BUSY clears", came && b_after == 0 && rdb == d.gold.exec(BIST, 64, 0x12345678));
    // STATUS and RD of an ordinary instruction
    d.exec_frame(ROTC, 0x12345678, 0x0c00);
    d.wait_ready();
    Status s3 = d.read(&rd);
    std::snprintf(buf, sizeof buf, "(STATUS %02x, seq %d -> %d)", s3.raw, sb.seq(), s3.seq());
    check("STATUS: VALID, no ERR, SEQ + 1", s3.valid() && !s3.err() && !s3.busy() && s3.seq() == ((sb.seq() + 1) & 15), buf);
    check("RD = model", rd == d.gold.exec(ROTC, 0x12345678, 0x0c00));

    // illegal ops and short frames are rejected, result and SEQ unchanged
    // (op 20 is cordic.bist; the result was read above, so VALID is clear)
    const unsigned bad_ops[] = {21, 22, 25, 31};   // the op is CMD[4:0]
    bool all = true;
    for (unsigned op : bad_ops) {
        d.exec_frame(op, 0x1000, 0x1000, nullptr, 9);
        d.wait_ready();
        Status s = d.read(&rd2);
        bool ok = s.err() && !s.valid() && s.seq() == s3.seq() && rd2 == rd;
        if (!ok) std::printf("    op %u: STATUS %02x RD %08x (before: STATUS %02x RD %08x)\n", op, s.raw, (unsigned)rd2, s3.raw, (unsigned)rd);
        all = all && ok;
    }
    check("illegal op (21, 22, 25, 31): ERR, nothing executed", all);
    d.exec_frame(SIN, 0x0800, 0, nullptr, 4);                 // CMD + 3 bytes
    d.wait_ready();
    Status s4 = d.read(&rd2);
    check("EXEC frame shorter than 5 bytes: ERR, nothing executed", s4.err() && s4.seq() == s3.seq() && rd2 == rd);
    d.exec(SIN, 0x0800, 0, &rd2, &s4);
    check("next good EXEC clears ERR", !s4.err() && rd2 == d.gold.exec(SIN, 0x0800, 0));

    // long frames: FLAGS, then zeros after RD
    uint8_t raw[16];
    Status s5 = d.read(&rd2, 16, raw);
    bool zeros = true;
    for (int i = 6; i < 16; ++i) zeros = zeros && raw[i] == 0;
    check("16-byte read frame: STATUS, RD, FLAGS, then zeros",
          zeros && raw[5] == d.gold.flags() && rd2 == d.gold.exec(SIN, 0x0800, 0) && !s5.valid());

    // exact mul / div / sqrt and the FLAGS byte (bit 0 SAT, bit 1 INV)
    {
        struct { unsigned op; uint32_t a, b, rd; uint8_t fl; const char *what; } t[] = {
            {MUL,  0x7000, 0x2000, 0x00007fff, 1, "mul 7 * 2: SAT"},
            {DIV,  0x1000, 0x0000, 0x00007fff, 2, "div 1 / 0: INV"},
            {DIV,  0xc000, 0x0800, 0xffff8000, 0, "div -4 / 0.5 = -8, not clipped"},
            {SQRT, 0xffff, 0x0000, 0xffff8000, 2, "sqrt of < 0: INV"},
            {DIV,  0x1000, 0x3000, 0x00000555, 0, "div 1 / 3 = 0x0555 (exact)"}};
        bool ok = true;
        for (auto &x : t) {
            uint32_t r = 0; d.exec(x.op, x.a, x.b, &r);
            const uint32_t m = d.gold.exec(x.op, x.a, x.b);
            const bool g = r == x.rd && d.last_flags == x.fl && m == x.rd && d.gold.flags() == x.fl;
            if (!g) std::printf("    %s: RD %08x FLAGS %u (model %08x %u)\n", x.what, (unsigned)r, d.last_flags,
                                (unsigned)m, d.gold.flags());
            ok = ok && g;
        }
        check("exact mul/div/sqrt and FLAGS (SAT, INV)", ok);
    }

    // pipelined read + exec
    uint32_t prev;
    d.exec(MUL, 0x1800, 0x2000, &rd);
    d.wait_ready();
    d.exec_frame(DIV, 0x1000, 0x3000, &prev);
    d.wait_ready();
    d.read(&rd2);
    check("pipelined frame returns the previous result, runs the next",
          prev == d.gold.exec(MUL, 0x1800, 0x2000) && rd2 == d.gold.exec(DIV, 0x1000, 0x3000));

    // queues. 4 EXEC frames back to back, then reads: every frame of
    // >= 5 bytes returns the oldest unread result; all 4 come back in order
    {
        const uint32_t qa[4] = {0x0400, 0x0800, 0x0c00, 0x1000};
        uint32_t got[8]; int ng = 0, nacc = 0; uint32_t r;
        for (int i = 0; i < 4; ++i) {
            Status s = d.exec_frame(SIN, qa[i], 0, &r);
            if (s.valid()) got[ng++] = r;
            Status p = d.read(&r, 1);
            if (!p.err()) ++nacc;
        }
        d.wait_ready();
        for (int k = 0; k < 8 && ng < nacc; ++k) { Status s = d.read(&r); if (s.valid()) got[ng++] = r; }
        bool ok = (nacc == 4) && (ng == 4);
        for (int i = 0; i < ng && i < 4; ++i) ok = ok && got[i] == d.gold.exec(SIN, qa[i], 0);
        std::snprintf(buf, sizeof buf, "(%d queued, %d results)", nacc, ng);
        check("queue: 4 EXECs back to back, 4 results in order", ok, buf);
    }
    // cordic.bist against the model's signature
    {
        uint32_t sig = 0;
        d.exec(BIST, 300, 0x00C0FFEE, &sig);
        uint32_t want = d.gold.exec(BIST, 300, 0x00C0FFEE);
        std::snprintf(buf, sizeof buf, "(%08x, model %08x)", (unsigned)sig, (unsigned)want);
        check("bist: 300 instructions, signature = model", sig == want, buf);
    }

    // unary op with and without RS2 bytes
    d.exec_frame(SQRT, 0x2000, 0xdeadbeef, nullptr, 9);
    d.wait_ready(); d.read(&rd);
    d.exec_frame(SQRT, 0x2000, 0, nullptr, 5);
    d.wait_ready(); d.read(&rd2);
    check("one-operand op: 5- and 9-byte EXEC frames agree", rd == rd2 && rd == d.gold.exec(SQRT, 0x2000, 0));

    // cfg: read-only flag, unused selectors
    uint32_t k1 = d.cfg_read(2);
    uint32_t r_ro = 0; d.exec(CFG, 0x00012345, 8 | 2, &r_ro);
    uint32_t k2 = d.cfg_read(2);
    check("cfg read-only (RS2 bit 3) leaves the register", k1 == d.gold.rst(2) && r_ro == k1 && k2 == k1);
    bool unused = true;
    for (unsigned s = 5; s < 8; ++s) { uint32_t r; d.exec(CFG, 0x5555, s, &r); unused = unused && r == 0; }
    for (unsigned s = 0; s < 5; ++s) unused = unused && d.cfg_read(s) == d.gold.rst(s);
    check("cfg selectors 5..7 read 0 and change nothing", unused);

    // EXEC while busy: only observable when a frame is shorter than an instruction
    {
        LinkActual dummy; (void)dummy;
        double frame_ns = 5 * 8 * 1e9 / double(c.cfg.sclk_hz) + 2e3;   // generous
        double op_ns = 78 * 1e9 / double(d.fclk_hz);
        if (frame_ns < op_ns) {
            d.exec_frame(ROTC, 0x12345678, 0x0c00);
            d.exec_frame(SIN, 0x0800, 0);
            d.wait_ready();
            Status s = d.read(&rd);
            check("EXEC while busy: ERR, first result kept", s.err() && rd == d.gold.exec(ROTC, 0x12345678, 0x0c00));
        } else
            std::printf("  %-52s SKIP (a frame takes longer than an instruction)\n", "EXEC while busy");
    }

    // legacy frames, both framings, and the recovery timeout
    uint16_t sn, cs, z;
    h.set_proto(0);
    bool ok1 = d.legacy(0x09B7, 0, 0x0800, 0x0C91, &sn, &cs, &z, true);
    uint32_t want = d.legacy_model(0x09B7, 0, 0x0800);
    check("legacy, one CS per byte", ok1 && sn == want >> 16 && cs == (want & 0xffff) && z == 0);
    bool ok2 = d.legacy(0x09B7, 0, 0x1234, 0x0C91, &sn, &cs, &z, false);
    want = d.legacy_model(0x09B7, 0, 0x1234);
    check("legacy, multi-byte frames (8 + 6)", ok2 && sn == want >> 16 && cs == (want & 0xffff) && z == 0);
    check("legacy: DATA_READY low after the read-out", h.ready() == 0);

    // abandoned transaction: 3 bytes, then quiet for 2^TIMEOUT_LOG2 clocks
    {
        uint8_t b[3] = {0x11, 0x22, 0x33}, r[3];
        for (int i = 0; i < 3; ++i) h.frame(&b[i], &r[i], 1);
        double wait_s = double(1ull << d.timeout_log2) / double(d.fclk_hz) * 1.15 + 0.002;
        std::printf("  (abandoned a legacy frame after 3 bytes, waiting %.3f s for the recovery timeout)\n", wait_s);
        uint64_t t0 = h.now_us();
        while (double(h.now_us() - t0) < wait_s * 1e6) h.wait_ns(100000);
        bool ok3 = d.legacy(0x09B7, 0, 0x0400, 0x0C91, &sn, &cs, &z, true);
        want = d.legacy_model(0x09B7, 0, 0x0400);
        check("legacy recovers after the timeout", ok3 && sn == want >> 16 && cs == (want & 0xffff));
    }
    h.set_proto(1);
    uint32_t a0 = d.cfg_read(0);
    check("back to command frames (PROTO = 1)", a0 == d.gold.rst(0));
    d.sync_cfg();
    std::printf("protocol: %s (%d failed)\n", pf(fails), fails);
    return fails;
}

// ---------------------------------------------------------------- shmoo
int shmoo(Ctx &c, uint32_t fmin, uint32_t fmax, uint32_t fstep, int ops) {
    Dut &d = c.dut;
    std::printf("\n== shmoo: SCLK x MISO sample delay, %d random ops per point vs the model ==\n", ops);
    std::printf("  '.' all bit-exact, 'x' errors, '-' timing not generated; chip clk %.3f MHz\n", c.cfg.fclk_hz / 1e6);
    Rng rng(c.seed ^ 0x5100);
    LinkCfg base = c.cfg;
    d.h.set_proto(1);
    for (int mode = 0; mode < 2; ++mode) {
        std::printf("  mode %d   sample delay (ns) ->\n  SCLK MHz  ", mode);
        const int dmax = 60, dstep = 4;
        for (int s = 0; s <= dmax; s += dstep) std::printf("%-3d", s);
        std::printf(" hwSPI\n");
        for (uint32_t f = fmin; f <= fmax; f += fstep) {
            std::printf("  %7.2f   ", f / 1e6);
            char row[40]; int nrow = 0;
            for (int s = 0; s <= dmax; s += dstep) {
                LinkCfg l = base; l.sclk_hz = f; l.cpha = mode; l.sample_ns = s; l.backend = Backend::PIO;
                char ch = '-';
                LinkActual a;
                if (d.h.configure(l, a)) {
                    uint32_t mism = 0;
                    for (int k = 0; k < ops; ++k) {
                        unsigned op = unsigned(rng.next() % kNumOps); if (op == CFG) op = MUL;
                        uint32_t a1 = rng.r16() | rng.r16() << 16, b1 = rng.r16(), r;
                        if (!d.exec(op, a1, b1, &r) || r != d.gold.exec(op, a1, uses_rs2(op) ? b1 : 0)) ++mism;
                    }
                    ch = mism ? 'x' : '.';
                }
                std::printf("%c  ", ch);
                if (nrow < 39) row[nrow++] = ch;
            }
            row[nrow] = 0;
            LinkCfg l = base; l.sclk_hz = f; l.cpha = mode; l.backend = Backend::HWSPI;
            LinkActual a;
            char hw = '-';
            if (d.h.configure(l, a)) {
                uint32_t mism = 0;
                for (int k = 0; k < ops; ++k) {
                    uint32_t a1 = rng.r16() | rng.r16() << 16, b1 = rng.r16(), r;
                    if (!d.exec(MUL, a1, b1, &r) || r != d.gold.exec(MUL, a1, b1)) ++mism;
                }
                hw = mism ? 'x' : '.';
            }
            std::printf("%c\n", hw);
            std::printf("CSV,shmoo,%d,%u,%s,%c\n", mode, (unsigned)f, row, hw);
            // a failed point can leave a half frame: resync
            apply_link(c, base, true);
            d.read(nullptr);
        }
    }
    apply_link(c, base, true);
    d.sync_cfg();
    return 0;
}

// ---------------------------------------------------------------- calibrate
int calibrate(Ctx &c, int ops) {
    Dut &d = c.dut;
    LinkCfg l = c.cfg;
    if (l.backend != Backend::PIO) { std::printf("calibrate: needs the PIO link\n"); return 1; }
    LinkActual a;
    l.sample_ns = 0;
    if (!d.h.configure(l, a)) { std::printf("calibrate: %s\n", a.note); return 1; }
    const double tick = a.pio_tick_ns;
    const int P = a.high + a.low;
    std::printf("\n== calibrate: MISO sample delay at SCLK %.3f MHz, mode %d (tick %.2f ns, bit = %d ticks) ==\n  ",
                a.sclk_hz / 1e6, l.cpha, tick, P);
    d.h.set_proto(1);
    Rng rng(c.seed ^ 0xca1);
    char map[3 * 64 + 1]; int nmap = 0;
    int best_lo = -1, best_len = 0, run_lo = -1;
    for (int t = 0; t < 3 * P && t < 3 * 64; ++t) {
        l.sample_ns = int(t * tick + 0.5);
        LinkActual a2;
        char ch = '-';
        if (d.h.configure(l, a2) && int(a2.sample_ns / tick + 0.5) == t) {
            uint32_t bad = 0;
            for (int k = 0; k < ops; ++k) {
                unsigned op = unsigned(rng.next() % kNumOps); if (op == CFG) op = DIV;
                uint32_t x = rng.r16() | rng.r16() << 16, y = rng.r16(), r;
                if (!d.exec(op, x, y, &r) || r != d.gold.exec(op, x, uses_rs2(op) ? y : 0)) ++bad;
                if (bad) break;
            }
            if (bad) { d.h.wait_ns(2000); d.read(nullptr); }
            ch = bad ? 'x' : '.';
        }
        map[nmap++] = ch;
        std::printf("%c", ch);
        if (ch == '.') { if (run_lo < 0) run_lo = t; if (t - run_lo + 1 > best_len) { best_len = t - run_lo + 1; best_lo = run_lo; } }
        else if (ch == 'x') run_lo = -1;                 // '-' (not placeable) does not break a window
    }
    map[nmap] = 0;
    std::printf("   ('.' pass, 'x' fail, '-' not placeable; one character per tick from 0 ns)\n");
    if (best_len == 0) {
        std::printf("calibrate: no working sample delay at this SCLK\nCSV,calibrate,FAIL,%s\n", map);
        apply_link(c, c.cfg, true);
        return 1;
    }
    int mid = best_lo + best_len / 2;
    c.cfg.sample_ns = int(mid * tick + 0.5);
    std::printf("  window %.1f .. %.1f ns (%d ticks); sample delay set to %d ns\n", best_lo * tick,
                (best_lo + best_len - 1) * tick, best_len, c.cfg.sample_ns);
    std::printf("CSV,calibrate,%.0f,%d,%.2f,%d,%d,%d,%s\n", a.sclk_hz, l.cpha, tick, best_lo, best_len, c.cfg.sample_ns, map);
    apply_link(c, c.cfg);
    return 0;
}

// ---------------------------------------------------------------- perf
int perf(Ctx &c, uint32_t n) {
    Dut &d = c.dut;
    std::printf("\n== perf ==\n");
    d.h.set_proto(1);
    d.sync_cfg();
    Rng rng(c.seed ^ 0xbeef);
    const unsigned ops[] = {SIN, ATAN2, EXP, SQRT, MUL, DIV, TANH, ROTC};
    for (unsigned op : ops) {
        uint32_t mism = 0;
        uint64_t t0 = d.h.now_us();
        uint32_t bad = stream(d, op, n, [&](uint32_t, uint32_t &a, uint32_t &b) { a = rng.r16() | rng.r16() << 16; b = rng.r16(); },
                              [&](uint32_t a, uint32_t b, uint32_t rd, bool) { if (rd != d.gold.exec(op, a, b)) ++mism; });
        double us = double(d.h.now_us() - t0);
        std::printf("  %-6s %8.0f ops/s pipelined (%u-byte frames)  %s\n", op_name(op), n * 1e6 / us,
                    uses_rs2(op) ? 9u : 5u, (mism || bad) ? "ERRORS" : "");
        std::printf("CSV,perf,%s,%.1f\n", op_name(op), n * 1e6 / us);
    }
    // latency: CS rise of the EXEC frame to DATA_READY, averaged
    uint64_t t0 = d.h.now_us(); uint32_t k = 0;
    for (; k < n; ++k) { d.exec_frame(ROTC, 0x12345678, 0x1c00); d.wait_ready(); }
    double per = double(d.h.now_us() - t0) / k;
    std::printf("  EXEC frame + wait for DATA_READY (rotc, longest): %.2f us per instruction\n", per);
    std::printf("CSV,perf,exec_wait_us,%.3f\n", per);
    return 0;
}

// ---------------------------------------------------------------- regression
int regression(Ctx &c) {
    int f = identify(c);
    if (f) return f;
    int fb = bitexact(c, c.bitexact_n);
    int fp = protocol(c);
    int fl = legacy(c, 250, true);
    int fa = accuracy(c, "all", c.n_binary);
    int total = fb + fp + fl + fa;
    std::printf("\n== regression: %s ==  bitexact %s, protocol %s, legacy %s, accuracy %s\n", pf(total),
                pf(fb), pf(fp), pf(fl), pf(fa));
    std::printf("CSV,regression,%s\n", pf(total));
    return total;
}

}  // namespace suites
