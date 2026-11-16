// fv_exact_miter.sv — F6b: a result of xc_exact depends only on (op, a, b).
//
// Two copies of the unit start from arbitrary, different internal states
// (every register free in the first cycle; both idle, out of reset) and get
// the same start, op and operands. Two cycles later every register a run
// depends on (fv_st, a formal-only port) is equal in both, and stays equal;
// so busy, done, rd and flags agree in every cycle that matters, for that run
// and forever after (unbounded, k-induction). Together with the exhaustive
// simulation (which runs the operations back to back from one particular
// history) this covers every history: what a previous operation left behind
// does not change a result.
`default_nettype none
module fv_exact_miter (
    input wire clk,
    input wire start, input wire [1:0] op, input wire [15:0] a, input wire [15:0] b
);
    wire b0, d0, b1, d1; wire [15:0] r0, r1; wire [1:0] f0, f1; wire [95:0] s0, s1;
    xc_exact u0 (.clk(clk), .rstn(1'b1), .start(start), .op(op), .a(a), .b(b),
                 .busy(b0), .done(d0), .rd(r0), .flags(f0), .fv_st(s0));
    xc_exact u1 (.clk(clk), .rstn(1'b1), .start(start), .op(op), .a(a), .b(b),
                 .busy(b1), .done(d1), .rd(r1), .flags(f1), .fv_st(s1));

    reg [1:0] f_cyc = 2'd0;                 // 0, 1, then 2 for good
    always @(posedge clk) if (f_cyc != 2'd2) f_cyc <= f_cyc + 2'd1;
    // both idle at the start (assumed inside each copy, XC_FV_EXACT_MITER),
    // a start in the first cycle, then no other
    always @* if (f_cyc == 2'd0) assume(start);
    always @* if (f_cyc != 2'd0) assume(!start);
    // rd, flags: equal once the run has written them, i.e. from done on
    reg f_rdeq = 1'b0;
    always @(posedge clk) if (d0 && f_cyc != 2'd0) f_rdeq <= 1'b1;
    always @* begin
        if (f_cyc != 2'd0) assert(b0 == b1 && d0 == d1);
        if (f_cyc == 2'd2) assert(s0 == s1);
        if (f_cyc != 2'd0 && (d0 || f_rdeq)) assert(r0 == r1 && f0 == f1);
    end
    always @* cover(d0 && op == 2'd1);
endmodule
`default_nettype wire
