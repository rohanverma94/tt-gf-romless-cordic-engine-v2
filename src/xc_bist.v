// xc_bist.v — built-in self-test between the instruction source and the core.
//
// Transparent for every instruction except op 20 (funct7 = 2,
// funct3 = 4), cordic.bist:
//   rs1[15:0] = N, the number of instructions to run (0..65535)
//   rs2       = LFSR seed (0 is replaced by 1)
//   rd        = 32-bit signature
// It runs N instructions on the core, cycling through every legal op except
// cfg (FUNCS = 1: 0-6, 8-19; FUNCS = 0: 0-6), each with rs1 and rs2 drawn from
// a 32-bit Galois LFSR (mask 0x80200003, stepped once for rs1 and once for
// rs2), and folds every rd into a 32-bit MISR (same mask, starts at
// 0xFFFFFFFF):  misr = (misr >> 1 ^ (misr[0] ? 0x80200003 : 0)) ^ rd ^ flags << 30
// (the result flags {INV, SAT} go into bits 31:30).
// The core's cfg registers are used as they are (reset values after reset).
// host/pico_harness/xc_model.hpp computes the same signature (Model::exec).
//
// Contract to the instruction source: the core's own (start accepted when
// !busy; busy from the next cycle; done pulses as busy falls, at least 2
// busy cycles later). Proof: formal/props/xc_bist_props.vh (F5).
//
// Done, rd and flags to the instruction source come from registers, one
// cycle after the core's (or the self-test's) done; busy stays high for that
// cycle, so the contract holds with one cycle more latency. In the earlier layout
// the self-test state -> done/rd mux -> the frame's output-queue write was
// 2.7 ns short at the slow corner.
`timescale 1ns/1ps
`default_nettype none

module xc_bist #(
    parameter FUNCS = 1
)(
    input  wire        clk,
    input  wire        rst_n,
    // instruction source (xc_frame)
    input  wire        u_start,
    input  wire [6:0]  u_funct7,
    input  wire [2:0]  u_funct3,
    input  wire [31:0] u_rs1,
    input  wire [31:0] u_rs2,
    output wire        u_busy,
    output wire        u_done,
    output wire [31:0] u_rd,
    output wire [1:0]  u_flags,             // {INV, SAT}
    // core
    output wire        c_start,
    output wire [6:0]  c_funct7,
    output wire [2:0]  c_funct3,
    output wire [31:0] c_rs1,
    output wire [31:0] c_rs2,
    input  wire        c_busy,
    input  wire        c_done,
    input  wire [31:0] c_rd,
    input  wire [1:0]  c_flags
);
    localparam [31:0] MASK = 32'h80200003;
    localparam [4:0]  LAST = (FUNCS != 0) ? 5'd19 : 5'd6;
    localparam [1:0]  B_IDLE = 2'd0, B_GEN = 2'd1, B_RUN = 2'd2, B_END = 2'd3;

    function [31:0] lstep(input [31:0] v);
        lstep = (v >> 1) ^ (v[0] ? MASK : 32'd0);
    endfunction

    reg [1:0]  bs;
    reg [15:0] bn, bk;                      // count, done so far
    reg [31:0] lfsr, misr;
    reg [4:0]  bop;                         // next op
    reg [31:0] brs1, brs2;
    reg        bstart;                      // start pulse to the core
    reg        bdone;

    wire is_bist = (u_funct7 == 7'd2) && (u_funct3 == 3'd4);
    wire active  = (bs != B_IDLE);
    wire take    = u_start && !u_busy && is_bist;

    // the core sees the source unless a self-test runs
    assign c_start  = active ? bstart : (u_start && !is_bist);
    assign c_funct7 = active ? {5'd0, bop[4:3]} : u_funct7;
    assign c_funct3 = active ? bop[2:0]          : u_funct3;
    assign c_rs1    = active ? brs1 : u_rs1;
    assign c_rs2    = active ? brs2 : u_rs2;
    wire        done_c  = bdone || (c_done && !active);
    reg         done_q;
    reg  [31:0] rd_q;
    reg  [1:0]  flags_q;
    always @(posedge clk) begin
        if (!rst_n) begin done_q <= 1'b0; rd_q <= 32'd0; flags_q <= 2'd0; end
        else begin
            done_q <= done_c;
            if (done_c) begin rd_q <= bdone ? misr : c_rd; flags_q <= bdone ? 2'b00 : c_flags; end
        end
    end
    assign u_busy   = c_busy || active || done_c;
    assign u_done   = done_q;
    assign u_rd     = rd_q;
    assign u_flags  = flags_q;

    wire [31:0] l1 = lstep(lfsr);
    wire [31:0] l2 = lstep(l1);

    always @(posedge clk) begin
        bstart <= 1'b0;
        bdone  <= 1'b0;
        if (!rst_n) begin
            // all state reset, so a gate-level simulation starts from known
            // values (an unknown count stays unknown through "load 0" there)
            bs <= B_IDLE;
            bn <= 16'd0; bk <= 16'd0; bop <= 5'd0;
            lfsr <= 32'd1; misr <= 32'hFFFFFFFF;
            brs1 <= 32'd0; brs2 <= 32'd0;
        end else case (bs)
            B_IDLE: if (take) begin
                bn   <= u_rs1[15:0];
                bk   <= 16'd0;
                lfsr <= (u_rs2 == 32'd0) ? 32'd1 : u_rs2;
                misr <= 32'hFFFFFFFF;
                bop  <= 5'd0;
                bs   <= B_GEN;
            end
            B_GEN: begin
                if (bk == bn) begin
                    bs <= B_END;
                end else begin
                    brs1 <= l1;
                    brs2 <= l2;
                    lfsr <= l2;
                    bstart <= 1'b1;
                    bs <= B_RUN;
                end
            end
            B_RUN: if (c_done && !bstart) begin
                misr <= lstep(misr) ^ c_rd ^ {c_flags, 30'd0};   // flags too
                bk   <= bk + 16'd1;
                bop  <= (bop == 5'd6) ? ((FUNCS != 0) ? 5'd8 : 5'd0) :
                        (bop == LAST) ? 5'd0 : bop + 5'd1;
                bs   <= B_GEN;
            end
            default: begin                  // B_END: busy falls, done pulses
                bdone <= 1'b1;
                bs <= B_IDLE;
            end
        endcase
    end
    // formal properties (formal/props), compiled only by the matching proof
`ifdef XC_FV_BIST
`include "xc_bist_props.vh"
`endif
endmodule

`default_nettype wire
