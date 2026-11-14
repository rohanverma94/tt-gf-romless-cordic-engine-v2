// pico_hal.cpp — the Hal on an RP2040 / RP2350: SPI master in PIO (generated
// program, programmable MISO sample delay) or in the SPI block, GPIO for CS,
// PROTO, CPHA, DATA_READY and BUSY.
#include "pico_hal.hpp"

#include <cstdio>
#include "board.hpp"
#include "hardware/clocks.h"
#include "hardware/gpio.h"
#include "hardware/pio.h"
#include "hardware/spi.h"
#include "hardware/sync.h"
#include "pico/stdlib.h"
#include "pio_spi_prog.hpp"

namespace {
PIO const kPio = pio0;
constexpr uint kSm = 0;
}

PicoHal::PicoHal() {
    const uint outs[] = {XC_PIN_CS, XC_PIN_PROTO, XC_PIN_CPHA};
    for (uint p : outs) { gpio_init(p); gpio_set_dir(p, GPIO_OUT); }
    gpio_put(XC_PIN_CS, 1);
    gpio_put(XC_PIN_PROTO, 1);
    gpio_put(XC_PIN_CPHA, 0);
    const uint ins[] = {XC_PIN_READY, XC_PIN_BUSY};
    for (uint p : ins) { gpio_init(p); gpio_set_dir(p, GPIO_IN); gpio_pull_down(p); }
    gpio_pull_down(XC_PIN_MISO);                       // an absent chip reads as 0
    const uint fast[] = {XC_PIN_SCLK, XC_PIN_MOSI, XC_PIN_CS};
    for (uint p : fast) {
        gpio_set_slew_rate(p, GPIO_SLEW_RATE_FAST);
        gpio_set_drive_strength(p, GPIO_DRIVE_STRENGTH_8MA);
    }
    proto_ = 1;
}

uint32_t PicoHal::clk_cycles(uint32_t chip_clocks) const {
    // chip clocks -> CPU cycles, rounded up, + 2 for the GPIO write itself
    uint64_t c = (uint64_t(chip_clocks) * clock_get_hz(clk_sys) + fclk_ - 1) / fclk_;
    return uint32_t(c) + 2;
}

void PicoHal::stop_pio() {
    if (pio_loaded_) {
        pio_sm_set_enabled(kPio, kSm, false);
        pio_remove_program(kPio, &prog_desc_, 0);
        pio_loaded_ = false;
    }
}

bool PicoHal::configure(const LinkCfg &c, LinkActual &a) {
    cfg_ = c;
    fclk_ = c.fclk_hz ? c.fclk_hz : 50000000;
    setup_ = clk_cycles(c.cs_setup_clk);
    hold_ = clk_cycles(c.cs_hold_clk);
    gap_ = clk_cycles(c.cs_gap_clk);
    a = LinkActual{};
    // CPHA pin: only change it with CS high and SCLK idle
    gpio_put(XC_PIN_CPHA, c.cpha & 1);

    if (c.backend == Backend::PIO) {
        const double fsys = clock_get_hz(clk_sys);
        pio_spi::Timing t = pio_spi::timing(fsys, c.sclk_hz, c.sample_ns, c.cpha, fclk_);
        if (!t.ok) { std::snprintf(a.note, sizeof a.note, "%s", t.err); return false; }
        pio_spi::Program p = pio_spi::build(t.p);
        if (!p.ok) { std::snprintf(a.note, sizeof a.note, "%s", p.err); return false; }
        stop_pio();
        if (hw_on_) { spi_deinit(XC_SPI_INST); hw_on_ = false; }
        for (int i = 0; i < p.len; ++i) insn_[i] = p.insn[i];
        prog_desc_ = pio_program_t{};
        prog_desc_.instructions = insn_;
        prog_desc_.length = uint8_t(p.len);
        prog_desc_.origin = 0;                            // jmp targets and the idle check assume address 0
        if (!pio_can_add_program_at_offset(kPio, &prog_desc_, 0)) {
            std::snprintf(a.note, sizeof a.note, "PIO0 instruction memory in use");
            return false;
        }
        pio_add_program_at_offset(kPio, &prog_desc_, 0);
        pio_loaded_ = true;

        pio_sm_config sc = pio_get_default_sm_config();
        sm_config_set_wrap(&sc, 0, uint(p.len - 1));
        sm_config_set_sideset(&sc, 1, false, false);
        sm_config_set_sideset_pins(&sc, XC_PIN_SCLK);
        sm_config_set_out_pins(&sc, XC_PIN_MOSI, 1);
        sm_config_set_in_pins(&sc, XC_PIN_MISO);
        sm_config_set_out_shift(&sc, false, false, 32);   // MSB first, explicit pull
        sm_config_set_in_shift(&sc, false, true, 8);      // autopush every byte
        sm_config_set_clkdiv_int_frac(&sc, uint16_t(t.div), 0);
        pio_gpio_init(kPio, XC_PIN_SCLK);
        pio_gpio_init(kPio, XC_PIN_MOSI);
        pio_gpio_init(kPio, XC_PIN_MISO);
        gpio_pull_down(XC_PIN_MISO);
        const uint32_t outmask = (1u << XC_PIN_SCLK) | (1u << XC_PIN_MOSI);
        pio_sm_set_pins_with_mask(kPio, kSm, 0, outmask);
        pio_sm_set_pindirs_with_mask(kPio, kSm, outmask, outmask | (1u << XC_PIN_MISO));
        // sample MISO without the 2-cycle input synchronizer: the program's
        // sample point is then exactly the cycle it says
        kPio->input_sync_bypass |= 1u << XC_PIN_MISO;
        pio_sm_init(kPio, kSm, 0, &sc);
        pio_sm_set_enabled(kPio, kSm, true);

        a.sclk_hz = t.sclk_hz; a.sample_ns = t.sample_ns; a.pio_tick_ns = t.tick_ns;
        a.high = t.p.high; a.low = t.p.low; a.sample = t.p.sample;
        std::snprintf(a.note, sizeof a.note, "PIO program %d instructions, clock divider %d, system clock %.1f MHz",
                      p.len, t.div, fsys / 1e6);
        hw_ = false;
    } else {
        stop_pio();
        uint baud = spi_init(XC_SPI_INST, c.sclk_hz);
        spi_set_format(XC_SPI_INST, 8, SPI_CPOL_0, c.cpha ? SPI_CPHA_1 : SPI_CPHA_0, SPI_MSB_FIRST);
        gpio_set_function(XC_PIN_SCLK, GPIO_FUNC_SPI);
        gpio_set_function(XC_PIN_MOSI, GPIO_FUNC_SPI);
        gpio_set_function(XC_PIN_MISO, GPIO_FUNC_SPI);
        gpio_pull_down(XC_PIN_MISO);
        hw_on_ = true;
        hw_ = true;
        a.sclk_hz = baud;
        std::snprintf(a.note, sizeof a.note, "SPI block samples MISO on its own edge (no read delay)");
    }
    return true;
}

