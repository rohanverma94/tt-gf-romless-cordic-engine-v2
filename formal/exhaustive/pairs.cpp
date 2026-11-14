// pairs.cpp — exhaustive run of the two-operand functions over all 2^32
// operand pairs: atan2, hypot, mul, div.
//
// For every pair it runs the RTL (src/xcordic_core.v via Verilator) and
//   1. compares the result bit-exactly with the Pico harness's golden model
//      (formal/exhaustive/xc_model.hpp, the host harness golden model), so the model is verified on every
//      input it can be asked about by these functions;
//   2. measures the error against the exact value (long double libm), with the
//      same rules as the T3 accuracy tool: values whose exact result is outside
//      [-8, 8) must saturate; defined special results (0 for atan2(0,0) and
//      0/0, saturation code for x/0) must match.
// The one-operand functions are also run (all 65536 inputs) with --unary.
//
// The work is split into 65536 blocks (one value of the second operand
// each, all 65536 first operands). Finished blocks are appended to a state
// file, so a run can be stopped and resumed, or split across machines
// (--part i/n) and the state files concatenated. Blocks are visited in
// bit-reversed order, so a partial run is an even sample of the space.
//
//   pairs [-jN] [--state F] [--part i/n] [--fn atan2,hypot,mul,div] [--hours H]
//   pairs --report F [F ...]      merge state files and print the table
//   pairs --unary                 the one-operand functions, all inputs
//
// Build: run_pairs.sh (one binary per GUARD).
#include "Vxcordic_core.h"
#include "verilated.h"
#include "xc_model.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef XC_GUARD
#define XC_GUARD 4
#endif

namespace {

constexpr long double kLsb = 4096.0L;
constexpr long double kMax = 32767.0L / 4096.0L;
constexpr long double kMin = -8.0L;
inline long double q2f(uint32_t v) { return static_cast<long double>(static_cast<int16_t>(v & 0xffff)) / kLsb; }

class Core {
public:
    Core() : m_(&ctx_) {
        m_.clk = 0; m_.rstn = 0; m_.start = 0;
        for (int i = 0; i < 4; ++i) tick();
        m_.rstn = 1;
        tick();
    }
    uint32_t exec(unsigned op, uint32_t rs1, uint32_t rs2, int &cycles) {
        m_.funct7 = op >> 3; m_.funct3 = op & 7; m_.rs1 = rs1; m_.rs2 = rs2;
        m_.start = 1; tick(); m_.start = 0;
        for (int n = 1; n <= 200; ++n) {
            tick();
            if (m_.done) { cycles = n; return m_.rd; }
        }
        std::fprintf(stderr, "core hung: op %u rs1 %08x rs2 %08x\n", op, rs1, rs2);
        std::exit(2);
    }
private:
    void tick() { m_.clk = 0; m_.eval(); m_.clk = 1; m_.eval(); }
    VerilatedContext ctx_;
    Vxcordic_core m_;
};

struct Ref { bool special; uint16_t code; long double v; };
Ref val(long double v) { return {false, 0, v}; }
Ref spec(uint16_t c) { return {true, c, 0}; }

struct Fn {
    const char *name;
    unsigned op;
    Ref (*ref)(long double a, long double b);
};
const Fn kBinary[] = {
    {"atan2", xc::ATAN2, [](long double y, long double x) { return (x == 0 && y == 0) ? spec(0) : val(std::atan2(y, x)); }},
    {"hypot", xc::HYPOT, [](long double a, long double b) { return val(std::hypot(a, b)); }},
    {"mul",   xc::MUL,   [](long double a, long double b) { return val(a * b); }},
    {"div",   xc::DIV,   [](long double a, long double b) {
         return b == 0 ? (a == 0 ? spec(0) : spec(a < 0 ? 0x8000 : 0x7fff)) : val(a / b); }},
};
const Fn kUnary[] = {
    {"sin",  xc::SIN,  [](long double a, long double) { return val(std::sin(a)); }},
    {"cos",  xc::COS,  [](long double a, long double) { return val(std::cos(a)); }},
    {"tan",  xc::TAN,  [](long double a, long double) { return val(std::tan(a)); }},
    {"exp",  xc::EXP,  [](long double a, long double) { return val(std::exp(a)); }},
    {"ln",   xc::LN,   [](long double a, long double) { return a > 0 ? val(std::log(a)) : spec(0x8000); }},
    {"sqrt", xc::SQRT, [](long double a, long double) {
         return a < 0 ? spec(0x8000) : (a == 0 ? spec(0) : val(std::sqrt(a))); }},
    {"tanh", xc::TANH, [](long double a, long double) { return val(std::tanh(a)); }},
};

struct Stats {
    uint64_t total = 0, n = 0, sat = 0, sat_ok = 0, sat_flip = 0, special = 0, special_bad = 0;
    uint64_t sext_bad = 0, model_bad = 0;
    long double sum_abs = 0, max_abs = 0, sum_sq = 0, sum_rel = 0, max_rel = 0;
    uint32_t arg_abs = 0, arg_rel = 0;
    int cyc_min = 1 << 30, cyc_max = 0;

