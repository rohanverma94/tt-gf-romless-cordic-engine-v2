// xc_model.hpp — bit-exact C++ model of the Xcordic core (tt_um_xcordic).
//
// A direct port of formal/spec/xcordic_spec.vh, the specification the RTL is
// proved against (F2: engine recurrence, F3: every instruction). So for every
// instruction, operand and cfg state, Model<G>::exec() returns exactly the rd
// the chip returns. host/pico_harness/check/model_check.cpp checks this
// port against the RTL itself (Verilator), exhaustively for one-operand
// instructions and on random operands for the rest.
//
// Header-only C++17, no allocation, 64-bit integer arithmetic: runs on the
// RP2040 (Cortex-M0+), the RP2350 (Cortex-M33) and a PC.
//
//   xc::Model<4> m;                    // GUARD = 4 build (the default)
//   uint32_t rd = m.exec(xc::SIN, 0x0800, 0);
//
// cfg (op 7) changes the model's state exactly as it changes the chip's.
//
// mul, div and sqrt are exact (rounded half up, saturated; the chip's
// xc_exact.v unit), and every exec() also sets flags() = {INV, SAT} as the
// chip returns them in the FLAGS byte: bit 0 SAT (a result was clipped to
// [-8, 8)), bit 1 INV (div by 0, ln of a <= 0, sqrt of a < 0).
#pragma once
#include <cstdint>

namespace xc {

enum Op : unsigned {
    ROT = 0, SINCOS, VEC, MAC, LDIV, HSINCOS, HVEC, CFG,
    SIN, COS, TAN, ATAN2, HYPOT, EXP, LN, SQRT,
    MUL, DIV, TANH, ROTC,
    BIST                           // self-test (xc_bist.v), not a core instruction
};
constexpr unsigned kNumOps = 20;   // core instructions 0..19 (BIST = 20 is extra)
inline const char *op_name(unsigned op) {
    static const char *n[kNumOps] = {"rot", "sincos", "vec", "mac", "ldiv", "hsincos", "hvec", "cfg",
                                     "sin", "cos", "tan", "atan2", "hypot", "exp", "ln", "sqrt",
                                     "mul", "div", "tanh", "rotc"};
    return op < kNumOps ? n[op] : op == BIST ? "bist" : "?";
}

template <int G>
class Model {
    static_assert(G >= 0 && G <= 4, "GUARD 0..4");
public:
    static constexpr int W = 16 + G;
    static constexpr int F = 12 + G;
    static constexpr int64_t ONE = int64_t(1) << F;
    static constexpr int NPE = 13 + (G + 1) / 2;
    static constexpr int NLIN = (G == 0) ? NPE : F + 1;
    static constexpr int REP13 = (NPE >= 14) ? 1 : 0;

    static constexpr int64_t pick(int64_t g0, int64_t g1, int64_t g2, int64_t g3, int64_t g4) {
        return G == 0 ? g0 : G == 1 ? g1 : G == 2 ? g2 : G == 3 ? g3 : g4;
    }
    // constants (as in src/xcordic_core.v), by GUARD
    static constexpr int64_t HALF_PI       = pick(6434, 12868, 25736, 51472, 102944);
    static constexpr int64_t PI            = pick(12868, 25736, 51472, 102944, 205887);
    static constexpr int64_t THREE_HALF_PI = pick(19302, 38604, 77208, 154416, 308831);
    static constexpr int64_t TWO_PI        = pick(25736, 51472, 102944, 205887, 411775);
    static constexpr int64_t INV_K         = pick(2487, 4975, 9949, 19898, 39797);
    static constexpr int64_t INV_2KH       = pick(2473, 4946, 9892, 19784, 39567);
    static constexpr int64_t LN2_Q         = pick(45426, 90852, 181704, 363409, 726817);
    // cfg reset values: atan0, atan1, kc, atanh1, kh
    static constexpr uint32_t RST[5] = {
        uint32_t(pick(3217, 6434, 12868, 25736, 51472)),
        uint32_t(pick(1899, 3798, 7596, 15193, 30386)),
        uint32_t(pick(2487, 4975, 9949, 19898, 39797)),
        uint32_t(pick(2250, 4500, 9000, 18000, 35999)),
        uint32_t(pick(4946, 9892, 19784, 39567, 79135))};

