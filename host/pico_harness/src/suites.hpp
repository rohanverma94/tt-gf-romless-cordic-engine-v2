// suites.hpp — the harness's tests. Each returns the number of failures
// (0 = PASS) and prints a human summary plus machine-readable "CSV," lines.
#pragma once
#include <cstdint>
#include "xc_dut.hpp"

namespace suites {

struct Ctx {
    xc::Dut &dut;
    LinkCfg cfg;            // the link setting the suites restore when they change it
    uint64_t seed = 1;
    bool dump = false;      // accuracy/legacy: print every input as CSV
    uint32_t acc_stride = 1;        // accuracy: every acc_stride-th input (1 = exhaustive)
    uint32_t n_binary = 1u << 16;   // accuracy: random pairs for two-operand functions
    uint32_t bitexact_n = 2000;     // regression: operands per op
};

// configure the link and print what was achieved; false if impossible
bool apply_link(Ctx &c, const LinkCfg &l, bool quiet = false);

int identify(Ctx &c);                       // link + GUARD; must run first
int bitexact(Ctx &c, uint32_t n_per_op);    // all 20 ops vs the golden model
int accuracy(Ctx &c, const char *fn, uint32_t n_binary); // vs libm; "all" or a name
int legacy(Ctx &c, int n_angles, bool byte_per_cs);       // ttsky25a harness sweep
int protocol(Ctx &c);                       // frame-level behaviour
int shmoo(Ctx &c, uint32_t sclk_min, uint32_t sclk_max, uint32_t sclk_step, int ops_per_point);
int calibrate(Ctx &c, int ops);             // find the MISO sample window, center the PIO sample delay
int perf(Ctx &c, uint32_t n);               // throughput and latency
int regression(Ctx &c);                     // identify + bitexact + protocol + legacy + accuracy

}  // namespace suites
