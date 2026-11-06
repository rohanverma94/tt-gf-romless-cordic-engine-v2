// xcordic_core.v — Xcordic instruction unit on the ttsky25a CORDIC datapath
//
// Native functions. The core sequences one to three engine passes per
// instruction and does the range reduction itself, so sin, cos, tan, atan2,
// hypot, exp, ln, sqrt, mul, div and tanh are each a single instruction over
// their full S3.12 domain.
//
// GUARD. The engine and every internal value carry GUARD extra fraction
// bits: W = 16 + GUARD bit registers, values S3.F with F = 12 + GUARD, and
// N_PE = 13 + (GUARD+1)/2 iterations. Operands enter as S3.12 shifted up by
// GUARD; every result is rounded (half up) back to S3.12 and saturated.
//   GUARD = 0  the ttsky25a datapath, bit-exact with silicon
//   GUARD = 4  20-bit datapath, 15 circular / 17 linear iterations:
//              sin/cos/ln ~1.2 LSB worst case (exhaustive, formal/run.sh t3)
// Two algorithm refinements apply only when GUARD > 0 (GUARD = 0 keeps the original algorithm):
//   - linear passes run F+1 iterations, down to the 1-LSB step
//   - tanh reduces -2|t| over [-16, 0] instead of saturating it at -8
// The ISA does not change. cfg registers are W bits wide (values S3.F).
//
// Pipelined pass setup, for a 100 MHz core clock on sky130. Each pass
// setup (S_PRE, S_MID) is preceded by capture cycles (S_PREP + S_PRE2,
// S_MIDP) that register the first half of every long setup chain: the
// normalization lanes' operands and leading-zero shifts, the wrapped and
// quadrant-mapped angle, the exp/tanh reduction k, the ln/sqrt exponent and
// then mantissa. The launch cycle then only shifts, negates and adds. Results
// and engine launches are unchanged (F3); each instruction takes a few cycles more.
//
// GUARD > 0 only. mac and mul launch their linear rotation pass with
// dir = D_MUL: the engine rounds x >> s and holds at z = 0 (xcordic_engine.v).
// mul's worst case drops from 4.0 to 1.4 LSB. The gain passes of hypot, sqrt
// and rotc keep the truncating pass: their truncation offsets the vectoring
// pass's bias (rounding them would raise hypot's mean error 0.37 -> 0.51 LSB).
//
// mul uses a hardware multiplier: rs1 * rs2 is registered in S_PREP,
// rounded half up to S3.12 and saturated in S_PRE2, and returned in S_PRE
// (no engine pass). The result is exact (|error| <= 0.5 LSB), at any GUARD.
// mac keeps its rounded linear-rotation pass (D_MUL).
//
// mul, div and sqrt run on xc_exact.v, a sequential unit (one adder,
// one bit per cycle) that replaces an array multiplier and the CORDIC
// div / sqrt sequences: every result is the exact value rounded half up and
// saturated (|error| <= 0.5 LSB), at any GUARD. Every instruction also
// returns flags = {INV, SAT}: SAT = a result (either half of a pair) was
// clipped to [-8, 8); INV = invalid argument (div by 0, ln of a <= 0,
// sqrt of a < 0). Slow-corner timing (paths from an earlier layout): the
// normalization lanes' shifted values and the quadrant-mapped sin / cos are
// registered in the capture cycles, and the scaler rounds after its shift.
// Results of every other instruction are unchanged (F3).
//
// funct7 = 0  base passes                   funct7 = 1  functions
//   000 rot     {y,x}, th  -> K*{y',x'}       000 sin    a        -> sin a
//   001 sincos  th         -> {sin, cos}      001 cos    a        -> cos a
//   010 vec     {y,x}      -> {atan2, K|v|}   010 tan    a        -> tan a
//   011 mac     {y,x}, z   -> y + x*z         011 atan2  y, x     -> atan2(y, x)
//   100 div     {y,x}      -> y / x           100 hypot  x, y     -> sqrt(x^2 + y^2)
//   101 hsincos th         -> {sinh, cosh}    101 exp    a        -> e^a
//   110 hvec    {y,x}      -> {atanh, Kh*r}   110 ln     a        -> ln a
//   111 cfg     v, {ro,sel}-> old cfg[sel]    111 sqrt   a        -> sqrt a
//
// funct7 = 2  functions
//   000 mul   a, b     -> a * b              010 tanh  a        -> tanh a
//   001 div   a, b     -> a / b              011 rotc  {y,x}, th -> {y',x'} (no gain)
//
// Scalar operands are rs1[15:0] / rs2[15:0]; scalar results are sign-extended.
// Results saturate to [-8, 8). ln/sqrt of an invalid argument return 0x8000.
// sqrt, mul and div are exact: rounded half up, |error| <= 0.5 LSB
// (xc_exact.v); div by 0 returns 0 (0/0) or 0x7FFF / 0x8000 by the sign of a.
// flags = {INV, SAT} with every result.
//
// For the gf180mcu slow corner at 25 MHz: one more capture cycle in
// front of each pass setup (S_PRE1 after S_PREP, S_MID1 after S_MIDP). The
// capture cycle registers the raw operands (lane values, the angle before
// wrapping, the exp/tanh argument, cosh + sinh); the new cycle forms what the
// first capture formed from them (the lanes' normalization shifts, the wrapped
// and quadrant-mapped angle, exp's k, the scaler input). In the earlier layout
// these chains (o_y -> lane -> |v| -> leading one -> shift) were 4 ns short.
// Results unchanged; each pass setup takes one cycle more (F3).
// cfg likewise takes its register access out of the accepting cycle (S_CFG):
// the selector and value come from op_rs1 / op_rs2, not straight from the
// self-test's instruction mux (4 ns short in the earlier layout). cfg now keeps
// busy high for one cycle, and done pulses one cycle later.
// The final results' rounding moves into S_MIDS too: S_MID picks registered
// rounded values (and their SAT bits) instead of rounding the engine outputs
// on the way into rd (in the earlier layout, o_z / k*ln2 -> round -> rd was 1 ns short).
`timescale 1ns/1ps
`default_nettype none

