// ttsky_top_props.vh — injected into the taped-out top_CORDIC_Engine_v1
// (formal/tools/inject.sh), F4b. Used with formal/tb/fv_silicon.sv, which
// drives one transaction after reset with held inputs, angle in [0, 2*pi).
//
// Theorem F4b (complete BMC over one transaction): the ttsky25a top
//   - starts its engine on (in_x, in_y, a) with {q, a} = sp_quad(in_alpha),
//   - feeds iteration k the angle sp_angle(circular, k, in_atan_0, 0x0758, -),
//     i.e. in_atan_0, 1880, 1003, 510, 256, 2^-k ... (dynamic_atan's values)
//   - outputs {sin, cos} = sp_unquad(q, engine x, engine y).
// With F4a: {out_sintheta, out_costheta} = sp_unquad(q, sp_step^13(...)), the
// specification Xcordic's cordic.rot implements (F2, F3) when atan1 = 0x0758.

`include "xcordic_spec.vh"

reg        f_past = 1'b0;
reg        f_txn = 1'b0;           // a transaction has been issued
reg [15:0] f_alpha;
reg        f_eng = 1'b0;           // engine iterations in progress
reg [4:0]  f_j;                    // engine iteration index
reg        f_eng_done = 1'b0;

always @(posedge i_clk) begin
    f_past <= 1'b1;
    if (i_valid_in) begin
        f_txn <= 1'b1;
        f_alpha <= in_alpha;
    end
    if (r_quadrant_valid && f_txn) begin          // ignores power-up garbage (see fv_silicon.sv)
        f_eng <= 1'b1;
        f_j <= 5'd1;
    end else if (f_eng && f_j != N_PE)
        f_j <= f_j + 5'd1;
    if (w_o_valid) begin
        f_eng <= 1'b0;
        f_eng_done <= 1'b1;
    end
end

wire [17:0] f_qa  = sp_quad(f_alpha);
wire        f_start = r_quadrant_valid && f_txn;
wire [4:0]  f_k   = f_start ? 5'd0 : f_j;              // iteration in this cycle

always @* if (f_past && i_rst_n && f_txn) begin
    // pre-processing: quadrant and reduced angle at engine start
    if (f_start) assert(quadrant == f_qa[17:16] && r_i_alpha2 == f_qa[15:0]);
    // ROM-less angle feed, one value per iteration
    if ((f_start || f_eng) && f_k < N_PE)
        assert(w_atan == sp_angle(2'd0, f_k, in_atan_0, 16'h0758, 16'd0));
    // the quadrant used by the post-processing is the transaction's
    if (w_o_valid) assert(w_quadrant == f_qa[17:16]);
end

always @(posedge i_clk) if (f_past && i_rst_n && f_txn && $past(w_o_valid))
    assert(o_valid_out &&
           {out_sintheta, out_costheta} == sp_unquad(f_qa[17:16], $past(w_costheta), $past(w_sintheta)));
