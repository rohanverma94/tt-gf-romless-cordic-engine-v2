// F7b: the two-stage angle generator (aterms, asum) equals xcordic_aval for every (mode, shift)
module aval_eq #(parameter DATA_WIDTH = 20, parameter GUARD = 4) (
    input [1:0] mode, input [4:0] s, input [DATA_WIDTH-1:0] a0, a1, ah, output ok);
    localparam integer IW = DATA_WIDTH + ((GUARD > 0) ? 4 : 0);
    wire [DATA_WIDTH-1:0] ref_a, new_a;
    wire [IW-1:0] ta, tb;
    xcordic_aval  #(.DATA_WIDTH(DATA_WIDTH), .GUARD(GUARD)) r (.i_mode(mode), .i_shift(s), .i_s3(8'd3 * {3'd0, s}), .i_s5(8'd5 * {3'd0, s}),
        .i_atan0(a0), .i_atan1(a1), .i_atanh1(ah), .o_angle(ref_a));
    xcordic_aterms #(.DATA_WIDTH(DATA_WIDTH), .GUARD(GUARD)) t (.i_shift(s), .i_s3(8'd3 * {3'd0, s}), .i_s5(8'd5 * {3'd0, s}), .o_ta(ta), .o_tb(tb));
    xcordic_asum  #(.DATA_WIDTH(DATA_WIDTH), .GUARD(GUARD)) u (.i_mode(mode), .i_shift(s), .i_ta(ta), .i_tb(tb),
        .i_atan0(a0), .i_atan1(a1), .i_atanh1(ah), .o_angle(new_a));
    assign ok = (ref_a == new_a);
endmodule
