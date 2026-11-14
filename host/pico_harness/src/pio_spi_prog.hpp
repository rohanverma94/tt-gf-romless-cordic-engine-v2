// pio_spi_prog.hpp — builds the PIO program of the harness's SPI master.
//
// The program is generated at run time for each (SCLK high, SCLK low, MISO
// sample delay, CPHA) setting, so MISO can be sampled on any PIO cycle after
// the edge, including one or two bits later. That is what a fast read
// through the Tiny Tapeout I/O needs: MISO arrives ~20-25 ns after the edge
// that launched it (docs/info.md, "SPI timing"), more than a bit at 50 MHz+.
// It is the "read delay" of a QSPI flash controller.
//
// Portable (no pico-sdk): the firmware loads the words into a PIO state machine,
// the simulator (sim/) executes them cycle by cycle against the RTL.
//
// State machine setup the program assumes:
//   side-set: 1 bit, not optional  -> SCLK         (idle low, CPOL = 0)
//   out pins: 1                    -> MOSI
//   in  pins: base                 -> MISO          (input sync bypassed)
//   OSR: shift left, no autopull, the CPU writes byte << 24
//   ISR: shift left, autopush at 8, the CPU reads the low byte
//   wrap: whole program (wrap_target = 0, wrap = len - 1)
// The CPU frames bytes with CS (a GPIO). Between bytes the SM is stalled on
// `pull` at address 0; a byte is complete when the SM is back there.
//
// A byte is 8 bit slots of P = H + L PIO cycles. Slot j starts on the edge
// where the slave samples MOSI bit j (CPHA 0: rising, CPHA 1: falling):
//   CPHA 0: high [0, H), falling edge + MOSI bit j+1 at H.
//   CPHA 1: low [0, L), rising edge + MOSI bit j+1 at L (not in slot 7);
//           the rise for bit 0 comes before slot 0.
// MISO bit b is sampled D PIO cycles after the start of slot b. With
// D = k*P + r, that is cycle r of slot b + k; for k > 0 the byte gets k
// extra "virtual" slots with SCLK idle, so each byte is self-contained.
#pragma once
#include <cstdint>

namespace pio_spi {

// --- instruction encoding (RP2040 datasheet 3.4) -------------------------
// delay/side-set field: 1 side-set bit (bit 12) + 4 delay bits
inline uint16_t ds(int side, int delay) { return uint16_t(((side & 1) << 12) | ((delay & 15) << 8)); }
inline uint16_t i_jmp_xdec(int addr) { return uint16_t(0x0000 | (2 << 5) | (addr & 31)); }
inline uint16_t i_in_pins1()   { return 0x4001; }               // in pins, 1
inline uint16_t i_out_pins1()  { return 0x6001; }               // out pins, 1
inline uint16_t i_pull_block() { return 0x80a0; }               // pull block
inline uint16_t i_nop()        { return 0xa042; }               // mov y, y
inline uint16_t i_set_x(int v) { return uint16_t(0xe020 | (v & 31)); }

enum Kind : uint8_t { NOP, IN, OUT, JMPX };

struct Program {
    uint16_t insn[32];
    int len = 0;
    int loop = 0;           // loop start address
    bool ok = false;
    const char *err = "";
};

struct Params {
    int high;      // SCLK high time, PIO cycles
    int low;       // SCLK low time, PIO cycles
    int sample;    // D: MISO sample delay after the slave's sample edge, PIO cycles
    int cpha;      // 0 or 1
    int setup;     // extra low cycles before the first edge of every byte (>= 0)
};

class Builder {
public:
    explicit Builder(Program &p) : p_(p) { p_.ok = true; }
    struct Ev { int at; Kind k; };

