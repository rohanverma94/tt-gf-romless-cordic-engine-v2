// pico_hal.hpp — Hal for the RP2040 / RP2350 (see pico_hal.cpp)
#pragma once
#include "hal.hpp"
#include "hardware/pio.h"

class PicoHal : public Hal {
public:
    PicoHal();
    bool configure(const LinkCfg &c, LinkActual &a) override;
    void frame(const uint8_t *tx, uint8_t *rx, int n) override;
    void set_proto(int v) override;
    int ready() override;
    int busy() override;
    void wait_ns(uint32_t ns) override;
    uint64_t now_us() override;
    const char *name() override { return "pico"; }
    uint32_t quiet_begin() override;
    void quiet_end(uint32_t s) override;
    // in-frame trace (diagnostics): when trace_on, each poll of the PIO loop
    // records {BUSY, READY, bytes received so far}
    struct Tr { uint8_t pins, rx; };
    bool trace_on = false;
    int trace_n = 0;
    Tr trace[3000];

private:
    uint32_t clk_cycles(uint32_t chip_clocks) const;
    void stop_pio();
    LinkCfg cfg_;
    uint32_t fclk_ = 50000000, setup_ = 0, hold_ = 0, gap_ = 0;
    int proto_ = -1;
    bool hw_ = false, hw_on_ = false, pio_loaded_ = false;
    uint16_t insn_[32] = {0};
    pio_program_t prog_desc_{};
};