    void add(uint32_t rd, const Ref &r, uint32_t arg) {
        ++total;
        const uint16_t lo = rd & 0xffff;
        if ((rd >> 16) != ((lo & 0x8000) ? 0xffffu : 0u)) ++sext_bad;
        if (r.special) { ++special; if (lo != r.code) ++special_bad; return; }
        if (r.v > kMax || r.v < kMin) {
            ++sat;
            if (lo == (r.v > 0 ? 0x7fff : 0x8000)) ++sat_ok;
            if ((r.v > 0) != (q2f(lo) > 0)) ++sat_flip;
            return;
        }
        const long double e = std::fabs(q2f(lo) - r.v) * kLsb;
        const long double rel = e / std::max<long double>(1.0L, std::fabs(r.v));
        ++n; sum_abs += e; sum_sq += e * e; sum_rel += rel;
        if (e > max_abs) { max_abs = e; arg_abs = arg; }
        if (rel > max_rel) { max_rel = rel; arg_rel = arg; }
    }
    void merge(const Stats &o) {
        total += o.total; n += o.n; sat += o.sat; sat_ok += o.sat_ok; sat_flip += o.sat_flip;
        special += o.special; special_bad += o.special_bad; sext_bad += o.sext_bad; model_bad += o.model_bad;
        sum_abs += o.sum_abs; sum_sq += o.sum_sq; sum_rel += o.sum_rel;
        if (o.max_abs > max_abs) { max_abs = o.max_abs; arg_abs = o.arg_abs; }
        if (o.max_rel > max_rel) { max_rel = o.max_rel; arg_rel = o.arg_rel; }
        cyc_min = std::min(cyc_min, o.cyc_min); cyc_max = std::max(cyc_max, o.cyc_max);
    }
    // one state-file line (exact: sums as hex floats)
    std::string line(const char *fn, uint32_t blk) const {
        char b[512];
        std::snprintf(b, sizeof b, "B g%d %s %u %llu %llu %llu %llu %llu %llu %llu %llu %llu %La %La %La %La %La %08x %08x %d %d\n",
                      XC_GUARD, fn, blk, (unsigned long long)total, (unsigned long long)n, (unsigned long long)sat,
                      (unsigned long long)sat_ok, (unsigned long long)sat_flip, (unsigned long long)special,
                      (unsigned long long)special_bad, (unsigned long long)sext_bad, (unsigned long long)model_bad,
                      sum_abs, max_abs, sum_sq, sum_rel, max_rel, arg_abs, arg_rel, cyc_min, cyc_max);
        return b;
    }
    bool parse(const char *s, int &g, std::string &fn, uint32_t &blk) {
        char f[16];
        unsigned long long v[9];
        int r = std::sscanf(s, "B g%d %15s %u %llu %llu %llu %llu %llu %llu %llu %llu %llu %La %La %La %La %La %x %x %d %d",
                            &g, f, &blk, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8],
                            &sum_abs, &max_abs, &sum_sq, &sum_rel, &max_rel, &arg_abs, &arg_rel, &cyc_min, &cyc_max);
        if (r != 21) return false;
        fn = f;
        total = v[0]; n = v[1]; sat = v[2]; sat_ok = v[3]; sat_flip = v[4]; special = v[5];
        special_bad = v[6]; sext_bad = v[7]; model_bad = v[8];
        return true;
    }
};

uint32_t bitrev16(uint32_t x) {
    uint32_t r = 0;
    for (int i = 0; i < 16; ++i) r |= ((x >> i) & 1u) << (15 - i);
    return r;
}

