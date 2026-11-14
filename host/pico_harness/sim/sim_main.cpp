// sim_main.cpp — runs the harness's test suites against the RTL.
//
// The firmware's protocol layer and suites (src/) run unchanged on top of a
// simulated board: the generated PIO program is executed cycle by cycle (a
// PIO emulator for the instructions the program uses), its pins reach the
// Verilated tt_um_xcordic through an I/O delay, and MISO comes back through
// another. The chip runs on its own clock. So this checks the PIO waveforms,
// the sample-delay arithmetic and every suite before a board is involved.
//
//   sim_main [options] [suite ...]
//     --fclk MHz       chip clock (50)            --fsys MHz  Pico system clock (150)
//     --sclk MHz       SCLK (10)                  --mode 0|1  SPI mode (0)
//     --sample ns      MISO sample delay (auto)   --hw        hardware-SPI master model
//     --din ns         master pin -> chip input delay (12)
//     --dout ns        chip output -> master pin delay (12)
//     --n N            bitexact operands per op (300)
//     --stride S       accuracy: every S-th input of the one-operand functions (64)
//     suites: identify calibrate bitexact accuracy legacy legacy8 protocol shmoo perf regression
#include "Vtt_um_xcordic.h"
#include "verilated.h"
#include "../src/hal.hpp"
#include "../src/pio_spi_prog.hpp"
#include "../src/suites.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

#ifndef XC_TIMEOUT_LOG2
#define XC_TIMEOUT_LOG2 16
#endif
#ifndef XC_SPI_SCLK
#define XC_SPI_SCLK 0
#endif

using ps_t = uint64_t;                         // simulation time, picoseconds

class SimHal : public Hal {
public:
    double fsys_hz = 150e6;
    ps_t din = 12000, dout = 12000;            // I/O delays

    SimHal() : top_(&ctx_) {
        top_.ena = 1; top_.ui_in = 0; top_.uio_in = 0; top_.clk = 0; top_.rst_n = 0;
        pins_ = 0x04;                           // CS high
        top_.ui_in = pins_;
        top_.eval();
        record();
    }
    void reset(double fclk_hz) {
        half_ = ps_t(5e11 / fclk_hz);
        next_edge_ = now_ + half_ + 1234;
        wait_ps(20 * 2 * half_);
        top_.rst_n = 1;                         // released between edges
        wait_ps(10 * 2 * half_);
    }

    bool configure(const LinkCfg &c, LinkActual &a) override {
        cfg_ = c;
        set_pin(4, c.cpha);
        if (c.backend == Backend::PIO) {
            int setup = 0;
            pio_spi::Timing t = pio_spi::timing(fsys_hz, c.sclk_hz, c.sample_ns, c.cpha, c.fclk_hz, setup);
            if (!t.ok) { std::snprintf(a.note, sizeof a.note, "%s", t.err); return false; }
            prog_ = pio_spi::build(t.p);
            if (!prog_.ok) { std::snprintf(a.note, sizeof a.note, "%s", prog_.err); return false; }
            tick_ = ps_t(1e12 * t.div / fsys_hz + 0.5);
            a.sclk_hz = t.sclk_hz; a.sample_ns = t.sample_ns; a.pio_tick_ns = t.tick_ns;
            a.high = t.p.high; a.low = t.p.low; a.sample = t.p.sample;
            std::snprintf(a.note, sizeof a.note, "PIO program %d instructions, divider %d", prog_.len, t.div);
        } else {
            // PL022 divider search as pico-sdk spi_set_baudrate (clk_peri = clk_sys)
            double fin = fsys_hz;
            unsigned pre = 2, post = 256;
            for (pre = 2; pre <= 254; pre += 2) if (fin < (pre + 2) * 256.0 * c.sclk_hz) break;
            for (post = 256; post > 1; --post) if (fin / (pre * (post - 1)) > c.sclk_hz) break;
            hw_half_ = ps_t(1e12 * pre * post / fin / 2);
            a.sclk_hz = fin / (pre * post);
        }
        return true;
    }