    // A run of `cycles` PIO cycles with SCLK high for cycles in [hi_from, hi_to).
    // An instruction starts at every event and at every level change.
    bool slot(const Ev *ev, int n, int cycles, int hi_from, int hi_to, int jmp_target = 0) {
        Ev all[8]; int m = 0;
        for (int i = 0; i < n; ++i) all[m++] = ev[i];
        auto has = [&](int c) { for (int i = 0; i < m; ++i) if (all[i].at == c) return true; return false; };
        if (!has(0)) all[m++] = {0, NOP};
        if (hi_from > 0 && hi_from < cycles && !has(hi_from)) all[m++] = {hi_from, NOP};
        if (hi_to > 0 && hi_to < cycles && !has(hi_to)) all[m++] = {hi_to, NOP};
        for (int i = 1; i < m; ++i)
            for (int j = i; j > 0 && all[j].at < all[j - 1].at; --j) { Ev t = all[j]; all[j] = all[j - 1]; all[j - 1] = t; }
        for (int i = 0; i < m; ++i) {
            const int start = all[i].at, end = (i + 1 < m) ? all[i + 1].at : cycles;
            if (end <= start || start < 0) return fail("events collide");
            const int side = (start >= hi_from && start < hi_to) ? 1 : 0;
            uint16_t op = all[i].k == IN ? i_in_pins1() : all[i].k == OUT ? i_out_pins1()
                        : all[i].k == JMPX ? i_jmp_xdec(jmp_target) : i_nop();
            if (all[i].k == JMPX && end - start != 1) return fail("jmp must be the last cycle");
            if (!emit_run(op, side, end - start)) return false;
        }
        return true;
    }
    // one instruction lasting `len` cycles (padded with nops past 16)
    bool emit_run(uint16_t op, int side, int len) {
        int first = len > 16 ? 16 : len;
        if (!emit(uint16_t(op | ds(side, first - 1)))) return false;
        for (len -= first; len > 0;) {
            int l = len > 16 ? 16 : len;
            if (!emit(uint16_t(i_nop() | ds(side, l - 1)))) return false;
            len -= l;
        }
        return true;
    }
    bool emit(uint16_t w) {
        if (p_.len >= 32) return fail("program longer than 32 instructions (lower SCLK or the sample delay)");
        p_.insn[p_.len++] = w;
        return true;
    }
    bool fail(const char *e) { p_.ok = false; p_.err = e; return false; }
    int here() const { return p_.len; }
private:
    Program &p_;
};

// cycle of a slot at which MOSI changes (the slave's launch edge)
inline int out_at(const Params &q) { return q.cpha ? q.low : q.high; }

// D is usable if it is at most 2 bits late and its in-slot cycle r is
// neither the MOSI change nor the loop's jmp (P - 1)
inline bool sample_ok(const Params &q) {
    const int P = q.high + q.low;
    if (P < 1 || q.sample < 0) return false;
    const int r = q.sample % P;
    return q.sample / P <= 2 && r != out_at(q) && r != P - 1;
}

inline Program build(const Params &q) {
    Program p;
    Builder b(p);
    const int H = q.high, L = q.low, P = H + L, D = q.sample;
    if (H < 1 || L < 1 || P < 3) { b.fail("SCLK phases too short"); return p; }
    if (q.cpha == 0 && L < 2) { b.fail("CPHA 0 needs a low phase of >= 2 PIO cycles"); return p; }
    if (q.cpha == 1 && H < 2) { b.fail("CPHA 1 needs a high phase of >= 2 PIO cycles"); return p; }
    if (!sample_ok(q)) { b.fail("sample delay not placeable (> 2 bits, or on the MOSI change / loop jump)"); return p; }
    const int k = D / P, r = D % P;
    const int oa = out_at(q);
    const int hf = q.cpha ? L : 0, ht = q.cpha ? P : H;      // SCLK high interval of a slot
    Builder::Ev ev[3];

    // prologue: wait for a byte with SCLK low; loop counter; MOSI bit 7
    const int loops = q.cpha ? 7 - k : 8 - k;               // looped slots k .. 6 (CPHA 1) / 7
    b.emit(uint16_t(i_pull_block() | ds(0, 0)));
    if (q.cpha == 0) {
        b.emit(uint16_t(i_set_x(loops - 1) | ds(0, 0)));
        b.emit_run(i_out_pins1(), 0, L + q.setup);          // MOSI bit 7 during a low phase
    } else {
        b.emit_run(i_set_x(loops - 1), 0, 1 + q.setup);
        b.emit_run(i_out_pins1(), 1, H);                     // rise + MOSI bit 7
    }
    if (!p.ok) return p;
    // slots 0 .. k-1: nothing to sample yet
    for (int j = 0; j < k; ++j) {
        ev[0] = {oa, OUT};
        if (!b.slot(ev, 1, P, hf, ht)) return p;
    }
    // looped slots: sample bit j - k at r, MOSI change at oa, jmp at P - 1
    p.loop = b.here();
    ev[0] = {r, IN}; ev[1] = {oa, OUT}; ev[2] = {P - 1, JMPX};
    if (!b.slot(ev, 3, P, hf, ht, p.loop)) return p;
    // CPHA 1: slot 7 has no rising edge
    if (q.cpha == 1) {
        ev[0] = {r, IN};
        int len = k ? P : (r + 1 > L ? r + 1 : L);
        if (!b.slot(ev, 1, len, len, len)) return p;
    }
    // virtual slots: SCLK idle, sample the last k bits
    for (int m = 0; m < k; ++m) {
        ev[0] = {r, IN};
        int len = (m + 1 < k) ? P : r + 1;
        if (!b.slot(ev, 1, len, len, len)) return p;
    }
    return p;
}

// PIO clock divider and bit timing for a requested SCLK and sample delay.
// The divider is an integer, chosen so a bit lasts at most max_period PIO
// cycles (program size); everything is then rounded to whole PIO cycles.
struct Timing {
    bool ok = false;
    const char *err = "";
    int div = 1;
    Params p{};
    double tick_ns = 0, sclk_hz = 0, sample_ns = 0;
};

// Where MISO bit b is valid at the master, relative to the slave's sample
// edge of bit b (ns). io_ns: Pico pads + Tiny Tapeout I/O, out and back.
//  * oversampled slave (default build): it shifts MISO on its sample edge,
//    after its synchronizer (2-3 core clocks), so bit b is valid from about
//    (sample edge of bit b-1) + delay to (sample edge of bit b) + delay.
//  * SCLK-domain slave (SPI_SCLK = 1): it shifts MISO on the other edge, one
//    SCLK phase before the sample edge, plus a few ns.
struct Window { double lo, hi; };
inline Window miso_window(bool sclk_build, double fclk_hz, double bit_ns, double before_ns, double io_ns = 22.0) {
    if (sclk_build) { double dl = io_ns + 3.0; return {dl - before_ns, dl - before_ns + bit_ns}; }
    double dl = io_ns + 2.5e9 / fclk_hz;
    return {dl - bit_ns, dl};
}

inline Timing timing(double f_sys, double sclk_hz, int sample_ns, int cpha, double fclk_hz,
                     int setup_cycles = 0, int max_period = 24) {
    Timing t;
    if (sclk_hz <= 0) { t.err = "bad SCLK"; return t; }
    int div = int((f_sys / sclk_hz + max_period - 1) / max_period);
    if (div < 1) div = 1;
    if (div > 65535) { t.err = "SCLK too slow for the PIO divider"; return t; }
    const double f_pio = f_sys / div;
    const int P = int(f_pio / sclk_hz + 0.999);           // SCLK <= requested
    if (P < 3) { t.err = "SCLK too fast: a bit needs >= 3 PIO cycles (raise the system clock)"; return t; }
    const int a = P / 2, b = P - a;                 // a <= b; the longer phase holds the MOSI change + jmp
    t.p.high = cpha ? b : a;
    t.p.low = cpha ? a : b;
    t.p.cpha = cpha;
    t.p.setup = setup_cycles;
    t.tick_ns = 1e9 / f_pio;
    double dns;
    if (sample_ns >= 0) dns = sample_ns;
    else {
        const double bit = P * t.tick_ns, before = (cpha ? t.p.high : t.p.low) * t.tick_ns;
        Window o = miso_window(false, fclk_hz, bit, before), s = miso_window(true, fclk_hz, bit, before);
        double lo = o.lo > s.lo ? o.lo : s.lo, hi = o.hi < s.hi ? o.hi : s.hi;
        // the middle of what both builds share; if they share too little (the
        // oversampled slave is out of its SCLK range), the SCLK-domain build's
        if (hi - lo >= 2 * t.tick_ns) dns = (lo + hi) / 2;
        else dns = (s.lo + s.hi) / 2;
        if (dns < 0) dns = 0;
    }
    const int d = int(dns / t.tick_ns + 0.5);
    // step off the MOSI change / loop jump cycles: one tick later, else earlier
    t.p.sample = d;
    if (!sample_ok(t.p)) { t.p.sample = d + 1; if (!sample_ok(t.p)) t.p.sample = d - 1; }
    if (!sample_ok(t.p)) { t.err = "sample delay too long (more than 2 bits) at this SCLK"; return t; }
    t.div = div;
    t.sclk_hz = f_pio / P;
    t.sample_ns = t.p.sample * t.tick_ns;
    t.ok = true;
    return t;
}

}  // namespace pio_spi
