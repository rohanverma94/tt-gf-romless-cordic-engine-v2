// cordic_top_contract.v — the transaction contract of top_CORDIC_Engine_v1
// (replaces it in O2): every i_valid_in is answered by exactly one o_valid_out
// pulse 2..MAXLAT cycles later; the results are arbitrary (F4 proves what they are).
`default_nettype none
module top_CORDIC_Engine_v1 #(parameter DATA_WIDTH = 16, parameter N_PE = 13) (
    input  wire i_clk, input wire i_rst_n,
    input  wire [DATA_WIDTH-1:0] in_x, in_y, in_alpha, in_atan_0,
    input  wire i_valid_in,
    output reg  [DATA_WIDTH-1:0] out_costheta, out_sintheta, out_alpha,
    output reg  o_valid_out
);
    (* anyseq *) wire f_done;
    (* anyseq *) wire [DATA_WIDTH-1:0] f_c, f_s, f_a;
    reg busy;
    reg [5:0] lat;
    always @(posedge i_clk) begin
        o_valid_out <= 0;
        if (!i_rst_n) begin busy <= 0; lat <= 0; end
        else if (!busy) begin
            if (i_valid_in) begin busy <= 1; lat <= 1; end
        end else begin
            lat <= lat + 1;
            if ((f_done && lat >= 2) || lat == `CORDIC_MAXLAT) begin
                busy <= 0; o_valid_out <= 1;
                out_costheta <= f_c; out_sintheta <= f_s; out_alpha <= f_a;
            end
        end
    end
    // one transaction at a time (the FSM never overlaps them; asserted in O2)
endmodule
`default_nettype wire
