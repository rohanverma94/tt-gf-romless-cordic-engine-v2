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
// v0.7: the ROM-less micro-angle generator runs one iteration ahead: its shift
// and angle for the next iteration are registered (q_shift, q_angle), so an
// iteration is only shift + add (100 MHz on sky130). Outputs are unchanged,
// cycle for cycle (F2).
//
// v0.8 (GUARD > 0 only; GUARD = 0 stays bit-exact with silicon): dir = 3
// is a linear rotation that rounds x >> s instead of truncating it (the
// shifted-out bit is the adder's carry-in) and holds x, y, z once z is
// exactly 0. The core uses it for mac and mul: mul's worst error drops from
// 4.0 to 1.4 LSB. The specification changed with it (F2).
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

    // angle generator one iteration ahead: at the accepting start it forms
    // iteration 0 of the new run, while busy iteration iter + 1
    wire [1:0] g_mode = o_busy ? mode : i_mode;
    wire [4:0] g_iter = o_busy ? iter + 5'd1 : 5'd0;
    wire [4:0] g_shift;
    wire [DATA_WIDTH-1:0] g_angle;

    xcordic_atan #(.DATA_WIDTH(DATA_WIDTH), .N_PE(N_PE), .GUARD(GUARD)) u_atan (
        .i_mode(g_mode), .i_iter(g_iter),
        .i_atan0(i_atan0), .i_atan1(i_atan1), .i_atanh1(i_atanh1),
        .o_shift(g_shift), .o_angle(g_angle)
    );
    reg [4:0] shift;                             // for iteration iter
    reg signed [DATA_WIDTH-1:0] angle;
    always @(posedge i_clk) begin shift <= g_shift; angle <= g_angle; end

    // sigma = +1 when pos
    wire pos = (dir == D_DIV) ? (o_y[DATA_WIDTH-1] ^ o_x[DATA_WIDTH-1]) :
               (dir == D_VEC) ?  o_y[DATA_WIDTH-1] :
                                ~o_z[DATA_WIDTH-1];

    // x >> shift with the last bit shifted out (the rounding bit)
    wire signed [DATA_WIDTH:0]   xs2 = $signed({o_x, 1'b0}) >>> shift;
    wire signed [DATA_WIDTH-1:0] xs = xs2[DATA_WIDTH:1];
    wire signed [DATA_WIDTH-1:0] ys = o_y >>> shift;
    // v0.8 linear rotation: rounded shift, hold once z = 0
    localparam LROUND = (GUARD > 0);
    wire lin_rot = LROUND && (mode == M_LIN) && (dir == D_MUL);
    wire rbit    = lin_rot && xs2[0];
    wire zhold   = lin_rot && (o_z == {DATA_WIDTH{1'b0}});
    // y + sigma * (xs + rbit): one adder, rbit is the carry-in
    wire [DATA_WIDTH-1:0] y_opd = pos ? xs : ~xs;
    wire                  y_cin = pos ? rbit : ~rbit;
    wire [DATA_WIDTH-1:0] y_new = o_y + y_opd + {{(DATA_WIDTH-1){1'b0}}, y_cin};

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
                M_CIRC:  o_x <= pos ? o_x - ys : o_x + ys;
                M_HYP:   o_x <= pos ? o_x + ys : o_x - ys;
                default: o_x <= o_x;
            endcase
            if (!zhold) begin
                o_y <= y_new;
                o_z <= pos ? o_z - angle : o_z + angle;
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
