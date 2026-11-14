// main.cpp — tt_um_xcordic test harness firmware (RP2040 / RP2350).
//
// A command console on USB serial (any terminal, or tools/xch). Every test
// prints a human summary and "CSV," lines for logging. `help` lists commands.
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "board.hpp"
#include "hardware/clocks.h"
#include "hardware/vreg.h"
#include "hardware/sync.h"
#include "hardware/structs/sio.h"
#include "pico/stdlib.h"
#include "pico_hal.hpp"
#include "suites.hpp"

namespace {

const char *kHelp =
    "tt_um_xcordic harness — commands (numbers in MHz / ns unless noted)\n"
    "  settings\n"
    "    status                 show the settings\n"
    "    fclk <MHz>             the chip's clock, as set on the demo board (default 25)\n"
    "    sclk <MHz>             SPI clock (default 5)\n"
    "    mode <0|1>             SPI mode = CPHA; also drives ui[4]\n"
    "    sample <ns|auto>       PIO MISO sample delay after the sample edge\n"
    "    link <pio|hw>          PIO master (sample delay) or the SPI block (samples on its edge)\n"
    "    cs <setup> <hold> <gap>  CS timing in chip clocks (default 4 3 6)\n"
    "    sysclk <MHz>           Pico system clock = PIO resolution (RP2040 <= 250, RP2350 <= 300)\n"
    "    seed <n> | dump <0|1>  random seed | print every accuracy/legacy input as CSV\n"
    "  tests (PASS = bit-exact with the golden model of the proven RTL)\n"
    "    id                     link check, GUARD detection, cfg reset values\n"
    "    calibrate              find the MISO sample window at this SCLK, center the delay\n"
    "    bitexact [n]           all 20 ops x n random operands (default 2000) + random cfg\n"
    "    accuracy [fn|all] [pairs]  one-operand functions exhaustively, two-operand on pairs\n"
    "                           (sin cos tan exp ln sqrt tanh | atan2 hypot mul div)\n"
    "    legacy [n] [cs|frame]  ttsky25a-protocol sweep (default 250 angles, one CS per byte)\n"
    "    protocol               frame-level behaviour, legacy timeout recovery\n"
    "    shmoo [min max step] [ops]  SCLK x sample-delay pass map, both modes, + SPI block\n"
    "    perf [n]               throughput / latency\n"
    "    regression             id + bitexact + protocol + legacy + accuracy\n"
    "  low level\n"
    "    raw <hex bytes>        one CS frame, prints MISO      proto <0|1>   PROTO pin\n"
    "    pinwatch               long self-test, then sample the BUSY and DATA_READY pins\n"
    "    timeline               BUSY / DATA_READY in the first 20 us after an EXEC\n"
    "    exec <op> <rs1> [rs2]  one instruction (hex), with the model's answer\n"
    "    pins                   wiring\n";

void print_pins() {
    std::printf("wiring (Pico GPIO -> Tiny Tapeout pin):\n"
                "  GP%-2d -> ui[0] SCLK        GP%-2d -> ui[1] MOSI       GP%-2d <- uo[0] MISO\n"
                "  GP%-2d -> ui[2] CS_N        GP%-2d -> ui[3] PROTO      GP%-2d -> ui[4] CPHA\n"
                "  GP%-2d <- uo[1] DATA_READY  GP%-2d <- uo[2] BUSY       GND -- GND (one ground per signal pair)\n"
                "  ui[5..7] low. Demo board: select tt_um_xcordic, clock the project (fclk), and leave\n"
                "  ui_in to the PMOD (its RP2040 must not drive ui_in; DIP switches off).\n",
                XC_PIN_SCLK, XC_PIN_MOSI, XC_PIN_MISO, XC_PIN_CS, XC_PIN_PROTO, XC_PIN_CPHA, XC_PIN_READY,
                XC_PIN_BUSY);
}

void print_status(const suites::Ctx &c) {
    const LinkCfg &l = c.cfg;
    std::printf("fclk %.3f MHz  sclk %.3f MHz  mode %d  link %s  sample %s", l.fclk_hz / 1e6, l.sclk_hz / 1e6,
                l.cpha, l.backend == Backend::PIO ? "pio" : "hw", l.sample_ns < 0 ? "auto" : "");
    if (l.sample_ns >= 0) std::printf("%d ns", l.sample_ns);
    std::printf("  cs %u/%u/%u clk  sysclk %.1f MHz  seed %llu  GUARD %s\n", (unsigned)l.cs_setup_clk,
                (unsigned)l.cs_hold_clk, (unsigned)l.cs_gap_clk, clock_get_hz(clk_sys) / 1e6,
                (unsigned long long)c.seed, c.dut.guard_known ? (c.dut.gold.guard ? "4" : "0") : "unknown (run id)");
}

// read one line from USB serial, with echo and backspace
int read_line(char *buf, int max) {
    int n = 0;
    for (;;) {
        int ch = getchar_timeout_us(100000);
        if (ch == PICO_ERROR_TIMEOUT) continue;
        if (ch == '\r' || ch == '\n') { std::printf("\n"); buf[n] = 0; return n; }
        if ((ch == 8 || ch == 127) && n > 0) { --n; std::printf("\b \b"); continue; }
        if (ch >= 32 && ch < 127 && n < max - 1) { buf[n++] = char(ch); std::putchar(ch); }
    }
}

int split(char *s, char **argv, int max) {
    int n = 0;
    while (*s && n < max) {
        while (*s && std::isspace((unsigned char)*s)) ++s;
        if (!*s) break;
        argv[n++] = s;
        while (*s && !std::isspace((unsigned char)*s)) ++s;
        if (*s) *s++ = 0;
    }
    return n;
}

double num(const char *s, double dflt) { return s ? std::atof(s) : dflt; }

bool need_guard(suites::Ctx &c) {
    if (c.dut.guard_known) return true;
    return suites::identify(c) == 0;
}

bool set_sysclk(double mhz) {
    uint32_t khz = uint32_t(mhz * 1000);
    uint vco, pd1, pd2;
    if (!check_sys_clock_khz(khz, &vco, &pd1, &pd2)) return false;
#if PICO_RP2040
    if (khz > 133000) { vreg_set_voltage(VREG_VOLTAGE_1_15); sleep_ms(10); }
#else
    if (khz > 150000) { vreg_set_voltage(VREG_VOLTAGE_1_20); sleep_ms(10); }
#endif
    stdio_flush();
    set_sys_clock_khz(khz, true);
    // clk_peri follows clk_sys (SPI block); USB runs from its own PLL
    clock_configure(clk_peri, 0, CLOCKS_CLK_PERI_CTRL_AUXSRC_VALUE_CLKSRC_PLL_SYS, khz * 1000, khz * 1000);
    return true;
}

}  // namespace