    uint32_t cfg[5];               // atan0, atan1, kc, atanh1, kh (W bits each)
    bool funcs = true;             // FUNCS = 1 build (the default): BIST cycles ops 0-6, 8-19

    Model() { reset(); }
    void reset() { for (int i = 0; i < 5; ++i) cfg[i] = RST[i]; }

    // one instruction; op = funct7 * 8 + funct3 (0..19, 20 = bist)
    uint32_t exec(unsigned op, uint32_t rs1, uint32_t rs2);
    // flags of the last exec(): bit 0 SAT, bit 1 INV
    unsigned flags() const { return fl; }

    // cordic.bist (src/xc_bist.v): N = rs1[15:0] instructions, LFSR seed rs2
    // (0 -> 1); returns the 32-bit MISR signature
    static uint32_t lstep(uint32_t v) { return (v >> 1) ^ ((v & 1u) ? 0x80200003u : 0u); }
    uint32_t bist(uint32_t rs1, uint32_t rs2) {
        const unsigned n = rs1 & 0xffffu, last = funcs ? 19 : 6;
        uint32_t lfsr = rs2 ? rs2 : 1u, misr = 0xffffffffu;
        unsigned op = 0;
        for (unsigned k = 0; k < n; ++k) {
            const uint32_t a = lstep(lfsr), b = lstep(a);
            lfsr = b;
            const uint32_t r = exec(op, a, b);
            misr = lstep(misr) ^ r ^ (uint32_t(fl) << 30);          // flags in bits 31:30
            op = (op == 6) ? (funcs ? 8 : 0) : (op == last) ? 0 : op + 1;
        }
        fl = 0;
        return misr;
    }

    // ---------------------------------------------------------------------
    // building blocks (public for tests)
    // ---------------------------------------------------------------------
    static int64_t wrap(int64_t v) {              // to a W-bit two's complement value
        const uint64_t m = (uint64_t(1) << W) - 1;
        uint64_t u = uint64_t(v) & m;
        return (u >> (W - 1)) ? int64_t(u | ~m) : int64_t(u);
    }
    static int64_t s16(uint32_t v) { return int16_t(uint16_t(v)); }
    static int64_t up(uint32_t v16) { return s16(v16) * (int64_t(1) << G); }
    static int64_t iabs(int64_t v) { return v < 0 ? -v : v; }
    static int64_t imax(int64_t a, int64_t b) { return a > b ? a : b; }
    static int64_t asr(int64_t v, int s) { return v >> s; }         // arithmetic on all targets used
    static int64_t floordiv(int64_t n, int64_t d) {                // d != 0
        if (d < 0) { n = -n; d = -d; }
        const int64_t q = n / d;
        return (n % d != 0 && n < 0) ? q - 1 : q;
    }
    mutable unsigned fl = 0;                      // flags of the instruction being executed
    uint32_t sat16(int64_t v) const {             // sets SAT when it clips
        if (v > 32767 || v < -32768) fl |= 1u;
        return v > 32767 ? 0x7fffu : v < -32768 ? 0x8000u : uint32_t(uint16_t(int16_t(v)));
    }
    static int64_t satw(int64_t v) {
        const int64_t hi = (int64_t(1) << (W - 1)) - 1;
        return v > hi ? hi : v < -hi - 1 ? -hi - 1 : v;
    }
    static uint32_t sext(uint32_t v16) { return uint32_t(int32_t(int16_t(uint16_t(v16)))); }
    static int log2i(int64_t m) { int r = 0; for (int i = 0; i < 24; ++i) if (m >= (int64_t(1) << i)) r = i; return r; }
    static int norm(int64_t m) { return m == 0 ? 0 : F - log2i(m); }
    static int64_t shl(int64_t v, int s) { return s >= 0 ? v * (int64_t(1) << s) : asr(v, -s); }
    static int64_t round(int64_t v, int k) {
        return k >= 0 ? v * (int64_t(1) << k) : asr(v + (int64_t(1) << (-k - 1)), -k);
    }
    uint32_t scale(int64_t v, int k) const { return sat16(round(v, k - G)); }
    uint32_t rnd(int64_t v) const { return scale(v, 0); }
    static int64_t scale_m(int64_t v, int k) { return satw(round(v, k)); }
    static int64_t kln2(int64_t k) { return asr(k * LN2_Q + 8, 4); }
    static int expk(int64_t t) { return int(asr(t + asr(t, 1) - asr(t, 4) + 2048, 12)); }

