// fv_silicon.sv — F4: the taped-out ttsky25a datapath (top_CORDIC_Engine_v1,
// DATA_WIDTH = 16, N_PE = 13, unmodified from ttsky-romless-cordic-engine)
// computes the specified rotation:
//
//   for every in_x, in_y, in_atan_0 and every angle 0 <= in_alpha < 2*pi,
//   {out_sintheta, out_costheta} = sp_unquad(q, CORDIC_13(in_x, in_y, a))
//   with micro-angles {in_atan_0, 1880, 1003, 510, 256, 2^-k...}
//
// 1880 (0x0758) is the shift-add Taylor value of atan(0.5) the chip generates.
// Xcordic's cordic.rot / cordic.sincos compute the same function when
// atan1 = 0x0758 (F3 shows the core issues exactly sp_launch_rot/sp_unquad,
// F2 that the engine runs sp_step), so they agree with the silicon bit for bit.
//
// Inputs are held for the whole transaction (as top_fsm does with
// r_spi_rx_data); one transaction from reset, complete BMC.
// Proof structure: F4a (ttsky_engine_props.vh, injected into the engine) and
// F4b (ttsky_top_props.vh, injected into the top); see those files.
`default_nettype none

module fv_silicon (
    input wire clk
);
`include "xcordic_spec.vh"

    (* anyconst *) wire [15:0] in_x, in_y, in_alpha, in_atan_0;
    (* anyseq *)   wire        f_go;

    // Reset held for 4 cycles. Note: diff_valid, quadrant_valid and
    // r_quadrant_valid in the original have no reset and power up arbitrary;
    // they flush after 3 cycles without i_valid_in. A request in the first 3
    // cycles after power-up would collide with a phantom run (top_fsm cannot
    // issue one that early: it first receives 8 SPI bytes).
    reg [2:0] f_rcnt = 3'd0;
    always @(posedge clk) if (f_rcnt != 3'd4) f_rcnt <= f_rcnt + 3'd1;
    wire rst_n = (f_rcnt == 3'd4);
    reg sent = 1'b0;

    wire valid_in = rst_n && f_go && !sent;
    always @(posedge clk) if (valid_in) sent <= 1'b1;

    wire [15:0] out_cos, out_sin, out_alpha;
    wire        valid_out;

    top_CORDIC_Engine_v1 #(.DATA_WIDTH(16), .N_PE(13)) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .in_x(in_x), .in_y(in_y), .in_alpha(in_alpha), .in_atan_0(in_atan_0),
        .i_valid_in(valid_in),
        .out_costheta(out_cos), .out_sintheta(out_sin), .out_alpha(out_alpha),
        .o_valid_out(valid_out)
    );

    // the chip's documented input range: 0 <= angle < 2*pi
    always @* assume($signed(in_alpha) >= 0 && $signed(in_alpha) < SP_TWO_PI);

    // specified result
    function [47:0] f_cordic13(input [15:0] x, input [15:0] y, input [15:0] z);
        reg [47:0] v;
        integer k;
        begin
            v = {x, y, z};
            for (k = 0; k < 13; k = k + 1)
                v = sp_step(2'd0, 2'd0, v[47:32], v[31:16], v[15:0], k[4:0], in_atan_0, 16'h0758, 16'd0);
            f_cordic13 = v;
        end
    endfunction

    wire [17:0] f_qa  = sp_quad(in_alpha);
    wire [47:0] f_eng = f_cordic13(in_x, in_y, f_qa[15:0]);
    wire [31:0] f_sc  = sp_unquad(f_qa[17:16], f_eng[47:32], f_eng[31:16]);

    reg [5:0] f_cyc = 6'd0;
    reg       f_got = 1'b0;
    always @(posedge clk) begin
        if (sent && f_cyc != 6'h3f) f_cyc <= f_cyc + 6'd1;
        if (valid_out) f_got <= 1'b1;
    end

    always @* if (sent) begin
`ifdef FV_SILICON_DIRECT
        // The end-to-end equality in one assertion. Not run by default: the
        // solver must rediscover the 13-stage equivalence without the
        // per-iteration lemmas, which takes hours. F4a + F4b prove the same.
        if (valid_out) assert(out_sin == f_sc[31:16] && out_cos == f_sc[15:0]);
`endif
        assert(f_got || valid_out || f_cyc < 6'd19);     // result within 19 cycles
    end
    always @* cover(valid_out);
endmodule

`default_nettype wire