    void frame(const uint8_t *tx, uint8_t *rx, int n) override {
        set_pin(2, 0);                                             // CS low
        wait_ps(ps_t(cfg_.cs_setup_clk * 2 * half_));
        if (cfg_.backend == Backend::PIO) run_pio(tx, rx, n);
        else run_hw(tx, rx, n);
        wait_ps(ps_t(cfg_.cs_hold_clk * 2 * half_));
        set_pin(2, 1);
        wait_ps(ps_t(cfg_.cs_gap_clk * 2 * half_));
    }
    void set_proto(int v) override {
        if (((pins_ >> 3) & 1) == unsigned(v)) return;
        set_pin(3, v);
        wait_ps(8 * 2 * half_);
    }
    int ready() override { return (seen() >> 1) & 1; }
    int busy() override { return (seen() >> 2) & 1; }
    void wait_ns(uint32_t ns) override { wait_ps(ps_t(ns) * 1000); }
    uint64_t now_us() override { return now_ / 1000000; }
    const char *name() override { return "sim"; }

private:
    VerilatedContext ctx_;
    Vtt_um_xcordic top_;
    LinkCfg cfg_;
    pio_spi::Program prog_;
    ps_t now_ = 0, half_ = 10000, next_edge_ = 11234, tick_ = 6667, hw_half_ = 50000;
    uint8_t pins_ = 0;                                // master-side ui_in
    std::deque<std::pair<ps_t, uint8_t>> inq_;        // ui_in values arriving at the chip
    std::deque<std::pair<ps_t, uint8_t>> outh_;       // uo_out history at the chip

    void record() {
        uint8_t uo = top_.uo_out;
        if (outh_.empty() || outh_.back().second != uo) outh_.push_back({now_, uo});
        while (outh_.size() > 4096) outh_.pop_front();
    }
    // the chip until time t: clock edges and delayed pin changes in time order
    void advance(ps_t t) {
        for (;;) {
            ps_t ti = inq_.empty() ? ~ps_t(0) : inq_.front().first;
            ps_t tn = ti < next_edge_ ? ti : next_edge_;
            if (tn > t) break;
            now_ = tn;
            if (ti <= next_edge_) { top_.ui_in = inq_.front().second; inq_.pop_front(); }
            else { top_.clk = !top_.clk; next_edge_ += half_; }
            top_.eval();
            record();
        }
        now_ = t;
    }
    void wait_ps(ps_t d) { advance(now_ + d); }
    void set_pin(int bit, int v) {
        pins_ = uint8_t((pins_ & ~(1u << bit)) | (unsigned(v & 1) << bit));
        inq_.push_back({now_ + din, pins_});
    }
    uint8_t seen() {                                  // uo_out as the master sees it now
        ps_t t = now_ >= dout ? now_ - dout : 0;
        for (auto it = outh_.rbegin(); it != outh_.rend(); ++it) if (it->first <= t) return it->second;
        return outh_.empty() ? 0 : outh_.front().second;
    }

