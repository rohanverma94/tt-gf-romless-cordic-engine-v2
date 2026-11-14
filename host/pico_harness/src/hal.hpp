// hal.hpp — what the test suites need from the board: SPI frames, the
// PROTO/CPHA pins, the DATA_READY/BUSY pins and time. Implemented by the
// Pico firmware (pico_hal.cpp) and by the RTL simulator (sim/sim_main.cpp),
// so the same suites run against silicon and against the Verilog.
#pragma once
#include <cstdint>

#ifndef XC_FCLK_HZ
#define XC_FCLK_HZ 25000000   // the project clock this build expects (GF26c: 25 MHz)
#endif

enum class Backend : uint8_t { PIO = 0, HWSPI = 1 };

struct LinkCfg {
    uint32_t fclk_hz   = XC_FCLK_HZ; // the chip's core clock (set by the demo board)
    uint32_t sclk_hz   = 10000000;  // requested SCLK
    int      cpha      = 0;         // SPI mode 0 / 1 (also drives ui[4])
    int      sample_ns = -1;        // PIO MISO sample delay after the slave's sample edge; -1 = auto
    Backend  backend   = Backend::PIO;
    // CS timing in core clocks of the chip (converted with fclk_hz); the
    // defaults hold for both slave builds with margin (docs/info.md)
    uint32_t cs_setup_clk = 4;      // CS low -> first SCLK edge   (needs >= 3)
    uint32_t cs_hold_clk  = 3;      // last SCLK edge -> CS high   (needs >= 2)
    uint32_t cs_gap_clk   = 6;      // CS high between frames      (needs >= 5)
};

// What a configure() achieved (integer PIO / SPI dividers)
struct LinkActual {
    double sclk_hz = 0;
    double sample_ns = 0;           // PIO only
    double pio_tick_ns = 0;         // resolution of high/low/sample
    int high = 0, low = 0, sample = 0;
    char note[96] = {0};
};

class Hal {
public:
    virtual ~Hal() = default;
    // false (with act.note) if the timing cannot be generated
    virtual bool configure(const LinkCfg &c, LinkActual &act) = 0;
    // one CS frame: CS low, n bytes full duplex MSB first, CS high, inter-frame gap
    virtual void frame(const uint8_t *tx, uint8_t *rx, int n) = 0;
    virtual void set_proto(int v) = 0;      // ui[3]: 0 legacy, 1 command frames
    virtual int  ready() = 0;               // uo[1] DATA_READY
    virtual int  busy() = 0;                // uo[2] BUSY
    virtual void wait_ns(uint32_t ns) = 0;
    virtual uint64_t now_us() = 0;
    virtual const char *name() = 0;         // "pico" / "sim"
    // a stretch that must not be interrupted (pin checks right after a frame);
    // the simulator has no interrupts, so these default to nothing
    virtual uint32_t quiet_begin() { return 0; }
    virtual void quiet_end(uint32_t) {}
};
