// xc_exact.v — exact mul, div and sqrt for Xcordic
//
// One small sequential unit with a single 20-bit adder/subtractor, one bit
// per cycle: shift-add multiply (16 steps), restoring divide (17 steps),
// digit-by-digit square root (15 steps). Operands and results are S3.12.
//
//   op 0  mul   a * b        = a*b / 4096
//   op 1  div   a / b        = a*4096 / b
//   op 2  sqrt  sqrt(a)      = sqrt(a*4096)
//
// Every result is the exact value rounded to nearest, ties up (toward +inf,
// as everywhere else in Xcordic), then saturated to [-8, 8): |error| <= 0.5 LSB.
// flags = {INV, SAT}:
//   SAT  the result was clipped to 0x7FFF / 0x8000
//   INV  invalid argument: div by 0 (result 0 for 0/0, else 0x7FFF / 0x8000
//        by the sign of a), sqrt of a < 0 (result 0x8000)
//
// Rounding from the magnitudes: with u = floor(2 |x|) and s = "2|x| is not an
// integer", round-half-up of x is  (u + 1) >> 1  for x >= 0 and
// -((u + s) >> 1)  for x < 0. mul: u = |a||b| >> 11, s = low 11 bits != 0.
// div: u = floor(|a| 2^13 / |b|), s = remainder != 0. sqrt: u = isqrt(a 2^14)
// (ties cannot occur). A divide with |a| >= 16 |b| overflows (|x| >= 2^16 LSB)
// and saturates without iterating.
//
// Contract (as xcordic_core's): a start is taken only when !busy; busy from
// the next cycle; done pulses for one cycle as busy falls, rd and flags valid
// then and held until the next start. Every register of the datapath is
// loaded from the operands, so a result depends only on (op, a, b) (F6).
// Latency: 21 cycles (mul), 22 (div), 20 (sqrt); 4 for the special cases.
`timescale 1ns/1ps
`default_nettype none

