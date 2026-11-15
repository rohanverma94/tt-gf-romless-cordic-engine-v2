// xcordic_core_abstract.v — the core's start/busy/done contract, as a module.
//
// Replaces rtl/xcordic_core.v in the PCPI wrapper proof (F1) and the
// end-to-end proof (F8). F3a proves the real core keeps this contract:
//   - a start is accepted only when !busy
//   - cfg (funct7 = 0, funct3 = 7): done pulses in the next cycle, busy stays low
//   - any other instruction: busy from the next cycle; >= 2 busy cycles later
//     busy falls and done pulses in the same cycle
//   - rd and flags at done are arbitrary here (their values are F3's business)
// XC_CORE_MAX_LAT bounds the run length (for bounded-response properties).
`timescale 1ns/1ps
`default_nettype none

module xcordic_core #(
    parameter FUNCS = 1,
    parameter GUARD = 0
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire        start,
    input  wire [6:0]  funct7,
    input  wire [2:0]  funct3,
    input  wire [31:0] rs1,
    input  wire [31:0] rs2,
    output reg         busy,
    output reg         done,
    output reg  [31:0] rd,
    output reg  [1:0]  flags           // arbitrary, like rd
);
    (* anyseq *) wire        f_end;
    (* anyseq *) wire [31:0] f_rd;
    (* anyseq *) wire [1:0]  f_flags;
    reg [5:0] f_len;

`ifdef XC_CORE_MAX_LAT
    always @* if (busy && f_len >= `XC_CORE_MAX_LAT) assume(f_end);
`endif

    always @(posedge clk) begin
        done <= 1'b0;
        if (!rstn) begin
            busy <= 1'b0;
            f_len <= 6'd0;
        end else if (!busy) begin
            if (start) begin
                if (funct7 == 7'd0 && funct3 == 3'd7) begin
                    done <= 1'b1;
                    rd <= f_rd;
                    flags <= f_flags;
                end else begin
                    busy <= 1'b1;
                    f_len <= 6'd1;
                end
            end
        end else begin
            if (f_len != 6'h3f) f_len <= f_len + 6'd1;
            if (f_end && f_len >= 6'd2) begin
                busy <= 1'b0;
                done <= 1'b1;
                rd <= f_rd;
                flags <= f_flags;
            end
        end
    end
endmodule

`default_nettype wire
