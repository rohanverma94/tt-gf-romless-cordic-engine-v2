// xcordic_engine_abstract.v — the engine's interface contract, as a module.
//
// Replaces rtl/xcordic_engine.v in the core proofs (F3a, F3b). Every behaviour
// of the real engine is a behaviour of this model (F2 proves the real engine
// keeps each item of the contract):
//   - a start is accepted only when !o_busy; o_busy is high from the next cycle
//   - the run lasts >= 1 busy cycles; it ends with o_busy falling and o_done
//     pulsing in the same cycle
//   - while busy, o_x/o_y/o_z may change arbitrarily; at the end they hold
//     arbitrary values, kept until the next accepted start
// So a proof against this model holds for every engine result.
//
// XC_ENGINE_MAX_LAT bounds the run length (used by the per-instruction BMC;
// the stutter lemma in F3a shows run length does not change core behaviour).
`timescale 1ns/1ps
`default_nettype none

module xcordic_engine #(
    parameter DATA_WIDTH = 16,
    parameter N_PE = 13,
    parameter N_LIN = N_PE,
    parameter GUARD = 0
)(
    input  wire                         i_clk,
    input  wire                         i_rst_n,
    input  wire                         i_start,
    input  wire [1:0]                   i_mode,
    input  wire [1:0]                   i_dir,
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
    (* anyseq *) wire f_end;
    (* anyseq *) wire signed [DATA_WIDTH-1:0] f_x, f_y, f_z;
    reg [3:0] f_len;

`ifdef XC_ENGINE_MAX_LAT
    always @* if (o_busy && f_len >= `XC_ENGINE_MAX_LAT) assume(f_end);
`endif

    always @(posedge i_clk) begin
        o_done <= 1'b0;
        if (!i_rst_n) begin
            o_busy <= 1'b0;
            o_x <= 0; o_y <= 0; o_z <= 0;
            f_len <= 0;
        end else if (!o_busy) begin
            if (i_start) begin
                o_busy <= 1'b1;
                f_len <= 4'd1;
            end
        end else begin
            o_x <= f_x; o_y <= f_y; o_z <= f_z;     // anything while busy, last value kept
            if (f_len != 4'hf) f_len <= f_len + 4'd1;
            if (f_end) begin
                o_busy <= 1'b0;
                o_done <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
