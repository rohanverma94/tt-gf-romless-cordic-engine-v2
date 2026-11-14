// xc_dut.hpp — the tt_um_xcordic protocols on top of a Hal, plus the golden
// model of whichever datapath (GUARD 0 or 4) the chip turns out to have.
#pragma once
#include <cstdint>
#include <cstdio>
#include "hal.hpp"
#include "../xc_model.hpp"

namespace xc {

// ops that read RS2 (9-byte EXEC frame); the others need only CMD + RS1
inline bool uses_rs2(unsigned op) {
    return op == ROT || op == MAC || op == CFG || op == ATAN2 || op == HYPOT ||
           op == MUL || op == DIV || op == ROTC || op == BIST;
}

struct Status {
    uint8_t raw = 0;
    int seq() const { return raw >> 4; }
    bool err() const { return raw & 4; }
    bool valid() const { return raw & 2; }
    bool busy() const { return raw & 1; }
    bool full() const { return raw & 8; }       // instruction queue full
};

// Model<0> or Model<4>, chosen at run time
struct Gold {
    int guard = 4;
    Model<0> m0;
    Model<4> m4;
    uint32_t exec(unsigned op, uint32_t a, uint32_t b) { return guard ? m4.exec(op, a, b) : m0.exec(op, a, b); }
    unsigned flags() const { return guard ? m4.flags() : m0.flags(); }     // of the last exec
    void reset() { m0.reset(); m4.reset(); }
    uint32_t rst(unsigned s) const { return guard ? Model<4>::RST[s] : Model<0>::RST[s]; }
    uint32_t wmask() const { return guard ? 0xfffffu : 0xffffu; }
};

class Dut {
public:
    explicit Dut(Hal &h) : h(h) {}
    Hal &h;
    Gold gold;
    bool guard_known = false;
    int timeout_log2 = 28;
    uint32_t fclk_hz = 50000000;
    uint32_t ready_timeout_us = 2000;
    // counters for the suites
    uint32_t timeouts = 0;
    // FLAGS byte (byte 5: bit 0 SAT, bit 1 INV) of the result in the last
    // frame of >= 6 bytes, the same result as its RD
    uint8_t last_flags = 0;

