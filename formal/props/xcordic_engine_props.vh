// xcordic_engine_props.vh — included in xcordic_engine when XC_FV_ENGINE is defined.
//
// Theorem F2 (engine): for every start command (mode, dir, x, y, z) with legal
// mode/dir and micro-angle registers held during the run,
//   - the run takes exactly sp_niter(mode) cycles, then o_busy falls and o_done
//     pulses in the same cycle;
//   - at o_done, (o_x, o_y, o_z) = sp_step applied sp_niter(mode) times;
//   - while idle the outputs hold their value until the next accepted start;
//   - a start while busy is ignored.
// Method: a shadow copy of the recurrence written with the spec functions runs
// in lockstep; equality with the RTL registers is the inductive invariant.
// Proved for each datapath: `XC_GUARD selects the spec, chparam the RTL.

`include "xcordic_spec.vh"

reg f_past = 1'b0;
always @(posedge i_clk) f_past <= 1'b1;
always @* if (!f_past) assume(!i_rst_n);

wire f_accept = i_rst_n && i_start && !o_busy;

// environment (xcordic_core): only legal commands
always @* if (f_accept) begin
    assume(i_mode != 2'd3);
    assume(i_dir  != 2'd3 || i_mode == 2'd1);   // dir 3: linear product pass
end

// environment: micro-angle registers do not change during a run
reg [SP_W-1:0] f_atan0, f_atan1, f_atanh1;
always @(posedge i_clk) if (f_accept) {f_atan0, f_atan1, f_atanh1} <= {i_atan0, i_atan1, i_atanh1};
always @* if (o_busy) assume(i_atan0 == f_atan0 && i_atan1 == f_atan1 && i_atanh1 == f_atanh1);

// shadow: the specified recurrence
reg        s_busy;
reg [1:0]  s_mode, s_dir;
reg [4:0]  s_k;
reg [SP_W-1:0] s_x, s_y, s_z;
always @(posedge i_clk) begin
    if (!i_rst_n) begin
        s_busy <= 1'b0;
        s_x <= 0; s_y <= 0; s_z <= 0;
    end else if (!s_busy) begin
        if (i_start) begin
            s_busy <= 1'b1;
            s_k <= 5'd0;
            s_mode <= i_mode; s_dir <= i_dir;
            s_x <= i_x; s_y <= i_y; s_z <= i_z;
        end
    end else begin
        {s_x, s_y, s_z} <= sp_step(s_mode, s_dir, s_x, s_y, s_z, s_k, f_atan0, f_atan1, f_atanh1);
        s_k <= s_k + 5'd1;
        if (s_k == sp_niter(s_mode) - 5'd1) s_busy <= 1'b0;
    end
end

// the angle generator as the spec'd function of (mode, iteration): checks the
// one-iteration lookahead registers
wire [4:0]      f_g_shift;
wire [SP_W-1:0] f_g_angle;
xcordic_atan #(.DATA_WIDTH(DATA_WIDTH), .N_PE(N_PE), .GUARD(GUARD)) f_atan (
    .i_mode(mode), .i_iter(iter), .i_atan0(f_atan0), .i_atan1(f_atan1), .i_atanh1(f_atanh1),
    .o_shift(f_g_shift), .o_angle(f_g_angle));
// the shifts of the next two iterations, and the next one's series terms
wire [4:0] f_n_shift, f_n2_shift;
xcordic_ashift #(.N_PE(N_PE)) f_ash  (.i_mode(mode), .i_iter(iter + 5'd1), .o_shift(f_n_shift));
xcordic_ashift #(.N_PE(N_PE)) f_ash2 (.i_mode(mode), .i_iter(iter + 5'd2), .o_shift(f_n2_shift));
wire [IW-1:0] f_ta, f_tb;
xcordic_aterms #(.DATA_WIDTH(DATA_WIDTH), .GUARD(GUARD)) f_at (.i_shift(n_s),
    .i_s3(8'd3 * {3'd0, n_s}), .i_s5(8'd5 * {3'd0, n_s}), .o_ta(f_ta), .o_tb(f_tb));

// cycles since the accepted start
reg [5:0] f_lat;
always @(posedge i_clk) f_lat <= f_accept ? 6'd1 : (o_busy ? f_lat + 6'd1 : f_lat);

always @* if (f_past) begin
    // the RTL instance is the datapath the spec describes
    assert(DATA_WIDTH == SP_W && GUARD == SP_G && N_PE == SP_NPE && N_LIN == SP_NLIN);
    // the run is the specified recurrence, step for step
    assert(o_busy == s_busy);
    assert(o_x == s_x && o_y == s_y && o_z == s_z);
    if (o_busy) begin
        assert(iter == s_k && mode == s_mode && dir == s_dir);
        // the lookahead registers hold the generator's value for this iteration
        assert(shift == f_g_shift && angle == f_g_angle);
        // the next iteration's shift and series terms, the one after's shift, 3x and 5x it
        assert(n_s == f_n_shift && t_a == f_ta && t_b == f_tb);
        assert(n2 == f_n2_shift && n2_3 == 8'd3 * {3'd0, n2} && n2_5 == 8'd5 * {3'd0, n2});
        assert(s_k < sp_niter(s_mode));
        assert(f_lat == {1'b0, s_k} + 6'd1);
        assert(s_mode != 2'd3 && (s_dir != 2'd3 || s_mode == 2'd1));
    end
end

always @(posedge i_clk) if (f_past) begin
    // done pulses exactly when a run ends, after sp_niter(mode) iterations
    if (i_rst_n && $past(i_rst_n))
        assert(o_done == ($past(o_busy) && !o_busy));
    if (o_done)
        assert(f_lat == {1'b0, sp_niter(mode)} + 6'd1);   // done in cycle niter+1 after the accept cycle
    // outputs hold while idle and no start is accepted
    if ($past(i_rst_n) && i_rst_n && $past(!o_busy && !i_start))
        assert(o_x == $past(o_x) && o_y == $past(o_y) && o_z == $past(o_z));
end

// reachability: each kind of run completes
always @* if (f_past) begin
    cover(o_done && mode == 2'd0 && dir == 2'd0);
    cover(o_done && mode == 2'd1 && dir == 2'd2);
    cover(o_done && mode == 2'd1 && dir == 2'd3);
    cover(o_done && mode == 2'd2 && dir == 2'd1);
end