    static int64_t angle_tab(bool hyp, int s);
    static int niter(int mode) { return mode == 2 ? NPE + 1 + REP13 : mode == 1 ? NLIN : NPE; }
    static int shift(int mode, int k) {
        if (mode != 2) return k;
        if (k <= 3) return k + 1;
        if (REP13 && k >= 14) return k - 1;
        return k;
    }

    struct V3 { int64_t x, y, z; };

    // one engine pass (mode 0 circ, 1 lin, 2 hyp; dir 0 rot, 1 vec, 2 div)
    V3 pass(int mode, int dir, int64_t x, int64_t y, int64_t z) const {
        x = wrap(x); y = wrap(y); z = wrap(z);
        for (int k = 0; k < niter(mode); ++k) {
            const int s = shift(mode, k);
            int64_t a;
            if (mode == 1)      a = ONE >> s;
            else if (mode == 2) a = (s == 1) ? int64_t(cfg[3]) : angle_tab(true, s);
            else if (s == 0)    a = cfg[0];
            else                a = (s == 1) ? int64_t(cfg[1]) : angle_tab(false, s);
            a = wrap(a);                                    // the engine's angle input is signed
            bool pos = (dir == 1) ? (y < 0) : (dir == 2) ? ((y < 0) != (x < 0)) : (z >= 0);
            int64_t xs = asr(x, s), ys = asr(y, s);
            if (G > 0 && mode == 1 && dir == 3) {        // product pass (mac, mul)
                if (z == 0) continue;                       // product complete: hold
                if (s > 0) xs = asr(x + (int64_t(1) << (s - 1)), s);   // rounded shift
            }
            int64_t sx = pos ? xs : -xs, sy = pos ? ys : -ys, sa = pos ? a : -a;
            int64_t nx = (mode == 0) ? x - sy : (mode == 2) ? x + sy : x;
            x = wrap(nx); y = wrap(y + sx); z = wrap(z - sa);
        }
        return {x, y, z};
    }