    // ---------------- command protocol (PROTO = 1) ----------------
    // read-only frame: 00 + 5 bytes -> STATUS, RD, FLAGS (snapshot at CS fall)
    Status read(uint32_t *rd, int nbytes = 6, uint8_t *raw = nullptr) {
        uint8_t tx[32] = {0}, rx[32] = {0};
        if (nbytes > 32) nbytes = 32;
        h.frame(tx, rx, nbytes);
        if (raw) for (int i = 0; i < nbytes; ++i) raw[i] = rx[i];
        Status s; s.raw = rx[0];
        if (nbytes >= 6) last_flags = rx[5];
        if (rd) *rd = rx[1] | rx[2] << 8 | rx[3] << 16 | uint32_t(rx[4]) << 24;
        return s;
    }
    // EXEC frame; returns the STATUS/RD snapshot taken at its CS fall (and FLAGS in last_flags)
    // (the previous instruction's result). nbytes overrides the frame length.
    Status exec_frame(unsigned op, uint32_t rs1, uint32_t rs2, uint32_t *prev_rd = nullptr, int nbytes = 0) {
        uint8_t tx[9], rx[9] = {0};
        tx[0] = uint8_t(0x80 | op);
        for (int i = 0; i < 4; ++i) { tx[1 + i] = uint8_t(rs1 >> (8 * i)); tx[5 + i] = uint8_t(rs2 >> (8 * i)); }
        // one-operand ops take 6 bytes (RS2[7:0] = 0), so FLAGS comes back too
        if (!nbytes && !uses_rs2(op & 0x7f)) for (int i = 5; i < 9; ++i) tx[i] = 0;
        int n = nbytes ? nbytes : (uses_rs2(op & 0x7f) ? 9 : 6);
        h.frame(tx, rx, n);
        Status s; s.raw = rx[0];
        if (n >= 6) last_flags = rx[5];
        if (prev_rd) *prev_rd = rx[1] | rx[2] << 8 | rx[3] << 16 | uint32_t(rx[4]) << 24;
        return s;
    }
    bool wait_ready(uint32_t timeout_us = 0) {
        if (!timeout_us) timeout_us = ready_timeout_us;
        uint64_t t0 = h.now_us();
        while (!h.ready()) {
            if (h.now_us() - t0 > timeout_us) { ++timeouts; return false; }
            h.wait_ns(40);
        }
        return true;
    }
    // EXEC, wait for DATA_READY, read. false on timeout.
    bool exec(unsigned op, uint32_t rs1, uint32_t rs2, uint32_t *rd, Status *st = nullptr) {
        exec_frame(op, rs1, rs2);
        if (!wait_ready()) return false;
        Status s = read(rd);
        if (st) *st = s;
        return true;
    }
    // pipelined: wait until the previous instruction is done, send the next
    // EXEC; returns the previous result (snapshot) in *prev_rd
    bool exec_pipe(unsigned op, uint32_t rs1, uint32_t rs2, uint32_t *prev_rd, Status *st) {
        if (!wait_ready()) return false;
        *st = exec_frame(op, rs1, rs2, prev_rd);
        return true;
    }
    // cfg helpers (op 7); returns the old value
    uint32_t cfg_read(unsigned sel) { uint32_t rd = 0; exec(CFG, 0, 8 | sel, &rd); return rd; }
    uint32_t cfg_write(unsigned sel, uint32_t v) { uint32_t rd = 0; exec(CFG, v, sel, &rd); gold.exec(CFG, v, sel); return rd; }
    // put every cfg register (chip and model) back to its reset value
    void sync_cfg() {
        for (unsigned s = 0; s < 5; ++s) { uint32_t rd; exec(CFG, gold.rst(s), s, &rd); }
        gold.reset();
    }
    // GUARD from the reset value of atan0 (cfg read-only). Writes atan0 back
    // to whichever reset value matches, so it also recovers after legacy frames.
    int identify(uint32_t *atan0 = nullptr) {
        h.set_proto(1);
        uint32_t v = cfg_read(0);
        if (atan0) *atan0 = v;
        if (v == Model<4>::RST[0]) { gold.guard = 4; guard_known = true; }
        else if (v == Model<0>::RST[0]) { gold.guard = 0; guard_known = true; }
        else {
            // legacy frames rewrite atan0: tell by the width of another register
            uint32_t kh = cfg_read(4);
            if (kh == Model<4>::RST[4]) { gold.guard = 4; guard_known = true; }
            else if (kh == Model<0>::RST[4]) { gold.guard = 0; guard_known = true; }
            else return -1;
        }
        return gold.guard;
    }

    // ---------------- legacy protocol (PROTO = 0) ----------------
    // write {x, y, alpha, atan0}, wait DATA_READY, read 6 bytes {sin, cos, 0}
    // byte_per_cs: one CS frame per byte (the ttsky25a harness) or one frame of 8 + one of 6
    bool legacy(uint16_t x, uint16_t y, uint16_t alpha, uint16_t atan0,
                uint16_t *sn, uint16_t *cs, uint16_t *third, bool byte_per_cs) {
        uint8_t tx[8] = {uint8_t(x), uint8_t(x >> 8), uint8_t(y), uint8_t(y >> 8),
                         uint8_t(alpha), uint8_t(alpha >> 8), uint8_t(atan0), uint8_t(atan0 >> 8)};
        uint8_t rx[8] = {0}, z[8] = {0};
        if (byte_per_cs) for (int i = 0; i < 8; ++i) h.frame(&tx[i], &rx[i], 1);
        else h.frame(tx, rx, 8);
        bool ok = wait_ready();
        if (byte_per_cs) for (int i = 0; i < 6; ++i) h.frame(&z[i], &rx[i], 1);
        else h.frame(z, rx, 6);
        *sn = uint16_t(rx[0] | rx[1] << 8);
        *cs = uint16_t(rx[2] | rx[3] << 8);
        *third = uint16_t(rx[4] | rx[5] << 8);
        // the model: cfg(atan0 << GUARD), then rot({y, x}, alpha)
        gold.exec(CFG, uint32_t(int32_t(int16_t(atan0)) * (1 << gold.guard)) & gold.wmask(), 0);
        return ok;
    }
    uint32_t legacy_model(uint16_t x, uint16_t y, uint16_t alpha) {
        return gold.exec(ROT, uint32_t(y) << 16 | x, alpha);
    }
};

}  // namespace xc
