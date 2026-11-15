// xc_bist_props.vh — included in xc_bist when XC_FV_BIST is defined. F5.
//
// Environment: the core is xcordic_core_abstract (its start/busy/done contract,
// any rd, F3a proves the real core keeps it); the instruction source starts an
// instruction only when u_busy is low (as xc_frame does, N2).
//
// Theorem F5 (unbounded, k-induction):
//   T  outside a self-test the unit is a wire: the core gets exactly the
//      source's starts (except cordic.bist) and operands, and the source gets
//      the core's busy, done, rd and flags;
//   B  a cordic.bist with N = rs1[15:0], seed rs2 issues exactly N core
//      instructions, the k-th with op = the k-th of 0-6, 8-19 (FUNCS = 0:
//      0-6) cyclically and rs1, rs2 = the next two LFSR values from the seed
//      (0 -> 1); no source start reaches the core meanwhile; its done pulses
//      once, after the N-th result, with rd = the MISR of the N results
//      (and their flags, in bits 31:30) and flags 0;
//   C  to the source it keeps the core's contract (busy from the cycle after
//      the start, done as busy falls, at least 2 busy cycles).
// done, rd and flags to the source are registered (one cycle later, busy
// held for that cycle). T and B are stated on the unregistered values (done_c,
// f_rdc, f_flc: what an unregistered output stage would drive); R states the output stage.

reg f_past = 1'b0;
wire [31:0] f_rdc = bdone ? misr : c_rd;     // the unregistered u_rd, u_flags
wire [1:0]  f_flc = bdone ? 2'b00 : c_flags;
always @(posedge clk) f_past <= 1'b1;
always @* if (!f_past) assume(!rst_n);
always @* if (u_busy) assume(!u_start);     // source contract

function [31:0] f_lstep(input [31:0] v);
    f_lstep = (v >> 1) ^ (v[0] ? 32'h80200003 : 32'd0);
endfunction
function [4:0] f_next_op(input [4:0] op);
    f_next_op = (op == 5'd6) ? ((FUNCS != 0) ? 5'd8 : 5'd0) :
                (op == ((FUNCS != 0) ? 5'd19 : 5'd6)) ? 5'd0 : op + 5'd1;
endfunction

// ---------------- spec of one self-test ----------------
reg        s_act = 1'b0;                     // a self-test is in progress
reg        s_wait = 1'b0;                    // its current core instruction has started
reg [15:0] s_n, s_k;
reg [31:0] s_lfsr, s_misr;
reg [4:0]  s_op;
wire       f_take = rst_n && u_start && !u_busy && (u_funct7 == 7'd2) && (u_funct3 == 3'd4);
always @(posedge clk) begin
    if (!rst_n) begin
        s_act <= 1'b0; s_wait <= 1'b0;
    end else if (f_take) begin
        s_act <= 1'b1; s_wait <= 1'b0;
        s_n <= u_rs1[15:0]; s_k <= 16'd0; s_op <= 5'd0;
        s_lfsr <= (u_rs2 == 32'd0) ? 32'd1 : u_rs2;
        s_misr <= 32'hFFFFFFFF;
    end else if (s_act) begin
        if (c_start && !done_c) begin       // (in the done cycle a start is the source's next)
            s_wait <= 1'b1;
            s_lfsr <= f_lstep(f_lstep(s_lfsr));
        end
        if (c_done && s_wait) begin
            s_wait <= 1'b0;
            s_misr <= f_lstep(s_misr) ^ c_rd ^ {c_flags, 30'd0};   // flags too
            s_k <= s_k + 16'd1;
            s_op <= f_next_op(s_op);
        end
        if (done_c) s_act <= 1'b0;
    end
end

// busy cycles of the self-test, for C
reg [1:0] f_bc;
always @(posedge clk) f_bc <= f_take ? 2'd0 : (u_busy && f_bc != 2'd3) ? f_bc + 2'd1 : f_bc;

always @* if (f_past && rst_n) begin
    // T: transparent outside a self-test
    if (!s_act) begin
        assert(!active && !bdone);
        assert(c_start == (u_start && !((u_funct7 == 7'd2) && (u_funct3 == 3'd4))));
        assert(c_funct7 == u_funct7 && c_funct3 == u_funct3 && c_rs1 == u_rs1 && c_rs2 == u_rs2);
        assert(done_c == c_done && f_rdc == c_rd && f_flc == c_flags && u_busy == (c_busy || done_c));
    end
    // B: the core instructions of a self-test
    if (s_act) begin
        assert(active || bdone);
        assert(u_busy == (active || done_c));
        if (c_start && active) begin
            assert(!s_wait && s_k < s_n);
            assert({c_funct7[1:0], c_funct3} == s_op && c_funct7[6:2] == 5'd0);
            assert(c_rs1 == f_lstep(s_lfsr) && c_rs2 == f_lstep(f_lstep(s_lfsr)));
            assert(s_op != 5'd7 && s_op <= ((FUNCS != 0) ? 5'd19 : 5'd6));
        end
        if (done_c) begin
            assert(!s_wait && s_k == s_n && f_rdc == s_misr && f_flc == 2'b00);
            // the done cycle: the unit is a wire again for the source's next start
            assert(c_start == (u_start && !((u_funct7 == 7'd2) && (u_funct3 == 3'd4))));
            assert(c_funct7 == u_funct7 && c_funct3 == u_funct3 && c_rs1 == u_rs1 && c_rs2 == u_rs2);
        end
        // inductive invariants: the unit's registers are the spec's
        assert(s_op != 5'd7 && s_op <= ((FUNCS != 0) ? 5'd19 : 5'd6));
        if (active) begin
            assert(bn == s_n && bk == s_k && bop == s_op && misr == s_misr);
            assert(lfsr == s_lfsr || (bstart && lfsr == f_lstep(f_lstep(s_lfsr))) ||
                   (s_wait && lfsr == s_lfsr));
            assert((bs == B_RUN) == (s_wait || bstart));
            if (bs == B_RUN && !bstart) assert(c_busy || c_done);
            if (bs != B_RUN) assert(!c_busy && !c_done && !bstart);
            if (bstart) assert(!c_busy && !c_done && brs1 == f_lstep(s_lfsr) && brs2 == f_lstep(f_lstep(s_lfsr)));
            if (s_wait) assert(!bstart && s_k < s_n);
            if (bstart) assert(s_k < s_n);
            assert(s_k <= s_n);
            if (bs == B_END) assert(s_k == s_n);
        end else begin
            assert(bdone && misr == s_misr && s_k == s_n && !s_wait);
        end
        // C: at least 2 busy cycles before done
        if (u_done) assert(f_bc >= 2'd2);
    end
    if (!active) assert(!bstart);
end
// R: the registered output stage, and done as busy falls
always @(posedge clk) if (f_past && $past(f_past) && $past(rst_n) && rst_n) begin
    assert(u_done == $past(done_c));
    if ($past(done_c)) assert(u_rd == $past(f_rdc) && u_flags == $past(f_flc));
    if (u_done) assert(!u_busy && $past(u_busy));
    if ($past(u_busy) && !u_busy) assert(u_done);
end
// reachability: a self-test of 2 instructions completes
always @* cover(f_past && rst_n && s_act && done_c && s_n == 16'd2);