void header(bool pairs) {
    std::printf("%-6s %14s %9s %7s %7s %9s %7s  %-8s %-8s %6s %10s  %s\n", "fn", "inputs", "abs max", "mean", "rms",
                "rel max", "mean", "argmax", "argrel", "cycles", "model", "notes");
    (void)pairs;
}
void report_line(const char *fn, const Stats &s, uint64_t space) {
    std::printf("%-6s %14llu %9.3Lf %7.3Lf %7.3Lf %9.3Lf %7.3Lf  %08x %08x %2d-%-3d %10s ", fn,
                (unsigned long long)s.total, s.max_abs, s.n ? s.sum_abs / s.n : 0.0L,
                s.n ? std::sqrt(s.sum_sq / s.n) : 0.0L, s.max_rel, s.n ? s.sum_rel / s.n : 0.0L, s.arg_abs,
                s.arg_rel, s.cyc_min, s.cyc_max, s.model_bad ? "MISMATCH" : "bit-exact");
    if (s.total < space) std::printf(" PARTIAL %.2f%%", 100.0 * double(s.total) / double(space));
    if (s.sat) std::printf(" |exact|>=8: %llu (saturated %llu, sign flipped %llu)", (unsigned long long)s.sat,
                           (unsigned long long)s.sat_ok, (unsigned long long)s.sat_flip);
    if (s.special) std::printf(" special %llu (bad %llu)", (unsigned long long)s.special,
                               (unsigned long long)s.special_bad);
    if (s.sext_bad) std::printf(" SIGN-EXTENSION ERRORS %llu", (unsigned long long)s.sext_bad);
    if (s.model_bad) std::printf(" MODEL MISMATCHES %llu", (unsigned long long)s.model_bad);
    std::printf("\n");
}

