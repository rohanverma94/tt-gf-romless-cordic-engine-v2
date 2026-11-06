// xcordic_engine.v — single-stage iterative CORDIC, circular/linear/hyperbolic
//
// Generalizes CORDIC_Engine_v1.v from ttsky-romless-cordic-engine. Same
// datapath: one micro-rotation per clock, DATA_WIDTH-bit registers (16 on
// silicon, 16+GUARD on Xcordic), arithmetic shift
// by the iteration index, no gain compensation. Added: direction select for
// vectoring, and the x-update sign for linear (none) and hyperbolic (+).
//
// In circular rotation mode with atan1 = 0x0758 this is bit-exact with the
// ttsky25a silicon (checked in model/check_vs_original.py).
//
// The ROM-less micro-angle generator runs one iteration ahead: its shift
// and angle for the next iteration are registered (q_shift, q_angle), so an
// iteration is only shift + add (100 MHz on sky130). Outputs are unchanged,
// cycle for cycle (F2).
//
// (GUARD > 0 only; GUARD = 0 stays bit-exact with silicon): dir = 3
// is a linear rotation that rounds x >> s instead of truncating it (the
// shifted-out bit is the adder's carry-in) and holds x, y, z once z is
// exactly 0. The core uses it for mac and mul: mul's worst error drops from
// 4.0 to 1.4 LSB. The specification changed with it (F2).
//
// The shift is formed two iterations ahead (n_s, with 3s and 5s), so
// the angle for the next iteration comes from registers through
// xcordic_aval only; iteration 0 is a plain select. Outputs unchanged (F2).
//
// For the gf180mcu slow corner at 25 MHz (in the earlier layout one
// iteration, sign -> add/sub select -> 20-bit ripple carry, was 9 ns short):
//   - x, y and z each compute both x + d and x - d with prefix adders
//     (xc_add.v) and the direction picks the sum after the adders, so the
//     sign no longer sits in front of the carry chain;
//   - the angle generator runs one stage deeper: the shifted series terms of
//     the next iteration are registered (t_a = 2^-s + x^5/5 + rounding bias,
//     t_b = x^3/3), formed from a shift held three iterations ahead, so the
//     angle register is loaded through one add and a select.
// Every register the run depends on (o_x, o_y, o_z, shift, angle) holds the
// value it held with the one-stage generator, cycle for cycle (F2).
`timescale 1ns/1ps
`default_nettype none

