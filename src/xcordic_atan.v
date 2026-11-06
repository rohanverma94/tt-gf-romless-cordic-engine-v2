// xcordic_atan.v — ROM-less micro-angle generator, three modes
//
// Generalizes dynamic_atan.v from ttsky-romless-cordic-engine. Same hybrid
// scheme, now one function of (mode, iteration) instead of a lockstep FSM.
// Values have F = DATA_WIDTH - 4 fraction bits (S3.F).
//
//   circular   s = 0      atan0 register   (in_atan_0 on ttsky25a)
//              s = 1      atan1 register   (the Taylor term is 19 codes short
//                                           here; 0x0758 reproduces silicon)
//              s >= 2     2^-s - x^3/3 (+ x^5/5 when GUARD > 0)
//   hyperbolic s = 1      atanh1 register
//              s >= 2     2^-s + x^3/3 (+ x^5/5 when GUARD > 0)
//              sequence   1,2,3,4,4,5,...   repeat at 4, and at 13 when N_PE >= 14
//   linear     s          2^-s
//
// GUARD = 0 (ttsky25a): x^3/3 = 2^-3s (1/4 + 1/16 + 1/64), truncated at F bits.
//   For s >= 5 the cube term shifts out, so this is the silicon table exactly.
// GUARD > 0: the series is formed at F+4 bits with 1/3 ~ 1/4+1/16+1/64+1/256+1/1024
//   and 1/5 ~ 1/8+1/16+1/128+1/256 (x^5 <= 2^-10, so finer terms shift out),
//   then rounded to F bits (worst table error ~1 LSB of F bits, see
//   toolchain/gen_consts.cpp).
//
// xcordic_ashift gives the shift of (mode, iteration);
// xcordic_aval gives the angle of (mode, shift), taking 3s and 5s as inputs so
// a caller can register them. The engine keeps the next iteration's shift,
// 3s and 5s in registers, so its angle path starts at registers (in an earlier
// layout this path, busy -> +1 -> shift -> 3s -> pattern shift -> adds, was the
// second slowest). xcordic_atan (mode, iteration) -> (shift, angle) is the two
// combined, as before; F2 uses it as the reference for the engine's registers.
//
// xcordic_aval in two stages, so the engine can register between them:
// xcordic_aterms gives the shifted series terms of a shift (t_a = 2^-s + x^5/5
// + the rounding bias, t_b = x^3/3, at F+4 bits), xcordic_asum the angle from
// them (t_a -/+ t_b, rounded, or a cfg register / 2^-s). asum(aterms(s)) ==
// aval(s) for every (mode, shift): F2 checks the engine against xcordic_atan.
`timescale 1ns/1ps
`default_nettype none

module xcordic_atan #(
    parameter DATA_WIDTH = 16,
    parameter N_PE = 13,
    parameter GUARD = 0
)(
    input  wire [1:0]                   i_mode,     // 0 circ, 1 lin, 2 hyp
    input  wire [4:0]                   i_iter,
    input  wire [DATA_WIDTH-1:0]        i_atan0,
    input  wire [DATA_WIDTH-1:0]        i_atan1,
    input  wire [DATA_WIDTH-1:0]        i_atanh1,
    output wire [4:0]                   o_shift,
    output wire [DATA_WIDTH-1:0]        o_angle
);
    xcordic_ashift #(.N_PE(N_PE)) u_s (.i_mode(i_mode), .i_iter(i_iter), .o_shift(o_shift));
    xcordic_aval #(.DATA_WIDTH(DATA_WIDTH), .GUARD(GUARD)) u_v (
        .i_mode(i_mode), .i_shift(o_shift), .i_s3(8'd3 * {3'd0, o_shift}), .i_s5(8'd5 * {3'd0, o_shift}),
        .i_atan0(i_atan0), .i_atan1(i_atan1), .i_atanh1(i_atanh1), .o_angle(o_angle));
endmodule