module xcordic_core #(
    parameter FUNCS = 1,       // 0: base passes only (base subset, smallest)
    parameter GUARD = 0        // extra fraction bits, 0..4 (0 = ttsky25a datapath)
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,      // 1-cycle pulse, ignored while busy
    input  wire [6:0]  funct7,     // 0, 1, 2 (decoded legal by the wrapper)
    input  wire [2:0]  funct3,
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    output reg         busy,
    output reg         done,       // 1-cycle pulse, rd valid
    output reg  [31:0] rd,
    output reg  [1:0]  flags       // {INV, SAT}, valid with rd
);
    localparam integer W = 16 + GUARD;          // datapath width
    localparam integer F = 12 + GUARD;          // fraction bits

    // ---- constants, generated by toolchain/gen_consts.cpp ----
    localparam integer N_PE = 13 + (GUARD + 1) / 2;
    localparam integer N_LIN = (GUARD == 0) ? N_PE : F + 1;
    localparam integer HALF_PI = (GUARD == 0) ? 6434 : (GUARD == 1) ? 12868 : (GUARD == 2) ? 25736 : (GUARD == 3) ? 51472 : 102944;
    localparam integer PI = (GUARD == 0) ? 12868 : (GUARD == 1) ? 25736 : (GUARD == 2) ? 51472 : (GUARD == 3) ? 102944 : 205887;
    localparam integer THREE_HALF_PI = (GUARD == 0) ? 19302 : (GUARD == 1) ? 38604 : (GUARD == 2) ? 77208 : (GUARD == 3) ? 154416 : 308831;
    localparam integer TWO_PI = (GUARD == 0) ? 25736 : (GUARD == 1) ? 51472 : (GUARD == 2) ? 102944 : (GUARD == 3) ? 205887 : 411775;
    localparam integer INV_K = (GUARD == 0) ? 2487 : (GUARD == 1) ? 4975 : (GUARD == 2) ? 9949 : (GUARD == 3) ? 19898 : 39797;
    localparam integer INV_2KH = (GUARD == 0) ? 2473 : (GUARD == 1) ? 4946 : (GUARD == 2) ? 9892 : (GUARD == 3) ? 19784 : 39567;
    localparam integer RST_ATAN0 = (GUARD == 0) ? 3217 : (GUARD == 1) ? 6434 : (GUARD == 2) ? 12868 : (GUARD == 3) ? 25736 : 51472;
    localparam integer RST_ATAN1 = (GUARD == 0) ? 1899 : (GUARD == 1) ? 3798 : (GUARD == 2) ? 7596 : (GUARD == 3) ? 15193 : 30386;
    localparam integer RST_KC = (GUARD == 0) ? 2487 : (GUARD == 1) ? 4975 : (GUARD == 2) ? 9949 : (GUARD == 3) ? 19898 : 39797;
    localparam integer RST_ATANH1 = (GUARD == 0) ? 2250 : (GUARD == 1) ? 4500 : (GUARD == 2) ? 9000 : (GUARD == 3) ? 18000 : 35999;
    localparam integer RST_KH = (GUARD == 0) ? 4946 : (GUARD == 1) ? 9892 : (GUARD == 2) ? 19784 : (GUARD == 3) ? 39567 : 79135;
    localparam integer LN2_Q = (GUARD == 0) ? 45426 : (GUARD == 1) ? 90852 : (GUARD == 2) ? 181704 : (GUARD == 3) ? 363409 : 726817;
    // ----

    localparam signed [W-1:0] C_HALF_PI = HALF_PI[W-1:0], C_PI = PI[W-1:0],
                              C_THREE_HALF_PI = THREE_HALF_PI[W-1:0], C_TWO_PI = TWO_PI[W-1:0],
                              C_INV_K = INV_K[W-1:0], C_INV_2KH = INV_2KH[W-1:0];
    localparam signed [W-1:0] ONE = 1 << F;
    localparam signed [15:0]  SAT_MAX = 16'sh7FFF, SAT_MIN = -16'sh8000;
    localparam signed [15:0]  NAN16 = -16'sh8000;
    localparam integer        RND_G = (GUARD > 0) ? (1 << (GUARD - 1)) : 0;   // half an S3.12 LSB

    // op = {funct7[1:0], funct3}
    localparam [4:0] OP_ROT = 0, OP_SC = 1, OP_VEC = 2, OP_MAC = 3,
                     OP_LDIV = 4, OP_HSC = 5, OP_HVEC = 6, OP_CFG = 7,
                     OP_SIN = 8, OP_COS = 9, OP_TAN = 10, OP_ATAN2 = 11,
                     OP_HYPOT = 12, OP_EXP = 13, OP_LN = 14, OP_SQRT = 15,
                     OP_MUL = 16, OP_DIV = 17, OP_TANH = 18, OP_ROTC = 19;
    localparam [1:0] M_CIRC = 2'd0, M_LIN = 2'd1, M_HYP = 2'd2;
    localparam [1:0] D_ROT = 2'd0, D_VEC = 2'd1, D_DIV = 2'd2;
    localparam [1:0] D_MUL = 2'd3;   // linear rotation of a user product (mac, mul): rounded, holds at z = 0 (GUARD > 0)

    // =====================================================================
    // arithmetic helpers (combinational)
    // =====================================================================
    // S3.12 operand -> S3.F
    function signed [W-1:0] up(input signed [15:0] v);
        begin
            up = v;
            up = up <<< GUARD;
        end
    endfunction

    function signed [W:0] absw(input signed [W-1:0] v);
        absw = v[W-1] ? -{v[W-1], v} : {v[W-1], v};
    endfunction

    function [4:0] msbw(input [W:0] a);
        integer i;
        begin
            msbw = 0;
            for (i = 0; i <= W; i = i + 1)
                if (a[i]) msbw = i[4:0];
        end
    endfunction

    // left shift that puts max |v| at [1, 2); negative = right shift
    function signed [5:0] nshift(input [W:0] m);
        nshift = (m == 0) ? 6'sd0 : $signed(F[5:0]) - $signed({1'b0, msbw(m)});
    endfunction

    function signed [W-1:0] shl(input signed [W-1:0] v, input signed [5:0] s);
        shl = s[5] ? (v >>> (-s)) : (v << s);
    endfunction

    // S3.F (any width up to W+4) -> S3.12, round half up, saturate
    function signed [15:0] rnd(input signed [W+3:0] v);
        reg signed [W+3:0] r;
        begin
            r = (v + RND_G) >>> GUARD;
            rnd = (r > 32767) ? SAT_MAX : (r < -32768) ? SAT_MIN : r[15:0];
        end
    endfunction
    // ... and whether that saturated (the SAT flag)
    function rnd_s(input signed [W+3:0] v);
        reg signed [W+3:0] r;
        begin
            r = (v + RND_G) >>> GUARD;
            rnd_s = (r > 32767) || (r < -32768);
        end
    endfunction

    // k * ln2 in S3.F, ln2 held with F+4 fraction bits
    function signed [W+5:0] kln2(input signed [5:0] k);
        reg signed [31:0] p;
        begin
            p = $signed(k) * LN2_Q + 8;
            kln2 = p >>> 4;
        end
    endfunction

    // t = k*ln2 + r, k = round(t * 1.4375)   (t in S5.12)
    function signed [5:0] exp_k(input signed [17:0] t);
        reg signed [21:0] wt, s;
        begin
            wt = {{4{t[17]}}, t};
            s = wt + (wt >>> 1) - (wt >>> 4) + 22'sd2048;
            exp_k = s >>> 12;
        end
    endfunction

    // =====================================================================
    // state
    // =====================================================================
    reg [W-1:0] r_atan0, r_atan1, r_kc, r_atanh1, r_kh;

    reg [4:0]  op;
    // Op decoded one-hot in the accepting cycle. Every op-dependent select
    // (capture muxes, engine launch operands, the finish mux) uses its own bit:
    // in an earlier layout the few op bits fed every decoder and their buffer
    // trees set the slow corner (op -> e_z, -9.9 ns). oh == 1 << op while busy.
    reg [19:0] oh;
    reg [31:0] op_rs1, op_rs2;
    reg [1:0]  quadrant;
    reg        zero_vec;
    reg [2:0]  pass;                     // engine passes completed (+ rotc final step)
    reg signed [5:0]  kexp;              // output exponent / normalization shift
    reg               neg;               // tanh sign
    reg signed [W-1:0] t_a, t_b;         // scratch between passes

    // S_PREP/S_PRE2 precede S_PRE, S_MIDP/S_MIDS precede S_MID: capture, then
    // scale (the shared scaler's shift and rounding get a cycle of their own).
    // S_XRUN: mul, div or sqrt on the exact unit.
    localparam [3:0] S_IDLE = 0, S_PRE = 1, S_RUN = 2, S_MID = 3, S_DONE = 4,
                     S_PREP = 5, S_MIDP = 6, S_PRE2 = 7, S_MIDS = 8, S_XRUN = 9,
                     S_PRE1 = 10, S_MID1 = 11,       // S_PREP -> S_PRE1 -> S_PRE2, S_MIDP -> S_MID1 -> S_MIDS
                     S_CFG = 12;                     // cfg reads and writes from the registered operands
    reg        sat2;                     // rotc: the first half (x') saturated

    // pipeline registers, loaded in S_PREP / S_MIDP from the same inputs the
    // following S_PRE / S_MID sees (op_rs*, engine outputs, t_a, pass, quadrant)
    reg  signed [W-1:0] q_va, q_vb;      // normalization lane operands
    reg  signed [5:0]   q_na, q_nb;      // their shifts
    reg  [1:0]          q_quad;          // rotation quadrant
    reg  signed [W-1:0] q_thm;           // angle mapped into [0, pi/2)
    reg  signed [17:0]  q_xt;            // exp/tanh argument (S5.12)
    reg  signed [5:0]   q_xk;            // its k = round(x / ln2)
    reg  signed [5:0]   q_lne;           // ln/sqrt exponent
    reg  signed [W+1:0] q_scv;           // scaler input value  (S_PREP / S_MIDP)
    reg  signed [6:0]   q_sce;           // scaler exponent     (S_PREP / S_MIDP)
    reg  signed [W+5:0] q_kl;            // k * ln2             (S_PRE2 / S_MIDS)
    reg  signed [W-1:0] q_van, q_vbn;    // the lanes' shifted values (S_PRE2 / S_MIDS)
    reg  signed [W-1:0] q_psin, q_pcos;  // quadrant-mapped sin, cos (S_MIDP)
    reg  signed [W-1:0] q_th0;           // the angle operand before wrapping (S_PREP / S_MIDP)
    reg  signed [W:0]   q_hsum;          // cosh + sinh (S_PREP / S_MIDP)
    reg  signed [W+5:0] q_kl2;           // k * ln2 for ln's result (S_MID1)
    // rounded results and their SAT bits (S_MIDS)
    reg  signed [15:0]  q_rx, q_ry, q_rz, q_rs, q_rc, q_rl;
    reg                 q_sx, q_sy, q_sz, q_ss, q_sc_, q_sl;
    reg [3:0] state;

    // ---------------- operand fields (S3.12) ----------------
    wire signed [15:0] f_lo = op_rs1[15:0];
    wire signed [15:0] f_hi = op_rs1[31:16];
    wire signed [15:0] f_z  = op_rs2[15:0];

    // ---------------- engine ----------------
    reg                 e_start;
    reg  [1:0]          e_mode, e_dir;
    reg  signed [W-1:0] e_x, e_y, e_z;
    wire signed [W-1:0] o_x, o_y, o_z;
    wire                e_busy, e_done;

    xcordic_engine #(.DATA_WIDTH(W), .N_PE(N_PE), .N_LIN(N_LIN), .GUARD(GUARD)) u_engine (
        .i_clk(clk), .i_rst_n(rstn), .i_start(e_start),
        .i_mode(e_mode), .i_dir(e_dir),
        .i_x(e_x), .i_y(e_y), .i_z(e_z),
        .i_atan0(r_atan0), .i_atan1(r_atan1), .i_atanh1(r_atanh1),
        .o_x(o_x), .o_y(o_y), .o_z(o_z), .o_busy(e_busy), .o_done(e_done)
    );

    // ---------------- exact unit: mul, div, sqrt ----------------
    // started in the accepting cycle with the operands as they arrive, so it
    // keeps copies of its own (op_rs1 does not feed it)
    wire [4:0]  in_op   = {(FUNCS != 0) ? funct7[1:0] : 2'b00, funct3};
    wire        in_xop  = (FUNCS != 0) && ((in_op == OP_MUL) || (in_op == OP_DIV) || (in_op == OP_SQRT));
    wire        x_start = (state == S_IDLE) && start && in_xop;
    wire [1:0]  x_opc   = (in_op == OP_MUL) ? 2'd0 : (in_op == OP_DIV) ? 2'd1 : 2'd2;
    wire        x_busy, x_done;
    wire [15:0] x_rd;
    wire [1:0]  x_flags;
    generate if (FUNCS != 0) begin : g_exact
        xc_exact u_exact (
            .clk(clk), .rstn(rstn), .start(x_start),
            .op(x_opc),
            .a(rs1[15:0]), .b(rs2[15:0]),
            .busy(x_busy), .done(x_done), .rd(x_rd), .flags(x_flags)
        );
    end else begin : g_no_exact
        assign x_busy = 1'b0; assign x_done = 1'b0; assign x_rd = 16'd0; assign x_flags = 2'd0;
    end endgenerate

    // ---------------- pair normalization (atan2, hypot, rotc) ----------------
    wire signed [W-1:0] px = up(oh[OP_ATAN2] ? f_z  : f_lo);
    wire signed [W-1:0] py = up(oh[OP_ATAN2] ? f_lo :
                                oh[OP_HYPOT] ? f_z  : f_hi);
    wire        p_zero = (px == 0) && (py == 0);

    // ---------------- circular rotation pre-processing ----------------
    wire signed [W-1:0] th0 = up((oh[OP_ROT] || oh[OP_ROTC]) ? f_z : f_lo);
    // Wrapped and mapped from the captured operand, in S_PRE1 / S_MID1
    wire signed [W-1:0] th  = q_th0[W-1]          ? q_th0 + C_TWO_PI :
                              (q_th0 >= C_TWO_PI) ? q_th0 - C_TWO_PI : q_th0;
    wire signed [W-1:0] diff1 = th - C_HALF_PI;
    wire signed [W-1:0] diff2 = th - C_PI;
    wire signed [W-1:0] diff3 = th - C_THREE_HALF_PI;
    wire v1 = diff1[W-1], v2 = diff2[W-1], v3 = diff3[W-1];
    wire [1:0] w_quadrant = {~v1 & ~v2, ~v1 & ~(v2 ^ v3)};
    reg  signed [W-1:0] th_mapped;
    always @* begin
        case (w_quadrant)
            2'b00: th_mapped = th;
            2'b01: th_mapped = diff1;
            2'b10: th_mapped = diff2;
            default: th_mapped = diff3;
        endcase
    end

    // ---------------- circular rotation post-processing ----------------
    reg signed [W-1:0] p_cos, p_sin;
    always @* begin
        case (quadrant)
            2'b00: begin p_cos = o_x;  p_sin = o_y;  end
            2'b01: begin p_cos = -o_y; p_sin = o_x;  end
            2'b10: begin p_cos = -o_x; p_sin = -o_y; end
            default: begin p_cos = o_y; p_sin = -o_x; end
        endcase
    end

    // ---------------- full-range divide a / b (tan, tanh; div: exact unit) ----------------
    wire signed [W-1:0] da = oh[OP_TAN] ? p_sin : ONE - t_a;
    wire signed [W-1:0] db = oh[OP_TAN] ? p_cos : ONE + t_a;

    // ---------------- two shared normalization lanes ----------------
    // pair ops scale (x, y) by one common shift; tan/tanh scale a and b separately
    wire pair = oh[OP_ATAN2] || oh[OP_HYPOT] || oh[OP_ROTC];
    wire signed [W-1:0] va = pair ? px : da;
    wire signed [W-1:0] vb = pair ? py : db;
    // From the captured lane values, in S_PRE1 / S_MID1
    wire signed [5:0] n_a = nshift(absw(q_va) | (pair ? absw(q_vb) : {(W+1){1'b0}}));
    wire signed [5:0] n_b = pair ? n_a : nshift(absw(q_vb));
    // shifted in the cycle after the capture (S_PRE2 / S_MIDS), registered
    wire signed [W-1:0] van = q_van;
    wire signed [W-1:0] vbn = q_vbn;
    wire signed [5:0]   p_sh = q_na, d_sa = q_na, d_sb = q_nb;
    wire signed [W-1:0] pxn  = van,  pyn  = vbn, dan  = van, dbn = vbn;

    // ---------------- circular vectoring pre-processing ----------------
    wire signed [W-1:0] vx = oh[OP_VEC] ? up(f_lo) : pxn;
    wire signed [W-1:0] vy = oh[OP_VEC] ? up(f_hi) : pyn;
    wire v_flip = vx[W-1];

    // ---------------- exp / tanh argument reduction ----------------
    // x_t is S5.12: exp's argument, or tanh's -2|t|. GUARD = 0 saturates -2|t|
    // to S3.12; GUARD > 0 keeps the full range [-16, 0].
    wire signed [16:0] th_absv = f_lo[15] ? -{f_lo[15], f_lo} : {f_lo[15], f_lo};
    wire signed [15:0] th_a   = (th_absv > 17'sd32767) ? SAT_MAX : th_absv[15:0];
    wire signed [17:0] th_u2  = -{th_a[15], th_a, 1'b0};
    wire signed [15:0] th_u   = (th_u2 < -18'sd32768) ? SAT_MIN : th_u2[15:0];
    wire signed [17:0] th_u18 = -{th_absv, 1'b0};
    wire signed [17:0] x_t    = !oh[OP_TANH] ? {{2{f_lo[15]}}, f_lo} :
                                (GUARD > 0)     ? th_u18 : {{2{th_u[15]}}, th_u};
    wire signed [5:0]  x_k    = exp_k(q_xt[17:0]);      // from the captured argument, in S_PRE1
    wire signed [W+5:0] kl_c  = kln2((state == S_PRE2) ? q_xk : kexp); // k*ln2, registered as q_kl
    wire signed [W+5:0] kl    = q_kl;
    wire signed [W+5:0] x_up  = q_xt;
    wire signed [W+5:0] x_rw  = (x_up <<< GUARD) - kl;
    wire signed [W-1:0] x_r   = x_rw[W-1:0];

    // ---------------- ln mantissa (sqrt: exact unit) ----------------
    wire [4:0]         a_msb  = msbw({{(W-15){1'b0}}, f_lo});
    wire signed [5:0]  ln_e   = $signed({1'b0, a_msb}) - 6'sd12;
    wire signed [5:0]  m_sh_c = ln_e;                                          // at capture

    // ---------------- final results ----------------
    wire signed [W:0]   hsum   = {o_x[W-1], o_x} + {o_y[W-1], o_y};      // cosh + sinh
    wire signed [W+3:0] ln_sum2 = {{3{o_z[W-1]}}, o_z, 1'b0} + q_kl2[W+3:0];   // rounded in S_MIDS

    // ---------------- shared scaler: v * 2^k, round half up, saturate ----------------
    // sc_v is S3.F. Intermediate values (ln/sqrt mantissa, tanh's E) stay S3.F
    // and saturate to W bits; final results drop the GUARD bits as well.
    localparam integer SCW = W + 26;
    reg  signed [W+1:0] sc_v;
    reg  signed [5:0]   sc_k;
    always @* begin                    // scaler input, registered in S_PRE1 / S_MID1
        sc_k = kexp;
        if (state == S_PRE1) begin
            sc_v = {{2{f_lo[15]}}, up(f_lo)};  sc_k = -m_sh_c;        // ln mantissa
        end else (* parallel_case *) case (1'b1)
            oh[OP_EXP]:                    sc_v = {q_hsum[W], q_hsum};
            oh[OP_TANH]:                   sc_v = (pass == 1) ? {q_hsum[W], q_hsum} : {{2{o_z[W-1]}}, o_z};
            oh[OP_TAN]:                    sc_v = {{2{o_z[W-1]}}, o_z};
            oh[OP_ROTC]:                   sc_v = (pass == 3) ? {{2{t_b[W-1]}}, t_b} : {{2{o_y[W-1]}}, o_y};
            default:                   sc_v = {{2{o_y[W-1]}}, o_y};    // hypot
        endcase
    end
    wire               sc_mid = (state == S_PRE1) || (oh[OP_TANH] && pass == 1);
    wire signed [6:0]  sc_e   = {sc_k[5], sc_k} - (sc_mid ? 7'sd0 : $signed(GUARD[6:0]));
    // shift and round from the captured input (S_PRE2 / S_MIDS), into q_sc.
    // A right shift by n rounds as ((v >> (n-1)) + 1) >> 1, which equals
    // (v + 2^(n-1)) >> n: the add is a constant increment after the shift.
    wire signed [SCW-1:0] sc_w = {{(SCW-W-2){q_scv[W+1]}}, q_scv};
    wire signed [SCW-1:0] sc_h = sc_w >>> (-q_sce - 7'sd1);
    wire signed [SCW-1:0] sc_i = sc_h + {{(SCW-1){1'b0}}, 1'b1};
    wire signed [SCW-1:0] sc_r = !q_sce[6] ? (sc_w <<< q_sce) : (sc_i >>> 1);
    reg  signed [SCW-1:0] q_sc;
    // saturate (S_PRE / S_MID). The range tests as sign and bit reductions
    // (v > 2^15-1 <=> v >= 0 and a bit above bit 14 is set; v < -2^15 <=> v < 0
    // and a bit above bit 14 is clear), the same tests as the comparisons.
    wire               sc_neg = q_sc[SCW-1];
    wire               sc_hi  = !sc_neg && (|q_sc[SCW-2:15]);      // > 32767
    wire               sc_lo  =  sc_neg && !(&q_sc[SCW-2:15]);     // < -32768
    wire               sc_whi = !sc_neg && (|q_sc[SCW-2:W-1]);     // > 2^(W-1) - 1
    wire               sc_wlo =  sc_neg && !(&q_sc[SCW-2:W-1]);    // < -2^(W-1)
    wire               sc_sat = sc_hi || sc_lo;
    wire signed [15:0]  sc_out = sc_hi ? SAT_MAX : sc_lo ? SAT_MIN : q_sc[15:0];
    wire signed [W-1:0] sc_wid = sc_whi ? {1'b0, {(W-1){1'b1}}} :
                                 sc_wlo ? {1'b1, {(W-1){1'b0}}} : q_sc[W-1:0];
    // -sc_out, 16 bits (tanh's sign), with a prefix adder
    wire [15:0] sc_outn;
    xc_add #(.W(16)) u_scn (.a(~sc_out), .b(16'd0), .ci(1'b1), .s(sc_outn));
    // -vx, -vy for the vectoring launch, with prefix adders
    wire [W-1:0] vxn, vyn;
    xc_add #(.W(W)) u_vxn (.a(~vx), .b({W{1'b0}}), .ci(1'b1), .s(vxn));
    xc_add #(.W(W)) u_vyn (.a(~vy), .b({W{1'b0}}), .ci(1'b1), .s(vyn));
    wire signed [W-1:0] m_val  = sc_wid;

    function [31:0] sx(input [15:0] v);
        sx = {{16{v[15]}}, v};
    endfunction

    // ---------------- cfg register file ----------------
    reg [W-1:0] cfg_old;
    always @* begin
        case (op_rs2[2:0])                 // in S_CFG
            3'd0: cfg_old = r_atan0;
            3'd1: cfg_old = r_atan1;
            3'd2: cfg_old = r_kc;
            3'd3: cfg_old = r_atanh1;
            3'd4: cfg_old = r_kh;
            default: cfg_old = 0;
        endcase
    end

    // =====================================================================
    // control
    // =====================================================================
    task launch(input [1:0] mode, input [1:0] dir,
                input signed [W-1:0] x, input signed [W-1:0] y, input signed [W-1:0] z);
        begin
            e_mode <= mode; e_dir <= dir;
            e_x <= x; e_y <= y; e_z <= z;
            e_start <= 1'b1;
            state <= S_RUN;
        end
    endtask

    task finish(input [31:0] v, input [1:0] f);     // f = {INV, SAT}
        begin
            rd <= v;
            flags <= f;
            state <= S_DONE;
        end
    endtask

    task launch_rotate(input signed [W-1:0] x, input signed [W-1:0] y);
        begin
            quadrant <= q_quad;
            launch(M_CIRC, D_ROT, x, y, q_thm);
        end
    endtask

    task launch_vec;
        begin
            launch(M_CIRC, D_VEC, v_flip ? vxn : vx, v_flip ? vyn : vy,
                   v_flip ? (vy[W-1] ? -C_PI : C_PI) : {W{1'b0}});
        end
    endtask

    // full-range divide of (da, db); special cases finish immediately
    task launch_fdiv;
        begin
            if (q_va == 0)       finish(32'd0, 2'b00);
            else if (q_vb == 0)  finish(sx(q_va[W-1] ? SAT_MIN : SAT_MAX), 2'b01);
            else begin
                kexp <= d_sb - d_sa;
                launch(M_LIN, D_DIV, dbn, dan, {W{1'b0}});
            end
        end
    endtask

    always @(posedge clk)
        if (state == S_PREP || state == S_MIDP) begin
            q_va <= va;  q_vb <= vb;
            q_th0 <= th0;  q_hsum <= hsum;
            q_xt <= x_t;  q_lne <= ln_e;
            if (state == S_MIDP) begin q_psin <= p_sin;  q_pcos <= p_cos; end
        end else if (state == S_PRE1 || state == S_MID1) begin
            if (state == S_MID1) q_kl2 <= kl_c;
            q_na <= n_a;  q_nb <= n_b;
            q_quad <= w_quadrant;  q_thm <= th_mapped;
            q_xk <= x_k;
            q_scv <= sc_v;  q_sce <= sc_e;
        end else if (state == S_PRE2 || state == S_MIDS) begin
            if (state == S_MIDS) begin
                q_rx <= rnd(o_x);     q_sx <= rnd_s(o_x);
                q_ry <= rnd(o_y);     q_sy <= rnd_s(o_y);
                q_rz <= rnd(o_z);     q_sz <= rnd_s(o_z);
                q_rs <= rnd(q_psin);  q_ss <= rnd_s(q_psin);
                q_rc <= rnd(q_pcos);  q_sc_ <= rnd_s(q_pcos);
                q_rl <= rnd(ln_sum2); q_sl <= rnd_s(ln_sum2);
            end
            q_sc <= sc_r;  q_kl <= kl_c;
            q_van <= shl(q_va, q_na);  q_vbn <= shl(q_vb, q_nb);
        end

    always @(posedge clk) begin
        done <= 1'b0;
        e_start <= 1'b0;
        if (!rstn) begin
            state <= S_IDLE;
            busy <= 1'b0;
            rd <= 0;
            flags <= 2'b00;
            oh <= 20'd0;
            r_atan0 <= RST_ATAN0[W-1:0];
            r_atan1 <= RST_ATAN1[W-1:0];
            r_kc <= RST_KC[W-1:0];
            r_atanh1 <= RST_ATANH1[W-1:0];
            r_kh <= RST_KH[W-1:0];
        end else case (state)
            S_IDLE: if (start) begin
                op <= in_op;
                oh <= 20'd1 << in_op;            // 0 for an op >= 20 (never issued)
                op_rs1 <= rs1;
                op_rs2 <= rs2;
                pass <= 0;
                zero_vec <= 1'b0;
                if (funct7 == 7'd0 && funct3 == 3'd7) begin
                    busy <= 1'b1;
                    state <= S_CFG;
                end else begin
                    busy <= 1'b1;
                    state <= in_xop ? S_XRUN : S_PREP;       // x_start pulses in this cycle
                end
            end

            // ---------------- cfg (from the registered operands) ----------------
            S_CFG: begin
                rd <= {{(32-W){1'b0}}, cfg_old};
                flags <= 2'b00;
                if (!op_rs2[3]) case (op_rs2[2:0])
                    3'd0: r_atan0 <= op_rs1[W-1:0];
                    3'd1: r_atan1 <= op_rs1[W-1:0];
                    3'd2: r_kc <= op_rs1[W-1:0];
                    3'd3: r_atanh1 <= op_rs1[W-1:0];
                    3'd4: r_kh <= op_rs1[W-1:0];
                    default: ;
                endcase
                busy <= 1'b0;
                done <= 1'b1;
                state <= S_IDLE;
            end

            S_PREP: state <= S_PRE1;
            S_PRE1: state <= S_PRE2;
            S_PRE2: state <= S_PRE;
            S_MIDP: state <= S_MID1;
            S_MID1: state <= S_MIDS;
            S_MIDS: state <= S_MID;

            // ---------------- mul, div, sqrt ----------------
            S_XRUN: if (x_done) finish(sx(x_rd), x_flags);

            // ---------------- first pass ----------------
            S_PRE: (* parallel_case *) case (1'b1)
                oh[OP_ROT]:                   launch_rotate(up(f_lo), up(f_hi));
                oh[OP_SC], oh[OP_SIN], oh[OP_COS],
                oh[OP_TAN]:                   launch_rotate(r_kc, {W{1'b0}});
                oh[OP_VEC]: begin
                    zero_vec <= (f_lo == 0) && (f_hi == 0);
                    launch_vec;
                end
                oh[OP_MAC]:                   launch(M_LIN, D_MUL, up(f_lo), up(f_hi), up(f_z));
                oh[OP_LDIV]:                  launch(M_LIN, D_DIV, up(f_lo), up(f_hi), {W{1'b0}});
                oh[OP_HSC]:                   launch(M_HYP, D_ROT, r_kh, {W{1'b0}}, up(f_lo));
                oh[OP_HVEC]: begin
                    zero_vec <= (f_lo == 0) && (f_hi == 0);
                    launch(M_HYP, D_VEC, up(f_lo), up(f_hi), {W{1'b0}});
                end
                oh[OP_ATAN2], oh[OP_HYPOT]: begin
                    if (q_va == 0 && q_vb == 0) finish(32'd0, 2'b00);     // p_zero, captured
                    else begin
                        kexp <= -p_sh;
                        launch_vec;
                    end
                end
                oh[OP_EXP], oh[OP_TANH]: begin
                    kexp <= q_xk;
                    neg <= f_lo[15];
                    launch(M_HYP, D_ROT, r_kh, {W{1'b0}}, x_r);
                end
                oh[OP_LN]: begin
                    if (f_lo[15] || f_lo == 0) finish(sx(NAN16), 2'b10);
                    else begin
                        kexp <= q_lne;
                        launch(M_HYP, D_VEC, m_val + ONE, m_val - ONE, {W{1'b0}});
                    end
                end
                oh[OP_ROTC]: begin
                    if (q_va == 0 && q_vb == 0) finish(32'd0, 2'b00);     // p_zero, captured
                    else begin
                        kexp <= -p_sh;
                        launch_rotate(pxn, pyn);
                    end
                end
                default:                  finish(32'd0, 2'b00);
            endcase

            S_RUN: if (e_done) begin
                pass <= pass + 3'd1;
                state <= S_MIDP;
            end

            // ---------------- between passes / final ----------------
            // (q_psin, q_pcos: the quadrant-mapped p_sin, p_cos, captured in S_MIDP)
            S_MID: (* parallel_case *) case (1'b1)
                // (q_r*, q_s*: rnd() and rnd_s() of o_x, o_y, o_z, q_psin, q_pcos, ln's sum, from S_MIDS)
                oh[OP_ROT], oh[OP_SC]:   finish({q_rs, q_rc}, {1'b0, q_ss || q_sc_});
                oh[OP_VEC], oh[OP_HVEC]: finish(zero_vec ? 32'd0 : {q_rz, q_rx},
                                        {1'b0, !zero_vec && (q_sz || q_sx)});
                oh[OP_MAC]:          finish(sx(q_ry), {1'b0, q_sy});
                oh[OP_LDIV]:         finish(sx(q_rz), {1'b0, q_sz});
                oh[OP_HSC]:          finish({q_ry, q_rx}, {1'b0, q_sy || q_sx});
                oh[OP_SIN]:          finish(sx(q_rs), {1'b0, q_ss});
                oh[OP_COS]:          finish(sx(q_rc), {1'b0, q_sc_});
                oh[OP_TAN]: begin
                    if (pass == 1) launch_fdiv;
                    else           finish(sx(sc_out), {1'b0, sc_sat});
                end
                oh[OP_ATAN2]:        finish(sx(q_rz), {1'b0, q_sz});
                oh[OP_HYPOT]: begin
                    if (pass == 1) launch(M_LIN, D_ROT, o_x, {W{1'b0}}, C_INV_K);
                    else           finish(sx(sc_out), {1'b0, sc_sat});
                end
                oh[OP_EXP]:          finish(sx(sc_out), {1'b0, sc_sat});
                oh[OP_LN]:           finish(sx(q_rl), {1'b0, q_sl});
                oh[OP_TANH]: begin
                    if (pass == 1) begin
                        // E = exp(-2|t|) in S3.F; the fdiv uses (1 - E) / (1 + E) next cycle
                        t_a <= sc_wid;
                        pass <= 3'd2;
                        state <= S_MIDP;       // lanes for (1 - E) / (1 + E)
                    end else if (pass == 2)
                        launch_fdiv;           // S_RUN increments pass to 3
                    else
                        finish(sx(neg ? sc_outn : sc_out), {1'b0, sc_sat});
                end
                oh[OP_ROTC]: begin
                    if (pass == 1) begin
                        t_a <= q_psin;
                        launch(M_LIN, D_ROT, q_pcos, {W{1'b0}}, C_INV_K);
                    end else if (pass == 2) begin
                        t_b <= o_y;
                        launch(M_LIN, D_ROT, t_a, {W{1'b0}}, C_INV_K);
                    end else if (pass == 3) begin
                        t_a <= sc_out;         // scaled x' (S3.12); engine output still holds y'
                        sat2 <= sc_sat;
                        pass <= 3'd4;
                        state <= S_MIDP;       // rescale: y' this time
                    end else
                        finish({sc_out, t_a[15:0]}, {1'b0, sc_sat || sat2});
                end
                default:         finish(32'd0, 2'b00);
            endcase

            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
    // formal properties (formal/props), compiled only by the matching proof
`ifdef XC_FV_CORE
`include "xcordic_core_props.vh"
`endif
endmodule

`default_nettype wire
