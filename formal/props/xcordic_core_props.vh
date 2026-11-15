// xcordic_core_props.vh — included in xcordic_core when XC_FV_CORE is defined.
// The engine is replaced by formal/models/xcordic_engine_abstract.v (its contract).
//
// F3a (XC_CORE_A, k-induction from reset, unbounded):
//   control invariants; every reachable idle state is "clean" (no engine run,
//   no pending launch); waiting for the engine and idling are stutter steps
//   (no instruction state changes); cfg registers change only on cfg; the
//   start/busy/done contract the PCPI wrapper relies on.
// F3b (XC_CORE_B, BMC from every clean idle state, one instruction):
//   for every legal instruction, every operand, every cfg value, any leftover
//   scratch state and every engine result, the core launches exactly the
//   engine passes sp_alg prescribes and writes exactly sp_alg's rd, within a
//   fixed number of cycles.
// Together: every instruction in every reachable execution meets sp_alg.
// Proved per datapath: `XC_GUARD selects the spec, chparam GUARD the RTL.

`include "xcordic_spec.vh"
`include "xcordic_isa_spec.vh"

reg f_past = 1'b0;
always @(posedge clk) f_past <= 1'b1;

wire        f_accept = rstn && start && !busy;
wire [31:0] f_insn   = {funct7, 10'd0, funct3, 5'd0, 7'b0001011};
wire        f_is_cfg = (funct7 == 7'd0) && (funct3 == 3'd7);
always @* if (f_accept) assume(sp_isa_legal(f_insn, FUNCS != 0));

localparam integer CW = 5 * SP_W;                  // cfg register file bits
wire [CW-1:0] f_cfg_rtl = {r_kh, r_atanh1, r_kc, r_atan1, r_atan0};
always @* assert(GUARD == SP_G && W == SP_W && N_PE == SP_NPE && N_LIN == SP_NLIN);

// everything that describes an instruction in progress (all registers except
// the one-cycle pulses e_start and done)
// (state is 4 bits; the pipeline registers q_* are written only in the
// capture cycles and read in the cycle after, so they are included too)
wire [146+10*SP_W-1:0] f_istate = {state, busy, rd, flags, sat2, op, oh, op_rs1, op_rs2, quadrant, zero_vec, pass,
                                   kexp, neg, t_a, t_b, e_mode, e_dir, e_x, e_y, e_z, f_cfg_rtl};
wire [10*SP_W+85-1:0] f_qstate = {q_va, q_vb, q_na, q_nb, q_quad, q_thm, q_xt, q_xk, q_lne,
                                   q_scv, q_sce, q_kl, q_sc, q_van, q_vbn, q_psin, q_pcos};
// the extra capture registers
wire [3*SP_W+111-1:0] f_q2state = {q_za, q_zb, q_th0, q_hsum, q_kl2, q_rx, q_ry, q_rz, q_rs, q_rc, q_rl,
                                   q_sx, q_sy, q_sz, q_ss, q_sc_, q_sl};

// cfg semantics: rd = old register value (zero-extended); write rs1[SP_W-1:0]
// unless rs2[3] (read-only)
function [CW+31:0] f_cfg_exec(input [CW-1:0] cfg, input [31:0] v, input [31:0] sel);  // {new cfg, rd}
    reg [CW-1:0] c;
    reg [31:0] old;
    begin
        c = cfg;
        old = 0;
        if (sel[2:0] <= 3'd4) old[SP_W-1:0] = cfg[sel[2:0]*SP_W +: SP_W];
        if (!sel[3] && sel[2:0] <= 3'd4) c[sel[2:0]*SP_W +: SP_W] = v[SP_W-1:0];
        f_cfg_exec = {c, old};
    end
endfunction

`ifdef XC_CORE_A
// =====================================================================
// F3a: control invariants (k-induction)
// =====================================================================
always @* if (!f_past) assume(!rstn);

always @* if (f_past) begin
    assert(state <= S_CFG);                  // S_PRE1, S_MID1, S_CFG
    assert(busy == (state != S_IDLE));
    // engine handshake: one run at a time, only from S_RUN
    if (e_start)          assert(state == S_RUN && !e_busy && !e_done);
    if (e_busy)           assert(state == S_RUN && !e_start && !e_done);
    if (e_done)           assert(state == S_RUN);
    if (state == S_RUN)   assert(e_start || e_busy || e_done);
    // clean idle
    if (state == S_IDLE)  assert(!e_start && !e_busy && !e_done);
    if (done)             assert(state == S_IDLE);
    // the one-hot decode matches op while an instruction runs
    if (state != S_IDLE)  assert(oh == (20'd1 << op));
    // exact unit: started only from idle, runs only in S_XRUN
    if (x_start)          assert(state == S_IDLE);
    if (x_busy || x_done) assert(state == S_XRUN);
    if (state == S_XRUN)  assert(x_busy || x_done);
    if (state == S_IDLE)  assert(!x_busy && !x_done);
    if (state == S_XRUN)  assert(!e_start && !e_busy && !e_done);
end

always @(posedge clk) if (f_past && $past(f_past) && $past(rstn) && rstn) begin
    // stutter: waiting for the engine, or idling, changes no instruction state
    if ($past(state == S_RUN && !e_done))  assert(f_istate == $past(f_istate) && f_qstate == $past(f_qstate) && f_q2state == $past(f_q2state));
    if ($past(state == S_XRUN && !x_done)) assert(f_istate == $past(f_istate) && f_qstate == $past(f_qstate) && f_q2state == $past(f_q2state));
    if ($past(state == S_IDLE && !start))  assert(f_istate == $past(f_istate) && f_qstate == $past(f_qstate) && f_q2state == $past(f_q2state));
    // cfg registers change only by cfg
    if (!$past(state == S_CFG))            assert(f_cfg_rtl == $past(f_cfg_rtl));   // written in S_CFG
    // contract used by the PCPI wrapper proof (F1)
    if ($past(f_accept) && !$past(f_is_cfg)) assert(busy && !done);
    // cfg is busy for one cycle (S_CFG), done as busy falls
    if ($past(f_accept) &&  $past(f_is_cfg)) assert(busy && !done && state == S_CFG);
    if ($past(state == S_CFG))             assert(done && !busy);
    if (state == S_CFG)                    assert($past(f_accept && f_is_cfg));
    if (done) assert($past(state == S_DONE) || $past(state == S_CFG));
    if ($past(state == S_DONE)) assert(done && !busy);
    // a non-cfg run keeps busy high for at least 2 cycles (S_PREP, ..., S_DONE)
    if ($past(state == S_DONE) && $past(f_past, 2)) assert($past(busy, 2));
end
`endif

`ifdef XC_CORE_B
// =====================================================================
// F3b: one instruction from an arbitrary clean idle state (BMC)
// =====================================================================
always @* begin
    assume(rstn);
    if (!f_past) begin
        assume(state == S_IDLE && !busy && !done && !e_start && !e_busy && !e_done);
        assume(start);                 // the instruction under test, accepted in cycle 0
        assume(((FUNCS != 0) ? {funct7[1:0], funct3} : {2'b00, funct3}) == `XC_CORE_B_OP);
    end else if (!busy)
        assume(!start);                // no second instruction in this trace
end

reg [4:0]  f_op;
reg [31:0] f_rs1, f_rs2;
reg        f_cfgop;
reg [CW-1:0] f_cfg;                    // cfg seen by the instruction
reg [CW+31:0] f_cfgx;                  // {cfg after, rd} for a cfg instruction
reg [1:0]  f_k;
reg [3*SP_W-1:0] f_e1, f_e2, f_e3;
reg        f_open;
reg [5:0]  f_cyc;

always @(posedge clk) begin
    if (!f_past) begin
        f_op    <= (FUNCS != 0) ? {funct7[1:0], funct3} : {2'b00, funct3};
        f_rs1   <= rs1;
        f_rs2   <= rs2;
        f_cfgop <= f_is_cfg;
        f_cfg   <= f_cfg_rtl;
        f_cfgx  <= f_cfg_exec(f_cfg_rtl, rs1, rs2);
        f_k     <= 2'd0;
        f_open  <= 1'b1;
        f_cyc   <= 6'd0;
    end else begin
        if (f_cyc != 6'h3f) f_cyc <= f_cyc + 6'd1;
        if (e_done) begin
            case (f_k)
                2'd0: f_e1 <= {o_x, o_y, o_z};
                2'd1: f_e2 <= {o_x, o_y, o_z};
                default: f_e3 <= {o_x, o_y, o_z};
            endcase
            f_k <= f_k + 2'd1;
        end
        if (done) f_open <= 1'b0;
    end
end

// The opcode is passed as a literal so the spec elaborates only this
// instruction's branch (one SBY task per instruction).
always @* if (f_past) assert(f_op == `XC_CORE_B_OP);
wire [SP_AW-1:0] f_act = sp_alg(5'd`XC_CORE_B_OP, f_rs1, f_rs2, f_cfg, f_k, f_e1, f_e2, f_e3);
wire [1:0]       f_kind = f_act[SP_AW-1 -: 2];
wire [1:0]       f_mode = f_act[SP_AW-3 -: 2];
wire [1:0]       f_dir  = f_act[SP_AW-5 -: 2];
wire [SP_W-1:0]  f_ax   = f_act[32+3*SP_W-1 -: SP_W];
wire [SP_W-1:0]  f_ay   = f_act[32+2*SP_W-1 -: SP_W];
wire [SP_W-1:0]  f_az   = f_act[32+SP_W-1 -: SP_W];
wire [31:0]      f_ard  = f_act[31:0];

wire [1:0]       f_afl  = f_act[33:32];          // flags {INV, SAT}

// sqrt, mul and div run on the exact unit (here its contract model,
// formal/models/xc_exact_abstract.v: any result, any flags). The core must
// start it in the accepting cycle with the instruction's op and operands, and
// return its rd (sign-extended) and flags; the unit's values are checked
// exhaustively (formal/exhaustive/exact.cpp), its contract by F6.
localparam F_XOP = (FUNCS != 0) && ((`XC_CORE_B_OP == 15) || (`XC_CORE_B_OP == 16) || (`XC_CORE_B_OP == 17));
localparam [1:0] F_XCODE = (`XC_CORE_B_OP == 16) ? 2'd0 : (`XC_CORE_B_OP == 17) ? 2'd1 : 2'd2;
reg [15:0] f_xrd; reg [1:0] f_xfl; reg f_xseen;
always @(posedge clk) begin
    if (!f_past) f_xseen <= 1'b0;
    if (x_done) begin f_xrd <= x_rd; f_xfl <= x_flags; f_xseen <= 1'b1; end
end
always @* if (!f_past) begin
    assert(x_start == F_XOP);
    if (F_XOP) assert(x_opc == F_XCODE);            // (a, b are wired to rs1[15:0], rs2[15:0])
end
always @* if (f_past) assert(!x_start);           // one run per instruction

always @* if (f_past) begin
    // every engine launch is the one the algorithm prescribes
    if (e_start) begin
        assert(f_open && !f_cfgop);
        assert(f_kind == SP_LAUNCH);
        assert(e_mode == f_mode && e_dir == f_dir);
        assert(e_x == f_ax && e_y == f_ay && e_z == f_az);
    end
    // the result is the one the algorithm prescribes
    if (done) begin
        assert(f_open);
        if (f_cfgop)
            assert(rd == f_cfgx[31:0] && flags == 2'b00);
        else if (F_XOP)
            assert(f_xseen && rd == sp_sext(f_xrd) && flags == f_xfl);
        else
            assert(f_kind == SP_FINISH && rd == f_ard && flags == f_afl);
    end
    if (F_XOP && e_start) assert(1'b0);           // no engine pass for sqrt, mul, div
    // cfg registers: updated by cfg only
    if (!f_open && f_cfgop) assert(f_cfg_rtl == f_cfgx[CW+31:32]);
    if (!f_cfgop)           assert(f_cfg_rtl == f_cfg);
    // completes within a bounded number of cycles
    assert(!f_open || f_cyc < `XC_CORE_B_MAXCYC);
    // nothing happens after the result
    if (!f_open) assert(!e_start && !done && !busy);
end

// reachability: the instruction finishes after its longest pass sequence
always @* if (f_past && done && !f_cfgop) cover(F_XOP ? f_xseen : (f_kind == SP_FINISH && f_k == `XC_CORE_B_COVER_K));
`endif