// the shift of iteration i_iter
module xcordic_ashift #(
    parameter N_PE = 13
)(
    input  wire [1:0] i_mode,
    input  wire [4:0] i_iter,
    output wire [4:0] o_shift
);
    localparam [1:0] M_HYP = 2'd2;
    localparam REP13 = (N_PE >= 14);
    // hyperbolic: shift = iter + 1, minus one after each repeated stage (4, 13)
    wire [4:0] s_hyp = i_iter + 5'd1 - {4'd0, (i_iter >= 5'd4)}
                                     - {4'd0, (REP13 && i_iter >= 5'd14)};
    assign o_shift = (i_mode == M_HYP) ? s_hyp : i_iter;
endmodule

// the angle for shift s (i_s3 = 3s, i_s5 = 5s)
module xcordic_aval #(
    parameter DATA_WIDTH = 16,
    parameter GUARD = 0
)(
    input  wire [1:0]                   i_mode,
    input  wire [4:0]                   i_shift,
    input  wire [7:0]                   i_s3,
    input  wire [7:0]                   i_s5,
    input  wire [DATA_WIDTH-1:0]        i_atan0,
    input  wire [DATA_WIDTH-1:0]        i_atan1,
    input  wire [DATA_WIDTH-1:0]        i_atanh1,
    output reg  [DATA_WIDTH-1:0]        o_angle
);
    localparam [1:0] M_CIRC = 2'd0, M_LIN = 2'd1, M_HYP = 2'd2;
    localparam integer F  = DATA_WIDTH - 4;
    localparam integer X  = (GUARD > 0) ? 4 : 0;        // extra internal fraction bits
    localparam integer IW = DATA_WIDTH + X;

    wire [DATA_WIDTH-1:0] one_f = {{(DATA_WIDTH-1){1'b0}}, 1'b1} << F;
    wire [IW-1:0]         one_i = {{(IW-1){1'b0}}, 1'b1} << (F + X);
    wire [IW-1:0]         p1    = one_i >> i_shift;
    // x^3/3 = (p3 >> 2) + (p3 >> 4) + ... with p3 = one_i >> 3s, a single set
    // bit: the terms never overlap, so their sum is the constant pattern
    // (one_i >> 2) | (one_i >> 4) | ... shifted right by 3s (logical shifts
    // compose, and drop the same low bits). Same bits as the sum, no adders
    // (this was the generator's slowest path). x^5/5 likewise.
    wire [IW-1:0]         pat3  = (GUARD > 0)
        ? (one_i >> 2) | (one_i >> 4) | (one_i >> 6) | (one_i >> 8) | (one_i >> 10)
        : (one_i >> 2) | (one_i >> 4) | (one_i >> 6);
    wire [IW-1:0]         pat5  = (one_i >> 3) | (one_i >> 4) | (one_i >> 7) | (one_i >> 8);
    wire [IW-1:0]         third = pat3 >> i_s3;
    wire [IW-1:0]         fifth = (GUARD > 0) ? (pat5 >> i_s5) : {IW{1'b0}};
    wire [IW-1:0]         t_circ = p1 - third + fifth;
    wire [IW-1:0]         t_hyp  = p1 + third + fifth;
    wire [IW-1:0]         r_bias = (X > 0) ? ({{(IW-1){1'b0}}, 1'b1} << (X - 1)) : {IW{1'b0}};
    wire [IW-1:0]         a_circ = (t_circ + r_bias) >> X;
    wire [IW-1:0]         a_hyp  = (t_hyp + r_bias) >> X;

    always @* begin
        case (i_mode)
            M_LIN: o_angle = one_f >> i_shift;
            M_HYP: begin
                if (i_shift == 5'd1)      o_angle = i_atanh1;
                else                      o_angle = a_hyp[DATA_WIDTH-1:0];
            end
            default: begin
                if (i_shift == 5'd0)      o_angle = i_atan0;
                else if (i_shift == 5'd1) o_angle = i_atan1;
                else                      o_angle = a_circ[DATA_WIDTH-1:0];
            end
        endcase
    end
endmodule

// Stage 1: the series terms of shift s (i_s3 = 3s, i_s5 = 5s)
module xcordic_aterms #(
    parameter DATA_WIDTH = 16,
    parameter GUARD = 0
)(
    input  wire [4:0]                   i_shift,
    input  wire [7:0]                   i_s3,
    input  wire [7:0]                   i_s5,
    output wire [DATA_WIDTH+((GUARD > 0) ? 4 : 0)-1:0] o_ta,   // 2^-s + x^5/5 + rounding bias
    output wire [DATA_WIDTH+((GUARD > 0) ? 4 : 0)-1:0] o_tb    // x^3/3
);
    localparam integer F  = DATA_WIDTH - 4;
    localparam integer X  = (GUARD > 0) ? 4 : 0;
    localparam integer IW = DATA_WIDTH + X;
    wire [IW-1:0] one_i = {{(IW-1){1'b0}}, 1'b1} << (F + X);
    wire [IW-1:0] p1    = one_i >> i_shift;
    wire [IW-1:0] pat3  = (GUARD > 0)
        ? (one_i >> 2) | (one_i >> 4) | (one_i >> 6) | (one_i >> 8) | (one_i >> 10)
        : (one_i >> 2) | (one_i >> 4) | (one_i >> 6);
    wire [IW-1:0] pat5  = (one_i >> 3) | (one_i >> 4) | (one_i >> 7) | (one_i >> 8);
    wire [IW-1:0] fifth = (GUARD > 0) ? (pat5 >> i_s5) : {IW{1'b0}};
    wire [IW-1:0] r_bias = (X > 0) ? ({{(IW-1){1'b0}}, 1'b1} << (X - 1)) : {IW{1'b0}};
    wire [IW-1:0] pf;
    xc_add #(.W(IW)) u_pf (.a(p1), .b(fifth),  .ci(1'b0), .s(pf));
    xc_add #(.W(IW)) u_rb (.a(pf), .b(r_bias), .ci(1'b0), .s(o_ta));
    assign o_tb = pat3 >> i_s3;
endmodule

// Stage 2: the angle of shift s from its terms
module xcordic_asum #(
    parameter DATA_WIDTH = 16,
    parameter GUARD = 0
)(
    input  wire [1:0]                   i_mode,
    input  wire [4:0]                   i_shift,
    input  wire [DATA_WIDTH+((GUARD > 0) ? 4 : 0)-1:0] i_ta,
    input  wire [DATA_WIDTH+((GUARD > 0) ? 4 : 0)-1:0] i_tb,
    input  wire [DATA_WIDTH-1:0]        i_atan0,
    input  wire [DATA_WIDTH-1:0]        i_atan1,
    input  wire [DATA_WIDTH-1:0]        i_atanh1,
    output reg  [DATA_WIDTH-1:0]        o_angle
);
    localparam [1:0] M_CIRC = 2'd0, M_LIN = 2'd1, M_HYP = 2'd2;
    localparam integer F  = DATA_WIDTH - 4;
    localparam integer X  = (GUARD > 0) ? 4 : 0;
    localparam integer IW = DATA_WIDTH + X;
    wire [DATA_WIDTH-1:0] one_f = {{(DATA_WIDTH-1){1'b0}}, 1'b1} << F;
    wire [IW-1:0] t_circ, t_hyp;
    xc_add #(.W(IW)) u_c (.a(i_ta), .b(~i_tb), .ci(1'b1), .s(t_circ));   // 2^-s - x^3/3 + x^5/5 + bias
    xc_add #(.W(IW)) u_h (.a(i_ta), .b(i_tb),  .ci(1'b0), .s(t_hyp));    // 2^-s + x^3/3 + x^5/5 + bias
    wire [IW-1:0] a_circ = t_circ >> X;
    wire [IW-1:0] a_hyp  = t_hyp >> X;
    always @* begin
        case (i_mode)
            M_LIN: o_angle = one_f >> i_shift;
            M_HYP: begin
                if (i_shift == 5'd1)      o_angle = i_atanh1;
                else                      o_angle = a_hyp[DATA_WIDTH-1:0];
            end
            default: begin
                if (i_shift == 5'd0)      o_angle = i_atan0;
                else if (i_shift == 5'd1) o_angle = i_atan1;
                else                      o_angle = a_circ[DATA_WIDTH-1:0];
            end
        endcase
    end
endmodule

`default_nettype wire
