// xc_exact_props.vh — included in xc_exact when XC_FV_EXACT is defined. F6a.
//
// Theorem F6a (unbounded, k-induction from reset): the unit keeps the contract
// formal/models/xc_exact_abstract.v states, which the core proof F3 assumes:
//   - busy rises in the cycle after an accepted start (start while busy is ignored)
//   - done pulses exactly as busy falls, once per accepted start
//   - the run takes 2 .. 22 cycles: 21 (mul), 22 (div), 20 (sqrt) cycles from
//     the start to done, 3 or 4 for the special cases (div by 0, div overflow,
//     sqrt of a negative argument)
//   - rd and flags change only while busy (they hold the last result while idle)
// F6b (formal/tb/fv_exact_miter.sv) shows the result depends only on (op, a, b);
// the values themselves are checked for every operand by formal/exhaustive/exact.cpp.

`ifdef XC_FV_EXACT_MITER
// F6b (fv_exact_miter.sv): this copy starts idle, every other register free
reg f_first = 1'b1;
always @(posedge clk) f_first <= 1'b0;
always @* if (f_first) assume(st == X_IDLE && !busy);
assign fv_st = {st, xop, ra, rb, neg, X, Q, R, cnt, busy};
`else
reg f_past = 1'b0;
always @(posedge clk) f_past <= 1'b1;
always @* if (!f_past) assume(!rstn);

wire f_take = rstn && start && !busy;
reg  [5:0] f_lat;                                // cycles since the accepted start
always @(posedge clk)
    if (f_take) f_lat <= 6'd1;
    else if (busy && f_lat != 6'h3f) f_lat <= f_lat + 6'd1;

function [4:0] f_steps(input [1:0] o);
    f_steps = (o == X_MUL) ? 5'd16 : (o == X_DIV) ? 5'd17 : 5'd15;
endfunction

always @* if (f_past && rstn) begin
    assert(st <= X_END);
    assert(busy == (st != X_IDLE));
    if (done) assert(!busy);
    // inductive invariant: where the run is, in cycles since the start
    if (st == X_ABS)  assert(f_lat == 6'd1);
    if (st == X_CHK)  assert(f_lat == 6'd2);
    if (st == X_ITER) assert(cnt >= 5'd1 && cnt <= f_steps(xop) && f_lat == 6'd3 + f_steps(xop) - cnt);
    if (st == X_RND)  assert(f_lat == 6'd3 + f_steps(xop));
    if (st == X_OUT)  assert(f_lat == 6'd4 + f_steps(xop));
    if (st == X_END)  assert(f_lat == 6'd2 || f_lat == 6'd3 || f_lat == 6'd5 + f_steps(xop));
    if (st != X_IDLE) assert(f_lat >= 6'd1 && f_lat <= 6'd22);
end

always @(posedge clk) if (f_past && $past(f_past) && rstn && $past(rstn)) begin
    // busy from the cycle after an accepted start
    if ($past(f_take)) assert(busy && !done);
    // done exactly when busy falls
    assert(done == ($past(busy) && !busy));
    // 3 .. 23 cycles from the start cycle to done (2 .. 22 busy cycles)
    if (done) assert($past(f_lat) >= 6'd2 && $past(f_lat) <= 6'd22);
    // rd, flags hold while idle
    if (!$past(busy)) assert(rd == $past(rd) && flags == $past(flags));
end

// reachability: each operation's normal path, and the special cases
reg [1:0] f_op_run;
always @(posedge clk) if (f_take) f_op_run <= op;
always @* if (f_past && rstn && done) begin
    cover(f_op_run == X_MUL);
    cover(f_op_run == X_DIV && flags == 2'b00);
    cover(f_op_run == X_DIV && flags == 2'b01);
    cover(f_op_run == X_DIV && flags == 2'b10);
    cover(f_op_run == X_SQRT && flags == 2'b00);
    cover(f_op_run == X_SQRT && flags == 2'b10);
end
`endif