void PicoHal::frame(const uint8_t *tx, uint8_t *rx, int n) {
    gpio_put(XC_PIN_CS, 0);
    busy_wait_at_least_cycles(setup_);
    if (hw_) {
        spi_write_read_blocking(XC_SPI_INST, tx, rx, size_t(n));
        // the SPI block is idle once the last byte is received
    } else {
        int ti = 0, ri = 0;
        // Keep the TX FIFO fed so bytes follow each other without a pause, but
        // never more than 4 bytes ahead of what has been read. Otherwise, when
        // the CPU is late (a USB interrupt), the 4-deep RX FIFO fills and the
        // `in` that completes the next byte stalls with SCLK high: it then
        // samples MISO after the slave has moved on to the next bit, which
        // corrupts the last bit of the 5th byte (result bit 24). With the limit
        // the SM waits on `pull` instead, with SCLK low, which is harmless.
        uint32_t spin = 0;
        while (ri < n) {
            if (trace_on && trace_n < 3000)
                trace[trace_n++] = Tr{uint8_t(gpio_get(XC_PIN_BUSY) | gpio_get(XC_PIN_READY) << 1), uint8_t(ri)};
            if (ti < n && ti - ri < 4 && !pio_sm_is_tx_fifo_full(kPio, kSm)) kPio->txf[kSm] = uint32_t(tx[ti++]) << 24;
            if (!pio_sm_is_rx_fifo_empty(kPio, kSm)) { rx[ri++] = uint8_t(kPio->rxf[kSm]); spin = 0; }
            else if (++spin > 50000000u) break;          // never: the SM always finishes a byte
        }
        // the last byte's trailing cycles: wait until the SM is back on `pull`
        while (pio_sm_get_pc(kPio, kSm) != 0) tight_loop_contents();
    }
    busy_wait_at_least_cycles(hold_);
    gpio_put(XC_PIN_CS, 1);
    busy_wait_at_least_cycles(gap_);
}

void PicoHal::set_proto(int v) {
    if (v == proto_) return;
    gpio_put(XC_PIN_PROTO, v & 1);
    proto_ = v;
    busy_wait_at_least_cycles(clk_cycles(8));           // sampled while CS is high and idle
}

int PicoHal::ready() { return gpio_get(XC_PIN_READY); }
int PicoHal::busy() { return gpio_get(XC_PIN_BUSY); }

void PicoHal::wait_ns(uint32_t ns) {
    if (ns >= 2000) { busy_wait_us_32(ns / 1000); return; }
    busy_wait_at_least_cycles(uint32_t(uint64_t(ns) * clock_get_hz(clk_sys) / 1000000000ull) + 1);
}

uint64_t PicoHal::now_us() { return time_us_64(); }

// USB stdio interrupts land a few microseconds after a printf; keep them out
// of checks that read the pins right after a frame
uint32_t PicoHal::quiet_begin() { return save_and_disable_interrupts(); }
void PicoHal::quiet_end(uint32_t s) { restore_interrupts(s); }
