// xc_exact_abstract.v — the exact unit's interface contract, as a module.
//
// Replaces src/xc_exact.v in the core proofs (F3a, F3b). Every behaviour of
// the real unit is a behaviour of this model (F6 proves the real unit keeps
// each item of the contract):
//   - a start is accepted only when !busy; busy is high from the next cycle
//   - the run lasts >= 1 busy cycles; it ends with busy falling and done
//     pulsing in the same cycle
//   - rd and flags at done are arbitrary, kept until the next accepted start
// So the core proof holds for every result the unit could return; that the
// unit returns the exact one is the exhaustive simulation's
// (formal/exhaustive/exact.cpp: every operand of mul, div and sqrt).
//
// XC_EXACT_MAX_LAT bounds the run length (used by the per-instruction BMC;
// F3a's stutter lemma covers longer runs).
`timescale 1ns/1ps
`default_nettype none

module xc_exact (
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire [1:0]  op,
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg         busy,
    output reg         done,
    output reg  [15:0] rd,
    output reg  [1:0]  flags
);
    (* anyseq *) wire        f_end;
    (* anyseq *) wire [15:0] f_rd;
    (* anyseq *) wire [1:0]  f_flags;
    reg [4:0] f_len;

`ifdef XC_EXACT_MAX_LAT
    always @* if (busy && f_len >= `XC_EXACT_MAX_LAT) assume(f_end);
`endif

    always @(posedge clk) begin
        done <= 1'b0;
        if (!rstn) begin
            busy <= 1'b0;
            rd <= 16'd0; flags <= 2'd0;
            f_len <= 5'd0;
        end else if (!busy) begin
            if (start) begin
                busy <= 1'b1;
                f_len <= 5'd1;
            end
        end else begin
            if (f_len != 5'h1f) f_len <= f_len + 5'd1;
            if (f_end) begin
                busy <= 1'b0;
                done <= 1'b1;
                rd <= f_rd;
                flags <= f_flags;
            end
        end
    end
endmodule

`default_nettype wire