    struct Quad { int q; int64_t th; };
    static Quad quad(uint32_t th16) {
        int64_t th = up(th16);
        if (th < 0) th += TWO_PI; else if (th >= TWO_PI) th -= TWO_PI;
        int q = th < HALF_PI ? 0 : th < PI ? 1 : th < THREE_HALF_PI ? 2 : 3;
        static const int64_t sub[4] = {0, HALF_PI, PI, THREE_HALF_PI};
        return {q, wrap(th - sub[q])};
    }
    // engine (x, y) after the reduced rotation -> (sin slot, cos slot), W-bit
    static void unquad(int q, int64_t x, int64_t y, int64_t &s, int64_t &c) {
        switch (q) {
        case 0:  c = x;        s = y;        break;
        case 1:  c = wrap(-y); s = x;        break;
        case 2:  c = wrap(-x); s = wrap(-y); break;
        default: c = y;        s = wrap(-x); break;
        }
    }
    V3 rot_pass(int64_t x, int64_t y, uint32_t th16) const {
        Quad qa = quad(th16);
        return pass(0, 0, x, y, qa.th);
    }
    V3 vec_pass(int64_t x, int64_t y) const {
        x = wrap(x); y = wrap(y);
        if (x < 0) return pass(0, 1, wrap(-x), wrap(-y), y < 0 ? -PI : PI);
        return pass(0, 1, x, y, 0);
    }
    // full-range a / b
    uint32_t fdiv(int64_t a, int64_t b) const {
        if (a == 0) return 0;
        if (b == 0) { fl |= 1u; return sext(a < 0 ? 0x8000 : 0x7fff); }
        const int sa = norm(iabs(a)), sb = norm(iabs(b));
        V3 e = pass(1, 2, shl(b, sb), shl(a, sa), 0);
        return sext(scale(e.z, sb - sa));
    }
};

template <int G>
int64_t Model<G>::angle_tab(bool hyp, int s) {
    if (G == 0) {
        if (!hyp && s == 2) return 1003;
        if (!hyp && s == 3) return 510;
        if (hyp && s == 2) return 1045;
        if (hyp && s == 3) return 514;
        return 4096 >> s;
    }
    if (G == 1) {
        if (!hyp) { if (s == 2) return 2007; if (s == 3) return 1019; if (s == 4) return 511; if (s == 14) return 1; }
        else      { if (s == 2) return 2092; if (s == 3) return 1029; if (s == 4) return 513; if (s == 14) return 1; }
        return 8192 >> s;
    }
    if (G == 2) {
        if (!hyp) { if (s == 2) return 4014; if (s == 3) return 2037; if (s == 4) return 1023; }
        else      { if (s == 2) return 4184; if (s == 3) return 2059; if (s == 4) return 1025; }
        return 16384 >> s;
    }
    if (G == 3) {
        if (!hyp) { if (s == 2) return 8028; if (s == 3) return 4075; if (s == 4) return 2045; }
        else      { if (s == 2) return 8369; if (s == 3) return 4118; if (s == 4) return 2051; }
        return 32768 >> s;
    }
    if (!hyp) { if (s == 2) return 16056; if (s == 3) return 8150; if (s == 4) return 4091; if (s == 5) return 2047; }
    else      { if (s == 2) return 16738; if (s == 3) return 8235; if (s == 4) return 4101; if (s == 5) return 2049; }
    return 65536 >> s;
}

template <int G>
uint32_t Model<G>::exec(unsigned op, uint32_t rs1, uint32_t rs2) {
    const int64_t lo = s16(rs1), hi = s16(rs1 >> 16), b = s16(rs2);
    const int64_t ul = up(rs1), uh = up(rs1 >> 16), ub = up(rs2);
    const int64_t kc = cfg[2], kh = cfg[4];
    auto pack = [](uint32_t h, uint32_t l) { return (h & 0xffffu) << 16 | (l & 0xffffu); };
    int64_t sn, cs;
    fl = 0;
    switch (op) {
    case ROT: {                                         // K * rotate({y, x}, th)
        Quad qa = quad(rs2);
        V3 e = pass(0, 0, ul, uh, qa.th);
        unquad(qa.q, e.x, e.y, sn, cs);
        return pack(rnd(sn), rnd(cs));
    }
    case SINCOS: case SIN: case COS: {
        Quad qa = quad(rs1);
        V3 e = pass(0, 0, kc, 0, qa.th);
        unquad(qa.q, e.x, e.y, sn, cs);
        if (op == SIN) return sext(rnd(sn));
        if (op == COS) return sext(rnd(cs));
        return pack(rnd(sn), rnd(cs));
    }
    case VEC: {
        V3 e = vec_pass(ul, uh);
        return (lo == 0 && hi == 0) ? 0 : pack(rnd(e.z), rnd(e.x));
    }
    case MAC:  { V3 e = pass(1, 3, ul, uh, ub); return sext(rnd(e.y)); }
    case LDIV: { V3 e = pass(1, 2, ul, uh, 0);  return sext(rnd(e.z)); }
    case HSINCOS: { V3 e = pass(2, 0, kh, 0, ul); return pack(rnd(e.y), rnd(e.x)); }
    case HVEC: {
        V3 e = pass(2, 1, ul, uh, 0);
        return (lo == 0 && hi == 0) ? 0 : pack(rnd(e.z), rnd(e.x));
    }
    case CFG: {
        const unsigned sel = rs2 & 7;
        uint32_t old = sel <= 4 ? cfg[sel] : 0;
        if (!(rs2 & 8) && sel <= 4) cfg[sel] = rs1 & ((uint32_t(1) << W) - 1);
        return old;
    }
    case TAN: {
        Quad qa = quad(rs1);
        V3 e = pass(0, 0, kc, 0, qa.th);
        unquad(qa.q, e.x, e.y, sn, cs);
        return fdiv(sn, cs);
    }
    case ATAN2: {                                       // atan2(y = rs1, x = rs2)
        if (lo == 0 && b == 0) return 0;
        const int ps = norm(imax(iabs(ul), iabs(ub)));
        V3 e = vec_pass(shl(ub, ps), shl(ul, ps));
        return sext(rnd(e.z));
    }
    case HYPOT: {
        if (lo == 0 && b == 0) return 0;
        const int ps = norm(imax(iabs(ul), iabs(ub)));
        V3 e1 = vec_pass(shl(ul, ps), shl(ub, ps));
        V3 e2 = pass(1, 0, e1.x, 0, INV_K);
        return sext(scale(e2.y, -ps));
    }
    case EXP: {
        const int kk = expk(lo);
        V3 e = pass(2, 0, kh, 0, ul - kln2(kk));
        return sext(scale(e.x + e.y, kk));
    }
    case LN: {
        if (lo <= 0) { fl = 2; return sext(0x8000); }
        const int e = log2i(lo) - 12;
        const int64_t m = (e < 0) ? ul * (int64_t(1) << -e) : scale_m(ul, -e);
        V3 r = pass(2, 1, m + ONE, m - ONE, 0);
        return sext(rnd(2 * r.z + kln2(e)));
    }
    // mul, div, sqrt on the exact unit (src/xc_exact.v): the exact value
    // rounded to nearest, ties up, then saturated
    case SQRT: {
        if (lo < 0) { fl = 2; return sext(0x8000); }
        // r = floor(sqrt(4096 a) + 1/2): the r with (2r - 1)^2 <= 16384 a < (2r + 1)^2
        const int64_t n = 16384 * lo;
        int64_t r = 0;
        while ((2 * r + 1) * (2 * r + 1) <= n) r += (r < 64 || (2 * r + 129) * (2 * r + 129) > n) ? 1 : 64;
        return sext(sat16(r));
    }
    case MUL: return sext(sat16(floordiv(2 * lo * b + 4096, 8192)));       // floor(a b / 4096 + 1/2)
    case DIV:
        if (b == 0) { fl = 2; return sext(lo == 0 ? 0 : lo < 0 ? 0x8000 : 0x7fff); }
        return sext(sat16(floordiv(8192 * lo + b, 2 * b)));                // floor(4096 a / b + 1/2)
    case BIST: return bist(rs1, rs2);
    case TANH: {
        int64_t u;
        if (G == 0) {                                   // -2|a| saturated to S3.12
            int64_t ta = iabs(lo); if (ta > 32767) ta = 32767;
            u = -2 * ta; if (u < -32768) u = -32768;
        } else
            u = -2 * iabs(lo);                          // full range [-16, 0]
        const int kk = expk(u);
        V3 e = pass(2, 0, kh, 0, u * (int64_t(1) << G) - kln2(kk));
        const int64_t E = scale_m(e.x + e.y, kk);
        const int64_t da = wrap(ONE - E), db = wrap(ONE + E);   // W-bit, as specified
        const uint32_t q = fdiv(da, db) & 0xffffu;
        return sext(lo < 0 ? (0u - q) & 0xffffu : q);
    }
    case ROTC: {                                        // rotation without gain
        if (lo == 0 && hi == 0) return 0;
        const int ps = norm(imax(iabs(ul), iabs(uh)));
        Quad qa = quad(rs2);
        V3 e1 = pass(0, 0, shl(ul, ps), shl(uh, ps), qa.th);
        unquad(qa.q, e1.x, e1.y, sn, cs);
        V3 e2 = pass(1, 0, cs, 0, INV_K);
        V3 e3 = pass(1, 0, sn, 0, INV_K);
        return pack(scale(e3.y, -ps), scale(e2.y, -ps));
    }
    default: return 0;
    }
}

}  // namespace xc