int report(int argc, char **argv, int first) {
    // (guard, fn) -> block -> stats; duplicate blocks (overlapping runs) count once
    std::map<std::pair<int, std::string>, std::map<uint32_t, Stats>> all;
    for (int i = first; i < argc; ++i) {
        FILE *f = std::fopen(argv[i], "r");
        if (!f) { std::perror(argv[i]); return 1; }
        char buf[600];
        while (std::fgets(buf, sizeof buf, f)) {
            Stats s; int g; std::string fn; uint32_t blk;
            if (s.parse(buf, g, fn, blk)) all[{g, fn}][blk] = s;
        }
        std::fclose(f);
    }
    int bad = 0, cur = -1;
    for (auto &kv : all) {
        if (kv.first.first != cur) {
            cur = kv.first.first;
            std::printf("\nGUARD %d: all 2^32 operand pairs (rs1 = first operand, rs2 = second; "
                        "atan2(y = rs1, x = rs2)). Errors in LSB of S3.12.\n", cur);
            header(true);
        }
        Stats s;
        for (auto &b : kv.second) s.merge(b.second);
        report_line(kv.first.second.c_str(), s, uint64_t(1) << 32);
        if (s.model_bad || s.sext_bad || s.special_bad) ++bad;
    }
    std::printf("\n%s\n", bad ? "FAIL: see the flagged rows" : "no model mismatches, special-case or sign-extension errors");
    return bad ? 1 : 0;
}

}  // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    unsigned threads = std::max(1u, std::thread::hardware_concurrency());
    std::string state = "pairs_g" + std::to_string(XC_GUARD) + ".state";
    unsigned part = 0, parts = 1;
    double hours = 0;
    std::vector<const Fn *> fns;
    bool unary = false;
    for (int i = 1; i < argc; ++i) {
        if (!std::strcmp(argv[i], "--report")) return report(argc, argv, i + 1);
        else if (!std::strcmp(argv[i], "--unary")) unary = true;
        else if (!std::strncmp(argv[i], "-j", 2)) threads = std::max(1, std::atoi(argv[i] + 2));
        else if (!std::strcmp(argv[i], "--state") && i + 1 < argc) state = argv[++i];
        else if (!std::strcmp(argv[i], "--hours") && i + 1 < argc) hours = std::atof(argv[++i]);
        else if (!std::strcmp(argv[i], "--part") && i + 1 < argc) {
            if (std::sscanf(argv[++i], "%u/%u", &part, &parts) != 2 || parts == 0 || part >= parts) {
                std::fprintf(stderr, "--part i/n with 0 <= i < n\n"); return 2;
            }
        } else if (!std::strcmp(argv[i], "--fn") && i + 1 < argc) {
            std::string list = argv[++i];
            for (const Fn &f : kBinary) if (list.find(f.name) != std::string::npos) fns.push_back(&f);
        } else { std::fprintf(stderr, "unknown argument %s\n", argv[i]); return 2; }
    }

    if (unary) {
        std::printf("GUARD %d: one-operand functions, all 65536 inputs, RTL vs exact and vs the model\n", XC_GUARD);
        header(false);
        int bad = 0;
        for (const Fn &f : kUnary) {
            Core core;
            xc::Model<XC_GUARD> model;
            Stats s;
            for (uint32_t a = 0; a < 65536; ++a) {
                int cyc;
                uint32_t rd = core.exec(f.op, a, 0, cyc);
                if (rd != model.exec(f.op, a, 0)) ++s.model_bad;
                s.cyc_min = std::min(s.cyc_min, cyc); s.cyc_max = std::max(s.cyc_max, cyc);
                s.add(rd, f.ref(q2f(a), 0), a);
            }
            report_line(f.name, s, 65536);
            if (s.model_bad || s.sext_bad || s.special_bad) ++bad;
        }
        return bad ? 1 : 0;
    }
    if (fns.empty()) for (const Fn &f : kBinary) fns.push_back(&f);

    // blocks already done
    std::map<std::string, std::vector<bool>> done;
    for (const Fn *f : fns) done[f->name].assign(65536, false);
    if (FILE *sf = std::fopen(state.c_str(), "r")) {
        char buf[600];
        while (std::fgets(buf, sizeof buf, sf)) {
            Stats s; int g; std::string fn; uint32_t blk;
            if (s.parse(buf, g, fn, blk) && g == XC_GUARD && done.count(fn) && blk < 65536) done[fn][blk] = true;
        }
        std::fclose(sf);
    }
    FILE *out = std::fopen(state.c_str(), "a");
    if (!out) { std::perror(state.c_str()); return 1; }

    // work list: (fn, block) in bit-reversed block order, this part only
    struct Job { const Fn *f; uint32_t blk; };
    std::vector<Job> jobs;
    for (uint32_t i = 0; i < 65536; ++i) {
        const uint32_t blk = bitrev16(i);
        if (blk % parts != part) continue;
        for (const Fn *f : fns) if (!done[f->name][blk]) jobs.push_back({f, blk});
    }
    std::printf("GUARD %d: %zu blocks of 65536 pairs to run (%s), %u threads, state %s\n", XC_GUARD, jobs.size(),
                parts > 1 ? ("part " + std::to_string(part) + "/" + std::to_string(parts)).c_str() : "all parts",
                threads, state.c_str());
    std::fflush(stdout);

    std::atomic<size_t> next{0};
    std::atomic<uint64_t> pairs_done{0};
    std::atomic<bool> stop{false};
    std::mutex io;
    const auto t0 = std::chrono::steady_clock::now();
    auto elapsed = [&] { return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count(); };
    std::vector<std::thread> pool;
    for (unsigned t = 0; t < threads; ++t)
        pool.emplace_back([&] {
            Core core;
            xc::Model<XC_GUARD> model;
            for (;;) {
                if (stop) break;
                const size_t j = next.fetch_add(1);
                if (j >= jobs.size()) break;
                const Fn &f = *jobs[j].f;
                const uint32_t b = jobs[j].blk;
                Stats s;
                for (uint32_t a = 0; a < 65536; ++a) {
                    int cyc;
                    const uint32_t rd = core.exec(f.op, a, b, cyc);
                    const uint32_t want = model.exec(f.op, a, b);
                    if (rd != want) {
                        if (s.model_bad++ < 4) {
                            std::lock_guard<std::mutex> l(io);
                            std::fprintf(stderr, "MODEL MISMATCH %s rs1 %04x rs2 %04x: rtl %08x model %08x\n",
                                         f.name, a, b, rd, want);
                        }
                    }
                    s.cyc_min = std::min(s.cyc_min, cyc); s.cyc_max = std::max(s.cyc_max, cyc);
                    s.add(rd, f.ref(q2f(a), q2f(b)), b << 16 | a);
                }
                const uint64_t pd = pairs_done += 65536;
                std::lock_guard<std::mutex> l(io);
                std::fputs(s.line(f.name, b).c_str(), out);
                std::fflush(out);
                if (((j + 1) & 255) == 0 || j + 1 == jobs.size()) {
                    const double el = elapsed(), rate = pd / el;
                    const double left = double(jobs.size() - j - 1) * 65536.0 / rate;
                    std::printf("  %zu/%zu blocks, %.0f pairs/s, %.1f h elapsed, ~%.1f h left\n", j + 1, jobs.size(),
                                rate, el / 3600, left / 3600);
                    std::fflush(stdout);
                }
                if (hours > 0 && elapsed() > hours * 3600) stop = true;
            }
        });
    for (auto &th : pool) th.join();
    std::fclose(out);
    std::printf(stop ? "stopped after %.2f h (resume with the same command)\n" : "done in %.2f h\n", elapsed() / 3600);
    return 0;
}