module xc_exact (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire [1:0]  op,          // 0 mul, 1 div, 2 sqrt
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg         busy,
    output reg         done,
    output reg  [15:0] rd,
    output reg  [1:0]  flags        // {INV, SAT}
`ifdef XC_FV_EXACT_MITER
  , output wire [95:0] fv_st        // F6b only: every register a run depends on
`endif
);
    localparam [1:0] X_MUL = 2'd0, X_DIV = 2'd1, X_SQRT = 2'd2;
    localparam [2:0] X_IDLE = 3'd0, X_ABS = 3'd1, X_CHK = 3'd2, X_ITER = 3'd3,
                     X_RND = 3'd4, X_OUT = 3'd5, X_END = 3'd6;

    reg [2:0]  st;
    reg [1:0]  xop;
    reg [15:0] ra, rb;              // operands as given
    reg        neg;                 // the result is negative
    reg [15:0] X;                   // mul: |a|; div: |b|; sqrt: a, two bits shifted out per step
    reg [16:0] Q;                   // mul: |b| -> low product; div: dividend bits -> quotient; sqrt: root
    reg [18:0] R;                   // mul: high product; div, sqrt: remainder; then the magnitude
    reg [4:0]  cnt;                 // steps left

    wire [15:0] abs_a = ra[15] ? 16'd0 - ra : ra;
    wire [15:0] abs_b = rb[15] ? 16'd0 - rb : rb;

    // ---------------- one step: the shared adder ----------------
    wire        is_mul = (xop == X_MUL);
    wire        is_div = (xop == X_DIV);
    wire [19:0] opa = is_mul ? {3'd0, R[16:0]} :
                      is_div ? {2'd0, R[16:0], Q[16]} :
                               {1'd0, R[16:0], X[15:14]};
    wire [19:0] opb = is_mul ? (Q[0] ? {4'd0, X} : 20'd0) :
                      is_div ? {4'd0, X} :
                               {1'd0, Q, 2'b01};
    wire [19:0] sum = is_mul ? opa + opb : opa - opb;
    wire        ge  = !sum[19];                     // div, sqrt: the trial subtraction fits

    // ---------------- rounding ----------------
    wire [19:0] u      = is_mul ? {R[14:0], Q[15:11]} : {3'd0, Q};
    wire        sticky = is_mul ? (Q[10:0] != 11'd0) : (R != 19'd0);
    wire        incr   = neg ? sticky : 1'b1;
    wire [20:0] u_inc  = {1'b0, u} + {20'd0, incr};
    wire [18:0] mag    = R;                         // after X_RND
    wire        sat    = neg ? (mag > 19'd32768) : (mag > 19'd32767);

    always @(posedge clk) begin
        done <= 1'b0;
        if (!rstn) begin
            // everything reset, so a gate-level simulation starts from known values
            st <= X_IDLE; busy <= 1'b0; rd <= 16'd0; flags <= 2'd0;
            xop <= 2'd0; ra <= 16'd0; rb <= 16'd0; neg <= 1'b0;
            X <= 16'd0; Q <= 17'd0; R <= 19'd0; cnt <= 5'd0;
        end else case (st)
            X_IDLE: if (start) begin
                xop <= op; ra <= a; rb <= b;
                busy <= 1'b1;
                st <= X_ABS;
            end

            // magnitudes and set-up; the special cases end here
            X_ABS: begin
                neg <= (xop != X_SQRT) && (ra[15] ^ rb[15]);
                R <= 19'd0;
                Q <= 17'd0;
                st <= X_CHK;
                case (xop)
                    X_MUL: begin
                        X <= abs_a;
                        Q <= {1'b0, abs_b};
                        cnt <= 5'd16;
                    end
                    X_DIV: begin
                        X <= abs_b;
                        R <= {7'd0, abs_a[15:4]};            // dividend bits above 2^17
                        Q <= {abs_a[3:0], 13'd0};            // the rest, shifted in step by step
                        cnt <= 5'd17;
                        if (rb == 16'd0) begin               // division by zero
                            rd <= (ra == 16'd0) ? 16'h0000 : ra[15] ? 16'h8000 : 16'h7fff;
                            flags <= 2'b10;
                            st <= X_END;
                        end
                    end
                    default: begin                           // X_SQRT
                        X <= ra;
                        cnt <= 5'd15;
                        if (ra[15]) begin                    // negative argument
                            rd <= 16'h8000;
                            flags <= 2'b10;
                            st <= X_END;
                        end
                    end
                endcase
            end

            // div: |a| >= 16 |b| overflows (quotient >= 2^17)
            X_CHK: begin
                if (is_div && (R[15:0] >= X)) begin
                    rd <= neg ? 16'h8000 : 16'h7fff;
                    flags <= 2'b01;
                    st <= X_END;
                end else
                    st <= X_ITER;
            end

            X_ITER: begin
                if (is_mul) begin
                    R <= {3'd0, sum[16:1]};
                    Q <= {1'b0, sum[0], Q[15:1]};
                end else if (is_div) begin
                    R <= ge ? {2'd0, sum[16:0]} : {2'd0, R[15:0], Q[16]};
                    Q <= {Q[15:0], ge};
                end else begin
                    R <= ge ? sum[18:0] : {R[16:0], X[15:14]};
                    Q <= {Q[15:0], ge};
                    X <= {X[13:0], 2'b00};
                end
                cnt <= cnt - 5'd1;
                if (cnt == 5'd1) st <= X_RND;
            end

            X_RND: begin
                R <= u_inc[19:1];
                st <= X_OUT;
            end

            X_OUT: begin
                rd <= sat ? (neg ? 16'h8000 : 16'h7fff) : (neg ? 16'd0 - mag[15:0] : mag[15:0]);
                flags <= {1'b0, sat};
                st <= X_END;
            end

            X_END: begin
                busy <= 1'b0;
                done <= 1'b1;
                st <= X_IDLE;
            end

            default: st <= X_IDLE;
        endcase
    end
    // formal properties (formal/props), compiled only by the matching proof
`ifdef XC_FV_EXACT
`include "xc_exact_props.vh"
`endif
endmodule

`default_nettype wire