    // ---- PIO emulator (instructions of pio_spi_prog.hpp only) ----
    void run_pio(const uint8_t *tx, uint8_t *rx, int n) {
        int pc = 0, delay = 0, txi = 0, rxi = 0, isr_n = 0;
        uint32_t osr = 0, isr = 0, x = 0;
        for (long guard = 0; guard < 10000000; ++guard) {
            advance(now_ + tick_);
            if (delay) { --delay; continue; }
            uint16_t w = prog_.insn[pc];
            int side = (w >> 12) & 1, dl = (w >> 8) & 15;
            if (((pins_ >> 0) & 1) != side) set_pin(0, side);
            int op = w >> 13;
            bool jumped = false;
            if (op == 4) {                                              // pull block
                if (txi == n) { if (rxi == n) return; continue; }    // stalled: frame done
                osr = uint32_t(tx[txi++]) << 24;
            } else if (op == 7) x = w & 31;                             // set x
            else if (op == 3) { set_pin(1, osr >> 31); osr <<= 1; }    // out pins, 1
            else if (op == 2) {                                         // in pins, 1
                isr = (isr << 1) | (seen() & 1);
                if (++isr_n == 8) { if (rxi < n) rx[rxi++] = uint8_t(isr); isr = 0; isr_n = 0; }
            } else if (op == 0) {                                       // jmp x--
                if (x) { pc = w & 31; jumped = true; }
                --x;
            }
            if (!jumped) pc = (pc + 1 == prog_.len) ? 0 : pc + 1;
            delay = dl;
        }
        std::fprintf(stderr, "PIO emulator hung\n"); std::exit(3);
    }
    // ---- hardware SPI master: samples MISO on its edge ----
    void run_hw(const uint8_t *tx, uint8_t *rx, int n) {
        for (int i = 0; i < n; ++i) {
            uint8_t r = 0;
            for (int b = 7; b >= 0; --b) {
                if (cfg_.cpha == 0) {
                    set_pin(1, (tx[i] >> b) & 1); wait_ps(hw_half_);
                    set_pin(0, 1); r = uint8_t(r << 1 | (seen() & 1)); wait_ps(hw_half_);
                    set_pin(0, 0);
                } else {
                    set_pin(0, 1); set_pin(1, (tx[i] >> b) & 1); wait_ps(hw_half_);
                    set_pin(0, 0); r = uint8_t(r << 1 | (seen() & 1)); wait_ps(hw_half_);
                }
            }
            rx[i] = r;
        }
        wait_ps(hw_half_);
    }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    SimHal hal;
    LinkCfg l;
    uint32_t n = 300, stride = 64;
    std::vector<std::string> todo;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto num = [&]() { return i + 1 < argc ? std::atof(argv[++i]) : 0.0; };
        if (a == "--fclk") l.fclk_hz = uint32_t(num() * 1e6);
        else if (a == "--sclk") l.sclk_hz = uint32_t(num() * 1e6);
        else if (a == "--fsys") hal.fsys_hz = num() * 1e6;
        else if (a == "--mode") l.cpha = int(num());
        else if (a == "--sample") l.sample_ns = int(num());
        else if (a == "--hw") l.backend = Backend::HWSPI;
        else if (a == "--din") hal.din = ps_t(num() * 1000);
        else if (a == "--dout") hal.dout = ps_t(num() * 1000);
        else if (a == "--n") n = uint32_t(num());
        else if (a == "--stride") stride = uint32_t(num());
        else if (a[0] == '+') continue;                       // verilator plusargs
        else todo.push_back(a);
    }
    if (todo.empty()) todo.push_back("regression");
    std::printf("sim: tt_um_xcordic SPI_SCLK=%d TIMEOUT_LOG2=%d, Pico at %.0f MHz, I/O delay in %.1f / out %.1f ns\n",
                XC_SPI_SCLK, XC_TIMEOUT_LOG2, hal.fsys_hz / 1e6, hal.din / 1e3, hal.dout / 1e3);
    hal.reset(l.fclk_hz);
    xc::Dut dut(hal);
    dut.timeout_log2 = XC_TIMEOUT_LOG2;
    suites::Ctx c{dut, l};
    c.acc_stride = stride;
    c.n_binary = 4096 / stride * 16;
    c.bitexact_n = n;
    if (!suites::apply_link(c, l)) return 2;
    int fails = 0;
    for (auto &t : todo) {
        if (t == "identify") fails += suites::identify(c);
        else if (t == "bitexact") fails += suites::bitexact(c, n);
        else if (t == "accuracy") fails += suites::accuracy(c, "all", c.n_binary);
        else if (t == "legacy") fails += suites::legacy(c, 250, true);
        else if (t == "legacy8") fails += suites::legacy(c, 64, false);
        else if (t == "protocol") fails += suites::protocol(c);
        else if (t == "shmoo") fails += suites::shmoo(c, l.sclk_hz, l.sclk_hz * 2, l.sclk_hz / 2, 4);
        else if (t == "perf") fails += suites::perf(c, 64);
        else if (t == "calibrate") fails += suites::calibrate(c, 6);
        else if (t == "regression") fails += suites::regression(c);
        else { std::printf("unknown suite %s\n", t.c_str()); return 2; }
    }
    std::printf("\nSIM RESULT: %s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
