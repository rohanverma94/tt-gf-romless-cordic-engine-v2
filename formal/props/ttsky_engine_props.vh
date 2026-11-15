// ttsky_engine_props.vh — injected into the taped-out CORDIC_Engine_v1
// (formal/tools/inject.sh), F4a.
//
// Theorem F4a (unbounded, k-induction): every run of the ttsky25a engine
// (DATA_WIDTH = 16, N_PE = 13) is the circular rotation-mode recurrence
//   v_{k+1} = sp_microrot(circular, rotate, v_k, shift = k, alpha = in_atan@k)
// for k = 0 .. N_PE-1, where in_atan@k is the in_atan input in the cycle of
// iteration k, starting from v_0 = (in_x, in_y, in_alpha) at valid_in; and
// {out_x, out_y, out_alpha} = v_N_PE at valid_out.

`include "xcordic_spec.vh"

reg f_past = 1'b0;
always @(posedge i_clk) f_past <= 1'b1;
always @* if (!f_past) assume(!i_rst_n);

reg [15:0] s_x, s_y, s_z;
always @(posedge i_clk) begin
    if (!i_rst_n) begin
        s_x <= 16'd0; s_y <= 16'd0; s_z <= 16'd0;
    end else if (state == 1'b0) begin
        if (valid_in)
            {s_x, s_y, s_z} <= sp_microrot(2'd0, 2'd0, in_x, in_y, in_alpha, 5'd0, in_atan);
    end else if (count != N_PE)
        {s_x, s_y, s_z} <= sp_microrot(2'd0, 2'd0, s_x, s_y, s_z, count[4:0], in_atan);
end

always @* if (f_past && i_rst_n) begin
    assert(DATA_WIDTH == 16);
    if (state == 1'b0) assert(count == 0);
    else begin
        assert(count >= 1 && count <= N_PE);
        assert(r_x == s_x && r_y == s_y && r_alpha == s_z);
    end
    if (valid_out) assert(out_x == s_x && out_y == s_y && out_alpha == s_z);
end

always @* if (f_past && i_rst_n) cover(valid_out);