module xcordic_engine #(
    parameter DATA_WIDTH = 16,
    parameter N_PE = 13,       // circular iterations
    parameter N_LIN = N_PE,    // linear iterations (F+1 on the GUARD datapath: steps down to 1 LSB)
    parameter GUARD = 0        // DATA_WIDTH - 16 on Xcordic; selects the angle generator
)(
    input  wire                         i_clk,
    input  wire                         i_rst_n,
    input  wire                         i_start,
    input  wire [1:0]                   i_mode,     // 0 circ, 1 lin, 2 hyp
    input  wire [1:0]                   i_dir,      // 0 rotate (sign z), 1 vector (sign y), 2 divide,
                                                    // 3 rotate, product (linear: rounded, hold at z = 0)
    input  wire signed [DATA_WIDTH-1:0] i_x,
    input  wire signed [DATA_WIDTH-1:0] i_y,
    input  wire signed [DATA_WIDTH-1:0] i_z,
    input  wire [DATA_WIDTH-1:0]        i_atan0,
    input  wire [DATA_WIDTH-1:0]        i_atan1,
    input  wire [DATA_WIDTH-1:0]        i_atanh1,
    output reg  signed [DATA_WIDTH-1:0] o_x,
    output reg  signed [DATA_WIDTH-1:0] o_y,
    output reg  signed [DATA_WIDTH-1:0] o_z,
    output reg                          o_busy,
    output reg                          o_done
);
    localparam [1:0] M_CIRC = 2'd0, M_LIN = 2'd1, M_HYP = 2'd2;
    localparam [1:0] D_ROT = 2'd0, D_VEC = 2'd1, D_DIV = 2'd2, D_MUL = 2'd3;

    reg [1:0] mode, dir;
    reg [4:0] iter;
    // hyperbolic repeats shift 4, and shift 13 when it is reached (N_PE >= 14)
    localparam integer N_HYP = N_PE + 1 + ((N_PE >= 14) ? 1 : 0);
    wire [4:0] niter = (mode == M_HYP) ? N_HYP[4:0] : (mode == M_LIN) ? N_LIN[4:0] : N_PE[4:0];

    // angle generator. While busy in iteration i:
    //   shift = shift(i), angle = angle(i)          (used by this iteration)
    //   n_s = shift(i+1), t_* = terms of shift(i+1)  (angle(i+1) = t_a -/+ t_b)
    //   n2  = shift(i+2), with 3x and 5x it         (terms of iteration i+2)
    // At the accepting start: iteration 0's shift and angle are plain selects
    // (0 or atan0, 1 or 1.0, 1 or atanh1), and iterations 1 and 2 have the
    // constant shifts (1, 2) circular and linear, (2, 3) hyperbolic.
    localparam integer F_ONE = DATA_WIDTH - 4;
    localparam integer GX    = (GUARD > 0) ? 4 : 0;          // xcordic_aval's extra fraction bits
    localparam integer IW    = DATA_WIDTH + GX;
    wire [DATA_WIDTH-1:0] one_f = {{(DATA_WIDTH-1){1'b0}}, 1'b1} << F_ONE;
    wire [4:0]            s0 = (i_mode == M_HYP) ? 5'd1 : 5'd0;
    wire [DATA_WIDTH-1:0] a0 = (i_mode == M_HYP) ? i_atanh1 : (i_mode == M_LIN) ? one_f : i_atan0;
    wire [4:0]            s1 = (i_mode == M_HYP) ? 5'd2 : 5'd1;
    wire [4:0]            s2 = (i_mode == M_HYP) ? 5'd3 : 5'd2;

    wire [4:0] a_s;                              // shift of iteration iter + 3
    xcordic_ashift #(.N_PE(N_PE)) u_ash (.i_mode(mode), .i_iter(iter + 5'd3), .o_shift(a_s));

    reg  [4:0] shift, n_s, n2;
    reg  [7:0] n2_3, n2_5;
    reg  signed [DATA_WIDTH-1:0] angle;
    reg  [IW-1:0] t_a, t_b;                      // series terms of shift n_s
    // the terms of shift n2 (busy) or of s1 (accepting start)
    wire [4:0] ts  = o_busy ? n2 : s1;
    wire [7:0] ts3 = o_busy ? n2_3 : 8'd3 * {3'd0, s1};
    wire [7:0] ts5 = o_busy ? n2_5 : 8'd5 * {3'd0, s1};
    wire [IW-1:0] w_ta, w_tb;
    xcordic_aterms #(.DATA_WIDTH(DATA_WIDTH), .GUARD(GUARD)) u_at (
        .i_shift(ts), .i_s3(ts3), .i_s5(ts5), .o_ta(w_ta), .o_tb(w_tb));
    wire [DATA_WIDTH-1:0] v_angle;               // angle of shift n_s, from t_a, t_b
    xcordic_asum #(.DATA_WIDTH(DATA_WIDTH), .GUARD(GUARD)) u_as (
        .i_mode(mode), .i_shift(n_s), .i_ta(t_a), .i_tb(t_b),
        .i_atan0(i_atan0), .i_atan1(i_atan1), .i_atanh1(i_atanh1), .o_angle(v_angle));

    always @(posedge i_clk) begin
        shift <= o_busy ? n_s : s0;
        angle <= o_busy ? v_angle : a0;
        n_s   <= o_busy ? n2 : s1;
        t_a   <= w_ta;
        t_b   <= w_tb;
        n2    <= o_busy ? a_s : s2;
        n2_3  <= 8'd3 * {3'd0, (o_busy ? a_s : s2)};
        n2_5  <= 8'd5 * {3'd0, (o_busy ? a_s : s2)};
    end

    // sigma = +1 when pos
    wire pos = (dir == D_DIV) ? (o_y[DATA_WIDTH-1] ^ o_x[DATA_WIDTH-1]) :
               (dir == D_VEC) ?  o_y[DATA_WIDTH-1] :
                                ~o_z[DATA_WIDTH-1];

    // x >> shift with the last bit shifted out (the rounding bit)
    wire signed [DATA_WIDTH:0]   xs2 = $signed({o_x, 1'b0}) >>> shift;
    wire signed [DATA_WIDTH-1:0] xs = xs2[DATA_WIDTH:1];
    wire signed [DATA_WIDTH-1:0] ys = o_y >>> shift;
    // linear rotation: rounded shift, hold once z = 0
    localparam LROUND = (GUARD > 0);
    wire lin_rot = LROUND && (mode == M_LIN) && (dir == D_MUL);
    wire rbit    = lin_rot && xs2[0];
    wire zhold   = lin_rot && (o_z == {DATA_WIDTH{1'b0}});
    // y + sigma * (xs + rbit), rbit the carry-in; both signs, picked after the adders
    wire [DATA_WIDTH-1:0] y_p, y_m, x_p, x_m, z_p, z_m;
    xc_add #(.W(DATA_WIDTH)) u_yp (.a(o_y), .b(xs),     .ci(rbit),  .s(y_p));   // y + (xs + rbit)
    xc_add #(.W(DATA_WIDTH)) u_ym (.a(o_y), .b(~xs),    .ci(~rbit), .s(y_m));   // y - (xs + rbit)
    xc_add #(.W(DATA_WIDTH)) u_xp (.a(o_x), .b(ys),     .ci(1'b0),  .s(x_p));   // x + ys
    xc_add #(.W(DATA_WIDTH)) u_xm (.a(o_x), .b(~ys),    .ci(1'b1),  .s(x_m));   // x - ys
    xc_add #(.W(DATA_WIDTH)) u_zp (.a(o_z), .b(angle),  .ci(1'b0),  .s(z_p));   // z + angle
    xc_add #(.W(DATA_WIDTH)) u_zm (.a(o_z), .b(~angle), .ci(1'b1),  .s(z_m));   // z - angle

    always @(posedge i_clk) begin
        o_done <= 1'b0;
        if (!i_rst_n) begin
            o_busy <= 1'b0;
            iter <= 0;
            o_x <= 0; o_y <= 0; o_z <= 0;
        end else if (!o_busy) begin
            if (i_start) begin
                mode <= i_mode;
                dir <= i_dir;
                o_x <= i_x;
                o_y <= i_y;
                o_z <= i_z;
                iter <= 0;
                o_busy <= 1'b1;
            end
        end else begin
            case (mode)
                M_CIRC:  o_x <= pos ? x_m : x_p;
                M_HYP:   o_x <= pos ? x_p : x_m;
                default: o_x <= o_x;
            endcase
            if (!zhold) begin
                o_y <= pos ? y_p : y_m;
                o_z <= pos ? z_m : z_p;
            end
            iter <= iter + 5'd1;
            if (iter == niter - 1) begin
                o_busy <= 1'b0;
                o_done <= 1'b1;
            end
        end
    end
    // formal properties (formal/props), compiled only by the matching proof
`ifdef XC_FV_ENGINE
`include "xcordic_engine_props.vh"
`endif
endmodule

`default_nettype wire