int main() {
    stdio_init_all();
    PicoHal hal;
    xc::Dut dut(hal);
    LinkCfg l;
    l.sclk_hz = 5000000;
    suites::Ctx c{dut, l};
#ifdef PICO_DEFAULT_LED_PIN
    gpio_init(PICO_DEFAULT_LED_PIN);
    gpio_set_dir(PICO_DEFAULT_LED_PIN, GPIO_OUT);
#endif
    while (!stdio_usb_connected()) {
#ifdef PICO_DEFAULT_LED_PIN
        gpio_xor_mask(1u << PICO_DEFAULT_LED_PIN);
#endif
        sleep_ms(250);
    }
    sleep_ms(200);
    std::printf("\n=== tt_um_xcordic harness (%s, %.0f MHz), build r8 2026-11-05 ===\n",
#if PICO_RP2040
                "RP2040",
#else
                "RP2350",
#endif
                clock_get_hz(clk_sys) / 1e6);
    print_pins();
    suites::apply_link(c, c.cfg);
    print_status(c);
    std::printf("type 'help'; start with 'id'\n");

    char line[160];
    char *argv[24];
    for (;;) {
#ifdef PICO_DEFAULT_LED_PIN
        gpio_put(PICO_DEFAULT_LED_PIN, 1);
#endif
        std::printf("> ");
        read_line(line, sizeof line);
        int argc = split(line, argv, 24);
        if (!argc) continue;
#ifdef PICO_DEFAULT_LED_PIN
        gpio_put(PICO_DEFAULT_LED_PIN, 0);
#endif
        const char *cmd = argv[0];
        const char *a1 = argc > 1 ? argv[1] : nullptr, *a2 = argc > 2 ? argv[2] : nullptr;
        const char *a3 = argc > 3 ? argv[3] : nullptr, *a4 = argc > 4 ? argv[4] : nullptr;
        LinkCfg nl = c.cfg;
        bool relink = false;

        if (!std::strcmp(cmd, "help") || !std::strcmp(cmd, "?")) std::printf("%s", kHelp);
        else if (!std::strcmp(cmd, "pins")) print_pins();
        else if (!std::strcmp(cmd, "status")) print_status(c);
        else if (!std::strcmp(cmd, "fclk") && a1) { nl.fclk_hz = uint32_t(num(a1, 50) * 1e6); relink = true; }
        else if (!std::strcmp(cmd, "sclk") && a1) { nl.sclk_hz = uint32_t(num(a1, 5) * 1e6); relink = true; }
        else if (!std::strcmp(cmd, "mode") && a1) { nl.cpha = std::atoi(a1) & 1; relink = true; }
        else if (!std::strcmp(cmd, "sample") && a1) { nl.sample_ns = !std::strcmp(a1, "auto") ? -1 : std::atoi(a1); relink = true; }
        else if (!std::strcmp(cmd, "link") && a1) { nl.backend = !std::strcmp(a1, "hw") ? Backend::HWSPI : Backend::PIO; relink = true; }
        else if (!std::strcmp(cmd, "cs") && a3) {
            nl.cs_setup_clk = uint32_t(std::atoi(a1)); nl.cs_hold_clk = uint32_t(std::atoi(a2));
            nl.cs_gap_clk = uint32_t(std::atoi(a3)); relink = true;
        }
        else if (!std::strcmp(cmd, "sysclk") && a1) {
            if (!set_sysclk(num(a1, 150))) std::printf("cannot make %.1f MHz exactly from the PLL\n", num(a1, 150));
            relink = true;
        }
        else if (!std::strcmp(cmd, "seed") && a1) c.seed = std::strtoull(a1, nullptr, 0);
        else if (!std::strcmp(cmd, "dump") && a1) c.dump = std::atoi(a1) != 0;
        else if (!std::strcmp(cmd, "id")) suites::identify(c);
        else if (!std::strcmp(cmd, "calibrate")) { if (need_guard(c)) suites::calibrate(c, 16); }
        else if (!std::strcmp(cmd, "bitexact")) { if (need_guard(c)) suites::bitexact(c, uint32_t(num(a1, 2000))); }
        else if (!std::strcmp(cmd, "accuracy")) { if (need_guard(c)) suites::accuracy(c, a1 ? a1 : "all", uint32_t(num(a2, 65536))); }
        else if (!std::strcmp(cmd, "legacy")) {
            if (need_guard(c)) suites::legacy(c, int(num(a1, 250)), !(a2 && !std::strcmp(a2, "frame")));
        }
        else if (!std::strcmp(cmd, "protocol")) { if (need_guard(c)) suites::protocol(c); }
        else if (!std::strcmp(cmd, "shmoo")) {
            if (need_guard(c)) {
                double lo = num(a1, 2), hi = num(a2, 20), st = num(a3, 2);
                suites::shmoo(c, uint32_t(lo * 1e6), uint32_t(hi * 1e6), uint32_t(st * 1e6), int(num(a4, 8)));
            }
        }
        else if (!std::strcmp(cmd, "perf")) { if (need_guard(c)) suites::perf(c, uint32_t(num(a1, 2000))); }
        else if (!std::strcmp(cmd, "regression")) {
            c.bitexact_n = 2000; c.acc_stride = 1; c.n_binary = 65536;
            dut.guard_known = false;
            suites::regression(c);
        }
        else if (!std::strcmp(cmd, "proto") && a1) hal.set_proto(std::atoi(a1) & 1);
        else if (!std::strcmp(cmd, "timeline")) {
            // BUSY / READY right before and after an EXEC frame, as fast as the
            // CPU samples (no interrupts), to compare with the RTL simulation:
            //   sim: rotc  t=0 BUSY 1 READY 0, t=3.1us BUSY 0 READY 1
            //        bist  t=0 BUSY 1 READY 0 (N = 200 runs ~190 us)
            hal.set_proto(1);
            struct { const char *name; uint8_t tx[9]; } fr[] = {
                {"rotc", {0x80 | 19, 0x78, 0x56, 0x34, 0x12, 0x00, 0x0c, 0x00, 0x00}},
                {"bist N=200", {0x94, 0xc8, 0x00, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12}},
            };
            static uint8_t smp[6000];
            for (auto &f : fr) {
                uint8_t z[6] = {0}, rr[6], rx[9];
                hal.frame(z, rr, 6);                      // empty the result queue
                hal.frame(z, rr, 6);
                const int before = hal.busy() | hal.ready() << 1;
                const uint32_t irq = save_and_disable_interrupts();
                hal.trace_n = 0; hal.trace_on = true;
                hal.frame(f.tx, rx, 9);
                hal.trace_on = false;
                const uint32_t t0 = time_us_32();
                for (int k = 0; k < 6000; ++k) smp[k] = uint8_t((sio_hw->gpio_in >> XC_PIN_BUSY & 1) | (sio_hw->gpio_in >> XC_PIN_READY & 1) << 1);
                const uint32_t dt = time_us_32() - t0;
                restore_interrupts(irq);
                std::printf("%-10s during the frame (byte = bytes received so far):\n   ", f.name);
                {
                    int lp = -1;
                    for (int k = 0; k < hal.trace_n; ++k)
                        if (hal.trace[k].pins != lp) { lp = hal.trace[k].pins;
                            std::printf(" byte %d: BUSY %d READY %d;", hal.trace[k].rx, lp & 1, lp >> 1); }
                    std::printf("\n");
                }
                const double ns = dt * 1000.0 / 6000;
                std::printf("%-10s before the frame: BUSY %d READY %d; after CS rise (%.0f ns per sample, %lu us):\n   ",
                            f.name, before & 1, before >> 1, ns, (unsigned long)dt);
                int last = -1, shown = 0;
                for (int k = 0; k < 6000 && shown < 12; ++k)
                    if (smp[k] != last) { std::printf(" t=%.2fus BUSY %d READY %d;", k * ns / 1000, smp[k] & 1, smp[k] >> 1); last = smp[k]; ++shown; }
                std::printf("\n");
                while (!hal.ready()) tight_loop_contents();
                hal.frame(z, rr, 6);
            }
        }
        else if (!std::strcmp(cmd, "pinwatch")) {
            // start a long self-test (N = 65535, about 0.1 s at 25 MHz), then sample the
            // BUSY and DATA_READY pins for 300 ms: shows what reaches the Pico's pins
            hal.set_proto(1);
            uint8_t tx[9] = {0x94, 0xff, 0xff, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12}, rx[9];
            hal.frame(tx, rx, 9);
            const uint32_t t0 = time_us_32();
            uint32_t n = 0, bhi = 0, rhi = 0, b_first = 0, b_last = 0, r_first = 0, b_changes = 0;
            int lb = -1;
            for (uint32_t t = 0; (t = time_us_32() - t0) < 300000;) {
                const int b = hal.busy(), r = hal.ready();
                ++n;
                if (b) { ++bhi; if (!b_first) b_first = t + 1; b_last = t; }
                if (r) { ++rhi; if (!r_first) r_first = t + 1; }
                if (b != lb) { if (lb >= 0) ++b_changes; lb = b; }
            }
            std::printf("pinwatch: %lu samples over 300 ms after a 65535-instruction self-test\n", (unsigned long)n);
            std::printf("  BUSY (GP%d):       high in %lu samples, %lu changes", XC_PIN_BUSY, (unsigned long)bhi, (unsigned long)b_changes);
            if (bhi) std::printf(", high from %lu us to %lu us", (unsigned long)(b_first - 1), (unsigned long)b_last);
            std::printf("\n  DATA_READY (GP%d): high in %lu samples", XC_PIN_READY, (unsigned long)rhi);
            if (rhi) std::printf(", first high at %lu us", (unsigned long)(r_first - 1));
            std::printf("\n  expected: BUSY high for about 100 ms from 0 us, then DATA_READY high\n");
            uint8_t z[6] = {0}, rr[6];
            hal.frame(z, rr, 6);                      // take the result off the queue
            std::printf("  result: STATUS %02x, RD %02x%02x%02x%02x (model 5a2e5c6f)\n", rr[0], rr[4], rr[3], rr[2], rr[1]);
        }
        else if (!std::strcmp(cmd, "raw") && a1) {
            uint8_t tx[22], rx[22]; int n = 0;
            for (int i = 1; i < argc && n < 22; ++i) tx[n++] = uint8_t(std::strtoul(argv[i], nullptr, 16));
            hal.frame(tx, rx, n);
            std::printf("MISO:");
            for (int i = 0; i < n; ++i) std::printf(" %02x", rx[i]);
            std::printf("\n");
        }
        else if (!std::strcmp(cmd, "exec") && a2) {
            if (need_guard(c)) {
                unsigned op = unsigned(std::strtoul(a1, nullptr, 0));
                uint32_t rs1 = uint32_t(std::strtoul(a2, nullptr, 16)), rs2 = a3 ? uint32_t(std::strtoul(a3, nullptr, 16)) : 0;
                uint32_t rd = 0; xc::Status st;
                hal.set_proto(1);
                bool ok = dut.exec(op, rs1, rs2, &rd, &st);
                uint32_t want = dut.gold.exec(op, rs1, xc::uses_rs2(op) ? rs2 : 0);
                std::printf("%s rs1 %08lx rs2 %08lx -> rd %08lx STATUS %02x%s; model %08lx %s\n", xc::op_name(op),
                            (unsigned long)rs1, (unsigned long)rs2, (unsigned long)rd, st.raw, ok ? "" : " (timeout)",
                            (unsigned long)want, rd == want ? "match" : "MISMATCH");
            }
        }
        else std::printf("? (help lists the commands)\n");

        if (relink) {
            if (suites::apply_link(c, nl)) c.cfg = nl;
            else suites::apply_link(c, c.cfg, true);
        }
    }
}
